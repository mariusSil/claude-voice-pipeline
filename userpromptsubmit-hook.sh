#!/bin/bash
# UserPromptSubmit hook: clears per-turn plan flag, sweeps stale state, injects voice rules.

INPUT=$(cat)
SESSION=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('session_id', 'default'))
except:
    print('default')
" 2>/dev/null)

# Per-turn flag clear (so PostToolUse speaks the plan once next turn)
rm -f "/tmp/claude-plan-spoken-$SESSION"

# Drop any unspoken sentences from the previous turn — user already moved on.
# (The daemon will finish whatever it's currently synthesizing; everything queued behind it gets dropped.)
rm -f "/tmp/claude-say-queue/$SESSION/messages/"*.msg 2>/dev/null

# Sweep stale flag files older than 7 days (orphans from old sessions).
find /tmp -maxdepth 1 -name 'claude-plan-spoken-*' -type f -mtime +7 -delete 2>/dev/null

# Sweep abandoned per-session queue dirs (>1 day old, no live lock).
find /tmp/claude-say-queue -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec rm -rf {} + 2>/dev/null

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "VOICE PIPELINE RULES (mandatory, every turn):\nYour voice is an extension of you — speak naturally, not as a status reporter.\n\n1. Before your FIRST tool call: one short sentence (max 14 words) saying what you're about to do.\n2. At the END of your response (last line): one short sentence (max 14 words) starting with 'DONE:' summarizing what you accomplished.\n\nLanguage: write both lines in the SAME language the user is writing in (Lithuanian if user wrote Lithuanian, English if English). The TTS layer auto-picks an LT or EN neural voice based on the text — do not translate for the voice.\n\nIf the turn was trivial (one-line answer, no real action) or you genuinely have nothing worth saying out loud, OMIT the DONE: line entirely — silence is fine. Never write filler like 'DONE: Done.' just to satisfy the rule.\n\nKeep both lines conversational, human, first-person. No emojis."
  }
}
EOF
