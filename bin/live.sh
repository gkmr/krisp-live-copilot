#!/usr/bin/env bash
# live.sh: find and print the current Krisp transcript for the krisp-* commands and skills (unofficial, not a Krisp product).
#
# Sources, in this order of trust:
#   1. pinned      a transcript the user chose with --use (until --live)
#   2. LIVE FILE   Krisp's Local Folder integration with its "live transcript" option on: the meeting folder
#                  $KRISP_DIR/Krisp Meetings/<app> meeting - <Month D, YYYY h-mm-ss PM>/ and its .md are created at call
#                  START and updated during the call. live_transcript.md lines carry the time since recording started
#                  (**00:12:34**) but no speaker labels; transcript.md, written at stop, has "**Speaker N | HH:MM:SS**".
#                  A Krisp .md written in the last LIVE_SECS (150 s), a live_transcript.md with no transcript.md beside it,
#                  or a file born after the current recording began, is the live call.
#                  Turn it on in Krisp: Settings > Integrations > Local folder > Live transcript (--doctor reads Krisp's
#                  own config, read-only, and says ON or OFF).
#   3. LIVE (AX)   fallback, macOS only: the text of the call read out of the Krisp app through accessibility, grown in
#                  $STATE/ax.md with a wall-clock stamp per line (no labels). Used only when the live file cannot answer:
#                  no fresh .md, no open live_transcript.md, and either the live option is off or Krisp is on the mic
#                  (optional helper $KRISP_MICUSERS) with no file yet. Each dump is cached AX_CACHE_SECS (15 s), so
#                  chained runs share one read. --ax always reads.
#   4. file        the same folder's .md after the call (with the live option off, Krisp writes it only at stop).
#   (the clipboard path, --clip, still works as a last resort)
# The header line says "source: live file", "source: AX", "source: AX cache" or "source: files".
#
#   live.sh                 last 40 lines of the current transcript
#   live.sh --tail N        last N lines
#   live.sh --delta         only the bytes added since the previous --delta read of the same transcript (polling)
#   live.sh --which         which transcript is current and why (one line), plus the path
#   live.sh --ax            read the Krisp app now and report what was captured (debug)
#   live.sh --new           start a fresh live buffer (a new call) without waiting for Krisp
#   live.sh --find <words>  list matching meetings, newest first (folder name, date like 10/12 or Oct 12, or a word said)
#   live.sh --use <n|path>  pin result n from the last --find (or a path) as the current transcript
#   live.sh --live          unpin: back to the live call / newest transcript
#   live.sh --me N          remember that the user is "Speaker N"
#   live.sh --clip          clipboard fallback (tap Copy on Krisp's Transcript tab first)
#   live.sh --doctor        is Krisp's live transcript option on, which file is live, is accessibility working
#   live.sh --finished      the whole transcript, only when it is a finished transcript.md (not live, not written in
#                           the last LIVE_SECS); otherwise one "not a finished transcript" line. For after-call review.
#   live.sh --status [--tail N]  one run, at most one AX read: status line (recording, timer, source, meeting folder),
#                           the doctor line, the transcript header and the last N lines (default 25)
#
# Environment (all optional):
#   KRISP_DIR        the folder chosen in Krisp's Local Folder integration (default ~/Meetings/Krisp). Read only.
#   KRISP_STATE_DIR  where offsets, pins and the live buffer go (default <repo>/.state). Never inside KRISP_DIR.
#   KRISP_CONFIG     Krisp's config file, read only by --doctor (default the macOS app support path).
#   KRISP_MICUSERS   a helper that prints the processes recording from the mic; unset means "unknown, read the app".
#   KRISP_FILE_ONLY  1 = never read the Krisp app, files only (tests, or when accessibility is not wanted).
#   KRISP_AX         1 = force the accessibility read.   LIVE_SECS (150), AX_CACHE_SECS (15): see above.
#   KRISP_DELTA_NS   a name that gives a caller its own --delta offsets (default: one shared offset per transcript).
#
# Safety: this script only reads KRISP_DIR. It refuses to run if its state folder resolves inside KRISP_DIR.
set -euo pipefail
DIR="${KRISP_DIR:-$HOME/Meetings/Krisp}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STATE="${KRISP_STATE_DIR:-$ROOT/.state}"
# never write into the recorder's folder: refuse a state folder that resolves inside KRISP_DIR
if [ -d "$DIR" ] && ! /usr/bin/env python3 -c 'import os,sys; d=os.path.realpath(sys.argv[1]); s=os.path.realpath(sys.argv[2]); sys.exit(1 if s==d or s.startswith(d.rstrip(os.sep)+os.sep) else 0)' "$DIR" "$STATE"; then
  echo "refusing to run: the state folder $STATE is inside the Krisp folder $DIR (nothing is ever written there; set KRISP_STATE_DIR elsewhere)" >&2
  exit 2
