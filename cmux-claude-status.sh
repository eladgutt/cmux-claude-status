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
RAW_INPUT="$(cat)"
DIR="$HOME/.cache/cmux-claude-status"
STATE_FILE="$DIR/${CMUX_SURFACE_ID:-$CMUX_TAB_ID}.state"
BG_MARKER="$DIR/${CMUX_SURFACE_ID:-$CMUX_TAB_ID}.bg-pending"
mkdir -p "$DIR"
NOW=$(date +%s)

send() { printf '%s\n' "$1" | nc -w 1 -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1; }

fmt_clock() { date -r "$1" '+[%H:%M]' 2>/dev/null; }

# Blink the crunching bolt (filled+bright <-> outline+dim) so an active row
# visibly moves. report_meta rows are static - cmux has no animation support -
# so each frame advance rides an event that fires anyway while crunching:
# every PreToolUse (any tool call, focus-independent) and every statusLine
# tick (while the tab is focused). No events = no blink, which is honest:
# a frozen bolt means nothing has happened since.
FRAME_FILE="$DIR/${CMUX_SURFACE_ID:-$CMUX_TAB_ID}.frame"
BOLT_ICON=bolt.fill
BOLT_COLOR='#E8833A'
advance_frame() {
    local idx
    idx=$(cat "$FRAME_FILE" 2>/dev/null || echo 0)
    idx=$(( (idx + 1) % 2 ))
    printf '%s' "$idx" > "$FRAME_FILE"
    if [ "$idx" = 1 ]; then BOLT_ICON=bolt; BOLT_COLOR='#F7B267'; fi
}

render() {
    local state="$1" epoch="$2" detail="$3" text icon color
    case "$state" in
        running)    icon=$BOLT_ICON;            color=$BOLT_COLOR; text="$(fmt_clock "$epoch") crunching";;
        needsInput) icon=hand.raised.fill;      color='#E5484D'; text="$(fmt_clock "$epoch") needs you";;
        waitingBg)  icon=hourglass;              color='#0090FF'; text="$(fmt_clock "$epoch") bg agent running";;
        idle)       icon=checkmark.circle.fill; color='#46A758'; text="$(fmt_clock "$epoch") idle"; detail="";;
        *) return;;
    esac
    [ -n "$detail" ] && text="$text - $detail"
    send "report_meta claude \"$text\" --icon=$icon --color=$color --priority=1 --tab=$CMUX_TAB_ID"
}

read_state() { { read -r S_STATE; read -r S_EPOCH; read -r S_DETAIL; } < "$STATE_FILE" 2>/dev/null; }
save() { printf '%s\n%s\n%s\n' "$1" "$2" "$3" > "$STATE_FILE"; }
set_state() { save "$1" "$NOW" "$2"; render "$1" "$NOW" "$2"; }

snippet() { printf '%s' "$RAW_INPUT" | jq -r "$1 // \"\"" 2>/dev/null | tr -d '"\\\r' | tr '\n' ' ' | sed -e 's/^ *//' -e 's/ *$//' | cut -c1-48; }

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
        # agent finishes - either way any outstanding bg-agent marker is moot.
        rm -f "$BG_MARKER"
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
        # The main turn parked. If it left a background agent running (the
        # Agent tool defaults to run_in_background=true), that's not done -
        # it's still crunching via a subagent, just not visible as a tool
        # call on this session anymore.
        if [ -f "$BG_MARKER" ]; then set_state waitingBg ""; else set_state idle ""; fi
        ;;
    start)  set_state idle "";;
    busy)
        # PreToolUse: a tool is actually executing - the only hard proof that
        # a turn resumed after a permission grant (no hook fires on "user
        # answered the prompt"), so this is what corrects a stale
        # needsInput/idle row left over from before this turn. When already
        # running it re-renders with the SAME epoch (timestamp never moves),
        # purely to advance the blink frame.
        [ -f "$STATE_FILE" ] && read_state
        if [ "${S_STATE:-}" = running ]; then
            advance_frame
            render running "$S_EPOCH" "$S_DETAIL"
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
        perm_mode="$(snippet .permission_mode)"
        [ -n "$perm_mode" ] && printf '%s' "$perm_mode" > "$MODE_FILE"
        ;;
    end)
        send "clear_meta claude --tab=$CMUX_TAB_ID"
        send "clear_meta claude-info --tab=$CMUX_TAB_ID"
        rm -f "$STATE_FILE" "$BG_MARKER" "$MODE_FILE" "$FRAME_FILE" "$DIR/${CMUX_SURFACE_ID:-$CMUX_TAB_ID}.info-stamp"
        ;;
    tick)
        # $RAW_INPUT here is the statusLine JSON payload (model/effort/context
        # live here, not in hook events)
        # Keep the crunching blink moving while the tab is focused, even
        # through long thinking stretches with no tool calls.
        if [ -f "$STATE_FILE" ]; then
            read_state
            if [ "$S_STATE" = running ]; then
                advance_frame
                render running "$S_EPOCH" "$S_DETAIL"
            fi
        fi
        INFO_STAMP="$DIR/${CMUX_SURFACE_ID:-$CMUX_TAB_ID}.info-stamp"
        LAST_INFO=$(cat "$INFO_STAMP" 2>/dev/null || echo 0)
        [ $(( NOW - LAST_INFO )) -ge 5 ] || exit 0
        IFS=$'\t' read -r model effort pct <<EOF
$(printf '%s' "$RAW_INPUT" | jq -r '[.model.display_name, .effort.level, .context_window.used_percentage] | @tsv' 2>/dev/null)
EOF
        [ -n "${model:-}" ] || exit 0
        ctx_color='#46A758'
        [ "${pct:-0}" -ge 60 ] 2>/dev/null && ctx_color='#E8833A'
        [ "${pct:-0}" -ge 85 ] 2>/dev/null && ctx_color='#E5484D'
        icon="$(mode_icon "$(cat "$MODE_FILE" 2>/dev/null)")"
        send "report_meta claude-info \"$model - ${effort:-default} - ${pct:-0}% ctx\" --icon=$icon --color=$ctx_color --priority=2 --tab=$CMUX_TAB_ID"
        echo "$NOW" > "$INFO_STAMP"
        ;;
esac
exit 0
