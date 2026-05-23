#!/bin/bash
# Stop hook: speaks the agent's 'SAY:' line if present, else 'DONE:' line.
# SAY: takes precedence (used when user explicitly asked for a spoken reply).
# Silent if the agent intentionally omitted both (e.g. trivial turn).

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

        def clean_for_tts(s):
            # Defensive scrubbing so TTS never reads markdown, em-dashes, or
            # stray marker words ('DONE', 'SAY') even if the agent leaks them.
            s = s.replace('**', '').replace(chr(96), '')
            s = s.replace(' — ', ', ').replace('—', ', ').replace(' – ', ', ').replace('–', ', ')
            s = re.sub(r'\b(DONE|SAY)\b\s*:?\s*', '', s)
            s = re.sub(r'\s{2,}', ' ', s)
            s = re.sub(r'\s+([,.!?])', r'\1', s)
            s = re.sub(r',\s*,', ',', s)
            return s.strip(' ,;:')

        # SAY: takes precedence over DONE:. SAY captures until newline or end (allows longer spoken replies).
        m_say = re.search(r'SAY:\s*(.+?)(?:\n|$)', full, re.IGNORECASE | re.DOTALL)
        if m_say:
            line = m_say.group(1).strip()
            cap = 600
            if len(line) > cap:
                cut = line[:cap]
                sp = cut.rfind(' ')
                line = cut[:sp] if sp > 200 else cut
            line = clean_for_tts(line)
            if len(line) >= 3:
                print(line)
            break
        # DONE: sentence-end = .!? followed by whitespace/end, but NOT inside a decimal (3.5).
        m = re.search(r'DONE:\s*(.+?)(?:(?<![0-9])[.!?](?:\s|$)|\n|$)', full, re.IGNORECASE | re.DOTALL)
        if m:
            line = m.group(1).strip()
            if len(line) > 180:
                cut = line[:180]
                sp = cut.rfind(' ')
                line = cut[:sp] if sp > 80 else cut
            line = clean_for_tts(line)
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
