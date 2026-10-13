#!/bin/bash
# Per-session singleton daemon. Synthesizes speech via Google Cloud Text-to-Speech
# (Chirp 3 HD) and plays it through ffplay (afplay fallback). Messages play
# sequentially in arrival order.
#
# Arg 1: queue dir (contains messages/ and daemon.lock).
#
# Google Cloud Text-to-Speech, Chirp 3 HD:
#   - Chirp 3 HD lt-LT are natural neural voices; the free tier (~1M chars/mo)
#     covers our ~210k/mo ≈ €0.
#   - The voice NAME carries the language (lt-LT-...), so languageCode is
#     derived from the voice name — no diacritic guessing needed.
#   - Chirp 3 HD does NOT support pitch, so we deepen locally with ffmpeg
#     (DEEPEN_FACTOR < 1.0 = deeper/lower).
#
# Auth follows the same Google/Gemini credential mapping used elsewhere:
# GOOGLE_ACCESS_TOKEN, then active `gcloud auth print-access-token`, then ADC.
# Project comes from GOOGLE_CLOUD_PROJECT / GCP_PROJECT / CLOUDSDK_CORE_PROJECT,
# falling back to `gcloud config get-value project`. No hardcoded account.

QUEUE_DIR="${1:?queue dir required}"
MESSAGES_DIR="$QUEUE_DIR/messages"
LOCKDIR="$QUEUE_DIR/daemon.lock"
PIDFILE="$QUEUE_DIR/daemon.pid"
SESSION_ID=$(basename "$QUEUE_DIR")

# lt-LT voice list: curl .../v1/voices?languageCode=lt-LT
#   Deep male: Enceladus, Algenib, Alnilam, Schedar, Charon
#   Female:    Aoede, Kore, Leda, Sulafat
GOOGLE_PROJECT="${GOOGLE_CLOUD_PROJECT:-${GCP_PROJECT:-${CLOUDSDK_CORE_PROJECT:-}}}"
if [ -z "$GOOGLE_PROJECT" ] && command -v gcloud >/dev/null 2>&1; then
  GCLOUD_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  if [ -n "$GCLOUD_PROJECT" ] && [ "$GCLOUD_PROJECT" != "(unset)" ]; then
    GOOGLE_PROJECT="$GCLOUD_PROJECT"
  fi
fi
# Paskutinė atrama: projektas iš servisinės paskyros rakto, kad demonas
# nenumirtų vien todėl, kad gcloud nesukonfigūruotas.
if [ -z "$GOOGLE_PROJECT" ]; then
  _sa_key="${GOOGLE_TTS_SA_KEY:-$HOME/.config/silo/transcriber-sa.json}"
  [ -r "$_sa_key" ] && GOOGLE_PROJECT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("project_id",""))' "$_sa_key" 2>/dev/null || true)
fi
TTS_ENDPOINT="${GOOGLE_TTS_ENDPOINT:-https://texttospeech.googleapis.com/v1/text:synthesize}"
DEFAULT_VOICE="${GOOGLE_TTS_VOICE:-lt-LT-Chirp3-HD-Enceladus}"   # deep male
DEEPEN_FACTOR="${GOOGLE_TTS_DEEPEN_FACTOR:-0.85}"                # <1.0 = deeper
PLAYBACK_VOLUME="${GOOGLE_TTS_PLAYBACK_VOLUME:-0.7}"
GOOGLE_TTS_SPEED="${GOOGLE_TTS_SPEED:-1.2}"                      # >1.0 = faster playback
# Google Cloud API account for the access token. The machine's active gcloud
# account (marius personal) lacks serviceusage.services.use on the TTS project,
# so synth returns 403 and nothing plays. Pin the silo@ account here without
# changing the global active account (other flows rely on it). Override with
# GOOGLE_TTS_ACCOUNT; set empty to fall back to whatever gcloud active account is.
GOOGLE_TTS_ACCOUNT="${GOOGLE_TTS_ACCOUNT-silo@silotech.xyz}"