fi
mkdir -p "$STATE"
MODE="tail"; N=40
LIVE_SECS="${LIVE_SECS:-150}"
KCONF="${KRISP_CONFIG:-$HOME/Library/Application Support/krisp/userConfigs.json}"
# Krisp's own setting for the Local Folder integration (read-only): ON when saveOptions includes live_transcripts.
live_option() {
  [ -r "$KCONF" ] || { echo "unknown (Krisp config not readable)"; return 0; }
  /usr/bin/env python3 - "$KCONF" <<'PY' 2>/dev/null || echo "unknown"
import re,sys
s=open(sys.argv[1],encoding="utf-8",errors="ignore").read()
m=list(re.finditer(r'"saveOptions":\[([^\]]*)\]',s))
if not m: print("unknown (no Local Folder setting found)")
else:
    opts=m[-1].group(1)
    print("ON" if "live_transcripts" in opts else "OFF (Krisp Settings > Integrations > Local folder > Live transcript)")
PY
}
# newest first. The first check keeps GNU xargs from running a bare "ls -t" (listing the current folder) when nothing matches.
krisp_files() {
  [ -n "$(find "$DIR" -type f -name '*.md' 2>/dev/null | head -1)" ] || return 0
  find "$DIR" -type f -name '*.md' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null
}
born() { if [ "$(uname)" = "Darwin" ]; then stat -f '%B' "$1"; else stat -c '%W' "$1"; fi; }
to_secs() { printf '%s\n' "$1" | awk '{print $1}' | awk -F: '{s=0; for(i=1;i<=NF;i++) s=s*60+$i; print s+0}'; }
now_s() { date +%s; }
mtime() { if [ "$(uname)" = "Darwin" ]; then stat -f '%m' "$1"; else stat -c '%Y' "$1"; fi; }
hms_of() { if [ "$(uname)" = "Darwin" ]; then date -r "$1" '+%H:%M:%S'; else date -d "@$1" '+%H:%M:%S'; fi; }   # epoch -> HH:MM:SS
sha() { if command -v shasum >/dev/null 2>&1; then shasum; else sha1sum; fi; }   # SHA-1 either way, same keys on macOS and Linux
is_timer() { printf '%s' "$1" | grep -qE '^[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?$'; }

