#!/bin/sh
# Claude Code hook (Stop and PostToolUse): asks the Claude Code CLI for current plan usage
# ("/usage") and saves its report to ~/Library/Application Support/GSStatusBar/claude-usage.jsonl
# for the menu bar app.
#
# Returns at once and does the work in the background, so it never slows Claude down.
# Runs at most once every 15 seconds. A call that comes sooner isn't dropped: it schedules one
# run for when the 15 seconds are up, so the last change is always picked up.
# --force (the app's refresh button) skips the wait.
# "/usage" is a local Claude Code command: it doesn't send a message to the model.

interval=15

# Don't run again from inside the /usage call below.
[ -n "${GSSTATUSBAR_USAGE_RUN:-}" ] && exit 0

# Claude Code passes hook details on stdin; they aren't needed.
[ -t 0 ] || cat >/dev/null

dir="$HOME/Library/Application Support/GSStatusBar"
mkdir -p "$dir" 2>/dev/null || exit 0
stamp="$dir/claude-usage.stamp"
pending="$dir/claude-usage.pending"

now=$(date +%s)

# A scheduled run normally clears this within $interval seconds; clear it if it was left behind.
if [ -d "$pending" ]; then
  pending_age=$(( now - $(stat -f %m "$pending" 2>/dev/null || echo 0) ))
  [ "$pending_age" -gt $(( interval + 60 )) ] && rmdir "$pending" 2>/dev/null
fi

if [ "${1:-}" = "--force" ]; then
  delay=0
else
  last=$(stat -f %m "$stamp" 2>/dev/null || echo 0)
  delay=$(( last + interval - now ))
  [ "$delay" -lt 0 ] && delay=0
fi

# Only one run waits at a time; it reads the newest numbers when it starts.
if [ "$delay" -gt 0 ]; then
  mkdir "$pending" 2>/dev/null || exit 0
else
  touch "$stamp"   # right away, so a call arriving at the same moment waits instead
fi

# Hooks run with a minimal PATH, so look in the usual install places too.
claude_bin=""
for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude "$(command -v claude 2>/dev/null)"; do
  if [ -n "$c" ] && [ -x "$c" ]; then claude_bin=$c; break; fi
done
if [ -z "$claude_bin" ]; then
  rmdir "$pending" 2>/dev/null
  exit 0
fi

(
  [ "$delay" -gt 0 ] && sleep "$delay"
  rmdir "$pending" 2>/dev/null
  touch "$stamp"
  cd "$dir" || exit 0
  tmp="$dir/claude-usage.jsonl.$$"
  # stream-json includes a structured "usage_report" next to the display text.
  GSSTATUSBAR_USAGE_RUN=1 "$claude_bin" -p "/usage" --no-session-persistence --strict-mcp-config \
    --output-format stream-json --verbose > "$tmp" 2>/dev/null
  # Keep the previous numbers if this run didn't produce any (signed out, offline, ...).
  if grep -q -e '"usage_report"' -e '% used' "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$dir/claude-usage.jsonl"
  else
    rm -f "$tmp"
  fi
) </dev/null >/dev/null 2>&1 &

exit 0
