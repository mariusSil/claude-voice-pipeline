# Claude Code Voice Pipeline

Hands-free voice narration for [Claude Code](https://claude.com/claude-code). Reads two short sentences per turn out loud — what the agent is about to do, and what it accomplished — with automatic Lithuanian/English voice selection via Microsoft Azure neural voices (edge-tts).

Designed as a **voice extension of the agent itself**: the agent writes the sentences in whatever language the user is speaking; the TTS layer picks the right neural voice based on the text.

---

## What you'll hear

For every turn:

1. **Plan sentence** — spoken right after the agent makes its first tool call. e.g. *"I'll check the queue daemon and fix the lag."*
2. **DONE: sentence** — spoken when the agent finishes its response. e.g. *"DONE: Patched the daemon and pushed to the private repo."*

Trivial turns (one-line answers, no action) are silent — the agent intentionally omits the DONE: line.

For `AskUserQuestion` interactions, the question and all option labels are read aloud so a voice-only user knows what they're choosing between.

---

## Architecture

```
┌──────────────────────────┐
│  Claude Code main loop   │
└─────────────┬────────────┘
              │ hook events
              ▼
┌──────────────────────────────────────────────────────┐
│  UserPromptSubmit  →  userpromptsubmit-hook.sh       │
│    • injects voice rules into agent context          │
│    • clears per-turn flag + sweeps stale state       │
│    • drops unspoken sentences from previous turn     │
├──────────────────────────────────────────────────────┤
│  PostToolUse       →  speak-plan-postuse.sh          │
│    • on first tool call: speaks the agent's plan     │
│    • on AskUserQuestion: speaks question + options   │
├──────────────────────────────────────────────────────┤
│  Stop              →  speak-from-transcript.sh       │
│    • extracts the DONE: line, speaks it              │
│    • silent if DONE: was intentionally omitted       │
└─────────────┬────────────────────────────────────────┘
              │ all 3 hooks call:
              ▼
┌──────────────────────────────────────────────────────┐
│  claude-say "text" [voice] [session_id]              │
│    • autodetects LT (ąčęėįšųūž) vs EN                │
│    • enqueues into per-session queue dir             │
│    • spawns daemon if not running                    │
└─────────────┬────────────────────────────────────────┘
              │
              ▼
┌──────────────────────────────────────────────────────┐
│  claude-say-daemon.sh                                │
│    • parallel synthesis of ALL queued messages       │
│    • sequential playback in arrival order            │
│    • while sentence N plays, N+1, N+2... pre-render  │
│    • exits when queue drains                         │
└──────────────────────────────────────────────────────┘
              │
              ▼
        edge-tts → MP3 → afplay
```

**Why a per-session queue?** Multiple Claude Code windows can run simultaneously. Each gets its own queue dir (`/tmp/claude-say-queue/<session_id>/`) so voices from different sessions never interleave.

**Why parallel pre-synthesis?** edge-tts has 0.5–1.5s roundtrip per sentence. If we synthesized one at a time, you'd hear a long gap between plan and DONE: lines. By kicking off synthesis for every queued message in parallel and playing in order, the daemon hides almost all latency.

---

## Setup

### 1. Install dependencies

```bash
# edge-tts (Python package — Microsoft Azure neural voices via free public endpoint)
pip3 install edge-tts

# Verify it works
edge-tts --voice en-US-MichelleNeural --text "Hello" --write-media /tmp/test.mp3
afplay /tmp/test.mp3
```

`afplay` and `say` come with macOS. No other dependencies.

### 2. Clone into `~/.claude/voice-pipeline/`

```bash
git clone git@github.com:<your-user>/claude-voice-pipeline.git ~/.claude/voice-pipeline
chmod +x ~/.claude/voice-pipeline/*.sh ~/.claude/voice-pipeline/claude-say
```

### 3. Wire the hooks in `~/.claude/settings.json`

Add this `hooks` block (merge with whatever you already have):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "bash ~/.claude/voice-pipeline/userpromptsubmit-hook.sh" }] }
    ],
    "PostToolUse": [
      { "hooks": [{ "type": "command", "command": "bash ~/.claude/voice-pipeline/speak-plan-postuse.sh" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "bash ~/.claude/voice-pipeline/speak-from-transcript.sh" }] }
    ]
  }
}
```

### 4. Restart Claude Code

Open a new session — on the first prompt, the agent should now narrate.

---

## Configuration

### Change voice

Default: `en-US-MichelleNeural` (English) / `lt-LT-OnaNeural` (Lithuanian).

To swap defaults, edit `claude-say` lines 16–22:

```bash
if printf '%s' "$TEXT" | LC_ALL=en_US.UTF-8 grep -qE '[ąčęėįšųūžĄČĘĖĮŠŲŪŽ]'; then
  VOICE="lt-LT-LeonasNeural"        # male LT
