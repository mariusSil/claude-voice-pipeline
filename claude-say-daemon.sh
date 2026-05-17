#!/bin/bash
# Per-session singleton daemon — synthesizes via OpenAI TTS (direct API),
# played sequentially in arrival order. Pre-synthesizes next sentences in parallel
# so playback transitions are near-instant.
#
# Arg 1: queue dir (contains messages/ and daemon.lock).
#
# Configuration:
#   - DEFAULT_VOICE: edit to change default voice (nova, shimmer, alloy, echo, fable, onyx).
#   - MODEL: tts-1 (fast) or tts-1-hd (higher quality, 2x cost).
#   - API key: macOS Keychain, service "claude-voice-openai-api-key".

QUEUE_DIR="${1:?queue dir required}"
MESSAGES_DIR="$QUEUE_DIR/messages"
LOCKDIR="$QUEUE_DIR/daemon.lock"
PIDFILE="$QUEUE_DIR/daemon.pid"

DEFAULT_VOICE="nova"
MODEL="tts-1"

# Write our PID so UserPromptSubmit can cleanly kill us when a new turn starts.
echo $$ > "$PIDFILE"
trap 'rm -rf "$LOCKDIR"; rm -f "$PIDFILE"; exit 0' EXIT TERM INT

# Retrieve API key once at startup.
OPENAI_KEY=$(security find-generic-password -s "claude-voice-openai-api-key" -w 2>/dev/null)
if [ -z "$OPENAI_KEY" ]; then
  # No key → no audio. Exit silently.
  exit 0
fi

shopt -s nullglob

# JSON-encode a string safely (handles quotes, newlines, UTF-8).
json_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

synthesize_one() {
  # $1 text, $2 voice, $3 output_path
  local text="$1" voice="$2" out="$3"
  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'model': sys.argv[1], 'voice': sys.argv[2], 'input': sys.argv[3]}))" "$MODEL" "$voice" "$text")
  curl -sS --fail-with-body --max-time 20 \
    -o "$out" \
    -X POST https://api.openai.com/v1/audio/speech \
    -H "Authorization: Bearer $OPENAI_KEY" \
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

  # Phase 1: kick off parallel synthesis for every queued message.
  audio_paths=()
  synth_pids=()
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    TEXT=$(cat "$f" 2>/dev/null)
    BASENAME=$(basename "$f" .msg)
    # Filename format: <ts>__<voice_override_or_empty>
    VOICE_OVERRIDE="${BASENAME##*__}"
    VOICE="${VOICE_OVERRIDE:-$DEFAULT_VOICE}"
    rm -f "$f"
    [ -z "$TEXT" ] && continue

    AUDIO="/tmp/claude-say-audio-$$-${BASENAME}.mp3"
    ( synthesize_one "$TEXT" "$VOICE" "$AUDIO" ) &
    synth_pids+=("$!")
    audio_paths+=("$AUDIO")
  done

  # Phase 2: play each in arrival order, waiting only for its own synthesis.
  for i in "${!audio_paths[@]}"; do
    PID="${synth_pids[$i]}"
    AUDIO="${audio_paths[$i]}"

    wait "$PID" 2>/dev/null
    if [ -s "$AUDIO" ]; then
      # Verify it's actually audio (not a JSON error blob)
      if file "$AUDIO" 2>/dev/null | grep -q 'MPEG\|Audio'; then
        afplay "$AUDIO" 2>/dev/null
      fi
    fi
    rm -f "$AUDIO"
  done
done
