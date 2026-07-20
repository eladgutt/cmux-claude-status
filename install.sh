#!/usr/bin/env bash
# Installs cmux-claude-status: copies the hook script and merges the needed
# hook entries into ~/.claude/settings.json. Additive and idempotent - safe
# to re-run, never removes or overwrites anything already there.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

mkdir -p "$HOME/.claude/hooks"
cp cmux-claude-status.sh "$HOME/.claude/hooks/cmux-claude-status.sh"
chmod +x "$HOME/.claude/hooks/cmux-claude-status.sh"
echo "Installed: ~/.claude/hooks/cmux-claude-status.sh"

python3 - <<'PYEOF'
import json, os

p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p)) if os.path.exists(p) else {}

EVENTS = {
    "SessionStart": "start",
    "UserPromptSubmit": "submit",
    "Notification": "notify",
    "Stop": "stop",
    "SessionEnd": "end",
    "PreToolUse": "busy",
}

hooks = d.setdefault("hooks", {})
added = []
for hook_name, event in EVENTS.items():
    cmd = f'bash "$HOME/.claude/hooks/cmux-claude-status.sh" {event}'
    groups = hooks.setdefault(hook_name, [])
    already = any(
        h.get("command", "").strip() == cmd
        for g in groups
        for h in g.get("hooks", [])
    )
    if not already:
        entry = {"type": "command", "command": cmd}
        if hook_name == "PreToolUse":
            entry["async"] = True
        groups.append({"hooks": [entry]})
        added.append(hook_name)

if added:
    tmp = p + ".tmp"
    json.dump(d, open(tmp, "w"), indent=2, sort_keys=True)
    os.replace(tmp, p)
    print("Added hooks:", ", ".join(added))
else:
    print("Hooks already present, nothing to add.")
PYEOF

cat <<'EOF'

One thing this can't merge automatically: the model/context/mode row needs a
line added to your statusLine command (settings.json only allows one, and it
can't be safely spliced into an arbitrary existing shell one-liner).

If you don't have a statusLine yet, add this to ~/.claude/settings.json:

  "statusLine": {
    "type": "command",
    "command": "IN=$(cat); printf '%s' \"$IN\"; printf '%s' \"$IN\" | bash \"$HOME/.claude/hooks/cmux-claude-status.sh\" tick >/dev/null 2>&1"
  }

If you already have one, capture stdin into $IN at the top instead of piping
it away, then append this line after whatever it already prints:

  printf '%s' "$IN" | bash "$HOME/.claude/hooks/cmux-claude-status.sh" tick >/dev/null 2>&1

For the steady 1-second crunching blink, also add the blinker snippet to the
startup file of the shell your cmux terminals ACTUALLY run (fresh tabs run
your configured interactive shell - fish/zsh/bash; restored agent tabs run
bash login shells reading ~/.bash_profile - cover both). See README.md
("The 1s blink needs a shell snippet") for the exact bash and fish snippets.

Without it the blink still moves, just irregularly (on tool calls and
focused-tab statusline ticks).
EOF
