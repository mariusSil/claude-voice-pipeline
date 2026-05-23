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
# Two-phase: SIGTERM first so the daemon's `on_exit` trap can run and stop
# in-flight ffplay/curl cleanly; then SIGKILL anything still alive.
kill_tree() {
  local sig=$1 pid=$2
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$sig" "$child"
  done
  kill -"$sig" "$pid" 2>/dev/null
}

# 1. Kill any daemon for this session by recorded PID.
PIDFILE="$QUEUE_DIR/daemon.pid"
if [ -f "$PIDFILE" ]; then
  DAEMON_PID=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$DAEMON_PID" ]; then
    kill_tree TERM "$DAEMON_PID"
    # Give trap a brief window to cascade SIGTERM to curl/ffplay.
    sleep 0.15
    kill_tree KILL "$DAEMON_PID"
  fi
fi

# 2. Belt-and-braces: catch any daemon for this session even if pidfile was missing
#    (e.g. claude-say in mid-spawn). Match by queue dir path in cmdline.
for pid in $(pgrep -f "claude-say-daemon.sh.*$QUEUE_DIR" 2>/dev/null); do
  kill_tree KILL "$pid"
done

# 3. Catch any stray players/curl bearing this session's identifier
#    (in case grandchildren got reparented to launchd before the tree kill).
#    ffplay/afplay are renamed via `exec -a` to embed the session ID in argv[0];
#    curl is matched via its session-tagged User-Agent.
pkill -KILL -f "ffplay-claude-say-${SESSION}" 2>/dev/null
pkill -KILL -f "afplay-claude-say-${SESSION}" 2>/dev/null
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
    "additionalContext": "VOICE PIPELINE RULE (fires once at session end, spoken aloud via TTS):\n\nLast line of your final response: ONE short sentence (max 14 words) starting with 'DONE:' that summarizes what you accomplished. Always include it, even for trivial turns. Match the user's language (LT if they wrote LT). First person.\n\nWRITE FOR THE EAR, NOT THE LOG:\n- Vary openers. Do NOT default to 'Paaiškinau/Patikrinau/Padariau/Sugeneravau...' every turn. Lead with the result or punchline when possible.\n- Use plain Lithuanian when the user wrote LT. Avoid English tech tokens if a normal word works: 'eilė' not 'queue', 'klaida' not 'bug', 'srautas' not 'pipeline'. Keep proper nouns (product names, brands, people) untouched.\n- NEVER use em-dash. Use a comma or 'ir'.\n- Avoid apostrophe-suffix tokens read aloud ('task'ą', 'log'ą', 'endpoint'as', 'bug'o'). Rephrase: 'užduotis', 'žurnalas', 'galas', 'klaida'.\n- Do NOT use the words 'DONE', 'SAY', or 'plan' INSIDE the spoken text - they confuse the listener (the 'DONE:' prefix itself is stripped before TTS).\n- One clean clause where possible. If two clauses, link with 'ir' or a comma. Three commas in one sentence is too many for the ear.\n- No filler like 'DONE: Done.' or 'DONE: Padaryta.' Say WHAT got done.\n\nGOOD examples:\n  DONE: Parser pataisytas, visi šeši failai jau transkribuojami.\n  DONE: Pelno prognozė 2026-iems centrinė 520 tūkst., upside iki 700.\n  DONE: Streaming galas įjungtas, pirmas garsas dabar trigubai greitesnis.\n  DONE: Eilė tuščia šiai sesijai, įtariu Stop kabliukas neveikia.\n\nBAD examples (do not write like this):\n  DONE: Paaiškinau, kad parallel sintezė plan ir DONE neapsimoka.\n  DONE: Patch'inau parser'į ir paleidau batch'ą, visi failai eina.\n  DONE: Patikrinau queue, Stop hook bug'as, reikia parser patch'o.\n\nDo NOT announce upcoming tool calls. Do NOT speak mid-turn. DONE: is the only voice output."
  }
}
EOF