# ---------- the live file: newest Krisp .md, its age, and whether its call is still open ----------
# Krisp (live option ON) creates <meeting folder>/live_transcript.md at the first words of a call and writes transcript.md
# at stop, so a live_transcript.md with no transcript.md beside it is a call in progress even during a long silence.
LIVE_FILE=""; LIVE_AGE=999999; LIVE_INPROGRESS=0
find_live() {
  LIVE_FILE="$(krisp_files | head -1 || true)"
  [ -n "$LIVE_FILE" ] || return 0
  LIVE_AGE=$(( $(now_s) - $(mtime "$LIVE_FILE") ))
  local d; d="$(dirname "$LIVE_FILE")"
  if [ -f "$d/live_transcript.md" ] && [ ! -f "$d/transcript.md" ] && [ "$LIVE_AGE" -lt 10800 ]; then LIVE_INPROGRESS=1; fi
  return 0
}
krisp_running() { command -v pgrep >/dev/null 2>&1 && pgrep -x krisp >/dev/null 2>&1; }   # the app's process is "krisp" (lowercase)
MICUSERS="${KRISP_MICUSERS:-}"   # optional: a Core Audio helper that lists who records from the mic (fast, no permission)
krisp_on_mic() { local m; [ -n "$MICUSERS" ] && [ -x "$MICUSERS" ] || return 0; m="$("$MICUSERS" 2>/dev/null)" || return 0; printf '%s' "$m" | grep -qi 'krisp'; }   # unknown = yes (read the app)
# Decide whether the Krisp app must be read through accessibility. Sets AX_NEEDED=1, or AX_STATUS + SOURCE when skipped.
SOURCE=""; AX_NEEDED=0
decide_source() {
  find_live
  if [ "${KRISP_FILE_ONLY:-0}" = 1 ]; then AX_STATUS="file mode (KRISP_FILE_ONLY=1, accessibility read off)"; SOURCE="files"; return 0; fi
  if ! krisp_running; then AX_STATUS="Krisp is not running"; SOURCE="files"; return 0; fi
  if [ "$MODE" = "ax" ] || [ "${KRISP_AX:-0}" = 1 ]; then AX_NEEDED=1; return 0; fi
  if [ "$LIVE_AGE" -lt "$LIVE_SECS" ]; then
    AX_STATUS="recording, live file written ${LIVE_AGE}s ago (accessibility read skipped)"; SOURCE="live file"; return 0
  fi
  if [ "$LIVE_INPROGRESS" = 1 ]; then
    AX_STATUS="recording, live file still open for this call, quiet ${LIVE_AGE}s (accessibility read skipped)"; SOURCE="live file"; return 0
  fi
  case "$(live_option)" in
    ON*)
      if krisp_on_mic; then AX_NEEDED=1; return 0; fi   # on the mic with no file yet: the call may have just started (or micusers unknown)
      AX_STATUS="Krisp open, no recording (live file option ON, no live file, Krisp not on the mic; accessibility read skipped)"
      SOURCE="files"; return 0 ;;
  esac
  AX_NEEDED=1; return 0   # live option off or unknown: the app is the only live source
}

# ---------- LIVE: read the Krisp app through accessibility ----------
AX_SCRIPT='
on run
  set out to {}
  set timer to ""
  tell application "System Events"
    if not (exists process "krisp") then return "NOKRISP"
    tell process "krisp"
      repeat with w in windows
        set wn to ""
        try
          set wn to name of w as text
        end try
        if wn is "Krisp Notification" then
          -- calendar reminder window: not transcript
        else
          set els to {}
          try
            set els to entire contents of w
          end try
          repeat with e in els
            try
              if class of e is static text then
                set v to value of e as text
                if wn is "Krisp Widget" then
                  -- the widget also shows the noise meter ("0%"); only a clock-like value is the timer
                  if v is not "" and v contains ":" then set timer to v
                else if v is not "" then
                  set end of out to v
                end if
              end if
            end try
          end repeat
        end if
      end repeat
    end tell
  end tell
  set AppleScript'"'"'s text item delimiters to linefeed
  return "TIMER=" & timer & linefeed & (out as text)
