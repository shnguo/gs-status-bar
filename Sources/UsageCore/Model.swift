import Foundation

public enum Provider: String, CaseIterable, Sendable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Short glyph used in the menu bar.
    public var glyph: String {
        switch self {
        case .claude: "✳︎"
        case .codex: "◎"
        }
    }
}

/// One rate-limit window, e.g. Claude's 5-hour session limit or Codex's weekly limit.
public struct LimitWindow: Equatable, Sendable, Identifiable {
    /// Stable key from the source data ("five_hour", "primary", ...).
    public let key: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let windowMinutes: Int?

    public var id: String { key }

    public init(key: String, label: String, usedPercent: Double, resetsAt: Date?, windowMinutes: Int?) {
        self.key = key
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }

    /// True once the reset time has passed. The stored percentage is then out of date.
    public func hasReset(at now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    /// Percent of the limit still available. A window whose reset time has passed counts as full.
    public func remainingPercent(at now: Date) -> Double {
        if hasReset(at: now) { return 100 }
        return min(100, max(0, 100 - usedPercent))
    }

    public static func label(forMinutes minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        switch minutes {
        case 300: return "5-hour"
        case 1440: return "Daily"
        case 10080: return "Weekly"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
            if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
            return "\(minutes)-min"
        }
    }
}

/// The latest known usage for one provider.
public struct UsageSnapshot: Equatable, Sendable {
    public let provider: Provider
    public let windows: [LimitWindow]
    /// When the provider reported these numbers.
    public let observedAt: Date
    /// Human-readable description of where the data came from.
    public let source: String
    public let plan: String?

    public init(provider: Provider, windows: [LimitWindow], observedAt: Date, source: String, plan: String?) {
        self.provider = provider
        self.windows = windows
        self.observedAt = observedAt
        self.source = source
        self.plan = plan
    }

    /// The window shown in the menu bar: Claude's 5-hour limit when it's known, otherwise the tightest window.
    public func headlineWindow(at now: Date) -> LimitWindow? {
        if provider == .claude, let fiveHour = windows.first(where: { $0.key == "five_hour" }) {
            return fiveHour
        }
        return tightestWindow(at: now)
    }

    /// The window with the least room left, which is the one that will block you first.
    public func tightestWindow(at now: Date) -> LimitWindow? {
        windows.min { $0.remainingPercent(at: now) < $1.remainingPercent(at: now) }
    }
}

public enum AppPaths {
    /// ~/Library/Application Support/GSStatusBar
    public static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GSStatusBar", isDirectory: true)
    }
}

enum JSONValue {
    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func date(iso string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: string) { return d }
        // Microsecond timestamps ("05:39:59.516750+00:00"): drop the fraction and retry.
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return trimmed == string ? nil : f.date(from: trimmed)
    }
}
