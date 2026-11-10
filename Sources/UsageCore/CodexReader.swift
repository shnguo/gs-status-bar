import Foundation

/// Reads Codex's rate-limit info from its session logs.
///
/// Every Codex request appends a `token_count` event to
/// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, and that event carries `rate_limits`.
public enum CodexReader {
    public static var defaultSessionsDir: URL {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return codexHome.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Returns the newest rate-limit snapshot across recent session files.
    /// - Parameter extraFiles: files known to have changed recently (from file events). A long-running
    ///   session keeps writing to the folder of the day it started, so it may not be among the newest folders.
    public static func read(
        sessionsDir: URL = defaultSessionsDir,
        extraFiles: [URL] = [],
        maxFiles: Int = 6
    ) -> UsageSnapshot? {
        var files = recentRolloutFiles(in: sessionsDir, limit: maxFiles)
        let known = Set(files.map(\.standardizedFileURL.path))
        for file in extraFiles where !known.contains(file.standardizedFileURL.path) {
            files.append(file)
        }

        var best: UsageSnapshot?
        for file in files {
            guard let snapshot = lastSnapshot(in: file) else { continue }
            if best == nil || snapshot.observedAt > best!.observedAt {
                best = snapshot
            }
        }
        return best
    }

    /// The most recently modified rollout files, looking only in the newest date folders.
    static func recentRolloutFiles(in root: URL, limit: Int) -> [URL] {
        let fm = FileManager.default

        func subdirectories(_ url: URL) -> [URL] {
            let items = (try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            return items
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }

        var files: [URL] = []
        var dayFoldersSeen = 0
        outer: for year in subdirectories(root) {
            for month in subdirectories(year) {
                for day in subdirectories(month) {
                    let items = (try? fm.contentsOfDirectory(
                        at: day, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
                    )) ?? []
                    files += items.filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
                    dayFoldersSeen += 1
                    if files.count >= limit && dayFoldersSeen >= 2 { break outer }
                }
            }
        }

        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return Array(files.sorted { modified($0) > modified($1) }.prefix(limit))
    }

    /// Finds the last rate-limit event in a file, reading backwards from the end so large logs stay cheap.
    static func lastSnapshot(in file: URL) -> UsageSnapshot? {
        let file = file.resolvingSymlinksInPath()
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }

        let marker = Data("\"rate_limits\"".utf8)
        var chunk: UInt64 = 128 * 1024
        let maxChunk: UInt64 = 32 * 1024 * 1024

        while true {
            let start = size > chunk ? size - chunk : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.read(upToCount: Int(size - start)) else { return nil }

            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            // The first line is probably cut off unless we started at the top of the file.
            if start > 0, !lines.isEmpty { lines.removeFirst() }

            var fallback: UsageSnapshot?
            for line in lines.reversed() where line.range(of: marker) != nil {
                guard let parsed = parseLine(Data(line)) else { continue }
                if parsed.isMainLimit { return parsed.snapshot }
                if fallback == nil { fallback = parsed.snapshot }
            }
            if let fallback { return fallback }

            if start == 0 || chunk >= maxChunk { return nil }
            chunk *= 4
        }
    }

    struct ParsedLine {
        let snapshot: UsageSnapshot
        /// Codex labels its general limit "codex". Other ids (if any appear) are only used as a fallback.
        let isMainLimit: Bool
    }

    static func parseLine(_ data: Data) -> ParsedLine? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any]
        else { return nil }

        let supportedDates = Date.distantPast...Date.distantFuture
        let timestamp = (obj["timestamp"] as? String).flatMap(JSONValue.date(iso:))
        let observedAt = timestamp.flatMap { supportedDates.contains($0) ? $0 : nil } ?? Date()

        var windows: [LimitWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any],
                  let used = JSONValue.number(w["used_percent"]), used.isFinite else { continue }
            let minutes = JSONValue.number(w["window_minutes"]).flatMap { Int(exactly: $0.rounded(.towardZero)) }
            var resetsAt = JSONValue.number(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            if resetsAt == nil, let seconds = JSONValue.number(w["resets_in_seconds"]) {
                // Older Codex versions reported a countdown instead of a timestamp.
                resetsAt = observedAt.addingTimeInterval(seconds)
            }
            if let reset = resetsAt, !supportedDates.contains(reset) { resetsAt = nil }
            windows.append(LimitWindow(
                key: key,
                label: LimitWindow.label(forMinutes: minutes) ?? key.capitalized,
                usedPercent: used,
                resetsAt: resetsAt,
                windowMinutes: minutes
            ))
        }
        guard !windows.isEmpty else { return nil }

        let limitID = limits["limit_id"] as? String
        let snapshot = UsageSnapshot(
            provider: .codex,
            windows: windows,
            observedAt: observedAt,
            source: "Codex session log",
            plan: limits["plan_type"] as? String
        )
        return ParsedLine(snapshot: snapshot, isMainLimit: limitID == nil || limitID == "codex")
    }
}
