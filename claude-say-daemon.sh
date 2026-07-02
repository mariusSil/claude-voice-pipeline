#!/bin/bash
# Per-session singleton daemon. Synthesizes speech via Google Cloud Text-to-Speech
# (Chirp 3 HD) and plays it through ffplay (afplay fallback). Messages play
# sequentially in arrival order.
#
# Arg 1: queue dir (contains messages/ and daemon.lock).
#
# Google Cloud Text-to-Speech, Chirp 3 HD (replaced ElevenLabs 2026-06-02):
#   - Chirp 3 HD lt-LT are natural neural voices; the free tier (~1M chars/mo)
#     covers our ~210k/mo ≈ €0.
#   - The voice NAME carries the language (lt-LT-...), so languageCode is
#     derived from the voice name — no diacritic guessing needed.
#   - Chirp 3 HD does NOT support pitch, so we deepen locally with ffmpeg
#     (DEEPEN_FACTOR < 1.0 = deeper/lower).
#
# Auth: Application Default Credentials via `gcloud auth print-access-token`.
# If gcloud isn't authed, the daemon stays silent.

QUEUE_DIR="${1:?queue dir required}"
MESSAGES_DIR="$QUEUE_DIR/messages"
LOCKDIR="$QUEUE_DIR/daemon.lock"
PIDFILE="$QUEUE_DIR/daemon.pid"
SESSION_ID=$(basename "$QUEUE_DIR")

# lt-LT voice list: curl .../v1/voices?languageCode=lt-LT
#   Deep male: Enceladus, Algenib, Alnilam, Schedar, Charon
#   Female:    Aoede, Kore, Leda, Sulafat
GOOGLE_PROJECT="silotech-workspace"
TTS_ENDPOINT="https://texttospeech.googleapis.com/v1/text:synthesize"
DEFAULT_VOICE="lt-LT-Chirp3-HD-Enceladus"   # deep male
DEEPEN_FACTOR="0.85"        # <1.0 = deeper (ffmpeg pitch shift); 0.82-0.88 sweet spot
PLAYBACK_VOLUME="0.7"

LOG_FILE="$HOME/.claude/voice-pipeline/voice.log"
log_event() {
  printf '%s [%s] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S.%3N')" "${SESSION_ID:0:8}" "$1" "${2:-}" >> "$LOG_FILE" 2>/dev/null
}

# Write our PID for the kill-on-new-prompt hook.
echo $$ > "$PIDFILE"
log_event "daemon-up" "pid=$$"

# Aggressively kill all our descendants on exit so UserPromptSubmit-triggered
# SIGTERM cleanly stops in-flight curl and ffplay.
kill_descendants() {
  local pid=$1
  local kids
  kids=$(pgrep -P "$pid" 2>/dev/null)
  for kid in $kids; do
    kill_descendants "$kid"
  done
  kill -KILL "$pid" 2>/dev/null
}
on_exit() {
  for kid in $(pgrep -P $$ 2>/dev/null); do
    kill_descendants "$kid"
  done
  # Only remove lock/pidfile if they still belong to us. Prevents a freshly
  # spawned successor daemon from having its lock wiped by our cleanup.
  local recorded_pid
  recorded_pid=$(cat "$PIDFILE" 2>/dev/null)
  if [ "$recorded_pid" = "$$" ]; then
    rm -rf "$LOCKDIR"
    rm -f "$PIDFILE"
  fi
}
trap 'on_exit; exit 0' EXIT TERM INT HUP

# Auth: Google access token via gcloud (ADC). Daemon is short-lived (spawned per
# message batch, exits when queue drains), so a token fetched once at startup is
# valid for its whole life. If gcloud isn't authed, stay silent.
# Pinned to silo@silotech.xyz (the account with TTS access to project
# silotech-workspace) so voice works regardless of which gcloud account is active.
GTOKEN=$(gcloud auth print-access-token --account=silo@silotech.xyz 2>/dev/null)
[ -z "$GTOKEN" ] && exit 0

# Push-to-mute via Option key. The Swift helper queries the system-wide
# modifier state via CGEventSource (no focus needed). We compile it once
# and cache the binary; subsequent invocations run in ~30ms.
OPT_BIN="$HOME/.claude/voice-pipeline/option-state"
OPT_SRC="$HOME/.claude/voice-pipeline/option-state.swift"
if [ ! -x "$OPT_BIN" ] && [ -f "$OPT_SRC" ] && command -v swiftc >/dev/null 2>&1; then
  swiftc "$OPT_SRC" -o "$OPT_BIN" 2>/dev/null
fi

is_option_held() {
  [ -x "$OPT_BIN" ] || return 1
  [ "$("$OPT_BIN" 2>/dev/null)" = "1" ]
}

# Wait while Option is held, up to MAX_HOLD seconds. Returns 0 always
# (we don't drop messages on long holds — the user explicitly chose to pause).
wait_until_option_released() {
  local waited_ms=0
  local max_ms=60000
  while is_option_held; do
    sleep 0.1
    waited_ms=$((waited_ms + 100))
    if [ "$waited_ms" -ge "$max_ms" ]; then
      log_event "option-hold-cap" "waited_ms=$waited_ms"
      break
    fi
  done
  [ "$waited_ms" -gt 0 ] && log_event "option-released" "waited_ms=$waited_ms"
}

