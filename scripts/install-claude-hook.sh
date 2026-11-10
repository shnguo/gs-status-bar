#!/bin/sh
# Copies claude-usage-hook.sh into ~/Library/Application Support/GSStatusBar and adds it as
# Stop and PostToolUse hooks in ~/.claude/settings.json (backup saved next to it). Safe to run more than once.
# Pass --uninstall to remove the hook again.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dest_dir="$HOME/Library/Application Support/GSStatusBar"
hook_script="$dest_dir/claude-usage-hook.sh"
settings="$HOME/.claude/settings.json"
command='sh "$HOME/Library/Application Support/GSStatusBar/claude-usage-hook.sh"'

mode=install
[ "${1:-}" = "--uninstall" ] && mode=uninstall

if [ "$mode" = install ]; then
  mkdir -p "$dest_dir"
  cp "$here/claude-usage-hook.sh" "$hook_script"
  chmod +x "$hook_script"
  echo "Installed $hook_script"
fi

mkdir -p "$(dirname "$settings")"
[ -f "$settings" ] || echo '{}' > "$settings"
# Keep the first backup: it holds the settings from before this script ever ran.
[ -f "$settings.bak-gsstatusbar-hook" ] || cp "$settings" "$settings.bak-gsstatusbar-hook"

python3 -I - "$settings" "$command" "$mode" <<'EOF'
import json, sys
path, command, mode = sys.argv[1:4]
with open(path) as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})
# Stop: after each reply. PostToolUse: after each tool step, so long replies update too.
events = {"Stop": {}, "PostToolUse": {"matcher": "*"}}

def is_ours(group):
    return any(h.get("command") == command for h in group.get("hooks", []))

changed = []
for event, extra in events.items():
    groups = hooks.setdefault(event, [])
    had_ours = any(is_ours(g) for g in groups)
    groups[:] = [g for g in groups if not is_ours(g)]
    if mode == "install":
        groups.append({**extra, "hooks": [{"type": "command", "command": command}]})
        if not had_ours:
            changed.append(event)
    elif had_ours:
        changed.append(event)
    if not groups:
        del hooks[event]
if not hooks:
    del settings["hooks"]

import os
with open(path + ".tmp", "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)

verb = "Added" if mode == "install" else "Removed"
print(f"{verb} hooks: {', '.join(changed)}" if changed else "Hooks already up to date.")
EOF
echo "Settings: $settings (backup: $settings.bak-gsstatusbar-hook)"
