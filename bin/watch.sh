#!/usr/bin/env bash
# watch.sh: notice a Krisp recording and start the hands-free coach (coach.sh); stop it when the recording ends.
# Runs forever under a LaunchAgent (launchd/com.example.krisp-watch.plist). Every INTERVAL seconds it sorts the moment into:
#   recording  Krisp's live transcript file is fresh (newest .md under FRESH seconds old), a live_transcript.md is still
#              open for this call, or the accessibility read (live.sh --ax) sees Krisp's recording timer:
#              coach on, call hook on.
#   call       optional, needs KRISP_MICUSERS and CALL_TEST: a call app is on the mic and CALL_TEST finds a call window
#              (it prints kind=video or kind=audio): call hook on, no coach. Instant, no accessibility read.
#   denied     the accessibility read was refused: back off 60 s.
#   nokrisp, idle  otherwise. The coach and the call hook stop after IDLE seconds with neither a recording nor a call.
#              A call the hook handled ends sooner: its app off the mic for OFF_LOOPS loops. Krisp often keeps recording
#              after a call; that does not restart the hook, but a new call (its app back on the mic) does.
# Why the order: the file checks cost milliseconds; the accessibility read of the Krisp app can take seconds (and much
# longer on some Krisp builds), so it runs only when Krisp is on the mic and no file answers.
#
#   watch.sh          run forever
#   watch.sh --once   classify the moment once, print "state <name> | <why>", start nothing
#
# Environment (all optional): KRISP_DIR, KRISP_STATE_DIR (as in live.sh); INTERVAL (0.5 s), IDLE (180 s), FRESH (45 s),
# OFF_LOOPS (5); KRISP_MICUSERS (a helper that prints the processes recording from the mic); CALL_APPS (regex of call
# app process names); CALL_TEST (a command that prints kind=video or kind=audio when a call window is up);
# ON_CALL_START, ON_CALL_STOP (shell commands run in the background, for example a window-layout script).
# The coach sends new transcript lines to a model about every 60 s. KRISP_COACH=0 never starts it; while a file named
# $KRISP_STATE_DIR/coach-off exists the coach is not started and a running one is stopped (touch it before a call where
# that is not acceptable, remove it after). Tell everyone on a call that it is recorded and transcribed.
# A test can pause the watcher: any $KRISP_STATE_DIR/watch-paused* file under 15 minutes old makes it stand down.
# Log: $KRISP_STATE_DIR/watch.log. Nothing here writes into the Krisp folder.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
INTERVAL="${INTERVAL:-0.5}"; IDLE="${IDLE:-180}"; FRESH="${FRESH:-45}"; OFF_LOOPS="${OFF_LOOPS:-5}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
DIR="${KRISP_DIR:-$HOME/Meetings/Krisp}"
STATE="${KRISP_STATE_DIR:-$ROOT/.state}"
if [ -d "$DIR" ] && ! /usr/bin/env python3 -c 'import os,sys; d=os.path.realpath(sys.argv[1]); s=os.path.realpath(sys.argv[2]); sys.exit(1 if s==d or s.startswith(d.rstrip(os.sep)+os.sep) else 0)' "$DIR" "$STATE"; then
  echo "refusing to run: the state folder $STATE is inside the Krisp folder $DIR (set KRISP_STATE_DIR elsewhere)" >&2
  exit 2
fi
mkdir -p "$STATE"
LOG="$STATE/watch.log"; PIDF="$STATE/coach.pid"
MICUSERS="${KRISP_MICUSERS:-}"; CALL_TEST="${CALL_TEST:-}"
ON_CALL_START="${ON_CALL_START:-}"; ON_CALL_STOP="${ON_CALL_STOP:-}"
CALL_APPS="${CALL_APPS:-comet|chrome|safari|thebrowser|zoom|whatsapp|teams|webex|slack|avconferenced|callservicesd|telephony|facetime}"
ONCE=0; [ "${1:-}" = "--once" ] && ONCE=1