shopt -s nullglob

# Player + deepen tooling detection.
HAVE_FFPLAY=0
command -v ffplay >/dev/null 2>&1 && HAVE_FFPLAY=1
HAVE_FFMPEG=0
command -v ffmpeg >/dev/null 2>&1 && HAVE_FFMPEG=1

# ffplay -volume is 0-100; PLAYBACK_VOLUME is 0-1.
FFPLAY_VOLUME=$(python3 -c "print(int(float('$PLAYBACK_VOLUME')*100))")
# atempo factor that cancels asetrate's slowdown (1/DEEPEN_FACTOR).
ATEMPO=$(python3 -c "print(1.0/float('$DEEPEN_FACTOR'))")

synth_and_play() {
  # $1 text, $2 voice name (e.g. lt-LT-Chirp3-HD-Enceladus)
  local text="$1" voice="$2"
  # languageCode is the first two dash-segments of the voice name: lt-LT-... -> lt-LT
  local lang
  lang=$(printf '%s' "$voice" | cut -d- -f1-2)

  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({
    'input': {'text': sys.argv[1]},
    'voice': {'languageCode': sys.argv[2], 'name': sys.argv[3]},
    'audioConfig': {'audioEncoding': 'MP3', 'sampleRateHertz': 44100},
}))
" "$text" "$lang" "$voice")

  local base="/tmp/claude-say-audio-${SESSION_ID}-$$-$RANDOM"
  local raw="${base}.mp3"

  # Google Cloud TTS. -A tags the User-Agent with the session id so the
  # UserPromptSubmit kill-hook can pkill -f "claude-say/<session>" mid-flight.
  printf '%s' "$payload" | curl -sS --fail-with-body --max-time 25 \
    -A "claude-say/${SESSION_ID}" \
    -H "Authorization: Bearer $GTOKEN" \
    -H "x-goog-user-project: $GOOGLE_PROJECT" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d @- \
    "$TTS_ENDPOINT" 2>/dev/null | \
  python3 -c "
import sys, json, base64
try:
    d = json.load(sys.stdin)
    sys.stdout.buffer.write(base64.b64decode(d['audioContent']))
except Exception:
    pass" > "$raw"

  if [ ! -s "$raw" ]; then
    rm -f "$raw"
    return 1
  fi

  # Chirp 3 HD has no pitch control — deepen locally with ffmpeg.
  # asetrate lowers pitch (and slows); atempo restores the original tempo.
  local play="$raw"
  if [ "$HAVE_FFMPEG" -eq 1 ] && [ "$DEEPEN_FACTOR" != "1.0" ]; then
    local deep="${base}-deep.mp3"
    if ffmpeg -y -i "$raw" -af "asetrate=44100*${DEEPEN_FACTOR},aresample=44100,atempo=${ATEMPO}" "$deep" 2>/dev/null && [ -s "$deep" ]; then
      play="$deep"
    fi
  fi

  # Players renamed via `exec -a` so the kill-hook's pkill -f finds them by
  # session id even after launchd reparents them when the daemon dies.
  if [ "$HAVE_FFPLAY" -eq 1 ]; then
    ( exec -a "ffplay-claude-say-${SESSION_ID}" ffplay -nodisp -autoexit -loglevel quiet -volume "$FFPLAY_VOLUME" -i "$play" >/dev/null 2>&1 )
  else
    ( exec -a "afplay-claude-say-${SESSION_ID}" afplay -v "$PLAYBACK_VOLUME" "$play" 2>/dev/null )
  fi

  rm -f "$raw" "${base}-deep.mp3"
}

while true; do
  files=("$MESSAGES_DIR"/*.msg)
  if [ ${#files[@]} -eq 0 ]; then
    # Two-stage idle drain. The longer second wait closes the window where
    # claude-say is writing a new .msg while we're about to exit, which would
    # otherwise leave an orphan message and require the next stop-hook to
    # rescue it.
    sleep 0.3
    files=("$MESSAGES_DIR"/*.msg)
    if [ ${#files[@]} -eq 0 ]; then
      sleep 0.3
      files=("$MESSAGES_DIR"/*.msg)
      [ ${#files[@]} -eq 0 ] && break
    fi
  fi

  # Synthesis IS playback (we wait for the player), so messages play one at a
  # time in arrival order.
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    TEXT=$(cat "$f" 2>/dev/null)
    BASENAME=$(basename "$f" .msg)
    VOICE_OVERRIDE="${BASENAME##*__}"
    VOICE="${VOICE_OVERRIDE:-$DEFAULT_VOICE}"
    rm -f "$f"
    [ -z "$TEXT" ] && continue

    wait_until_option_released
    log_event "tts-start" "chars=${#TEXT} voice=$VOICE"
    T0=$(python3 -c 'import time; print(int(time.time()*1000))')
    synth_and_play "$TEXT" "$VOICE"
    T1=$(python3 -c 'import time; print(int(time.time()*1000))')
    log_event "tts-end" "dur_ms=$((T1-T0))"
  done
done
