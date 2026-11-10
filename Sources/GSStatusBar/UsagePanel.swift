import SwiftUI
import UsageCore

/// The dropdown shown when clicking the menu bar item.
struct UsagePanel: View {
    @Bindable var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Usage limits").font(.headline)
                #if APP_STORE
                if store.isShowingSample {
                    Text("Sample data").font(.caption).foregroundStyle(.secondary)
                }
                #endif
                Spacer()
                Button {
                    #if !APP_STORE
                    store.fetchClaudeUsage(force: true)
                    #endif
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }

            if store.visibleProviders.isEmpty {
                Text("Both providers are hidden.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(store.visibleProviders) { provider in
                ProviderSection(provider: provider, snapshot: store.snapshot(for: provider), now: store.now)
            }

            Divider()

            #if APP_STORE
            storeSources
            Divider()
            #endif

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show Claude Code", isOn: $store.showClaude)
                Toggle("Show Codex", isOn: $store.showCodex)
                Toggle("Notify at 20% and 5% left", isOn: $store.notifyLow)
                Toggle("Launch at login", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                ))
                if let message = store.loginItemMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .font(.callout)

            Divider()

            HStack {
                #if APP_STORE
                Button(store.isShowingSample ? "Hide Sample Data" : "Show Sample Data") {
                    store.toggleSampleData()
                }
                Button("Privacy Policy") { showPrivacyPolicy() }
                #endif
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            #if !APP_STORE
            store.fetchClaudeUsage(force: false)
            #endif
            store.refresh()
        }
    }

    #if APP_STORE
    private var storeSources: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(store.codexFolderName == nil ? "Choose Codex Folder…" : "Change Folder…") {
                    store.chooseCodexFolder()
                }
                if let folder = store.codexFolderName {
                    Text(folder).lineLimit(1).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Disconnect") { store.disconnectCodexFolder() }
                }
            }
            if let message = store.codexFolderError {
                Text(message).foregroundStyle(.secondary)
            }
            HStack {
                Button("Import Claude Report…") { store.importClaudeReport() }
                    .disabled(store.isImportingClaudeReport)
                if store.isImportingClaudeReport {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
                if store.hasClaudeReport {
                    Button("Clear Report") { store.clearClaudeReport() }
                        .disabled(store.isImportingClaudeReport)
                }
            }
            if let message = store.claudeImportError {
                Text(message).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func showPrivacyPolicy() {
        let alert = NSAlert()
        alert.messageText = "GS Status Bar Privacy Policy"
        alert.informativeText = """
            GS Status Bar processes usage data on this Mac. It reads Codex session files from the folder you select to extract rate-limit fields, and extracts usage limits from Claude reports you import.

            The app saves your settings, folder permission, and parsed Claude usage summary locally. It does not store a copy of the imported report or send this data anywhere. Use Disconnect or Clear Report to remove the saved folder permission or Claude summary.
            """
        alert.addButton(withTitle: "Done")
        let policy = (Bundle.main.object(forInfoDictionaryKey: "GSPrivacyPolicyURL") as? String)
            .flatMap { URL(string: $0) }
            .flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
        if policy != nil { alert.addButton(withTitle: "Open Privacy Policy") }

        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn, let policy {
            NSWorkspace.shared.open(policy)
        }
    }
    #endif
}

private struct ProviderSection: View {
    let provider: Provider
    let snapshot: UsageSnapshot?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(provider.glyph)
                Text(provider.displayName).fontWeight(.semibold)
                if let plan = snapshot?.plan {
                    Text(plan)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if let snapshot {
                    Text("updated \(Fmt.ago(snapshot.observedAt, now: now))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(snapshot.source)
                }
            }

            if let snapshot {
                ForEach(snapshot.windows) { window in
                    WindowRow(window: window, now: now)
                }
            } else {
                Text(emptyHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyHint: String {
        switch provider {
        case .claude:
            #if APP_STORE
            "Import a Claude Code usage report to see your limits here."
            #else
            "No data yet. Run scripts/install-claude-hook.sh, then it updates after each Claude Code reply, in the terminal or the Claude desktop app."
            #endif
        case .codex:
            #if APP_STORE
            "Choose your Codex sessions folder. Usage appears after a Codex request."
            #else
            "No data yet. It appears after your next Codex request."
            #endif
        }
    }
}

private struct WindowRow: View {
    let window: LimitWindow
    let now: Date

    var body: some View {
        let remaining = window.remainingPercent(at: now)
        let level = Level(remaining: remaining)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                Spacer()
                Text("\(Fmt.percent(remaining)) left")
                    .monospacedDigit()
                    .fontWeight(.medium)
                    .foregroundStyle(level.textColor)
            }
            .font(.callout)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(level.barColor)
                        .frame(width: geo.size.width * remaining / 100)
                }
            }
            .frame(height: 6)

            Text(resetText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var resetText: String {
        guard let reset = window.resetsAt else { return "Reset time unknown" }
        if window.hasReset(at: now) {
            return "Reset at \(Fmt.resetTime(reset, now: now)), waiting for new data"
        }
        return "Resets \(Fmt.resetTime(reset, now: now)) · in \(Fmt.countdown(to: reset, from: now))"
    }
}
