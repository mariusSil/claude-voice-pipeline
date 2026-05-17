#!/bin/bash
# UserPromptSubmit hook:
#   - Kills any voice still playing/synthesizing from the previous turn (hard cut).
#   - Clears per-turn plan flag.
#   - Sweeps stale state from old sessions.
#   - Injects voice rules into agent context.

INPUT=$(cat)
SESSION=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('session_id', 'default'))
except:
    print('default')
" 2>/dev/null)

QUEUE_DIR="/tmp/claude-say-queue/$SESSION"

# HARD CUT: kill any in-flight voice work from the previous turn so the user
# isn't hearing the prior DONE: while starting a new prompt.
PIDFILE="$QUEUE_DIR/daemon.pid"
if [ -f "$PIDFILE" ]; then
  DAEMON_PID=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    # Kill the daemon's children first (curl mid-request, afplay mid-playback)
    pkill -P "$DAEMON_PID" 2>/dev/null
    # Then the daemon itself
    kill "$DAEMON_PID" 2>/dev/null
    # Give it a moment to clean up, then SIGKILL if still alive
    sleep 0.05
    kill -9 "$DAEMON_PID" 2>/dev/null
  fi
  rm -f "$PIDFILE"
fi

# Wipe any orphaned audio files this daemon may have left behind
rm -f /tmp/claude-say-audio-*.mp3 2>/dev/null

# Drop queue dir entirely — daemon will be respawned fresh on next claude-say call.
rm -rf "$QUEUE_DIR" 2>/dev/null

# Per-turn flag clear (so PostToolUse speaks the plan once next turn)
rm -f "/tmp/claude-plan-spoken-$SESSION"

# Sweep stale flag files older than 7 days (orphans from old sessions).
find /tmp -maxdepth 1 -name 'claude-plan-spoken-*' -type f -mtime +7 -delete 2>/dev/null

# Sweep abandoned per-session queue dirs (>1 day old).
find /tmp/claude-say-queue -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec rm -rf {} + 2>/dev/null

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "VOICE PIPELINE RULES (mandatory, every turn):\nYour voice is an extension of you — speak naturally, not as a status reporter.\n\n1. Before your FIRST tool call: one short sentence (max 14 words) saying what you're about to do.\n2. At the END of your response (last line): one short sentence (max 14 words) starting with 'DONE:' summarizing what you accomplished.\n\nLanguage: write both lines in the SAME language the user is writing in (Lithuanian if user wrote Lithuanian, English if English). The TTS provider (OpenAI tts-1, voice 'nova') handles mixed LT/EN natively in one voice — do not translate, do not switch.\n\nIf the turn was trivial (one-line answer, no real action) or you genuinely have nothing worth saying out loud, OMIT the DONE: line entirely — silence is fine. Never write filler like 'DONE: Done.' just to satisfy the rule.\n\nKeep both lines conversational, human, first-person. No emojis."
  }
}
EOF
