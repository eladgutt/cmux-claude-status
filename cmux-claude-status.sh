#!/usr/bin/env bash
# Feeds Claude Code state into the cmux sidebar as a colored metadata row.
# Events: submit | busy | notify | stop | start | end | tick
#
# All four states render a fixed "[HH:MM] <label>" - the clock time the
# state started, not an elapsed counter. cmux's control socket only accepts
# processes that are live descendants of a cmux terminal, so nothing can
# tick a counter in the background; any "Xm ago" text only updates when a
# hook happens to fire, which for a backgrounded tab (or a long thinking
# stretch with no tool calls) can be a long time - so it goes stale and
# lies. A clock time is true forever the moment it's written, no re-render
# needed.
set -u
[ -n "${CMUX_SOCKET_PATH:-}" ] && [ -n "${CMUX_TAB_ID:-}" ] || exit 0
[ -S "$CMUX_SOCKET_PATH" ] || exit 0

EVENT="${1:-}"
# blink is launched from a shell rc with the terminal on stdin - cat would
# block forever (or eat keystrokes). It never needs a JSON payload anyway.
RAW_INPUT=""
[ "$EVENT" = blink ] || RAW_INPUT="$(cat)"
DIR="$HOME/.cache/cmux-claude-status"
STATE_FILE="$DIR/${CMUX_SURFACE_ID:-$CMUX_TAB_ID}.state"
BG_MARKER="$DIR/${CMUX_SURFACE_ID:-$CMUX_TAB_ID}.bg-pending"
PROC_MARKER="$DIR/${CMUX_SURFACE_ID:-$CMUX_TAB_ID}.proc-pending"
mkdir -p "$DIR"
NOW=$(date +%s)

send() { printf '%s\n' "$1" | nc -w 1 -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1; }

fmt_clock() { date -r "$1" '+[%H:%M]' 2>/dev/null; }

# Crunching is a STATIC orange gear. It used to blink via a 1s heartbeat
# loop per tab, but 7 concurrent blinkers each forcing a sidebar text diff
# every second drove cmux's main thread into a SwiftUI relayout spiral
# (beachball, 10GB RSS, hang reports Jul 15/20/21) - removed Jul 21. A gear,
# not a bolt - bolt.fill is the auto-mode icon on the info row.
render() {
    local state="$1" epoch="$2" detail="$3" text icon color
    case "$state" in
        running)    icon=gearshape.fill;        color='#E8833A'; text="$(fmt_clock "$epoch") crunching";;
        needsInput) icon=hand.raised.fill;      color='#E5484D'; text="$(fmt_clock "$epoch") needs you";;
        waitingBg)  icon=hourglass;              color='#0090FF'; text="$(fmt_clock "$epoch") bg agent running";;
        waitingProc) icon=terminal.fill;          color='#0090FF'; text="$(fmt_clock "$epoch") bg process running";;
        idle)       icon=checkmark.circle.fill; color='#46A758'; text="$(fmt_clock "$epoch") idle"; detail="";;
        *) return;;
    esac
    [ -n "$detail" ] && text="$text - $detail"
    send "report_meta claude \"$text\" --icon=$icon --color=$color --priority=1 --tab=$CMUX_TAB_ID"
}

read_state() { { read -r S_STATE; read -r S_EPOCH; read -r S_DETAIL; read -r S_PID; read -r S_ROUTE; } < "$STATE_FILE" 2>/dev/null; }

# Line 5: whether this claude routes through the ValarCode gateway (same
# ANTHROPIC_BASE_URL test as valar_row; env inherited from claude, so per
# session-lifetime like the badge). Lets the menu bar V color crunching by
# routing - green via ValarCode, orange direct.
case "${ANTHROPIC_BASE_URL:-}" in *valar*) ROUTE=valar;; *) ROUTE=direct;; esac

