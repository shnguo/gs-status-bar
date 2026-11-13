#!/bin/sh
# Claude Code hook (Stop and PostToolUse): asks the Claude Code CLI for current plan usage
# ("/usage") and saves its report to ~/Library/Application Support/GSStatusBar/claude-usage.jsonl
# for the menu bar app.
#
# Returns at once and does the work in the background, so it never slows Claude down.
# Runs at most once a minute: Claude Code reuses its last answer for 60 seconds, so asking sooner
# gains nothing. A call that comes sooner isn't dropped: it schedules one run for when the wait
# is up, so the last change is always picked up.
# Anthropic limits how often usage can be checked. When a check is refused, Claude Code answers
# with a saved copy up to an hour old; the wait then doubles (up to 15 minutes) and shrinks
# again once checks succeed. Asking more often only gets more checks refused.
# --force (the app's refresh button) skips the wait.
# "/usage" is a local Claude Code command: it doesn't send a message to the model.
# Each time fresh numbers differ from the last ones logged, a line with the time is added to
# claude-usage-history.log in the same folder, so a jump can be matched to the minute it showed up.

interval=60
max_wait=900

# Don't run again from inside the /usage call below.
[ -n "${GSSTATUSBAR_USAGE_RUN:-}" ] && exit 0

# Claude Code passes hook details on stdin; they aren't needed.
[ -t 0 ] || cat >/dev/null

dir="$HOME/Library/Application Support/GSStatusBar"
mkdir -p "$dir" 2>/dev/null || exit 0
stamp="$dir/claude-usage.stamp"
pending="$dir/claude-usage.pending"
waitfile="$dir/claude-usage.wait"
out="$dir/claude-usage.jsonl"
hist="$dir/claude-usage-history.log"

# Seconds to leave between runs: $interval normally, longer after refused checks.
wait=$(cat "$waitfile" 2>/dev/null)
case "$wait" in ''|*[!0-9]*) wait=$interval ;; esac
[ "$wait" -lt "$interval" ] && wait=$interval
[ "$wait" -gt "$max_wait" ] && wait=$max_wait

now=$(date +%s)

# A scheduled run normally clears this within $wait seconds; clear it if it was left behind.
if [ -d "$pending" ]; then
  pending_age=$(( now - $(stat -f %m "$pending" 2>/dev/null || echo 0) ))
  [ "$pending_age" -gt $(( wait + 60 )) ] && rmdir "$pending" 2>/dev/null
fi

if [ "${1:-}" = "--force" ]; then
  delay=0
else
  last=$(stat -f %m "$stamp" 2>/dev/null || echo 0)
  delay=$(( last + wait - now ))
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
  # A check may have been refused while this run waited: wait out the longer gap too.
  if [ "${1:-}" != "--force" ]; then
    w=$(cat "$waitfile" 2>/dev/null)
    case "$w" in ''|*[!0-9]*) w=$wait ;; esac
    more=$(( $(stat -f %m "$stamp" 2>/dev/null || echo 0) + w - $(date +%s) ))
    if [ "$more" -gt 0 ] && [ "$more" -le "$max_wait" ]; then sleep "$more"; wait=$w; fi
  fi
  rmdir "$pending" 2>/dev/null
  touch "$stamp"
  cd "$dir" || exit 0
  tmp="$out.$$"
  # stream-json includes a structured "usage_report" next to the display text.
  GSSTATUSBAR_USAGE_RUN=1 "$claude_bin" -p "/usage" --no-session-persistence --strict-mcp-config \
    --output-format stream-json --verbose > "$tmp" 2>/dev/null

  slower() { w=$(( wait * 2 )); [ "$w" -gt "$max_wait" ] && w=$max_wait; echo "$w" > "$waitfile"; }
  faster() { w=$(( wait / 2 )); [ "$w" -lt "$interval" ] && w=$interval; echo "$w" > "$waitfile"; }
  numbers() { grep -o 'Current [a-zA-Z ()]*: [0-9.]*% used' "$1" 2>/dev/null | sort -u; }
  # Logs the saved numbers with the time, unless they match the last line. Not called for a
  # refused check: its numbers are an old copy, so the time would be wrong.
  record() {
    line=$(numbers "$out" | sed -e 's/^Current //' -e 's/ used$//' | paste -sd'|' - | sed 's/|/, /g')
    [ -n "$line" ] || return 0
    [ "$line" = "$(tail -n 1 "$hist" 2>/dev/null | cut -f2-)" ] && return 0
    printf '%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line" >> "$hist"
    if [ "$(wc -l < "$hist")" -gt 5000 ]; then
      tail -n 4000 "$hist" > "$hist.$$" && mv -f "$hist.$$" "$hist"
    fi
  }

  if grep -q '"limits":\[' "$tmp" 2>/dev/null; then
    # A fresh answer from Anthropic.
    faster
    mv -f "$tmp" "$out"
    record
  elif ! grep -q '% used' "$tmp" 2>/dev/null; then
    # No numbers at all (signed out, offline, ...): keep the previous ones.
    slower
    rm -f "$tmp"
  elif grep -q '"usage_report"' "$tmp" 2>/dev/null; then
    # The report has no limits: the check was refused and the text is Claude Code's saved copy.
    # Keep it only if it differs from what's saved, so the file's time stays the time its
    # numbers were first seen.
    slower
    if [ -f "$out" ] && [ "$(numbers "$tmp")" = "$(numbers "$out")" ]; then
      rm -f "$tmp"
    else
      mv -f "$tmp" "$out"
    fi
  else
    # Text only (a Claude Code version without the report): can't tell fresh from saved.
    mv -f "$tmp" "$out"
    record
  fi
) </dev/null >/dev/null 2>&1 &

exit 0
