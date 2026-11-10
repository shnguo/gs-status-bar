import XCTest
@testable import UsageCore

final class CodexReaderTests: XCTestCase {
    /// Shape copied from a real Codex 0.166 session log.
    static func tokenCountLine(timestamp: String, used: Double, limitID: String = "codex") -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"total_tokens":12}},"rate_limits":{"limit_id":"\(limitID)","limit_name":null,"primary":{"used_percent":\(used),"window_minutes":10080,"resets_at":1794577445},"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"prolite","rate_limit_reached_type":null}}}
        """
    }

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testParsesTokenCountLine() throws {
        let line = Self.tokenCountLine(timestamp: "2026-11-09T08:58:53.361Z", used: 12)
        let parsed = try XCTUnwrap(CodexReader.parseLine(Data(line.utf8)))
        XCTAssertTrue(parsed.isMainLimit)
        let s = parsed.snapshot
        XCTAssertEqual(s.provider, .codex)
        XCTAssertEqual(s.plan, "prolite")
        XCTAssertEqual(s.windows.count, 1)
        XCTAssertEqual(s.windows[0].label, "Weekly")
        XCTAssertEqual(s.windows[0].usedPercent, 12)
        XCTAssertEqual(s.windows[0].resetsAt, Date(timeIntervalSince1970: 1794577445))
        XCTAssertEqual(s.observedAt.timeIntervalSince1970, 1794214733.361, accuracy: 0.01)
    }

    func testOlderResetsInSecondsFormat() throws {
        let line = """
        {"timestamp":"2026-01-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":40,"window_minutes":300,"resets_in_seconds":600},"secondary":{"used_percent":5,"window_minutes":10080,"resets_in_seconds":86400}}}}
        """
        let s = try XCTUnwrap(CodexReader.parseLine(Data(line.utf8))).snapshot
        XCTAssertEqual(s.windows.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(s.windows[0].resetsAt, s.observedAt.addingTimeInterval(600))
    }

    func testRejectsInvalidUsageAndDropsInvalidWindowMetadata() throws {
        let line = #"{"payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":"NaN"},"secondary":{"used_percent":5,"window_minutes":"Infinity","resets_at":1e30}}}}"#
        let windows = try XCTUnwrap(CodexReader.parseLine(Data(line.utf8))).snapshot.windows
        XCTAssertEqual(windows.map(\.key), ["secondary"])
        XCTAssertEqual(windows.first?.usedPercent, 5)
        XCTAssertNil(windows.first?.windowMinutes)
        XCTAssertNil(windows.first?.resetsAt)
    }

    func testIgnoresOtherEvents() {
        let lines = [
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"rate_limits"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#,
            "not json",
        ]
        for line in lines {
            XCTAssertNil(CodexReader.parseLine(Data(line.utf8)), line)
        }
    }

    func testFindsLastEventPastLargeLines() throws {
        let file = tempDir.appendingPathComponent("rollout-a.jsonl")
        let filler = #"{"type":"response_item","payload":{"text":""# + String(repeating: "x", count: 300_000) + #""}}"#
        let content = [
            Self.tokenCountLine(timestamp: "2026-11-09T08:00:00Z", used: 10),
            Self.tokenCountLine(timestamp: "2026-11-09T09:00:00Z", used: 30),
            filler,
            #"{"type":"event_msg","payload":{"type":"user_message"}}"#,
        ].joined(separator: "\n") + "\n"
        try content.write(to: file, atomically: true, encoding: .utf8)

        let s = try XCTUnwrap(CodexReader.lastSnapshot(in: file))
        XCTAssertEqual(s.windows[0].usedPercent, 30)
    }

    func testPrefersMainLimitOverOtherIDs() throws {
        let file = tempDir.appendingPathComponent("rollout-b.jsonl")
        let content = [
            Self.tokenCountLine(timestamp: "2026-11-09T08:00:00Z", used: 20),
            Self.tokenCountLine(timestamp: "2026-11-09T09:00:00Z", used: 70, limitID: "something_else"),
        ].joined(separator: "\n")
        try content.write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(try XCTUnwrap(CodexReader.lastSnapshot(in: file)).windows[0].usedPercent, 20)
    }

    func testReadPicksNewestEventAcrossFolders() throws {
        let fm = FileManager.default
        let oldDay = tempDir.appendingPathComponent("2026/11/07")
        let newDay = tempDir.appendingPathComponent("2026/11/09")
        try fm.createDirectory(at: oldDay, withIntermediateDirectories: true)
        try fm.createDirectory(at: newDay, withIntermediateDirectories: true)

        let newer = oldDay.appendingPathComponent("rollout-long-running.jsonl")
        let older = newDay.appendingPathComponent("rollout-new.jsonl")
        try Self.tokenCountLine(timestamp: "2026-11-09T10:00:00Z", used: 55).write(to: newer, atomically: true, encoding: .utf8)
        try Self.tokenCountLine(timestamp: "2026-11-09T07:00:00Z", used: 15).write(to: older, atomically: true, encoding: .utf8)
        try "not a session".write(to: newDay.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let s = try XCTUnwrap(CodexReader.read(sessionsDir: tempDir))
        XCTAssertEqual(s.windows[0].usedPercent, 55)
    }

    func testReadMissingFolder() {
        XCTAssertNil(CodexReader.read(sessionsDir: tempDir.appendingPathComponent("nope")))
    }
}

final class ClaudeReaderTests: XCTestCase {
    func testParsesBridgeOutput() throws {
        let json = #"{"rate_limits":{"five_hour":{"used_percentage":36.4,"resets_at":1794230000},"seven_day":{"used_percentage":19,"resets_at":1794600000}},"ts":1794214000.5}"#
        let s = try XCTUnwrap(ClaudeReader.parse(Data(json.utf8)))
        XCTAssertEqual(s.provider, .claude)
        XCTAssertEqual(s.windows.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(s.windows[0].usedPercent, 36.4)
        XCTAssertEqual(s.windows[1].resetsAt, Date(timeIntervalSince1970: 1794600000))
        XCTAssertEqual(s.observedAt, Date(timeIntervalSince1970: 1794214000.5))
    }

    func testOnlyOneWindowPresent() throws {
        let json = #"{"rate_limits":{"seven_day":{"used_percentage":50,"resets_at":1794600000}}}"#
        let fallback = Date(timeIntervalSince1970: 1_000)
        let s = try XCTUnwrap(ClaudeReader.parse(Data(json.utf8), fallbackDate: fallback))
        XCTAssertEqual(s.windows.map(\.key), ["seven_day"])
        XCTAssertEqual(s.observedAt, fallback)
    }

    func testNoRateLimits() {
        XCTAssertNil(ClaudeReader.parse(Data(#"{"rate_limits":{}}"#.utf8)))
        XCTAssertNil(ClaudeReader.parse(Data(#"{"ts":1}"#.utf8)))
    }
}

final class ClaudeUsageTextTests: XCTestCase {
    /// Shape copied from `claude -p "/usage"` output (Claude Code 2.1.321).
    static let sample = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 40% used · resets Nov 9 at 9:40pm (America/Los_Angeles)
    Current week (all models): 48% used · resets Nov 10 at 5pm (America/Los_Angeles)
    Current week (Fable): 10% used · resets Nov 10 at 5pm (America/Los_Angeles)

    What's contributing to your usage?
    Last 24h · 334 requests · 6 sessions
      54%  Start fresh when you switch tasks · run /clear
    """

    // 2026-11-09 17:00 PST
    let observed = Date(timeIntervalSince1970: 1_794_272_400)

    func testParsesUsageOutput() throws {
        let s = try XCTUnwrap(ClaudeUsageText.parse(Self.sample, observedAt: observed))
        XCTAssertEqual(s.provider, .claude)
        XCTAssertEqual(s.observedAt, observed)
        XCTAssertEqual(s.windows.map(\.key), ["five_hour", "seven_day", "seven_day_fable"])
        XCTAssertEqual(s.windows.map(\.label), ["5-hour", "Weekly", "Weekly · Fable"])
        XCTAssertEqual(s.windows.map(\.usedPercent), [40, 48, 10])
        // Nov 9 21:40 PST = 05:40 UTC Nov 10; Nov 10 17:00 PST = 01:00 UTC Nov 11.
        XCTAssertEqual(s.windows[0].resetsAt, Date(timeIntervalSince1970: 1_794_289_200))
        XCTAssertEqual(s.windows[1].resetsAt, Date(timeIntervalSince1970: 1_794_358_800))
        XCTAssertEqual(s.headlineWindow(at: observed)?.key, "five_hour")
    }

    func testResetFormats() {
        let la = "(America/Los_Angeles)"
        // Time only: today if still ahead, otherwise tomorrow.
        XCTAssertEqual(ClaudeUsageText.parseReset("9:40pm \(la)", now: observed), Date(timeIntervalSince1970: 1_794_289_200))
        XCTAssertEqual(ClaudeUsageText.parseReset("3pm \(la)", now: observed), Date(timeIntervalSince1970: 1_794_351_600))
        // Year rolls over when the date is far behind.
        let dec30 = Date(timeIntervalSince1970: 1_798_617_600) // 2026-12-30 00:00 PST
        XCTAssertEqual(ClaudeUsageText.parseReset("Jan 2 at 5am \(la)", now: dec30), Date(timeIntervalSince1970: 1_798_894_800))
        XCTAssertNil(ClaudeUsageText.parseReset("soon", now: observed))
    }

    /// Shape copied from `claude -p /usage --output-format stream-json --verbose` (Claude Code 2.1.321).
    static let streamOutput = #"""
    {"type":"system","subtype":"init","cwd":"/tmp"}
    {"type":"assistant","message":{"content":[{"type":"text","text":"Current session: 68% used · resets Nov 9 at 9:39pm (America/Los_Angeles)"}]},"usage_report":{"session":{"total_cost_usd":0},"rate_limits":{"limits":[{"kind":"session","group":"session","percent":68,"resets_at":"2026-11-10T05:39:59.516750+00:00","scope":null,"severity":"normal","is_active":true},{"kind":"weekly_all","group":"weekly","percent":51,"resets_at":"2026-11-11T00:59:59.516769+00:00","scope":null,"severity":"normal","is_active":false},{"kind":"weekly_scoped","group":"weekly","percent":15,"resets_at":"2026-11-11T00:59:59.517056+00:00","scope":{"model":{"display_name":"Fable"},"surface":null},"severity":"normal","is_active":false}],"extra_usage":{"is_enabled":true,"utilization":null}}}}
    {"type":"result","subtype":"success","result":"Current session: 68% used · resets Nov 9 at 9:39pm (America/Los_Angeles)"}
    """#

    func testParsesStructuredReport() throws {
        let s = try XCTUnwrap(ClaudeUsageText.parseOutput(Self.streamOutput, observedAt: observed))
        XCTAssertEqual(s.windows.map(\.key), ["five_hour", "seven_day", "seven_day_fable"])
        XCTAssertEqual(s.windows.map(\.label), ["5-hour", "Weekly", "Weekly · Fable"])
        XCTAssertEqual(s.windows.map(\.usedPercent), [68, 51, 15])
        XCTAssertEqual(try XCTUnwrap(s.windows[0].resetsAt).timeIntervalSince1970, 1_794_289_199.5, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(s.windows[1].resetsAt).timeIntervalSince1970, 1_794_358_799.5, accuracy: 1)
    }

    func testStreamOutputWithoutReportFallsBackToText() throws {
        let noReport = #"{"type":"result","subtype":"success","result":"Current session: 12% used · resets 9:40pm (America/Los_Angeles)"}"#
        let s = try XCTUnwrap(ClaudeUsageText.parseOutput(noReport, observedAt: observed))
        XCTAssertEqual(s.windows.map(\.usedPercent), [12])
        XCTAssertEqual(s.windows[0].resetsAt, Date(timeIntervalSince1970: 1_794_289_200))
    }

    func testIgnoresUnrelatedText() {
        XCTAssertNil(ClaudeUsageText.parse("Not logged in · Please run /login", observedAt: observed))
        XCTAssertNil(ClaudeUsageText.parse("  54%  Start fresh when you switch tasks", observedAt: observed))
    }

    func testImportsUsageTextAndStreamJSON() throws {
        let text = try XCTUnwrap(ClaudeUsageText.parseImportedReport(Data(Self.sample.utf8), fallbackDate: observed))
        XCTAssertEqual(text.observedAt, observed)
        XCTAssertEqual(text.windows[0].resetsAt, Date(timeIntervalSince1970: 1_794_289_200))

        let stream = try XCTUnwrap(ClaudeUsageText.parseImportedReport(Data(Self.streamOutput.utf8), fallbackDate: observed))
        XCTAssertEqual(stream.windows.map(\.usedPercent), [68, 51, 15])
    }

    func testImportsStandaloneStructuredJSON() throws {
        let report = """
        {
          "rate_limits": {
            "limits": [{"kind":"session","percent":25,"resets_at":"2026-11-10T05:40:00Z"}]
          }
        }
        """
        for json in [report, "{\"usage_report\":\(report)}"] {
            let snapshot = try XCTUnwrap(ClaudeUsageText.parseImportedReport(Data(json.utf8), fallbackDate: observed))
            XCTAssertEqual(snapshot.windows.map(\.usedPercent), [25])
            XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_794_289_200))
        }
    }

    func testImportsStatusLineJSONWithOriginalObservationTime() throws {
        let json = #"{"rate_limits":{"five_hour":{"used_percentage":36.4}},"ts":1794214000.5}"#
        let snapshot = try XCTUnwrap(ClaudeUsageText.parseImportedReport(Data(json.utf8), fallbackDate: observed))
        XCTAssertEqual(snapshot.observedAt, Date(timeIntervalSince1970: 1_794_214_000.5))
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [36.4])
    }

    func testRejectsInvalidImportedReports() {
        let invalidReports = [
            "Not logged in",
            #"{"rate_limits":{"five_hour":{"used_percentage":"nan"}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":"inf"}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":20}},"ts":"1e40"}"#,
        ]
        for report in invalidReports {
            XCTAssertNil(ClaudeUsageText.parseImportedReport(Data(report.utf8), fallbackDate: observed))
        }
    }

    func testReadLatestPicksNewerSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let statusLine = dir.appendingPathComponent("claude.json")
        let usage = dir.appendingPathComponent("claude-usage.txt")
        try #"{"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":1794220200}},"ts":1794271737}"#
            .write(to: statusLine, atomically: true, encoding: .utf8)
        try Self.sample.write(to: usage, atomically: true, encoding: .utf8)

        // The usage file was just written, so it's newer than the status line's ts.
        let latest = try XCTUnwrap(ClaudeReader.readLatest(statusLineFile: statusLine, usageFile: usage))
        XCTAssertEqual(latest.source, "Claude Code /usage")
        XCTAssertEqual(latest.windows.first?.usedPercent, 40)

        // Only the status line file present.
        try FileManager.default.removeItem(at: usage)
        XCTAssertEqual(ClaudeReader.readLatest(statusLineFile: statusLine, usageFile: usage)?.windows.first?.usedPercent, 24)
    }
}

final class ModelTests: XCTestCase {
    func testRemainingPercent() {
        let now = Date(timeIntervalSince1970: 1_000)
        let w = LimitWindow(key: "a", label: "5-hour", usedPercent: 64, resetsAt: now.addingTimeInterval(60), windowMinutes: 300)
        XCTAssertEqual(w.remainingPercent(at: now), 36)
        XCTAssertFalse(w.hasReset(at: now))

        // Once the reset time passes, the old number no longer applies.
        let later = now.addingTimeInterval(120)
        XCTAssertTrue(w.hasReset(at: later))
        XCTAssertEqual(w.remainingPercent(at: later), 100)

        let over = LimitWindow(key: "b", label: "x", usedPercent: 130, resetsAt: nil, windowMinutes: nil)
        XCTAssertEqual(over.remainingPercent(at: now), 0)
    }

    func testTightestWindow() {
        let now = Date()
        let s = UsageSnapshot(provider: .claude, windows: [
            LimitWindow(key: "five_hour", label: "5-hour", usedPercent: 20, resetsAt: nil, windowMinutes: 300),
            LimitWindow(key: "seven_day", label: "Weekly", usedPercent: 85, resetsAt: nil, windowMinutes: 10080),
        ], observedAt: now, source: "test", plan: nil)
        XCTAssertEqual(s.tightestWindow(at: now)?.key, "seven_day")
    }

    func testHeadlineWindow() {
        let now = Date()
        let windows = [
            LimitWindow(key: "five_hour", label: "5-hour", usedPercent: 20, resetsAt: nil, windowMinutes: 300),
            LimitWindow(key: "seven_day", label: "Weekly", usedPercent: 85, resetsAt: nil, windowMinutes: 10080),
        ]
        // Claude: the 5-hour limit even when the weekly one is tighter.
        let claude = UsageSnapshot(provider: .claude, windows: windows, observedAt: now, source: "test", plan: nil)
        XCTAssertEqual(claude.headlineWindow(at: now)?.key, "five_hour")

        // Claude without 5-hour data falls back to the tightest window.
        let weeklyOnly = UsageSnapshot(provider: .claude, windows: [windows[1]], observedAt: now, source: "test", plan: nil)
        XCTAssertEqual(weeklyOnly.headlineWindow(at: now)?.key, "seven_day")

        // Codex keeps using the tightest window.
        let codex = UsageSnapshot(provider: .codex, windows: windows, observedAt: now, source: "test", plan: nil)
        XCTAssertEqual(codex.headlineWindow(at: now)?.key, "seven_day")
    }

    func testLabels() {
        XCTAssertEqual(LimitWindow.label(forMinutes: 300), "5-hour")
        XCTAssertEqual(LimitWindow.label(forMinutes: 10080), "Weekly")
        XCTAssertEqual(LimitWindow.label(forMinutes: 120), "2-hour")
        XCTAssertEqual(LimitWindow.label(forMinutes: 2880), "2-day")
        XCTAssertEqual(LimitWindow.label(forMinutes: 45), "45-min")
        XCTAssertNil(LimitWindow.label(forMinutes: nil))
    }
}
