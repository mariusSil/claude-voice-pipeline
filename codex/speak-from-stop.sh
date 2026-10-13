#!/bin/bash
# Codex Stop hook:
# - extracts SAY:/DONE: from last_assistant_message (fallback transcript)
# - speaks through existing ~/.claude/voice-pipeline/claude-say
# - always returns valid JSON on stdout (required by Codex Stop hooks)

INPUT=$(cat)

SESSION=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("session_id", "default"))
except Exception:
    print("default")
')

LAST_MSG=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("last_assistant_message") or "")
except Exception:
    print("")
')

TRANSCRIPT=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("transcript_path") or "")
except Exception:
    print("")
')

extract_text() {
  python3 - <<'PY'
import os, re, sys, json

last_msg = os.environ.get("LAST_MSG", "")
transcript = os.environ.get("TRANSCRIPT", "")


def clean(s: str) -> str:
    s = s.replace("**", "").replace("`", "")
    s = s.replace(" — ", ", ").replace("—", ", ")
    s = s.replace(" – ", ", ").replace("–", ", ")
    s = re.sub(r"\s+", " ", s).strip(" ,;:")
    return s


def pick(full: str) -> str:
    m_say = re.search(r"SAY:\s*(.+?)(?:\n|$)", full, re.IGNORECASE | re.DOTALL)
    if m_say:
        line = clean(m_say.group(1).strip())
        return line[:600].rstrip()

    m_done = re.search(r"DONE:\s*(.+?)(?:(?<![0-9])[.!?](?:\s|$)|\n|$)", full, re.IGNORECASE | re.DOTALL)
    if m_done:
        line = clean(m_done.group(1).strip())
        if len(line) > 180:
            cut = line[:180]
            sp = cut.rfind(" ")
            line = cut[:sp] if sp > 80 else cut
        return line
    return ""

text = ""
if last_msg:
    text = pick(last_msg)

if not text and transcript and os.path.isfile(transcript):
    try:
        with open(transcript, "r", encoding="utf-8") as f:
            lines = f.readlines()
        for raw in reversed(lines):
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
            except Exception:
                continue
            if obj.get("type") != "assistant":
                continue
            msg = obj.get("message") or {}
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            parts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text" and c.get("text", "").strip()]
            if not parts:
                continue
            text = pick(" ".join(parts))
            if text:
                break
    except Exception:
        pass

print(text)
PY
}

TEXT=$(LAST_MSG="$LAST_MSG" TRANSCRIPT="$TRANSCRIPT" extract_text)

if [ -n "$TEXT" ]; then
  bash ~/.claude/voice-pipeline/claude-say "Codex. $TEXT" "" "$SESSION" >/dev/null 2>&1 || true
fi

# Stop expects JSON on stdout when exit code is 0.
echo '{}'
