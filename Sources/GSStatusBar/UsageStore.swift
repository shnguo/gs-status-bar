import AppKit
import Observation
import ServiceManagement
import UsageCore

@MainActor
@Observable
final class UsageStore {
    var claude: UsageSnapshot?
    var codex: UsageSnapshot?
    /// Drives countdowns and "updated x ago" labels.
    var now = Date()

    var showClaude: Bool { didSet { defaults.set(showClaude, forKey: "showClaude") } }
    var showCodex: Bool { didSet { defaults.set(showCodex, forKey: "showCodex") } }
    var notifyLow: Bool {
        didSet {
            defaults.set(notifyLow, forKey: "notifyLow")
            if notifyLow { notifier.requestAuthorization() }
        }
    }
    private(set) var launchAtLogin = false
    private(set) var loginItemMessage: String?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let notifier = LowUsageNotifier()
    @ObservationIgnored private var watchers: [FileWatcher] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    /// False in snapshot mode, which must not run anything.
    @ObservationIgnored private var servicesStarted = false
    /// When Claude was last seen in use: its numbers changed, or a hook saved new ones.
    @ObservationIgnored private var lastClaudeActivity: Date?
    /// When the app last asked for Claude's numbers itself.
    @ObservationIgnored private var lastClaudePoll = Date.distantPast
    /// Rollout files that changed recently, newest first.
    @ObservationIgnored private var activeCodexFiles: [URL] = []

    var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var visibleProviders: [Provider] {
        Provider.allCases.filter { $0 == .claude ? showClaude : showCodex }
    }

    func snapshot(for provider: Provider) -> UsageSnapshot? {
        provider == .claude ? claude : codex
    }

    /// - Parameter startServices: false for snapshot mode (no file watching or notifications).
    init(startServices: Bool = true) {
        defaults.register(defaults: ["showClaude": true, "showCodex": true, "notifyLow": true])
        showClaude = defaults.bool(forKey: "showClaude")
        showCodex = defaults.bool(forKey: "showCodex")
        notifyLow = defaults.bool(forKey: "notifyLow")
        servicesStarted = startServices
        guard startServices else { return }

        try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
        if isBundledApp { launchAtLogin = SMAppService.mainApp.status == .enabled }
        if notifyLow { notifier.requestAuthorization() }

        startWatching()

        // Fallback refresh in case a file event is missed; also keeps countdowns moving.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollClaudeUsage()
                self?.refresh()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        refresh()
    }

    /// Re-reads both sources off the main thread. Calls that arrive close together are merged.
    func refresh() {
        pendingRefresh?.cancel()
        let hints = activeCodexFiles
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }

            let (claude, codex) = await Task.detached(priority: .utility) {
                (ClaudeReader.readLatest(), CodexReader.read(extraFiles: hints))
            }.value

            guard let self, !Task.isCancelled else { return }
            self.now = Date()
            // New numbers, or a save the app didn't ask for (a hook), mean Claude is in use.
            let numbersChanged = self.claude?.windows.map(\.usedPercent) != claude?.windows.map(\.usedPercent)
            let savedByHook = self.claude?.observedAt != claude?.observedAt
                && self.now.timeIntervalSince(self.lastClaudePoll) > 20
            if numbersChanged || savedByHook { self.lastClaudeActivity = self.now }
            if self.claude != claude { self.claude = claude }
            if self.codex != codex { self.codex = codex }
            if self.notifyLow {
                self.notifier.check([claude, codex].compactMap { $0 }, now: self.now)
            }
        }
    }

    /// Reads both sources synchronously, without notifications. Used by snapshot mode.
    func loadNow() {
        claude = ClaudeReader.readLatest()
        codex = CodexReader.read()
        now = Date()
    }

    /// The `/usage` number trails Claude's live one by a minute or two, and hooks only fire while
    /// Claude Code is working, so the last hook of a turn saves a number that's already behind.
    /// The app therefore also asks on its own: every 30 seconds for 10 minutes after Claude was
    /// last seen in use, then every 5 minutes.
    private func pollClaudeUsage() {
        let now = Date()
        let inUse = lastClaudeActivity.map { now.timeIntervalSince($0) < 600 } ?? false
        guard now.timeIntervalSince(lastClaudePoll) >= (inUse ? 25 : 295) else { return }
        lastClaudePoll = now
        fetchClaudeUsage(force: false)
    }

    /// Asks the Claude Code CLI for fresh numbers through the installed hook script.
    /// The script runs `/usage` in the background; the file watcher picks up the result.
    /// Without `force`, the script waits until 15 seconds after its last run.
    func fetchClaudeUsage(force: Bool) {
        let script = AppPaths.supportDir.appendingPathComponent("claude-usage-hook.sh")
        guard servicesStarted, showClaude, FileManager.default.fileExists(atPath: script.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path] + (force ? ["--force"] : [])
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard isBundledApp else {
            loginItemMessage = "Only available when running the built .app."
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemMessage = nil
        } catch {
            loginItemMessage = error.localizedDescription
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval {
            loginItemMessage = "Approve it in System Settings › General › Login Items."
        }
    }

    private func startWatching() {
        let sessionsDir = CodexReader.defaultSessionsDir.standardizedFileURL.path
        // If ~/.codex/sessions doesn't exist yet, watch the closest folder that does.
        let codexWatchPath = Self.closestExistingFolder(sessionsDir)
        if let watcher = FileWatcher(paths: [codexWatchPath], handler: { [weak self] paths in
            MainActor.assumeIsolated { self?.codexFilesChanged(paths, sessionsDir: sessionsDir) }
        }) {
            watchers.append(watcher)
        }

        let claudeFiles = [ClaudeReader.defaultCacheFile, ClaudeUsageText.defaultFile].map { "/" + $0.lastPathComponent }
        if let watcher = FileWatcher(paths: [AppPaths.supportDir.path], handler: { [weak self] paths in
            guard paths.contains(where: { path in claudeFiles.contains { path.hasSuffix($0) } }) else { return }
            MainActor.assumeIsolated { self?.refresh() }
        }) {
            watchers.append(watcher)
        }
    }

    private func codexFilesChanged(_ paths: [String], sessionsDir: String) {
        let rollouts = paths.filter {
            $0.hasPrefix(sessionsDir) && $0.hasSuffix(".jsonl") && $0.contains("/rollout-")
        }
        guard !rollouts.isEmpty else { return }
        for path in rollouts {
            let url = URL(fileURLWithPath: path)
            activeCodexFiles.removeAll { $0.path == url.path }
            activeCodexFiles.insert(url, at: 0)
        }
        activeCodexFiles = Array(activeCodexFiles.prefix(4))
        refresh()
    }

    private static func closestExistingFolder(_ path: String) -> String {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        return url.path
    }
}
