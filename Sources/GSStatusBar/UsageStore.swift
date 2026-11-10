import AppKit
import Observation
import ServiceManagement
#if APP_STORE
import UniformTypeIdentifiers
#endif
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
    #if APP_STORE
    private var codexFolder: StoreCodexFolder?
    private var sampleDate: Date?
    private(set) var codexFolderError: String?
    private(set) var claudeImportError: String?
    private(set) var isImportingClaudeReport = false

    var codexFolderName: String? { codexFolder?.url.lastPathComponent }
    var hasClaudeReport: Bool { claude != nil }
    var isShowingSample: Bool { sampleDate != nil }
    #else
    /// False in snapshot mode, which must not run anything.
    @ObservationIgnored private var servicesStarted = false
    /// When Claude was last seen in use: its numbers changed, or a hook saved new ones.
    @ObservationIgnored private var lastClaudeActivity: Date?
    /// When the app last asked for Claude's numbers itself.
    @ObservationIgnored private var lastClaudePoll = Date.distantPast
    #endif
    /// Rollout files that changed recently, newest first.
    @ObservationIgnored private var activeCodexFiles: [URL] = []

    var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var visibleProviders: [Provider] {
        Provider.allCases.filter { $0 == .claude ? showClaude : showCodex }
    }

    func snapshot(for provider: Provider) -> UsageSnapshot? {
        #if APP_STORE
        if let sampleDate { return Snapshot.sample(for: provider, at: sampleDate) }
        #endif
        return provider == .claude ? claude : codex
    }

    /// - Parameter startServices: false for snapshot mode (no file watching or notifications).
    init(startServices: Bool = true) {
        #if APP_STORE
        let notificationsDefault = false
        #else
        let notificationsDefault = true
        #endif
        defaults.register(defaults: ["showClaude": true, "showCodex": true, "notifyLow": notificationsDefault])
        showClaude = defaults.bool(forKey: "showClaude")
        showCodex = defaults.bool(forKey: "showCodex")
        notifyLow = defaults.bool(forKey: "notifyLow")
        #if !APP_STORE
        servicesStarted = startServices
        #endif
        guard startServices else { return }

        if isBundledApp { launchAtLogin = SMAppService.mainApp.status == .enabled }
        if notifyLow { notifier.requestAuthorization() }

        #if APP_STORE
        restoreStoreSources()
        #else
        try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
        startWatching()
        #endif

        // Fallback refresh in case a file event is missed; also keeps countdowns moving.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                #if !APP_STORE
                self?.pollClaudeUsage()
                #endif
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
        #if APP_STORE
        let folder = codexFolder
        #endif
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }

            #if APP_STORE
            let codex = await Task.detached(priority: .utility) { () -> UsageSnapshot? in
                guard let folder else { return nil }
                return withExtendedLifetime(folder) {
                    CodexReader.read(sessionsDir: folder.url, extraFiles: hints)
                }
            }.value

            guard let self, !Task.isCancelled else { return }
            self.now = Date()
            if self.codex != codex { self.codex = codex }
            #else
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
            #endif
            self.checkNotifications()
        }
    }

    private func checkNotifications() {
        #if APP_STORE
        guard !isShowingSample else { return }
        #endif
        if notifyLow {
            notifier.check([claude, codex].compactMap { $0 }, now: now)
        }
    }

    #if !APP_STORE
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
    #endif

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

    #if !APP_STORE
    private func startWatching() {
        let sessionsDir = CodexReader.defaultSessionsDir.standardizedFileURL.path
        // If ~/.codex/sessions doesn't exist yet, watch the closest folder that does.
        let codexWatchPath = Self.closestExistingFolder(sessionsDir)
        watchCodexFolder(at: codexWatchPath, sessionsDir: sessionsDir)

        let claudeFiles = [ClaudeReader.defaultCacheFile, ClaudeUsageText.defaultFile].map { "/" + $0.lastPathComponent }
        if let watcher = FileWatcher(paths: [AppPaths.supportDir.path], handler: { [weak self] paths in
            guard paths.contains(where: { path in claudeFiles.contains { path.hasSuffix($0) } }) else { return }
            MainActor.assumeIsolated { self?.refresh() }
        }) {
            watchers.append(watcher)
        }
    }

    private static func closestExistingFolder(_ path: String) -> String {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        return url.path
    }
    #endif

    private func watchCodexFolder(at path: String, sessionsDir: String) {
        if let watcher = FileWatcher(paths: [path], handler: { [weak self] paths in
            MainActor.assumeIsolated { self?.codexFilesChanged(paths, sessionsDir: sessionsDir) }
        }) {
            watchers.append(watcher)
        }
    }

    private func codexFilesChanged(_ paths: [String], sessionsDir: String) {
        let prefix = sessionsDir.hasSuffix("/") ? sessionsDir : sessionsDir + "/"
        let rollouts = paths.filter {
            $0.hasPrefix(prefix) && $0.hasSuffix(".jsonl") && $0.contains("/rollout-")
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

    #if APP_STORE
    private static let codexBookmarkKey = "codexSessionsBookmark"
    private static let claudeReportKey = "importedClaudeReport"

    func chooseCodexFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Codex Sessions Folder"
        panel.message = "Select your Codex sessions folder to allow read-only access."
        panel.prompt = "Connect"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = codexFolder?.url ?? Self.suggestedCodexSessionsFolder

        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            try connectCodexFolder(bookmark: StoreCodexFolder.bookmark(for: url))
            refresh()
        } catch {
            codexFolderError = "Couldn’t open this folder. Choose your Codex sessions folder again."
        }
    }

    private static var suggestedCodexSessionsFolder: URL? {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            return CodexReader.defaultSessionsDir
        }

        // Foundation resolves the current home to the app container in the sandbox.
        // Use the account home only to position the system picker.
        guard let accountHome = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: accountHome), isDirectory: true)
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func disconnectCodexFolder() {
        pendingRefresh?.cancel()
        watchers.removeAll()
        activeCodexFiles.removeAll()
        codexFolder = nil
        codex = nil
        codexFolderError = nil
        defaults.removeObject(forKey: Self.codexBookmarkKey)
    }

    func importClaudeReport() {
        let panel = NSOpenPanel()
        panel.title = "Import Claude Code Usage Report"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.plainText, .json, UTType(filenameExtension: "jsonl") ?? .text]

        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        loadClaudeReport { try StoreClaudeReport.readSelectedFile(url) }
    }

    func pasteClaudeReport(_ text: String) {
        loadClaudeReport { try StoreClaudeReport.readPastedText(text) }
    }

    private func loadClaudeReport(_ readReport: @escaping @Sendable () throws -> UsageSnapshot) {
        claudeImportError = nil
        isImportingClaudeReport = true
        Task {
            defer { isImportingClaudeReport = false }
            do {
                let report = try await Task.detached(priority: .userInitiated, operation: readReport).value
                defaults.set(try JSONEncoder().encode(report), forKey: Self.claudeReportKey)
                claude = report
                now = Date()
                checkNotifications()
            } catch {
                claudeImportError = error.localizedDescription
            }
        }
    }

    func clearClaudeReport() {
        claude = nil
        claudeImportError = nil
        defaults.removeObject(forKey: Self.claudeReportKey)
    }

    func toggleSampleData() {
        now = Date()
        sampleDate = isShowingSample ? nil : now
    }

    private func restoreStoreSources() {
        if let data = defaults.data(forKey: Self.claudeReportKey) {
            claude = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        }
        if let bookmark = defaults.data(forKey: Self.codexBookmarkKey) {
            do {
                try connectCodexFolder(bookmark: bookmark)
            } catch {
                defaults.removeObject(forKey: Self.codexBookmarkKey)
                codexFolderError = "Access to the saved folder expired. Choose your Codex sessions folder again."
            }
        }
    }

    private func connectCodexFolder(bookmark: Data) throws {
        let (folder, refreshedBookmark) = try StoreCodexFolder.resolve(bookmark)
        pendingRefresh?.cancel()
        watchers.removeAll()
        activeCodexFiles.removeAll()
        codex = nil
        codexFolder = folder
        codexFolderError = nil
        defaults.set(refreshedBookmark, forKey: Self.codexBookmarkKey)
        let path = folder.url.standardizedFileURL.path
        watchCodexFolder(at: path, sessionsDir: path)
    }
    #endif
}