end run
'
is_control_label() {
  case "$1" in
    "My accent"|"Others' accent"|"My noise"|"Other's noise"|"Take Notes"|"in progress"|"Krisp"|"Transcript"|"Summary"|"Notes"|"Copy"|"Transcribing"*|"Start recording"|"Stop recording"|"Recording"*) return 0 ;;
  esac
  # a bare timer like 18:20 or 1:02:33
  printf '%s' "$1" | grep -qE '^[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?$' && return 0
  return 1
}
AX_STATUS="not read"
AX_TIMER=""
AX_CACHE="$STATE/ax.cache"; AX_CACHE_SECS="${AX_CACHE_SECS:-15}"
grab_ax() {
  [ "$(uname)" = "Darwin" ] || { AX_STATUS="not macOS"; return 0; }
  command -v osascript >/dev/null 2>&1 || { AX_STATUS="no osascript"; return 0; }
  local raw rc age
  # one System Events read per AX_CACHE_SECS: chained runs (--ax then --tail, watch + coach) share the dump
  if [ -s "$AX_CACHE" ] && age=$(( $(now_s) - $(mtime "$AX_CACHE") )) && [ "$age" -lt "$AX_CACHE_SECS" ]; then
    raw="$(cat "$AX_CACHE")"; SOURCE="AX cache (${age}s old)"
  else
    raw="$(osascript -e "$AX_SCRIPT" 2>&1)" || true
    SOURCE="AX"
    case "$raw" in TIMER=*) printf '%s\n' "$raw" > "$AX_CACHE" ;; esac
  fi
  if [ "$raw" = "NOKRISP" ]; then AX_STATUS="Krisp is not running"; return 0; fi
  if printf '%s' "$raw" | grep -q 'not allowed assistive access\|osascript is not allowed\|(-1719)\|(-25211)'; then
    AX_STATUS="accessibility denied (System Settings > Privacy & Security > Accessibility: allow the app that runs this, e.g. Terminal or Claude)"; return 0
  fi
  AX_TIMER="$(printf '%s\n' "$raw" | sed -n '1s/^TIMER=//p' | tr -d '\r')"
  # only a clock-like value (12:34 or 1:02:33) is the timer; "0%" or "33%" is the widget's noise meter (before this check it reset the buffer several times in one call)
  is_timer "$AX_TIMER" || AX_TIMER=""
  local stamp; stamp="$(date '+%Y-%m-%d %H:%M:%S')"
  local added=0 total=0 last=""
  # new recording detection: the widget timer went backwards -> start a fresh buffer
  if [ -n "$AX_TIMER" ] && [ -s "$STATE/ax.timer" ] && is_timer "$(cat "$STATE/ax.timer")"; then
    local prev; prev="$(cat "$STATE/ax.timer")"
    if [ "$(printf '%s\n' "$AX_TIMER" | awk -F: '{s=0; for(i=1;i<=NF;i++) s=s*60+$i; print s}')" -lt "$(printf '%s\n' "$prev" | awk -F: '{s=0; for(i=1;i<=NF;i++) s=s*60+$i; print s}')" ] 2>/dev/null; then
      [ -s "$STATE/ax.md" ] && mv "$STATE/ax.md" "$STATE/ax-$(date '+%Y%m%d-%H%M%S').md"
      rm -f "$STATE/ax.seen" "$STATE/ax.last"
    fi
  fi
  if [ -n "$AX_TIMER" ]; then printf '%s' "$AX_TIMER" > "$STATE/ax.timer"
  elif [ -s "$STATE/ax.timer" ] && is_timer "$(cat "$STATE/ax.timer")" && [ $(( $(now_s) - $(mtime "$STATE/ax.timer") )) -lt 180 ]; then
    # the widget redraws its timer; a read can land between frames. Trust the last timer seen under 3 minutes ago.
    AX_TIMER="$(cat "$STATE/ax.timer") (seen $(( $(now_s) - $(mtime "$STATE/ax.timer") ))s ago)"
  fi
  touch "$STATE/ax.seen"
  [ -s "$STATE/ax.last" ] && last="$(cat "$STATE/ax.last")"
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | tr -d '\r')"
    [ -z "$line" ] && continue
    is_control_label "$line" && continue
    total=$((total+1))
    local h; h="$(printf '%s' "$line" | sha | cut -c1-16)"
    if grep -q "^$h$" "$STATE/ax.seen" 2>/dev/null; then continue; fi
    if [ -n "$last" ] && [ "${line#"$last"}" != "$line" ] && [ "${#line}" -gt "${#last}" ]; then
      # the last caption grew (same sentence, more words): replace it instead of appending twice
      if [ -s "$STATE/ax.md" ]; then
        /usr/bin/env python3 - "$STATE/ax.md" <<'PY'
import sys
p=sys.argv[1]; L=open(p,encoding="utf-8").read().split("\n")
# drop the final caption (last two lines: header + text) if present
while L and L[-1]=="": L.pop()
if len(L)>=2 and L[-2].startswith("**Live |"): L=L[:-2]
open(p,"w",encoding="utf-8").write("\n".join(L)+"\n")
PY
      fi
    fi
    if [ ! -s "$STATE/ax.md" ]; then
      { echo "Krisp live transcript (read from the Krisp app, started $stamp)"; echo "live"; echo "in progress"; } > "$STATE/ax.md"
    fi
    { echo "**Live | $(date '+%H:%M:%S')**"; echo "$line"; } >> "$STATE/ax.md"
    echo "$h" >> "$STATE/ax.seen"
    printf '%s' "$line" > "$STATE/ax.last"
    last="$line"; added=$((added+1))
  done < <(printf '%s\n' "$raw" | sed '1d')
  if [ -n "$AX_TIMER" ]; then AX_STATUS="recording ${AX_TIMER} on the Krisp timer, ${total} caption lines on screen, ${added} new"
  else AX_STATUS="Krisp open, no recording timer, ${total} caption lines on screen, ${added} new"; fi
  return 0
}