# Line 4 of the state file: the claude process pid, so out-of-band readers
# (the ValarClaudeStatus menu bar app) can drop files whose session died
# without an `end` hook (killed tab = no SessionEnd = state frozen at
# "running"). Walk up from the hook shell; the claude binary's comm is
# literally "claude". Empty on no match - readers fall back to mtime age.
claude_pid() {
    local p=$PPID c
    for _ in 1 2 3 4 5 6; do
        [ -n "$p" ] && [ "$p" != 1 ] || break
        c=$(ps -o comm= -p "$p" 2>/dev/null) || break
        case "$c" in *claude*) printf '%s' "$p"; return;; esac
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    done
}
save() { printf '%s\n%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$(claude_pid)" "$ROUTE" > "$STATE_FILE"; }
set_state() { save "$1" "$NOW" "$2"; render "$1" "$NOW" "$2"; }

snippet() { printf '%s' "$RAW_INPUT" | jq -r "$1 // \"\"" 2>/dev/null | tr -d '"\\\r' | tr '\n' ' ' | sed -e 's/^ *//' -e 's/ *$//' | cut -c1-48; }

# Routing badge: teal V via the ValarCode gateway, dark navy A direct to
# Anthropic (Elad's pick). Not the brand colors on purpose - Valar green
# #40B96C and Anthropic clay-orange sit on top of the idle/crunching status
# colors. Navy #1E40AF is kept deliberately darker than the bg-agent azure
# #0090FF so the two blues stay tellable apart. The env
# is inherited from the claude process and fixed for its lifetime, so this
# can't flip mid-session - rendered at start and refreshed on tick to also
# cover sessions that were already running when this installed.
valar_row() {
    case "${ANTHROPIC_BASE_URL:-}" in
        *valar*) send "report_meta claude-valar \"Valar Serving\" --icon=v.square.fill --color=#14B8A6 --priority=0 --tab=$CMUX_TAB_ID";;
        *)       send "report_meta claude-valar \"Anthropic Serving\" --icon=a.square.fill --color=#1E40AF --priority=0 --tab=$CMUX_TAB_ID";;
    esac
}

# permission_mode only shows up in PreToolUse hook JSON (checked: absent from
# the statusLine payload and every other hook event). No separate row for it -
# it just swaps which icon the model/context line (claude-info) uses. Only
# updates on the next tool call after you cycle modes with shift+tab - there's
# no dedicated hook for the mode-change keystroke itself.
MODE_FILE="$DIR/${CMUX_SURFACE_ID:-$CMUX_TAB_ID}.mode"
mode_icon() {
    case "$1" in
        plan)              echo list.bullet.clipboard;;
        acceptEdits)       echo pencil.circle.fill;;
        auto)              echo bolt.fill;;
        bypassPermissions) echo exclamationmark.triangle.fill;;
        manual|dontAsk)    echo checkmark.shield;;
        *)                 echo cpu;;
    esac
}

