import AppKit
import SwiftUI

enum Fmt {
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "2d 4h", "1h 42m", "12m"
    static func countdown(to date: Date, from now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    /// "3:20 PM" today, otherwise "Thu 3:20 PM".
    static func resetTime(_ date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

/// Warning levels for "% left".
enum Level {
    case normal, low, critical

    init(remaining: Double) {
        switch remaining {
        case ..<10: self = .critical
        case ..<30: self = .low
        default: self = .normal
        }
    }

    var nsColor: NSColor? {
        switch self {
        case .normal: nil
        case .low: .systemOrange
        case .critical: .systemRed
        }
    }

    var barColor: Color {
        switch self {
        case .normal: .green
        case .low: .orange
        case .critical: .red
        }
    }

    var textColor: Color {
        switch self {
        case .normal: .primary
        case .low: .orange
        case .critical: .red
        }
    }
}
