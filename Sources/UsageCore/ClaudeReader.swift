import Foundation

/// Reads Claude Code's rate-limit info saved by the status line bridge
/// (scripts/claude-statusline-bridge.sh).
///
/// Claude Code passes `rate_limits.five_hour` / `rate_limits.seven_day` to the status line command,
/// each with `used_percentage` (0-100) and `resets_at` (Unix seconds). The bridge writes
/// `{"rate_limits": {...}, "ts": <unix seconds>}` to claude.json.
public enum ClaudeReader {
    public static var defaultCacheFile: URL {
        AppPaths.supportDir.appendingPathComponent("claude.json")
    }

    /// The newest Claude numbers from either source: `/usage` output saved by the Stop hook,
    /// or rate limits saved by the status line bridge.
    public static func readLatest(statusLineFile: URL = defaultCacheFile,
                                  usageFile: URL = ClaudeUsageText.defaultFile) -> UsageSnapshot? {
        let candidates = [read(file: statusLineFile), ClaudeUsageText.read(file: usageFile)].compactMap { $0 }
        return candidates.max { $0.observedAt < $1.observedAt }
    }

    public static func read(file: URL = defaultCacheFile) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return parse(data, fallbackDate: modified)
    }

    public static func parse(_ data: Data, fallbackDate: Date? = nil) -> UsageSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = obj["rate_limits"] as? [String: Any]
        else { return nil }

        let observedAt = JSONValue.number(obj["ts"]).map { Date(timeIntervalSince1970: $0) }
            ?? fallbackDate ?? Date()

        let known: [(key: String, label: String, minutes: Int)] = [
            ("five_hour", "5-hour", 300),
            ("seven_day", "Weekly", 10080),
        ]
        var windows: [LimitWindow] = []
        for item in known {
            guard let w = limits[item.key] as? [String: Any],
                  let used = JSONValue.number(w["used_percentage"]) else { continue }
            windows.append(LimitWindow(
                key: item.key,
                label: item.label,
                usedPercent: used,
                resetsAt: JSONValue.number(w["resets_at"]).map { Date(timeIntervalSince1970: $0) },
                windowMinutes: item.minutes
            ))
        }
        guard !windows.isEmpty else { return nil }

        return UsageSnapshot(
            provider: .claude,
            windows: windows,
            observedAt: observedAt,
            source: "Claude Code status line",
            plan: nil
        )
    }
}