# ---------- clipboard fallback ----------
grab_clip() {
  command -v pbpaste >/dev/null 2>&1 || return 0
  C="$(pbpaste 2>/dev/null || true)"
  [ -z "$C" ] && return 0
  if printf '%s' "$C" | grep -q 'Speaker' && { printf '%s' "$C" | grep -qE '[0-9]{1,2}:[0-9]{2}' || [ "$(printf '%s\n' "$C" | wc -l | tr -d ' ')" -ge 3 ]; }; then
    NEW="$(printf '%s' "$C" | sha | cut -c1-12)"
    OLD="$(cat "$STATE/clip.sha" 2>/dev/null || true)"
    if [ "$NEW" != "$OLD" ]; then
      { echo "Krisp live transcript (copied from the app at $(date '+%Y-%m-%d %H:%M:%S'))"; echo "clipboard"; echo "live"; printf '%s\n' "$C"; } > "$STATE/clip.md"
      echo "$NEW" > "$STATE/clip.sha"
      [ "$MODE" = "clip" ] && echo "clip: captured $(printf '%s' "$C" | wc -c | tr -d ' ') bytes from the clipboard as the live transcript"
    else
      [ "$MODE" = "clip" ] && echo "clip: clipboard unchanged since the last capture"
    fi
  else
    [ "$MODE" = "clip" ] && echo "clip: the clipboard does not look like a Krisp transcript (tap Copy on the Transcript tab in Krisp, then run this again)"
  fi
  return 0
}

case "${1:-}" in
  --clip)  MODE="clip" ;;
  --doctor) MODE="doctor" ;;
  --ax)    MODE="ax" ;;
  --delta) MODE="delta" ;;
  --tail)  N="${2:-40}" ;;
  --which) MODE="which" ;;
  --finished) MODE="finished"; N=100000 ;;
  --status) MODE="status"; N=25; [ "${2:-}" = "--tail" ] && N="${3:-25}" ;;
  --new)   [ -s "$STATE/ax.md" ] && mv "$STATE/ax.md" "$STATE/ax-$(date '+%Y%m%d-%H%M%S').md"; rm -f "$STATE/ax.seen" "$STATE/ax.last" "$STATE/ax.timer"; echo "fresh live buffer: the next read starts a new call"; exit 0 ;;
  --live)  rm -f "$STATE/pinned.txt"; echo "unpinned: following the live call / newest transcript again"; exit 0 ;;
  --me)    echo "Speaker ${2:-1}" > "$STATE/me.txt"; echo "ok, you = Speaker ${2:-1} until the next --me"; exit 0 ;;
  --find)
    shift; Q="$*"
    QN="$(/usr/bin/env python3 - "$Q" <<'PY'
import re,sys,calendar
q=sys.argv[1].strip()
m=re.search(r'\b(\d{1,2})[/-](\d{1,2})\b',q)
if m and 1<=int(m.group(1))<=12: q=q.replace(m.group(0),f"{calendar.month_name[int(m.group(1))]} {int(m.group(2))}")
for i,name in enumerate(calendar.month_name):
    if i and re.search(rf'\b{name[:3]}\w*\s+\d{{1,2}}\b',q,re.I):
        q=re.sub(rf'\b{name[:3]}\w*\s+(\d{{1,2}})\b',lambda mm:f"{name} {int(mm.group(1))}",q,flags=re.I)
print(q)
PY
)"
    : > "$STATE/find.txt"
    i=0
    while IFS= read -r f; do
      d="$(dirname "$f")"; name="$(basename "$d")"
      hit=""
      if [ -z "$QN" ]; then hit="newest"
      elif printf '%s' "$name" | grep -qi -- "$QN"; then hit="name"
      elif grep -qi -- "$QN" "$f" 2>/dev/null; then hit="said in the call"
      fi
      [ -z "$hit" ] && continue
      i=$((i+1)); [ "$i" -gt 15 ] && break
      echo "$f" >> "$STATE/find.txt"
      dur="$(sed -n 3p "$f" 2>/dev/null | tr -d '\r')"; sz="$(wc -c < "$f" | tr -d ' ')"
      first="$(grep -v '^\*\*Speaker' "$f" | sed -n '4,40p' | grep -v '^\s*$' | head -1 | cut -c1-90)"
      echo "$i. $name | $dur | ${sz} bytes | match: $hit"
      [ -n "$first" ] && echo "   $first"
    done < <(krisp_files)
    [ "$i" -eq 0 ] && echo "no transcript matches \"$Q\" under $DIR (try a date like 10/12, the app name, or a word said in the call)"
    echo "(pin one with live.sh --use <n>; the /krisp-use command does that)"
    exit 0 ;;
  --use)
    T="${2:-}"
    if [ -f "$T" ]; then P="$T"
    elif printf '%s' "$T" | grep -qE '^[0-9]+$'; then P="$(sed -n "${T}p" "$STATE/find.txt" 2>/dev/null || true)"
    else P=""; fi
    [ -z "$P" ] || [ ! -f "$P" ] && { echo "nothing to pin: run --find first and give a result number, or a path"; exit 1; }
    printf '%s' "$P" > "$STATE/pinned.txt"; echo "pinned: $(basename "$(dirname "$P")")"; exit 0 ;;
