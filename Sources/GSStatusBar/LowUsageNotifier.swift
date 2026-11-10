import Foundation
import UsageCore
import UserNotifications

/// Sends a notification when a window drops to 20% or 5% left, once per threshold per window cycle.
@MainActor
final class LowUsageNotifier {
    static let thresholds: [Double] = [20, 5]
    private let defaultsKey = "notifiedKeys"
    private var notified: [String]

    /// Notifications need a real .app bundle; `swift run` has none.
    var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init() {
        notified = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func check(_ snapshots: [UsageSnapshot], now: Date) {
        guard isAvailable else { return }
        for snapshot in snapshots {
            for window in snapshot.windows {
                let remaining = window.remainingPercent(at: now)
                let crossed = Self.thresholds.filter { remaining <= $0 }
                guard let lowest = crossed.min() else { continue }

                // Round the reset time to the hour so small jitter doesn't look like a new cycle.
                let cycle = window.resetsAt.map { String(Int($0.timeIntervalSince1970 / 3600)) } ?? "none"
                let keys = crossed.map { "\(snapshot.provider.rawValue).\(window.key).\(cycle).\(Int($0))" }
                let isNew = !notified.contains(keys[crossed.firstIndex(of: lowest)!])
                for key in keys where !notified.contains(key) { notified.append(key) }

                if isNew { send(snapshot.provider, window, remaining: remaining, now: now) }
            }
        }
        if notified.count > 100 { notified.removeFirst(notified.count - 100) }
        UserDefaults.standard.set(notified, forKey: defaultsKey)
    }

    private func send(_ provider: Provider, _ window: LimitWindow, remaining: Double, now: Date) {
        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName): \(Int(remaining.rounded()))% left"
        if let reset = window.resetsAt {
            content.body = "\(window.label) limit resets \(Fmt.resetTime(reset, now: now)) (in \(Fmt.countdown(to: reset, from: now)))."
        } else {
            content.body = "\(window.label) limit is running low."
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
