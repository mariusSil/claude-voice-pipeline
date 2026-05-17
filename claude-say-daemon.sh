#!/bin/bash
# Per-session singleton daemon — synthesizes via OpenAI TTS (direct API),
# plays sequentially in arrival order, pre-synthesizes in parallel.
#
# Arg 1: queue dir (contains messages/ and daemon.lock).
#
# Two-model strategy:
#   - English / non-LT text → tts-1 (cheap, fast).
#   - Lithuanian (LT diacritics detected) → gpt-4o-mini-tts with explicit
#     'speak in Lithuanian' instructions, because tts-1 auto-detects from
#     text and frequently mistakes short Lithuanian for Latvian.
#
# API key: macOS Keychain, service "claude-voice-openai-api-key".

QUEUE_DIR="${1:?queue dir required}"
MESSAGES_DIR="$QUEUE_DIR/messages"
LOCKDIR="$QUEUE_DIR/daemon.lock"
PIDFILE="$QUEUE_DIR/daemon.pid"
SESSION_ID=$(basename "$QUEUE_DIR")

DEFAULT_VOICE="onyx"
MODEL_EN="tts-1-hd"
MODEL_LT="gpt-4o-mini-tts"
EN_SPEED="1.35"
LT_INSTRUCTIONS="Speak in natural, fluent Lithuanian (lietuvių kalba). The text is Lithuanian, NOT Latvian, NOT Polish. Voice: deep, calm, masculine, confident, decisive. Pace: quick and energetic, faster than default, brisk. Tone: matter-of-fact, like a senior engineer giving a status update."
PLAYBACK_VOLUME="0.7"

# Write our PID for the kill-on-new-prompt hook.
echo $$ > "$PIDFILE"

# Aggressively kill all our descendants on exit so UserPromptSubmit-triggered
# SIGTERM cleanly stops in-flight curl and afplay.
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
  rm -rf "$LOCKDIR"
  rm -f "$PIDFILE"
}
trap 'on_exit; exit 0' EXIT TERM INT HUP

# Retrieve API key once at startup.
OPENAI_KEY=$(security find-generic-password -s "claude-voice-openai-api-key" -w 2>/dev/null)
[ -z "$OPENAI_KEY" ] && exit 0

shopt -s nullglob

# Returns 0 if text contains Lithuanian-only diacritics (ą č ę ė į š ų ū ž).
# Note: 'š' and 'ž' exist in both LT and LV, but ą č ę ė į ų ū are LT-only.
is_lithuanian() {
  printf '%s' "$1" | LC_ALL=en_US.UTF-8 grep -qE '[ąčęėįųūĄČĘĖĮŲŪ]'
}

synthesize_one() {
  # $1 text, $2 voice, $3 output_path
  local text="$1" voice="$2" out="$3"
  local payload
  if is_lithuanian "$text"; then
    payload=$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'voice': sys.argv[2],
    'input': sys.argv[3],
    'instructions': sys.argv[4],
}))
" "$MODEL_LT" "$voice" "$text" "$LT_INSTRUCTIONS")
  else
    payload=$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'voice': sys.argv[2],
    'input': sys.argv[3],
    'speed': float(sys.argv[4]),
}))
" "$MODEL_EN" "$voice" "$text" "$EN_SPEED")
  fi
  # User-Agent embeds session id so UserPromptSubmit can pkill -f us by session
  # even if process tree walking misses orphan grandchildren.
  # Auth header passed via stdin config (-K -) so the API key never appears in argv/ps.
  printf 'header = "Authorization: Bearer %s"\n' "$OPENAI_KEY" | \
  curl -K - -sS --fail-with-body --max-time 25 \
    -A "claude-say/${SESSION_ID}" \
    -o "$out" \
    -X POST https://api.openai.com/v1/audio/speech \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null 2>&1
}

while true; do
  files=("$MESSAGES_DIR"/*.msg)
  if [ ${#files[@]} -eq 0 ]; then
    sleep 0.1
    files=("$MESSAGES_DIR"/*.msg)
    [ ${#files[@]} -eq 0 ] && break
  fi

  # Phase 1: kick off parallel synthesis for all queued messages.
  audio_paths=()
  synth_pids=()
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    TEXT=$(cat "$f" 2>/dev/null)
    BASENAME=$(basename "$f" .msg)
    VOICE_OVERRIDE="${BASENAME##*__}"
    VOICE="${VOICE_OVERRIDE:-$DEFAULT_VOICE}"
    rm -f "$f"
    [ -z "$TEXT" ] && continue

    # Include session id in audio filename so the hook can pkill by session.
    AUDIO="/tmp/claude-say-audio-${SESSION_ID}-${BASENAME}.mp3"
    ( synthesize_one "$TEXT" "$VOICE" "$AUDIO" ) &
    synth_pids+=("$!")
    audio_paths+=("$AUDIO")
  done

  # Phase 2: play in arrival order, waiting only for each's synthesis.
  for i in "${!audio_paths[@]}"; do
    PID="${synth_pids[$i]}"
    AUDIO="${audio_paths[$i]}"

    wait "$PID" 2>/dev/null
    if [ -s "$AUDIO" ] && file "$AUDIO" 2>/dev/null | grep -q 'MPEG\|Audio'; then
      afplay -v "$PLAYBACK_VOLUME" "$AUDIO" 2>/dev/null
    fi
    rm -f "$AUDIO"
  done
done