mtime() { if [ "$(uname)" = "Darwin" ]; then stat -f '%m' "$1"; else stat -c '%Y' "$1"; fi; }
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
krisp_running() { command -v pgrep >/dev/null 2>&1 && pgrep -x krisp >/dev/null 2>&1; }
coach_running() { [ -s "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }
newest_md() {
  [ -n "$(find "$DIR" -type f -name '*.md' 2>/dev/null | head -1)" ] || return 0
  find "$DIR" -type f -name '*.md' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1
}
# file_status: prints a status line and returns 0 when the live file says Krisp is recording (no accessibility read)
file_status() {
  local f age d
  f="$(newest_md)"; [ -n "$f" ] || return 1
  age=$(( $(date +%s) - $(mtime "$f") )); d="$(dirname "$f")"
  if [ "$age" -lt "$FRESH" ]; then echo "live file: $(basename "$d") written ${age}s ago | live file being written"; return 0; fi
  if [ -f "$d/live_transcript.md" ] && [ ! -f "$d/transcript.md" ] && [ "$age" -lt 10800 ]; then
    echo "live file: $(basename "$d") open for this call, quiet ${age}s | live file being written"; return 0
  fi
  return 1
}
MICS=""; MICKNOWN=0
read_mics() {
  MICS=""; MICKNOWN=0
  [ -n "$MICUSERS" ] && [ -x "$MICUSERS" ] || return 1
  MICS="$("$MICUSERS" 2>/dev/null)" || return 1
  MICKNOWN=1; return 0
}
# Krisp records from a microphone right now. Unknown (no helper, or it fails) = yes, so the accessibility fallback runs.
krisp_on_mic() { [ "$MICKNOWN" = 1 ] || return 0; printf '%s' "$MICS" | grep -qi krisp; }
# a calling app (not a dictation or notes app) records from the mic too
call_app_on_mic() { [ "$MICKNOWN" = 1 ] && printf '%s' "$MICS" | grep -qiE "$CALL_APPS"; }
# a call window is up, per the optional CALL_TEST command
call_window() { local t; [ -n "$CALL_TEST" ] || return 1; t="$(sh -c "$CALL_TEST" 2>/dev/null)" && printf '%s' "$t" | grep -qE 'kind=(video|audio)'; }
hook() { [ -n "$1" ] || return 0; nohup sh -c "$1" >/dev/null 2>&1 & }
# the coach sends transcript lines to a model: KRISP_COACH=0 turns it off, and so does $STATE/coach-off while it exists
coach_allowed() { [ "${KRISP_COACH:-1}" != 0 ] && [ ! -e "$STATE/coach-off" ]; }

classify() {
  read_mics
  if ! krisp_running; then
    CAT=nokrisp; STATUS="Krisp is not running"
  elif FS="$(file_status)"; then
    CAT=recording; STATUS="$FS"
  elif [ "$HOOK_ON" = 1 ] && [ "$HOOK_CALL" = 1 ] && call_app_on_mic; then
    CAT=call; STATUS="the call app is on the mic, the call hook is handling it (accessibility read skipped)"
  elif call_app_on_mic && call_window; then
    # a call app on the mic and a call window = a call, whether or not Krisp has started recording yet
    CAT=call; STATUS="a call app on the mic and a call window"
  elif krisp_on_mic; then
    # on the mic (or unknown) with no fresh live file: read the app (live.sh caches the read for 15 s)
    local out; out="$(bash "$HERE/live.sh" --ax 2>&1)"
    STATUS="$(printf '%s\n' "$out" | head -1)"
    case "$STATUS" in
      *"on the Krisp timer"*|*"recording, live file"*) CAT=recording ;;
      *"accessibility denied"*) CAT=denied ;;
      *"not running"*) CAT=nokrisp ;;
      *) CAT=idle ;;
    esac
  else
    CAT=idle; STATUS="Krisp open, not on the mic, no live file (accessibility read skipped)"
  fi
}

LAST_LIVE=0; PREV=""; OFF=0; DONE=0; IDLEN=0; HOOK_ON=0; HOOK_CALL=0; CAT=idle; STATUS=""
if [ "$ONCE" = 1 ]; then classify; echo "state $CAT | $STATUS"; exit 0; fi
log "watch started (interval ${INTERVAL}s, call over after ${OFF_LOOPS} loops off the mic, idle ${IDLE}s)"
while true; do
  PZ="$(ls -t "$STATE"/watch-paused* 2>/dev/null | head -1)"
  if [ -n "$PZ" ] && [ $(( $(date +%s) - $(mtime "$PZ") )) -lt 900 ]; then sleep "$INTERVAL"; continue; fi
  classify
  [ "$CAT" != "$PREV" ] && { log "state $CAT | $STATUS"; PREV="$CAT"; }
  if ! coach_allowed && coach_running; then kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"; log "coach turned off (KRISP_COACH=0 or coach-off): coach stopped"; fi
  # the call is over (its app left the mic for OFF_LOOPS loops): stop the hook now, not after IDLE. Only for a call the
  # hook handled, and only while the mic list is readable.
  if [ "$HOOK_ON" = 1 ] && [ "$HOOK_CALL" = 1 ] && [ "$MICKNOWN" = 1 ]; then
    if call_app_on_mic; then OFF=0; else OFF=$((OFF + 1)); fi
    if [ "$OFF" -ge "$OFF_LOOPS" ]; then HOOK_ON=0; HOOK_CALL=0; OFF=0; DONE=1; hook "$ON_CALL_STOP"; log "call over (its app left the mic): call hook stop"; fi
  else OFF=0; fi
  case "$CAT" in
    recording|call)
      LAST_LIVE="$(date +%s)"; IDLEN=0
      # after a call-over stop (DONE), Krisp's continuing recording does not restart the hook, but a new call does
      if [ "$HOOK_ON" != 1 ] && { [ "$CAT" = call ] || [ "$DONE" != 1 ] || { call_app_on_mic && call_window; }; }; then
        HOOK_ON=1; HOOK_CALL=0; hook "$ON_CALL_START"; log "call hook start"
      fi
      [ "$CAT" = call ] && HOOK_CALL=1
      if [ "$CAT" = recording ] && coach_allowed && ! coach_running; then
        if command -v claude >/dev/null 2>&1; then
          nohup bash "$HERE/coach.sh" >> "$STATE/coach.out" 2>&1 &
          echo $! > "$PIDF"; log "recording detected: coach started pid $! | $STATUS"
        else
          [ -f "$STATE/no-claude" ] || { log "recording detected but 'claude' is not on PATH; the live buffer is still captured"; touch "$STATE/no-claude"; }
        fi
      fi ;;
    denied) sleep 60 ;;
    *)
      IDLEN=$((IDLEN + 1)); [ "$IDLEN" -ge 3 ] && DONE=0   # Krisp quiet for 3 loops: the next recording may start the hook again
      if [ "$HOOK_ON" = 1 ] && [ $(( $(date +%s) - LAST_LIVE )) -gt "$IDLE" ]; then HOOK_ON=0; HOOK_CALL=0; hook "$ON_CALL_STOP"; log "call hook stop"; fi
      if coach_running && [ $(( $(date +%s) - LAST_LIVE )) -gt "$IDLE" ]; then
        kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"; log "no recording for ${IDLE}s: coach stopped"
      fi ;;
  esac
  sleep "$INTERVAL"
done