esac

decide_source                       # the live file first; the 3.5 s accessibility read only when it cannot answer
[ "$AX_NEEDED" = 1 ] && grab_ax
[ "$MODE" = "clip" ] && grab_clip
[ "$MODE" = "ax" ] && { echo "live read: $AX_STATUS"; [ -s "$STATE/ax.md" ] && echo "buffer: $STATE/ax.md, $(wc -c < "$STATE/ax.md" | tr -d ' ') bytes, last write $(hms_of "$(mtime "$STATE/ax.md")")"; MODE="which"; }
[ "$MODE" = "clip" ] && MODE="which"
doctor_lines() {   # the health check, one item per line
  echo "krisp live transcript option: $(live_option)"
  echo "accessibility read: $AX_STATUS"
  if [ -n "$LIVE_FILE" ]; then echo "newest Krisp file: $(basename "$(dirname "$LIVE_FILE")")/$(basename "$LIVE_FILE"), last write ${LIVE_AGE}s ago, $(wc -c < "$LIVE_FILE" | tr -d ' ') bytes"; fi
}
if [ "$MODE" = "doctor" ]; then doctor_lines; MODE="which"; fi
if [ "$MODE" = "status" ]; then
  REC="idle"; TM="none"
  krisp_running || REC="Krisp not running"
  case "$AX_STATUS" in recording*) REC="recording" ;; esac
  [ -n "$AX_TIMER" ] && TM="$AX_TIMER"
  MF="none"; [ -n "$LIVE_FILE" ] && MF="$(basename "$(dirname "$LIVE_FILE")")"
  echo "status: $REC | timer $TM | source: $SOURCE | meeting: $MF"
  echo "doctor: $(doctor_lines | paste -sd '|' - | sed 's/|/ | /g')"
fi

# ---------- resolve the current transcript ----------
WHY=""
NEWEST="$LIVE_FILE"
NOW="$(now_s)"
REC_START=0
if [ -n "$AX_TIMER" ]; then REC_START=$(( NOW - $(to_secs "$AX_TIMER") - 120 )); fi
if [ -s "$STATE/pinned.txt" ] && [ -f "$(cat "$STATE/pinned.txt")" ]; then
  FILE="$(cat "$STATE/pinned.txt")"; WHY="pinned (live.sh --live to unpin)"
elif [ -n "$NEWEST" ] && [ $(( NOW - $(mtime "$NEWEST") )) -lt "$LIVE_SECS" ]; then
  FILE="$NEWEST"; WHY="LIVE FILE, Krisp is writing it during the call (Local Folder live transcript)"
elif [ -n "$NEWEST" ] && [ "$LIVE_INPROGRESS" = 1 ]; then
  FILE="$NEWEST"; WHY="LIVE FILE, still open for this call (quiet for $(( NOW - $(mtime "$NEWEST") ))s; Krisp writes transcript.md at stop)"
elif [ -n "$NEWEST" ] && [ "$REC_START" -gt 0 ] && [ "$(born "$NEWEST")" -ge "$REC_START" ]; then
  FILE="$NEWEST"; WHY="LIVE FILE, created when this recording started (quiet for $(( NOW - $(mtime "$NEWEST") ))s; Local Folder live transcript)"
elif [ -n "$AX_TIMER" ] && [ -s "$STATE/ax.md" ]; then
  FILE="$STATE/ax.md"; WHY="LIVE, read from the Krisp app (recording ${AX_TIMER} in; accessibility fallback: lines carry the wall clock, no speaker labels; turn on Krisp live transcript for labels)"
