import SwiftUI
import UsageCore

/// The dropdown shown when clicking the menu bar item.
struct UsagePanel: View {
    @Bindable var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Usage limits").font(.headline)
                Spacer()
                Button {
                    store.fetchClaudeUsage(force: true)
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
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            store.fetchClaudeUsage(force: false)
            store.refresh()
        }
    }
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
            "No data yet. Run scripts/install-claude-hook.sh, then it updates after each Claude Code reply, in the terminal or the Claude desktop app."
        case .codex:
            "No data yet. It appears after your next Codex request."
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
