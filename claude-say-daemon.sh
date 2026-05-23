#!/bin/bash
# Per-session singleton daemon. Streams MP3 from ElevenLabs /stream endpoint
# directly into ffplay stdin (afplay fallback if ffplay missing). Plays
# sequentially in arrival order. Streaming endpoint cuts first-byte latency
# (~600ms saved per sentence) vs the prior approach of downloading full MP3.
#
# Arg 1: queue dir (contains messages/ and daemon.lock).
#
# ElevenLabs-only strategy:
#   - Single model (eleven_v3, the latest production model as of mid-2025)
#     handles both EN and LT - 70+ languages, most expressive voice.
#   - LT detected by Lithuanian-only diacritics, forces language_code="lt"
#     so the model doesn't auto-detect as Latvian/Polish for short text.
#   - Voice character comes from the voice_id itself + voice_settings -
#     ElevenLabs has no "instructions" field like OpenAI.
#
# API key: macOS Keychain, service "claude-voice-elevenlabs-api-key".
# Add it:
#   security add-generic-password -a "$USER" \
#     -s "claude-voice-elevenlabs-api-key" -w "sk_YOUR_KEY" -U

QUEUE_DIR="${1:?queue dir required}"
MESSAGES_DIR="$QUEUE_DIR/messages"
LOCKDIR="$QUEUE_DIR/daemon.lock"
PIDFILE="$QUEUE_DIR/daemon.pid"
SESSION_ID=$(basename "$QUEUE_DIR")

# Default voice. ElevenLabs uses voice IDs, not names.
# Masculine options:
#   Adam   pNInz6obpgDQGcFmaJgB   deep, narrator-like, energetic
#   Brian  nPczCjzI2devNBz1zQrb   deep, mature, calm
#   Bill   pqHfZKP75CvOlQylNhV4   warm, deep, conversational
#   George JBFqnCBsd6RMkjVDRZzb   calm, narrative, mature
#   Roger  CwhRBWXzGAHq8TQ4Fs17   confident mid-age American, corporate counsel
# Feminine options (trained-actress / mature timbre):
#   Alice    Xb7hH8MSUJpSbSDYk0k2  confident British mid-age, theatrical
#   Matilda  XrExE9yKIg1WjnnlVkGX  warm American narrator, mature
#   Charlotte XB0fDUnXU5powFXDhCwa Swedish-accented, smooth, seductive
#   Rachel   21m00Tcm4TlvDq8ikWAM  calm American narrator, neutral
#   Sarah    EXAVITQu4vr4xnSDxMaL  soft young American
# Browse all: https://elevenlabs.io/app/voice-library
DEFAULT_VOICE="XrExE9yKIg1WjnnlVkGX"   # Matilda - mature warm narrator, deep storyteller timbre

MODEL="eleven_v3"          # latest production model (70+ langs, most expressive)
STABILITY="0.75"           # higher = steadier, more grounded delivery (older/sage feel)
SIMILARITY_BOOST="0.85"    # 0.0-1.0, voice fidelity - push deep timbre
STYLE="0.30"               # moderate expressiveness, narrator warmth
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
ELEVEN_KEY=$(security find-generic-password -s "claude-voice-elevenlabs-api-key" -w 2>/dev/null)
[ -z "$ELEVEN_KEY" ] && exit 0

shopt -s nullglob

# Returns 0 if text contains Lithuanian-only diacritics (ą č ę ė į š ų ū ž).
# Note: 'š' and 'ž' exist in both LT and LV, but ą č ę ė į ų ū are LT-only.
is_lithuanian() {
  printf '%s' "$1" | LC_ALL=en_US.UTF-8 grep -qE '[ąčęėįųūĄČĘĖĮŲŪ]'
}

# Streaming pipeline: curl streams MP3 chunks from /stream endpoint straight
# into ffplay stdin, so first audio byte plays ~150-300ms after request start
# instead of ~800ms (waiting for full MP3). Falls back to non-streaming + afplay
# if ffplay isn't available.
HAVE_FFPLAY=0
if command -v ffplay >/dev/null 2>&1; then
  HAVE_FFPLAY=1
fi

# ffplay -volume is 0-100; PLAYBACK_VOLUME is 0-1.
FFPLAY_VOLUME=$(python3 -c "print(int(float('$PLAYBACK_VOLUME')*100))")

synth_and_play_stream() {
  # $1 text, $2 voice_id
  local text="$1" voice_id="$2"
  local lang_code="en"
  if is_lithuanian "$text"; then
    lang_code="lt"
  fi
  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({
    'text': sys.argv[1],
    'model_id': sys.argv[2],
    'language_code': sys.argv[3],
    'voice_settings': {
        'stability': float(sys.argv[4]),
        'similarity_boost': float(sys.argv[5]),
        'style': float(sys.argv[6]),
        'use_speaker_boost': True,
    },
}))
" "$text" "$MODEL" "$lang_code" "$STABILITY" "$SIMILARITY_BOOST" "$STYLE")

  if [ "$HAVE_FFPLAY" -eq 1 ]; then
    # curl -> ffplay pipe. Both die together on SIGTERM via process tree walk.
    printf 'header = "xi-api-key: %s"\n' "$ELEVEN_KEY" | \
    curl -K - -sS --fail-with-body --max-time 25 \
      -A "claude-say/${SESSION_ID}" \
      -X POST "https://api.elevenlabs.io/v1/text-to-speech/${voice_id}/stream?output_format=mp3_44100_128" \
      -H "Accept: audio/mpeg" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>/dev/null | \
    ffplay -nodisp -autoexit -loglevel quiet -volume "$FFPLAY_VOLUME" -i - >/dev/null 2>&1
  else
    local out="/tmp/claude-say-audio-${SESSION_ID}-$$-$RANDOM.mp3"
    printf 'header = "xi-api-key: %s"\n' "$ELEVEN_KEY" | \
    curl -K - -sS --fail-with-body --max-time 25 \
      -A "claude-say/${SESSION_ID}" \
      -o "$out" \
      -X POST "https://api.elevenlabs.io/v1/text-to-speech/${voice_id}?output_format=mp3_44100_128" \
      -H "Accept: audio/mpeg" \
      -H "Content-Type: application/json" \
      -d "$payload" >/dev/null 2>&1
    if [ -s "$out" ] && file "$out" 2>/dev/null | grep -q 'MPEG\|Audio'; then
      afplay -v "$PLAYBACK_VOLUME" "$out" 2>/dev/null
    fi
    rm -f "$out"
  fi
}

while true; do
  files=("$MESSAGES_DIR"/*.msg)
  if [ ${#files[@]} -eq 0 ]; then
    sleep 0.1
    files=("$MESSAGES_DIR"/*.msg)
    [ ${#files[@]} -eq 0 ] && break
  fi

  # Streaming = synthesis IS playback, so we play one message at a time in
  # arrival order. The /stream endpoint cuts first-byte latency, which is the
  # actual user-perceived delay (~600ms saved per sentence).
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    TEXT=$(cat "$f" 2>/dev/null)
    BASENAME=$(basename "$f" .msg)
    VOICE_OVERRIDE="${BASENAME##*__}"
    VOICE="${VOICE_OVERRIDE:-$DEFAULT_VOICE}"
    rm -f "$f"
    [ -z "$TEXT" ] && continue

    synth_and_play_stream "$TEXT" "$VOICE"
  done
done
