#!/bin/bash
# UserPromptSubmit hook: hard-cuts any prior-turn voice work for THIS session,
# clears per-turn flags, sweeps stale state, injects voice rules.

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

# Recursive bottom-up kill — handles grandchildren (curl spawned inside subshell).
kill_tree() {
  local pid=$1
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -KILL "$pid" 2>/dev/null
}

# 1. Kill any daemon for this session by recorded PID.
PIDFILE="$QUEUE_DIR/daemon.pid"
if [ -f "$PIDFILE" ]; then
  DAEMON_PID=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$DAEMON_PID" ] && kill_tree "$DAEMON_PID"
fi

# 2. Belt-and-braces: catch any daemon for this session even if pidfile was missing
#    (e.g. claude-say in mid-spawn). Match by queue dir path in cmdline.
for pid in $(pgrep -f "claude-say-daemon.sh.*$QUEUE_DIR" 2>/dev/null); do
  kill_tree "$pid"
done

# 3. Catch any stray afplay/curl bearing this session's identifier
#    (in case grandchildren got reparented to launchd before the tree kill).
#    afplay matched via its audio filename arg; curl matched via session-tagged User-Agent.
pkill -KILL -f "claude-say-audio-${SESSION}-" 2>/dev/null
pkill -KILL -f "claude-say/${SESSION}" 2>/dev/null

# 4. Wipe queue + any orphan audio files for this session.
rm -rf "$QUEUE_DIR" 2>/dev/null
rm -f "/tmp/claude-say-audio-${SESSION}-"*.mp3 2>/dev/null

# 5. Per-turn flag (so PostToolUse speaks the plan once next turn).
rm -f "/tmp/claude-plan-spoken-$SESSION"

# 6. Sweep cross-session stale state (best-effort).
find /tmp -maxdepth 1 -name 'claude-plan-spoken-*' -type f -mtime +7 -delete 2>/dev/null
find /tmp/claude-say-queue -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec rm -rf {} + 2>/dev/null

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "VOICE PIPELINE RULES (mandatory, every turn):\nYour voice is an extension of you — speak naturally, not as a status reporter.\n\n1. Before your FIRST tool call: one short sentence (max 14 words) saying what you're about to do.\n2. At the END of your response (last line): one short sentence (max 14 words) starting with 'DONE:' summarizing what you accomplished.\n\nLanguage: write both lines in the SAME language the user is writing in (Lithuanian if user wrote Lithuanian, English if English). The TTS layer auto-detects Lithuanian from diacritics and uses gpt-4o-mini-tts with explicit LT instructions for those; otherwise uses tts-1 (voice 'nova' in both cases). Do not translate or switch — just write in the user's language.\n\nIf the turn was trivial (one-line answer, no real action) or you genuinely have nothing worth saying out loud, OMIT the DONE: line entirely — silence is fine. Never write filler like 'DONE: Done.' just to satisfy the rule.\n\nKeep both lines conversational, human, first-person. No emojis."
  }
}
EOF
