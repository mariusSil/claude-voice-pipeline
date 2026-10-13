#!/bin/bash
# Codex UserPromptSubmit hook:
# - hard-cuts any leftover speech from the same session
# - injects voice + memory/skills hygiene context for this turn

INPUT=$(cat)

SESSION=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("session_id", "default"))
except Exception:
    print("default")
')

QUEUE_DIR="/tmp/claude-say-queue/$SESSION"
PIDFILE="$QUEUE_DIR/daemon.pid"

kill_tree() {
  local sig=$1 pid=$2
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$sig" "$child"
  done
  kill -"$sig" "$pid" 2>/dev/null
}

# 1) Kill daemon by pidfile (TERM then KILL).
if [ -f "$PIDFILE" ]; then
  DAEMON_PID=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$DAEMON_PID" ]; then
    kill_tree TERM "$DAEMON_PID"
    sleep 0.15
    kill_tree KILL "$DAEMON_PID"
  fi
fi

# 2) Safety: catch any daemon/player/curl leftovers tagged for this session.
for pid in $(pgrep -f "claude-say-daemon.sh.*$QUEUE_DIR" 2>/dev/null); do
  kill_tree KILL "$pid"
done
pkill -KILL -f "ffplay-claude-say-${SESSION}" 2>/dev/null
pkill -KILL -f "afplay-claude-say-${SESSION}" 2>/dev/null
pkill -KILL -f "claude-say-audio-${SESSION}-" 2>/dev/null
pkill -KILL -f "claude-say/${SESSION}" 2>/dev/null

# 3) Wipe queue/audio leftovers.
rm -rf "$QUEUE_DIR" 2>/dev/null
rm -f "/tmp/claude-say-audio-${SESSION}-"*.mp3 2>/dev/null

# 4) Light stale cleanup.
find /tmp/claude-say-queue -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec rm -rf {} + 2>/dev/null

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "VOICE RULE: At the very end of your final answer, add one short sentence (max 14 words) starting with DONE: summarizing what you completed in first person, matching user language. If user explicitly asks for spoken text, use SAY: instead. MEMORY/SKILLS HYGIENE: You are Codex, not Claude. Prefer Codex tools and configured Codex skills. Ignore Claude-specific workflow assumptions unless user explicitly asks for Claude behavior. Memory writes must keep only durable Codex-relevant user preferences and project facts; do not persist Claude-only conventions unless user explicitly asks."
  }
}
JSON
