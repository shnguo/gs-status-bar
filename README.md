# GS Status Bar

A macOS menu bar app that shows how much of your Claude Code and Codex usage limits is left,
for example `✳︎ 64%  ◎ 88%` (✳︎ = Claude Code, ◎ = Codex). Claude's number is its 5-hour limit;
Codex's is its tightest limit. Click it for every window, reset times, and settings.

## Where the numbers come from

| Tool | Source | Updates when |
|---|---|---|
| Codex | `token_count` events in `~/.codex/sessions/**/rollout-*.jsonl` | after every Codex request |
| Claude Code | `claude -p /usage` output, saved by the hook `scripts/claude-usage-hook.sh` (Stop and PostToolUse) to `~/Library/Application Support/GSStatusBar/claude-usage.jsonl` | after every Claude Code reply and tool step, at most every 15 seconds, in the terminal or the Claude desktop app; also when you open the dropdown or click refresh |
| Claude Code (fallback) | `rate_limits` passed to the status line, saved by `scripts/claude-statusline-bridge.sh` to `claude.json` in the same folder | after replies in a Claude Code terminal session |

For Claude, the app uses whichever source is newer. `/usage` is a local Claude Code command: it
doesn't send a message to the model. The hook runs it in the background, so replies aren't slowed down. A call that arrives within 15
seconds of the last run schedules one run for when the 15 seconds are up, so the latest change is never dropped.
The app itself never reads Claude login tokens or calls Anthropic: only the official Claude Code CLI
does, the same way it does when you type `/usage`. The hook saves `/usage` as stream-json, whose
structured `usage_report` the app reads; if a Claude Code version lacks it, the app reads the display text instead.

The app also runs the same request itself: every 30 seconds for 10 minutes after Claude was last
seen in use, then every 5 minutes. That covers usage no hook sees (claude.ai chat, other devices).

The `/usage` number trails the live number the Claude desktop app shows: Anthropic's servers update
it a minute or two late, so during heavy use this app can show several percent less used than Claude
desktop, and it catches up once usage slows. `/usage` also rounds down where Claude desktop rounds
to nearest. No local source has the live value.

The app watches the saved files and updates within a second of a change; it also re-reads every 30
seconds and after the Mac wakes. Once a window's reset time passes, the app shows it as 100% left
until fresh data arrives.

## Setup

```sh
sh scripts/install-claude-hook.sh     # adds the hooks to ~/.claude/settings.json (keeps a .bak; --uninstall removes it)
sh scripts/install-claude-bridge.sh   # optional: status line fallback in ~/.claude/statusline-command.sh (keeps a .bak)
sh scripts/build-app.sh               # builds "build/GS Status Bar.app"
open "build/GS Status Bar.app"
```

Move the app to `/Applications` if you turn on "Launch at login".

## Development

```sh
swift test                                                   # parser and model tests
swift run GSStatusBar --snapshot /tmp/gs-snap [--sample]     # render the UI to PNGs
```

`Sources/UsageCore` has the data model and readers (no UI). `Sources/GSStatusBar` is the app.