elif [ -s "$STATE/ax.md" ] && [ $(( NOW - $(mtime "$STATE/ax.md") )) -lt 10800 ] && { [ -z "$NEWEST" ] || [ "$(mtime "$STATE/ax.md")" -ge "$(mtime "$NEWEST")" ]; }; then
  FILE="$STATE/ax.md"; WHY="live buffer from the Krisp app (no recording timer right now; Krisp has not written the file yet)"
elif [ -s "$STATE/clip.md" ] && [ $(( NOW - $(mtime "$STATE/clip.md") )) -lt 10800 ] && { [ -z "$NEWEST" ] || [ "$(mtime "$STATE/clip.md")" -ge "$(mtime "$NEWEST")" ]; }; then
  FILE="$STATE/clip.md"; WHY="copied from the Krisp app (clipboard fallback)"
else
  FILE=""
  if [ -n "$(find "$DIR" -type f -name '*.md' -mmin -240 2>/dev/null | head -1)" ]; then
    FILE="$(find "$DIR" -type f -name '*.md' -mmin -240 -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1 || true)"
  fi
  if [ -n "$FILE" ]; then WHY="newest file, written in the last 4 hours, not changing now (the call has ended)"
  else
    FILE="$NEWEST"
    WHY="newest on disk, NOT live (nothing written in 4 hours and no recording in Krisp; use /krisp-find to pick another)"
  fi
fi
if [ -z "$FILE" ]; then echo "no transcript found under $DIR and no live call in Krisp ($AX_STATUS)"; exit 0; fi
KEY="$(printf '%s' "$FILE" | sha | cut -c1-12)"
[ -n "${KRISP_DELTA_NS:-}" ] && KEY="$KEY.$(printf '%s' "$KRISP_DELTA_NS" | tr -c 'A-Za-z0-9_-' '_')"
SIZE="$(wc -c < "$FILE" | tr -d ' ')"
if [ "$(uname)" = "Darwin" ]; then MT="$(stat -f '%Sm' -t '%H:%M:%S' "$FILE")"; else MT="$(stat -c '%y' "$FILE" | cut -c12-19)"; fi
ME="$(cat "$STATE/me.txt" 2>/dev/null || echo "unknown, infer from context (the user's own introduction; live.sh --me N records it)")"
LABEL="$(basename "$(dirname "$FILE")")"
[ "$FILE" = "$STATE/ax.md" ] && LABEL="live call in Krisp"
[ "$FILE" = "$STATE/clip.md" ] && LABEL="live copy from the Krisp app"
if [ "$MODE" = "finished" ]; then   # after-call review only: never hand over a call that is live or still being written
  NOTFIN=""
  case "$WHY" in LIVE*|"live buffer"*|"copied from"*) NOTFIN="the source is live: $WHY" ;; esac
  [ -n "$NOTFIN" ] || [ "$(basename "$FILE")" = "transcript.md" ] || NOTFIN="$(basename "$FILE") is not a finished transcript.md"
  [ -n "$NOTFIN" ] || [ $(( NOW - $(mtime "$FILE") )) -ge "$LIVE_SECS" ] || NOTFIN="it was written $(( NOW - $(mtime "$FILE") ))s ago"
  if [ -n "$NOTFIN" ]; then
    echo "not a finished transcript: $LABEL ($NOTFIN). Review runs only after the call, on Krisp's finished transcript.md; pick one with --find and --use."
    exit 0
  fi
fi
echo "transcript: $LABEL | $WHY | last write $MT, $SIZE bytes | source: $SOURCE | krisp: $AX_STATUS | me: $ME"
[ "$MODE" = "which" ] && { echo "path: $FILE"; exit 0; }
echo "----------"
if [ "$MODE" = "delta" ]; then
  LAST="$(cat "$STATE/$KEY" 2>/dev/null || echo 0)"
  if [ "$SIZE" -lt "$LAST" ]; then LAST=0; fi
  if [ "$SIZE" -eq "$LAST" ]; then echo "(nothing new since last read)"; else tail -c +"$((LAST+1))" "$FILE"; fi
  echo "$SIZE" > "$STATE/$KEY"
else
  tail -n "$N" "$FILE"
fi
