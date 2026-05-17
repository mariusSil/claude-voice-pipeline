#!/bin/bash
# Stop hook: speaks the agent's 'DONE: ...' line from the last assistant message.
# Silent if the agent intentionally omitted DONE: (e.g. trivial turn).

INPUT=$(cat)

SESSION=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('session_id', 'default'))
except:
    print('default')
" 2>/dev/null)

TRANSCRIPT=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('transcript_path', ''))
except:
    pass
" 2>/dev/null)

TEXT=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
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
        full = ' '.join(texts)
        # Capture DONE: line. Sentence-end = .!? followed by whitespace/end, but NOT inside a decimal (3.5).
        m = re.search(r'DONE:\s*(.+?)(?:(?<![0-9])[.!?](?:\s|$)|\n|$)', full, re.IGNORECASE | re.DOTALL)
        if m:
            line = m.group(1).strip()
            # Hard cap so a runaway line doesn't synthesize forever.
            if len(line) > 180:
                cut = line[:180]
                sp = cut.rfind(' ')
                line = cut[:sp] if sp > 80 else cut
            if len(line) >= 5:
                print(line)
        break
    except:
        pass
" 2>/dev/null)
fi

# No DONE: line → stay silent. The agent decides whether this turn deserves voice.
[ -z "$TEXT" ] && exit 0

bash ~/.claude/voice-pipeline/claude-say "$TEXT" "" "$SESSION"
