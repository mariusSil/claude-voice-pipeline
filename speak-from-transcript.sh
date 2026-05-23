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

LOG_FILE_EARLY="$HOME/.claude/voice-pipeline/voice.log"
log_event_early() {
  printf '%s [%s] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S.%3N')" "${SESSION:0:8}" "$1" "${2:-}" >> "$LOG_FILE_EARLY" 2>/dev/null
}

# Wait for a NEW assistant message to appear in the transcript before reading.
# Race: Stop hook can fire before Claude Code flushes the just-finished turn to
# the JSONL. State-tracked polling solves this without arbitrary sleeps:
# - we remember the assistant line count seen in the previous invocation
# - we wait, up to 2s, for that count to grow by at least one
# - as soon as a new line is present we proceed; if the deadline hits we proceed anyway
SEEN_DIR="$HOME/.claude/voice-pipeline/state"
mkdir -p "$SEEN_DIR" 2>/dev/null
SEEN_FILE="$SEEN_DIR/seen-${SESSION}.txt"
LAST_SEEN=$(cat "$SEEN_FILE" 2>/dev/null || echo 0)
DEADLINE_MS=$(($(date +%s%3N) + 2000))
FRESH=0
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  while [ "$(date +%s%3N)" -lt "$DEADLINE_MS" ]; do
    COUNT=$(grep -c '"type":"assistant"' "$TRANSCRIPT" 2>/dev/null || echo 0)
    if [ "$COUNT" -gt "$LAST_SEEN" ]; then
      echo "$COUNT" > "$SEEN_FILE"
      FRESH=1
      log_event_early "poll-fresh" "count=$COUNT prev=$LAST_SEEN"
      break
    fi
    sleep 0.05
  done
  if [ "$FRESH" -eq 0 ]; then
    log_event_early "poll-timeout" "count_unchanged=$LAST_SEEN"
  fi
fi

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

LOG_FILE="$HOME/.claude/voice-pipeline/voice.log"
log_event() {
  printf '%s [%s] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S.%3N')" "${SESSION:0:8}" "$1" "${2:-}" >> "$LOG_FILE" 2>/dev/null
}

# No DONE: line → stay silent. The agent decides whether this turn deserves voice.
if [ -z "$TEXT" ]; then
  log_event "stop-hook" "silent (no DONE/SAY)"
  exit 0
fi

CHAR_COUNT=${#TEXT}
log_event "stop-hook" "extracted chars=$CHAR_COUNT preview=\"${TEXT:0:60}\""
bash ~/.claude/voice-pipeline/claude-say "$TEXT" "" "$SESSION"
