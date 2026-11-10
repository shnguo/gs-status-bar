#!/bin/sh
# Reads Claude Code's status line JSON on stdin and saves its rate_limits for GS Status Bar.
# Writes nothing when rate_limits is missing (API-key login, or before the first reply).
dir="$HOME/Library/Application Support/GSStatusBar"
mkdir -p "$dir" 2>/dev/null || exit 0
out=$(jq -c 'select(.rate_limits != null) | {rate_limits, ts: now}' 2>/dev/null) || exit 0
[ -n "$out" ] || exit 0
tmp="$dir/claude.json.$$"
printf '%s\n' "$out" > "$tmp" && mv -f "$tmp" "$dir/claude.json"
