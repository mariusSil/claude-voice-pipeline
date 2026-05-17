#!/bin/bash
# Per-session singleton daemon — processes a per-session say queue via edge-tts.
# Key trick: synthesize ALL pending messages in parallel (background), play in arrival order.
# So while sentence N is playing, sentences N+1, N+2... are already being downloaded.
#
# Arg 1: queue dir (contains messages/ and daemon.lock).

QUEUE_DIR="${1:?queue dir required}"
MESSAGES_DIR="$QUEUE_DIR/messages"
LOCKDIR="$QUEUE_DIR/daemon.lock"

shopt -s nullglob

# Each iteration: drain ALL .msg files, kick off parallel synthesis for each,
# then play them sequentially in arrival order (filename has microsecond timestamp prefix).
while true; do
  files=("$MESSAGES_DIR"/*.msg)
  if [ ${#files[@]} -eq 0 ]; then
    sleep 0.1
    files=("$MESSAGES_DIR"/*.msg)
    [ ${#files[@]} -eq 0 ] && break
  fi

  # Phase 1: kick off synthesis for every queued message in parallel.
  audio_paths=()
  synth_pids=()
  voices=()
  texts=()
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    TEXT=$(cat "$f" 2>/dev/null)
    BASENAME=$(basename "$f" .msg)
    VOICE="${BASENAME##*_}"
    rm -f "$f"
    [ -z "$TEXT" ] && continue

    AUDIO="/tmp/claude-say-audio-$$-${BASENAME}.mp3"
    edge-tts --voice "$VOICE" --text "$TEXT" --write-media "$AUDIO" >/dev/null 2>&1 &
    synth_pids+=("$!")
    audio_paths+=("$AUDIO")
    voices+=("$VOICE")
    texts+=("$TEXT")
  done

  # Phase 2: play each in arrival order, waiting only for its own synthesis to finish.
  for i in "${!audio_paths[@]}"; do
    PID="${synth_pids[$i]}"
    AUDIO="${audio_paths[$i]}"
    VOICE="${voices[$i]}"
    TEXT="${texts[$i]}"

    wait "$PID" 2>/dev/null
    SYNTH_RC=$?

    if [ "$SYNTH_RC" -eq 0 ] && [ -s "$AUDIO" ]; then
      afplay "$AUDIO" 2>/dev/null
    else
      # edge-tts failed (offline?). Only fall back to macOS `say` for EN voices.
      case "$VOICE" in
        en-*) say -v Samantha "$TEXT" ;;
      esac
    fi
    rm -f "$AUDIO"
  done
done

rm -rf "$LOCKDIR"