else
  VOICE="en-US-AvaMultilingualNeural" # warm female, also speaks LT
fi
```

Browse all voices: `edge-tts --list-voices`. Multilingual variants (`*MultilingualNeural`) handle mixed LT/EN gracefully — recommended if you mix languages often.

### Change voice rules / sentence style

The agent's instructions live in `userpromptsubmit-hook.sh` — the `additionalContext` heredoc. Edit it to change tone, sentence length cap, language behavior, when to be silent, etc.

### Disable temporarily

Comment out the hook entries in `settings.json` and restart Claude Code. Or just `pkill -f claude-say-daemon` to silence whatever's currently queued.

---

## How language autodetect works

`claude-say` greps the text for any Lithuanian diacritic (`ą č ę ė į š ų ū ž` + uppercase). Match → routes to `lt-LT-OnaNeural`. No match → `en-US-MichelleNeural`.

This means:
- LT text **without diacritics** ("aciu uz pagalba") will be misrouted to EN. Don't write LT without diacritics — beyond ugliness, it breaks the voice.
- Mixed sentences ("DONE: deploy'inau į Vercel") route to LT (because of "į"). Lithuanian voice will try to pronounce "Vercel" with Lithuanian phonetics. Acceptable but not perfect. Multilingual voices solve this — see Configuration.

---

## Troubleshooting

**Nothing speaks.**
1. Verify edge-tts: `edge-tts --voice en-US-MichelleNeural --text "test" --write-media /tmp/t.mp3 && afplay /tmp/t.mp3`
2. Check hooks are wired: `python3 -c "import json; print(json.load(open('$HOME/.claude/settings.json'))['hooks'].keys())"`
3. Check the queue: `ls /tmp/claude-say-queue/*/messages/` — should be empty between turns.
4. Manually fire: `bash ~/.claude/voice-pipeline/claude-say "test" "" debugsession`

**Voice arrives way too late.**
The daemon already does parallel pre-synthesis. Remaining latency is edge-tts API roundtrip + the fact that the DONE: hook fires only after the agent's full response is done. If your turns are long, the DONE: arrives only after all tools/text complete — that's by design (it's a *summary*, not a running commentary).

**Voice from previous turn plays after I send a new prompt.**
`userpromptsubmit-hook.sh` drops unspoken queued sentences from the previous turn. But the daemon will finish whatever sentence it's currently mid-synthesis on — that one can't be killed cleanly. Max overlap is the duration of one sentence (~3–5s).

**Lithuanian text pronounced with English voice (or vice versa).**
Check that LT diacritics are present. The detector only triggers on `ąčęėįšųūž` — without them, it falls back to EN.

**Multiple Claude sessions narrate over each other.**
They shouldn't — each session gets its own queue dir. If it's happening, check that `session_id` is being passed correctly: `ls /tmp/claude-say-queue/` should show one dir per active session.

**Stale `/tmp/claude-plan-spoken-*` files piling up.**
`userpromptsubmit-hook.sh` sweeps files older than 7 days on every prompt submit. If they're recent, that's normal — one per active session.

**Daemon stuck / queue won't drain.**
```bash
pkill -f claude-say-daemon
rm -rf /tmp/claude-say-queue
```
The next `claude-say` call will respawn a fresh daemon.

---

## File reference

| File | Hook event | Role |
|---|---|---|
| `userpromptsubmit-hook.sh` | UserPromptSubmit | Injects voice rules, sweeps stale state, drops unspoken previous-turn audio |
| `speak-plan-postuse.sh` | PostToolUse | Speaks plan sentence (once per turn) + AskUserQuestion content |
| `speak-from-transcript.sh` | Stop | Speaks the DONE: line from the agent's last message |
| `claude-say` | — | Queue entry point: autodetects language, enqueues, spawns daemon |
| `claude-say-daemon.sh` | — | Per-session daemon: parallel synthesis, sequential playback |

---

## Caveats / known limitations

- **macOS only** (`afplay`, `say`). Linux port would need `mpg123`/`paplay` and a different fallback.
- **edge-tts uses a free Microsoft endpoint** — no API key, but rate-limited. Heavy use may hit throttling.
- **No streaming** — each sentence is synthesized to a full MP3 before playback starts. ~0.5s minimum latency per sentence.
- **macOS `say` fallback** only fires for English voices. If edge-tts is down and you're in a LT session, you'll get silence rather than mangled Lithuanian from Samantha.
