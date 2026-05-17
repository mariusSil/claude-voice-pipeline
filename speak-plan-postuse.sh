#!/bin/bash
# PostToolUse hook:
#   - Speaks the agent's pre-tool plan sentence ONCE per turn (first text block of the latest assistant message).
#   - Speaks AskUserQuestion questions immediately (including option labels) every time they fire.

INPUT=$(cat)

SESSION=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('session_id', 'default'))
except:
    print('default')
" 2>/dev/null)

TOOL_NAME=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_name', ''))
except:
    pass
" 2>/dev/null)

# AskUserQuestion: speak first question + its option labels, so voice users hear the choices.
if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
  SPOKEN=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    qs = d.get('tool_input', {}).get('questions', [])
    if not qs:
        sys.exit(0)
    q = qs[0]
    parts = [q.get('question', '').strip()]
    opts = q.get('options', []) or []
    if opts:
        labels = [o.get('label', '').strip() for o in opts if o.get('label')]
        if labels:
            parts.append('Options: ' + '; '.join(labels) + '.')
    print(' '.join(p for p in parts if p))
except:
    pass
" 2>/dev/null)
  [ -n "$SPOKEN" ] && bash ~/.claude/voice-pipeline/claude-say "$SPOKEN" "" "$SESSION"
  exit 0
fi

# Plan sentence: only once per turn. Cheap exit before doing any JSON work.
FLAG="/tmp/claude-plan-spoken-$SESSION"
[ -f "$FLAG" ] && exit 0

TRANSCRIPT=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('transcript_path', ''))
except:
    pass
" 2>/dev/null)

[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

# Mark flag BEFORE speaking so concurrent PostToolUse invocations don't double-speak.
touch "$FLAG"

TEXT=$(grep '"type":"assistant"' "$TRANSCRIPT" | python3 -c "
import sys, json, re
for line in reversed(list(sys.stdin)):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        content = obj['message']['content']
        if not isinstance(content, list):
            continue
        texts = [c['text'] for c in content if isinstance(c, dict) and c.get('type') == 'text' and c.get('text', '').strip()]
        if not texts:
            continue
        full = texts[0].strip()
        # Skip a DONE line — that's a stale previous turn.
        if re.match(r'DONE:', full, re.IGNORECASE):
            break
        # Take the first sentence; if no terminator within 240 chars, take up to a word boundary near 180.
        m = re.search(r'(?<![0-9])[.!?](?:\s|$)', full[:240])
        if m:
            result = full[:m.end()-1].strip()
        else:
            cut = full[:180]
            sp = cut.rfind(' ')
            result = (cut[:sp] if sp > 80 else cut).strip()
        if len(result) > 5:
            print(result)
        break
    except:
        pass
" 2>/dev/null)

[ -z "$TEXT" ] && exit 0

bash ~/.claude/voice-pipeline/claude-say "$TEXT" "" "$SESSION"
