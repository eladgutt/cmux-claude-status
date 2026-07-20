# cmux-claude-status

Shows what Claude Code is actually doing, per tab, in the [cmux](https://cmux.com) sidebar - instead of cmux's generic "Claude is waiting for your input" for every session regardless of what's really happening.

Two rows appear under each workspace:

```
🔵 [16:34] needs you - needs your permission to use Bash
🖥  Fable 5 - xhigh - 34% ctx
```

- **State row** - one of:
  - 🟠 `[HH:MM] crunching - <prompt or tool>` - actively working; the gear icon blinks (filled/bright vs outline/dim) as work happens, so a live session visibly moves
  - 🔴 `[HH:MM] needs you - <reason>` - actually blocked on a permission prompt
  - 🔵 `[HH:MM] bg agent running` - the main turn parked, but it launched a background subagent that's still working
  - 🟢 `[HH:MM] idle` - genuinely done, nothing outstanding
- **Model/context row** - `<model> - <effort> - <context %>`, with the icon swapped to reflect the current permission mode (auto/plan/accept-edits/bypass/ask) instead of a generic cpu icon. Colored gray/violet/fuchsia as context fills up - deliberately a different hue family from every state color, so a full-context session can't be mistaken for a blocked one at a glance (and the crunching gear can't be confused with auto mode's bolt).
- **Gateway badge** (optional) - a green `V` badge appears for sessions routed through a custom `ANTHROPIC_BASE_URL` containing `valar`. Since a process's env is fixed at launch, this is accurate per session even if you toggle the gateway between sessions. If you don't use such a gateway, the row simply never appears - or adapt the one-line match in `valar_row()` to badge whatever gateway you use.

All timestamps are fixed clock times, not elapsed counters. Nothing can tick a live counter in the background (see [Why clock times, not elapsed counters](#why-clock-times-not-elapsed-counters)), so a wall-clock time is the only thing that stays honest without needing a process to keep updating it.

## Install

```bash
git clone <this repo> ~/projects/cmux-claude-status
~/projects/cmux-claude-status/install.sh
```

This copies `cmux-claude-status.sh` to `~/.claude/hooks/` and merges the needed hook entries into `~/.claude/settings.json` (additively - it won't touch or remove anything else already in your hooks). It's safe to re-run.

One piece it can't merge automatically: **the model/context/mode row needs a line added to your `statusLine` command**, because `settings.json` only allows one statusLine command and it can't be safely spliced into an arbitrary existing one. The installer prints the exact line to add; see [Wiring the statusLine](#wiring-the-statusline) if you don't have a statusLine yet.

### Wiring the statusLine

Your `statusLine.command` needs to both consume stdin (the statusLine JSON payload) and forward it to the tick handler. If you don't already have a statusLine command, this is a complete one:

```json
{
  "statusLine": {
    "type": "command",
    "command": "IN=$(cat); printf '%s' \"$IN\"; printf '%s' \"$IN\" | bash \"$HOME/.claude/hooks/cmux-claude-status.sh\" tick >/dev/null 2>&1"
  }
}
```

If you already have one, capture stdin into `$IN` at the top instead of piping it away, print whatever you already print, then append:

```bash
printf '%s' "$IN" | bash "$HOME/.claude/hooks/cmux-claude-status.sh" tick >/dev/null 2>&1
```

## Uninstall

Remove the hook entries this added from `~/.claude/settings.json` (they're each a single `bash "$HOME/.claude/hooks/cmux-claude-status.sh" <event>` line - grep for `cmux-claude-status.sh` to find them all) and delete `~/.claude/hooks/cmux-claude-status.sh`.

## How it works

cmux exposes a raw socket command, `report_meta`, that draws a colored icon+text row in the sidebar for the current tab (`$CMUX_SOCKET_PATH`, `$CMUX_TAB_ID` are set automatically inside any cmux terminal). This project is a shell script wired into Claude Code's hooks that calls `report_meta` whenever something worth showing happens:

| Hook | Event | What it does |
|---|---|---|
| `SessionStart` | `start` | Renders idle |
| `UserPromptSubmit` | `submit` | Renders crunching (a real prompt or the synthetic "task finished" notification Claude Code submits when a background agent completes) |
| `PreToolUse` | `busy` | Corrects a stale needs-you/idle row the moment real work resumes (see below); records the current permission mode and whether a background agent got spawned |
| `Notification` | `notify` | Renders needs-you only if the message is actually about a permission ask; otherwise idle |
| `Stop` | `stop` | Renders idle, or bg-agent-running if a background agent from this turn is still outstanding |
| `SessionEnd` | `end` | Clears everything for this tab |
| `statusLine` | `tick` | Reads model/effort/context-window/permission-mode from the statusLine JSON payload (not available in any hook event) and updates the info row |

### Why clock times, not elapsed counters

cmux's control socket only accepts processes that are live descendants of a cmux terminal (confirmed by testing - a detached background process gets `Access denied`), so there's no way to run an independent ticker to age a counter live. The `tick` event only fires when that specific tab's Claude Code process re-renders its statusLine, which only reliably happens while the tab is focused. A backgrounded tab, or even a focused one mid a long thinking stretch with no tool calls, would show an elapsed counter that silently goes stale and lies. A fixed wall-clock timestamp of when the state started is true forever the instant it's written, so that's what every state shows instead.

### Correcting a stale "needs you"

There's no hook that fires when you answer a permission prompt, only when it's asked (`Notification`). So after granting permission and the agent resumes, nothing tells this script "we're running again" - it would otherwise sit on the stale `needsInput` state indefinitely. `PreToolUse` fires on every actual tool execution, which is the only hard proof a turn has resumed, so it's used to correct the row - but only flips state if it wasn't already `running`, so it doesn't reset the crunching-since timestamp on every single tool call.

### Detecting a background agent

Claude Code's `Agent` tool defaults to `run_in_background: true`. When the main turn spawns one and then parks (fires `Stop`) before that agent finishes, that's not "done" - it's still crunching via a subagent, just invisible as a tool call on the main session. `PreToolUse` sets a marker when it sees an `Agent` call that isn't explicitly synchronous (`run_in_background: false`); `Stop` checks that marker instead of always assuming idle. The marker clears on the next `submit`, whether that's you typing something new or the synthetic `<task-notification>` prompt Claude Code submits when the background agent completes - either way a new turn starting makes the old marker moot.

This is a single boolean marker, not a per-task registry - it tracks "is anything outstanding", not how many background agents are still running. Good enough for the common case; if you regularly fan out several background agents per turn, it clears as soon as any one completion notification arrives even if others are still running.

## Known limitations

- **Elapsed time is never live.** By design (see above) - states show when they started, not a running counter.
- **The needs-you/idle split is a text heuristic.** `Notification` fires for both real permission asks and plain "still waiting on you" idle nudges; this distinguishes them by checking whether the message contains the word "permission". If Claude Code ever ships a genuinely-blocking notification worded differently, it'll currently be misclassified as idle.
- **`settings.json` is shared across every concurrently-open Claude Code session on your machine.** If you run many sessions at once, one session flushing its own in-memory settings back to disk can clobber hook entries another session (or this installer) just added. There's no real fix for this short of Claude Code itself not doing whole-file rewrites; if a row stops updating, re-run `install.sh`.
- **The mode icon only updates on the next tool call after you cycle modes with shift+tab.** There's no dedicated hook for the mode-change keystroke itself, only the `permission_mode` field riding along inside the next `PreToolUse` payload.
- **The 1s blink needs the shell snippet below; without it the blink is event-driven.** cmux's sidebar rows are static and its socket rejects orphaned processes, so the only place a steady 1-second heartbeat can live is as a child of the tab's long-lived shell. Add this to the shell startup file your terminals actually use (`~/.bash_profile` for bash login shells - which is also what cmux's Claude tabs run - or `~/.config/fish/config.fish` / `~/.zshrc` translated accordingly):

  ```bash
  # cmux-claude-status: 1s crunching blinker (must be a child of this shell)
  if [ -n "${CMUX_SURFACE_ID:-}" ] && [ -S "${CMUX_SOCKET_PATH:-}" ] && [ -f "$HOME/.claude/hooks/cmux-claude-status.sh" ]; then
      bash "$HOME/.claude/hooks/cmux-claude-status.sh" blink </dev/null >/dev/null 2>&1 & disown 2>/dev/null
  fi
  ```

  One heartbeat runs per surface (pid-lock), it only writes while the state is `crunching`, and it exits on its own when the tab's shell dies. Without the snippet you still get motion, just irregular: frames advance on each tool call (`PreToolUse`, focus-independent) and each statusLine tick (focused tab only) - so a long thinking stretch on a backgrounded tab shows a frozen gear.
