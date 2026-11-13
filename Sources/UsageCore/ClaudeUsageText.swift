import Foundation

/// Reads the output of Claude Code's `/usage` command, saved by scripts/claude-usage-hook.sh.
///
/// The lines it reads look like:
///
///     Current session: 40% used · resets Nov 9 at 9:40pm (America/Los_Angeles)
///     Current week (all models): 48% used · resets Nov 10 at 5pm (America/Los_Angeles)
///     Current week (Fable): 10% used · resets Nov 10 at 5pm (America/Los_Angeles)
///
/// This is display text, not a stable format, so anything unrecognized is skipped.
/// The hook saves `claude -p /usage --output-format stream-json` output, whose `usage_report`
/// holds the same numbers in structured form; that's preferred, and the text is the fallback.
public enum ClaudeUsageText {
    public static var defaultFile: URL {
        AppPaths.supportDir.appendingPathComponent("claude-usage.jsonl")
    }

    /// The saved file's modification time is when the numbers were fetched.
    public static func read(file: URL = defaultFile) -> UsageSnapshot? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return parseOutput(text, observedAt: modified)
    }

    /// Imports a status-line JSON report, structured usage JSON, stream-json, or plain usage text.
    /// Use the file's modification date for reports without a timestamp, especially when text omits a reset date or year.
    public static func parseImportedReport(_ data: Data, fallbackDate: Date = Date()) -> UsageSnapshot? {
        let snapshot = ClaudeReader.parse(data, fallbackDate: fallbackDate)
            ?? parseImportedJSON(data, observedAt: fallbackDate)
            ?? String(data: data, encoding: .utf8).flatMap { parseOutput($0, observedAt: fallbackDate) }

        let supportedDates = Date.distantPast...Date.distantFuture
        guard let snapshot, supportedDates.contains(snapshot.observedAt),
              snapshot.windows.allSatisfy({ window in
                  window.usedPercent.isFinite && (window.resetsAt.map(supportedDates.contains) ?? true)
              }) else { return nil }
        return snapshot
    }

    private static func parseImportedJSON(_ data: Data, observedAt: Date) -> UsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let report = object["usage_report"] as? [String: Any] ?? object
        return parseReport(report, observedAt: observedAt)
            ?? (object["result"] as? String).flatMap { parse($0, observedAt: observedAt) }
    }

    /// Accepts stream-json lines (structured report, else the text inside them) or plain text.
    public static func parseOutput(_ output: String, observedAt: Date) -> UsageSnapshot? {
        var texts: [String] = []
        var savedCopy = false
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("{"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            if let report = obj["usage_report"] as? [String: Any] {
                if let snapshot = parseReport(report, observedAt: observedAt) { return snapshot }
                // A report without limits: Anthropic refused the check, and the text holds
                // Claude Code's saved copy of the numbers.
                savedCopy = true
            }
            if let result = obj["result"] as? String { texts.append(result) }
        }
        var snapshot = parse(texts.isEmpty ? output : texts.joined(separator: "\n"), observedAt: observedAt)
        snapshot?.mayBeBehind = savedCopy
        return snapshot
    }

    /// `usage_report.rate_limits.limits`: `[{kind, group, percent, resets_at, scope}]`.
    static func parseReport(_ report: [String: Any], observedAt: Date) -> UsageSnapshot? {
        guard let rateLimits = report["rate_limits"] as? [String: Any],
              let limits = rateLimits["limits"] as? [[String: Any]] else { return nil }
        var windows: [LimitWindow] = []
        for limit in limits {
            guard let kind = limit["kind"] as? String, let used = JSONValue.number(limit["percent"]) else { continue }
            let group = (limit["group"] as? String) ?? ""
            let resetsAt = (limit["resets_at"] as? String).flatMap(JSONValue.date(iso:))
            let scopeName = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String

            let key: String, label: String, minutes: Int?
            switch (kind, group) {
            case ("session", _):
                (key, label, minutes) = ("five_hour", "5-hour", 300)
            case ("weekly_all", _):
                (key, label, minutes) = ("seven_day", "Weekly", 10080)
            case (_, "weekly"):
                let name = scopeName ?? kind.replacingOccurrences(of: "weekly_", with: "").capitalized
                (key, label, minutes) = (weeklyKey(for: name), "Weekly · \(name)", 10080)
            default:
                (key, label, minutes) = (kind, kind.replacingOccurrences(of: "_", with: " ").capitalized, nil)
            }
            guard !windows.contains(where: { $0.key == key }) else { continue }
            windows.append(LimitWindow(key: key, label: label, usedPercent: used, resetsAt: resetsAt, windowMinutes: minutes))
        }
        guard !windows.isEmpty else { return nil }
        return UsageSnapshot(provider: .claude, windows: windows, observedAt: observedAt,
                             source: "Claude Code /usage", plan: nil)
    }

    static func weeklyKey(for name: String) -> String {
        "seven_day_" + name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }

    public static func parse(_ text: String, observedAt: Date) -> UsageSnapshot? {
        var windows: [LimitWindow] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if let window = parseLine(String(line), now: observedAt),
               !windows.contains(where: { $0.key == window.key }) {
                windows.append(window)
            }
        }
        guard !windows.isEmpty else { return nil }
        return UsageSnapshot(provider: .claude, windows: windows, observedAt: observedAt,
                             source: "Claude Code /usage", plan: nil)
    }

    // "Current <session|week>[ (<scope>)]: <n>% used[ · resets <when>]"
    private static let linePattern = try! NSRegularExpression(
        pattern: #"^\s*Current (session|week)(?: \(([^)]*)\))?:\s*(\d+(?:\.\d+)?)%\s*used(?:\s*·\s*resets\s+(.+?))?\s*$"#,
        options: [.caseInsensitive]
    )

    static func parseLine(_ line: String, now: Date) -> LimitWindow? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = linePattern.firstMatch(in: line, range: range) else { return nil }
        func group(_ i: Int) -> String? {
            Range(m.range(at: i), in: line).map { String(line[$0]) }
        }
        guard let kind = group(1)?.lowercased(), let used = group(3).flatMap(Double.init) else { return nil }
        let scope = group(2)?.trimmingCharacters(in: .whitespaces)
        let resetsAt = group(4).flatMap { parseReset($0, now: now) }

        if kind == "session" {
            return LimitWindow(key: "five_hour", label: "5-hour", usedPercent: used, resetsAt: resetsAt, windowMinutes: 300)
        }
        if let scope, !scope.isEmpty, scope.lowercased() != "all models" {
            return LimitWindow(key: weeklyKey(for: scope), label: "Weekly · \(scope)", usedPercent: used,
                               resetsAt: resetsAt, windowMinutes: 10080)
        }
        return LimitWindow(key: "seven_day", label: "Weekly", usedPercent: used, resetsAt: resetsAt, windowMinutes: 10080)
    }

    /// Parses "Nov 9 at 9:40pm (America/Los_Angeles)", "5pm (UTC)", "Nov 10" and similar.
    /// A missing year or date is filled in so the result is the next matching time after `now`.
    static func parseReset(_ raw: String, now: Date) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var timeZone = TimeZone.current
        if let open = text.lastIndex(of: "("), text.hasSuffix(")") {
            let name = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            if let tz = TimeZone(identifier: name) ?? TimeZone(abbreviation: name) { timeZone = tz }
            text = text[..<open].trimmingCharacters(in: .whitespaces)
        }
        text = text.replacingOccurrences(of: " at ", with: " ")
            .replacingOccurrences(of: "am", with: "AM")
            .replacingOccurrences(of: "pm", with: "PM")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.defaultDate = now

        let withYear = ["MMM d, yyyy h:mma", "MMM d, yyyy ha", "MMM d yyyy h:mma", "MMM d yyyy ha", "MMM d, yyyy"]
        for format in withYear {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let withDate = ["MMM d h:mma", "MMM d ha", "MMM d"]
        for format in withDate {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                // No year given: a date well before now means next year (e.g. "Jan 2" seen on Dec 30).
                if date < now.addingTimeInterval(-2 * 86400) {
                    return calendar.date(byAdding: .year, value: 1, to: date)
                }
                return date
            }
        }
        let timeOnly = ["h:mma", "ha"]
        for format in timeOnly {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                // No date given: today, or tomorrow if that time has passed.
                return date < now.addingTimeInterval(-60) ? calendar.date(byAdding: .day, value: 1, to: date) : date
            }
        }
        return nil
    }
}
