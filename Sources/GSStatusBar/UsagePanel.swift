import SwiftUI
import UsageCore

/// The dropdown shown when clicking the menu bar item.
struct UsagePanel: View {
    @Bindable var store: UsageStore
    #if APP_STORE
    @State private var copiedClaudeCommand = false
    #endif

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
                VStack(alignment: .leading, spacing: 8) {
                    ProviderSection(provider: provider, snapshot: store.snapshot(for: provider),
                                    now: store.now, emptyHint: emptyHint(for: provider))
                    #if APP_STORE
                    if !store.isShowingSample { sourceControls(for: provider) }
                    #endif
                }
            }

            Divider()

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
                Button(store.isShowingSample ? "Hide Sample Data" : "Try Sample Data") {
                    store.toggleSampleData()
                }
                Button("Privacy Policy") { showPrivacyPolicy() }
                #endif
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            #if APP_STORE
            .controlSize(.small)
            #endif
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

    private func emptyHint(for provider: Provider) -> String {
        switch provider {
        case .claude:
            #if APP_STORE
            "Copy the command, run it in Terminal, then click Paste."
            #else
            "No data yet. Run scripts/install-claude-hook.sh, then it updates after each Claude Code reply, in the terminal or the Claude desktop app."
            #endif
        case .codex:
            #if APP_STORE
            store.codexFolderName == nil
                ? "Connect once to see your limits update automatically."
                : "Connected. Usage appears after your next Codex request."
            #else
            "No data yet. It appears after your next Codex request."
            #endif
        }
    }

    #if APP_STORE
    private func sourceControls(for provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch provider {
            case .codex:
                HStack {
                    if let folder = store.codexFolderName {
                        Button("Change Folder…") { store.chooseCodexFolder() }
                            .help("Connected to \(folder)")
                        Button("Disconnect") { store.disconnectCodexFolder() }
                    } else {
                        Button("Connect Codex…") { store.chooseCodexFolder() }
                    }
                }
                if let message = store.codexFolderError {
                    Text(message).foregroundStyle(.secondary)
                }
            case .claude:
                HStack {
                    Button(copiedClaudeCommand ? "Command Copied" : "Copy Command") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        copiedClaudeCommand = pasteboard.setString(StoreClaudeReport.copyCommand, forType: .string)
                    }
                    .help("Copy the Claude Code usage command to run in Terminal")
                    PasteButton(payloadType: String.self, onPaste: pasteClaudeUsage)
                        .accessibilityLabel("Paste Claude Usage")
                        .help("Paste copied Claude Code usage")
                    Menu {
                        Button("Import Report File…") {
                            copiedClaudeCommand = false
                            store.importClaudeReport()
                        }
                        if store.hasClaudeReport {
                            Button("Clear Report") { store.clearClaudeReport() }
                        }
                    } label: {
                        Label("Claude Report Options", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    if store.isImportingClaudeReport {
                        ProgressView().controlSize(.small)
                    }
                }
                .disabled(store.isImportingClaudeReport)
                if let message = store.claudeImportError {
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .controlSize(.small)
    }

    private func pasteClaudeUsage(_ values: [String]) {
        guard let text = values.first, !store.isImportingClaudeReport else { return }
        copiedClaudeCommand = false
        store.pasteClaudeReport(text)
    }

    private func showPrivacyPolicy() {
        let alert = NSAlert()
        alert.messageText = "GS Status Bar Privacy Policy"
        alert.informativeText = """
            GS Status Bar processes usage data on this Mac. It reads rate-limit fields from the Codex sessions folder you select and extracts limits from Claude reports you paste or import.

            The app saves your settings, folder permission, and parsed Claude usage summary locally. The original report and usage data stay on your Mac. Use Disconnect or Clear Report to remove the saved folder permission or Claude summary.
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
    let emptyHint: String

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
                    Text("updated \(Fmt.ago(snapshot.observedAt, now: now))" + (snapshot.mayBeBehind ? " · may be behind" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(snapshot.mayBeBehind
                              ? "Anthropic is limiting usage checks right now, so Claude Code returned a saved copy. It can be up to an hour old."
                              : snapshot.source)
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