LOG_FILE="$HOME/.claude/voice-pipeline/voice.log"
log_event() {
  printf '%s [%s] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${SESSION_ID:0:8}" "$1" "${2:-}" >> "$LOG_FILE" 2>/dev/null
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
  [ "$(cat /tmp/claude-say-play.lock/pid 2>/dev/null)" = "$$" ] && rm -rf /tmp/claude-say-play.lock
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

# Servisinės paskyros raktas -> access token, tik openssl + curl, be gcloud.
# Naudojam pirmiau už gcloud, nes vartotojo OAuth tokenas periodiškai miršta
# (07-15..07-17 ir 08-01 gedimai: 81 auth-missing, 0 tts-start per dieną).
SA_KEY="${GOOGLE_TTS_SA_KEY:-$HOME/.config/silo/transcriber-sa.json}"

sa_access_token() {
  [ -r "$SA_KEY" ] || return 1
  command -v openssl >/dev/null 2>&1 || return 1

  local b64u='openssl base64 -A | tr "+/" "-_" | tr -d "="'
  local email token_uri now exp header claims signing sig assertion keyfile resp
  email=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["client_email"])' "$SA_KEY" 2>/dev/null) || return 1
  token_uri=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["token_uri"])' "$SA_KEY" 2>/dev/null) || return 1
  now=$(date +%s); exp=$((now + 3600))

  header=$(printf '{"alg":"RS256","typ":"JWT"}' | eval "$b64u")
  claims=$(printf '{"iss":"%s","scope":"https://www.googleapis.com/auth/cloud-platform","aud":"%s","iat":%s,"exp":%s}' \
    "$email" "$token_uri" "$now" "$exp" | eval "$b64u")
  signing="${header}.${claims}"

  keyfile=$(mktemp) || return 1
  python3 -c 'import json,sys;sys.stdout.write(json.load(open(sys.argv[1]))["private_key"])' "$SA_KEY" > "$keyfile" 2>/dev/null || { rm -f "$keyfile"; return 1; }
  sig=$(printf '%s' "$signing" | openssl dgst -sha256 -sign "$keyfile" 2>/dev/null | eval "$b64u")
  rm -f "$keyfile"
  [ -n "$sig" ] || return 1
  assertion="${signing}.${sig}"

  resp=$(curl -s --max-time 20 -X POST "$token_uri" \
    -d 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer' \
    --data-urlencode "assertion=${assertion}" 2>/dev/null) || return 1
  token=$(printf '%s' "$resp" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
  [ -n "$token" ] || return 1
  printf '%s' "$token"
}

resolve_google_access_token() {
  if [ -n "${GOOGLE_ACCESS_TOKEN:-}" ]; then
    printf '%s' "$GOOGLE_ACCESS_TOKEN"
    return 0
  fi

  local sa_tok
  sa_tok=$(sa_access_token || true)
  if [ -n "$sa_tok" ]; then
    printf '%s' "$sa_tok"
    return 0
  fi

  command -v gcloud >/dev/null 2>&1 || return 1

  local token acct_arg=""
  [ -n "$GOOGLE_TTS_ACCOUNT" ] && acct_arg="--account=$GOOGLE_TTS_ACCOUNT"
  token=$(gcloud auth print-access-token $acct_arg 2>/dev/null || true)
  if [ -n "$token" ]; then
    printf '%s' "$token"
    return 0
  fi

  token=$(gcloud auth application-default print-access-token 2>/dev/null || true)
  if [ -n "$token" ]; then
    printf '%s' "$token"
    return 0
  fi

  return 1
}

if [ -z "$GOOGLE_PROJECT" ]; then
  log_event "auth-missing" "missing GOOGLE_CLOUD_PROJECT/GCP_PROJECT and no gcloud project"
  exit 0
fi

GTOKEN=$(resolve_google_access_token)
if [ -z "$GTOKEN" ]; then
  log_event "auth-missing" "no GOOGLE_ACCESS_TOKEN, gcloud user token, or ADC token"
  exit 0
fi

# Push-to-mute via Option key. The Swift helper queries the system-wide
# modifier state via CGEventSource (no focus needed). We compile it once
# and cache the binary; subsequent invocations run in ~30ms.
OPT_BIN="$HOME/.claude/voice-pipeline/option-state"
OPT_SRC="$HOME/.claude/voice-pipeline/option-state.swift"
if [ ! -x "$OPT_BIN" ] && [ -f "$OPT_SRC" ] && command -v swiftc >/dev/null 2>&1; then
  swiftc "$OPT_SRC" -o "$OPT_BIN" 2>/dev/null
fi

modifier_state() {
  [ -x "$OPT_BIN" ] || { echo 0; return; }
  "$OPT_BIN" 2>/dev/null || echo 0
}

is_option_held() {
  [ "$(modifier_state)" = "1" ]
}

PLAY_LOCK="/tmp/claude-say-play.lock"
acquire_play_lock() {
  local waited=0 holder
  until mkdir "$PLAY_LOCK" 2>/dev/null; do
    holder=$(cat "$PLAY_LOCK/pid" 2>/dev/null)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$PLAY_LOCK"; continue
    fi
    sleep 0.2; waited=$((waited + 1))
    # 10 min cap: a stuck lock must not silence everything forever.
    [ "$waited" -ge 3000 ] && { log_event "play-lock-timeout" ""; rm -rf "$PLAY_LOCK"; }
  done
  echo $$ > "$PLAY_LOCK/pid"
  [ "$waited" -gt 0 ] && log_event "play-lock-waited" "ms=$((waited * 200))"
  return 0
}
release_play_lock() {
  [ "$(cat "$PLAY_LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$PLAY_LOCK"
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
# atempo restores tempo after asetrate's slowdown, then scales by GOOGLE_TTS_SPEED (>1 = faster).
ATEMPO=$(python3 -c "print(float('$GOOGLE_TTS_SPEED')/float('$DEEPEN_FACTOR'))")

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

  # One sentence at a time across ALL sessions (Claude and Codex): synthesis runs
  # in parallel per session, but playback waits for the global lock, so voices
  # queue up instead of talking over each other. The lock is a directory with
  # the holder PID; a dead holder's lock is taken over.
  acquire_play_lock || { rm -f "$raw" "${base}-deep.mp3"; return 0; }

  # Players renamed via `exec -a` so the kill-hook's pkill -f finds them by
  # session id even after launchd reparents them when the daemon dies.
  if [ "$HAVE_FFPLAY" -eq 1 ]; then
    ( exec -a "ffplay-claude-say-${SESSION_ID}" ffplay -nodisp -autoexit -loglevel quiet -volume "$FFPLAY_VOLUME" -i "$play" >/dev/null 2>&1 ) &
  else
    ( exec -a "afplay-claude-say-${SESSION_ID}" afplay -v "$PLAYBACK_VOLUME" "$play" 2>/dev/null ) &
  fi
  local player=$!
  # While playing, Control+Option+Command stops every voice and clears queues.
  while kill -0 "$player" 2>/dev/null; do
    if [ "$(modifier_state)" = "2" ]; then
      log_event "stop-combo" ""
      bash "$HOME/.claude/voice-pipeline/voicestop"
      break
    fi
    sleep 0.15
  done
  wait "$player" 2>/dev/null
  release_play_lock

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
