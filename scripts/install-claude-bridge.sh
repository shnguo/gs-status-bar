#!/bin/sh
# Copies the bridge into ~/Library/Application Support/GSStatusBar and hooks it into
# ~/.claude/statusline-command.sh (backup saved next to it). Safe to run more than once.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dest_dir="$HOME/Library/Application Support/GSStatusBar"
bridge="$dest_dir/claude-statusline-bridge.sh"
statusline="$HOME/.claude/statusline-command.sh"
marker="# gs-status-bar bridge"

mkdir -p "$dest_dir"
cp "$here/claude-statusline-bridge.sh" "$bridge"
chmod +x "$bridge"
echo "Installed $bridge"

hook="printf '%s' \"\$input\" | sh \"\$HOME/Library/Application Support/GSStatusBar/claude-statusline-bridge.sh\" >/dev/null 2>&1 || true  $marker"

if [ ! -f "$statusline" ]; then
  echo "No $statusline found."
  echo "Add this to your status line script, after it reads stdin into \$input:"
  echo "  $hook"
  exit 1
fi

if grep -q "$marker" "$statusline"; then
  echo "Status line already calls the bridge."
  exit 0
fi

if ! grep -q '^input=$(cat)' "$statusline"; then
  echo "Couldn't find 'input=\$(cat)' in $statusline."
  echo "Add this line after the script reads stdin into \$input:"
  echo "  $hook"
  exit 1
fi

cp "$statusline" "$statusline.bak-gsstatusbar"
awk -v hook="$hook" '{ print } /^input=\$\(cat\)/ && !done { print hook; done = 1 }' "$statusline" > "$statusline.tmp"
mv "$statusline.tmp" "$statusline"
echo "Hooked the bridge into $statusline (backup: $statusline.bak-gsstatusbar)"