case "$EVENT" in
    submit)
        # A new turn is starting, whether typed by the user or the synthetic
        # "<task-notification>" prompt Claude Code submits when a background
        # agent/process finishes - either way any outstanding markers are moot.
        rm -f "$BG_MARKER" "$PROC_MARKER"
        set_state running "$(snippet .prompt)"
        ;;
    notify)
        # Notification fires for two very different things sharing one event:
        # an actual permission ask, and a plain "turn already ended, still
        # waiting on you" idle nudge. Only the former is really blocked.
        # ponytail: heuristic keyed on the word "permission"; widen if another
        # genuinely-blocking notification text shows up that doesn't say it.
        msg="$(snippet .message)"
        if printf '%s' "$msg" | grep -qi permission; then
            set_state needsInput "$(printf '%s' "$msg" | sed 's/^Claude //')"
        else
            set_state idle ""
        fi
        ;;
    stop)
        # The main turn parked. If it left a background agent or a background
        # shell process running, that's not done - work continues, just not
        # visible as a tool call on this session anymore. Agent outranks
        # process when both are outstanding.
        if [ -f "$BG_MARKER" ]; then set_state waitingBg ""
        elif [ -f "$PROC_MARKER" ]; then set_state waitingProc ""
        else set_state idle ""; fi
        ;;
    start)  set_state idle ""; valar_row;;
    blink)
        # Removed (see header). Kept as an explicit no-op so a stale shell rc
        # or restored tab that still launches it exits instead of erroring.
        exit 0
        ;;
    busy)
        # PreToolUse: a tool is actually executing - the only hard proof that
        # a turn resumed after a permission grant (no hook fires on "user
        # answered the prompt"), so this is what corrects a stale
        # needsInput/idle row left over from before this turn. Already
        # running: nothing to redraw (the row text is fixed), so don't -
        # every skipped report_meta is one less main-thread sync into cmux.
        [ -f "$STATE_FILE" ] && read_state
        if [ "${S_STATE:-}" = running ]; then
            # one-time upgrade: re-save files predating the pid (line 4) or
            # route (line 5) format so in-flight sessions pick them up mid-turn
            { [ -z "${S_PID:-}" ] || [ -z "${S_ROUTE:-}" ]; } && save running "$S_EPOCH" "$S_DETAIL"
        else
            set_state running "$(snippet .tool_name)"
        fi
        # Record a background Agent spawn so the Stop that follows (main loop
        # parking to wait on it) doesn't get rendered as plain done.
        # ponytail: one boolean marker, not a per-task registry - good enough
        # for "is anything outstanding", cleared wholesale on the next submit.
        # NB: jq's `//` treats `false` as falsy too, so `x // true` would
        # silently flip an explicit run_in_background:false back to true -
        # use `!= false` instead so only an explicit false opts out.
        if printf '%s' "$RAW_INPUT" | jq -e '.tool_name == "Agent" and (.tool_input.run_in_background != false)' >/dev/null 2>&1; then
            touch "$BG_MARKER"
        fi
        # Background shell process ("waiting on a sub process"): unlike Agent,
        # Bash defaults run_in_background to FALSE, so require explicit true.
        # Workflow always runs in the background. NB: this only catches
        # explicit backgrounding - a foreground command the harness moves to
        # background (timeout, ctrl-b) is invisible in tool_input; the `post`
        # event below catches those from the tool RESPONSE.
        if printf '%s' "$RAW_INPUT" | jq -e '(.tool_name == "Bash" and .tool_input.run_in_background == true) or .tool_name == "Workflow"' >/dev/null 2>&1; then
            touch "$PROC_MARKER"
        fi
        perm_mode="$(snippet .permission_mode)"
        [ -n "$perm_mode" ] && printf '%s' "$perm_mode" > "$MODE_FILE"
        ;;
    post)
        # PostToolUse: a tool just COMPLETED, so the agent is definitely
        # active again. This is the earliest signal after the user answers
        # an AskUserQuestion or grants a permission - the gated tool call
        # completes and fires this, while the next PreToolUse may be a long
        # thinking stretch away. Corrects a stale needs-you row that busy
        # alone left standing for minutes.
        [ -f "$STATE_FILE" ] && read_state
        [ "${S_STATE:-}" = running ] || set_state running "$(snippet .tool_name)"
        # Also catches backgrounding that PreToolUse can't see - a
        # foreground Bash the harness moved to background (timeout, ctrl-b)
        # completes its tool call with a distinctive response ("Command
        # running in background with ID: ..."). Narrow phrases on purpose:
        # a command whose OUTPUT merely mentions "background" must not
        # false-positive.
        if printf '%s' "$RAW_INPUT" | jq -e '.tool_name == "Bash" and ((.tool_response | tostring) | test("running in background with ID|moved to background"))' >/dev/null 2>&1; then
            touch "$PROC_MARKER"
        fi
        ;;
    end)
        send "clear_meta claude --tab=$CMUX_TAB_ID"
        send "clear_meta claude-info --tab=$CMUX_TAB_ID"
        send "clear_meta claude-valar --tab=$CMUX_TAB_ID"
        rm -f "$STATE_FILE" "$BG_MARKER" "$PROC_MARKER" "$MODE_FILE" "$DIR/${CMUX_SURFACE_ID:-$CMUX_TAB_ID}.info-stamp"
        ;;
    tick)
        # $RAW_INPUT here is the statusLine JSON payload (model/effort/context
        # live here, not in hook events)
        INFO_STAMP="$DIR/${CMUX_SURFACE_ID:-$CMUX_TAB_ID}.info-stamp"
        LAST_INFO=$(cat "$INFO_STAMP" 2>/dev/null || echo 0)
        [ $(( NOW - LAST_INFO )) -ge 5 ] || exit 0
        IFS=$'\t' read -r model effort pct <<EOF
$(printf '%s' "$RAW_INPUT" | jq -r '[.model.display_name, .effort.level, .context_window.used_percentage] | @tsv' 2>/dev/null)
EOF
        [ -n "${model:-}" ] || exit 0
        # Context ramp deliberately shares no hue with the state row's colors
        # (green idle / orange crunching / red needs-you / blue bg-agent), so
        # a full-context session can't be mistaken for a blocked one at a
        # glance: gray -> violet -> fuchsia.
        ctx_color='#8E8E93'
        [ "${pct:-0}" -ge 60 ] 2>/dev/null && ctx_color='#A78BFA'
        [ "${pct:-0}" -ge 85 ] 2>/dev/null && ctx_color='#D946EF'
        icon="$(mode_icon "$(cat "$MODE_FILE" 2>/dev/null)")"
        send "report_meta claude-info \"$model - ${effort:-default} - ${pct:-0}% ctx\" --icon=$icon --color=$ctx_color --priority=2 --tab=$CMUX_TAB_ID"
        valar_row
        echo "$NOW" > "$INFO_STAMP"
        ;;
esac
exit 0
