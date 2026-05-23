# Claude Code Voice Pipeline

Hands-free voice narration for [Claude Code](https://claude.com/claude-code). Reads two short sentences per turn out loud — what the agent is about to do, and what it accomplished — via ElevenLabs TTS (`eleven_flash_v2_5`, voice `Adam` by default) with API key in macOS Keychain.

Designed as a **voice extension of the agent itself**: the agent writes the sentences in whatever language the user is speaking (Lithuanian or English). One multilingual voice handles both — no language switching, no accent mismatch.

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
│    • HARD CUT: kills prior-turn daemon + children    │
│      (curl mid-request, afplay mid-playback)         │
│    • clears per-turn flag, sweeps stale state        │
│    • injects voice rules into agent context          │
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
│  claude-say "text" [voice_override] [session_id]     │
│    • enqueues into per-session queue dir             │
│    • spawns daemon if not running                    │
└─────────────┬────────────────────────────────────────┘
              │
              ▼
┌──────────────────────────────────────────────────────┐
│  claude-say-daemon.sh                                │
│    • writes own PID to daemon.pid (kill target)      │
│    • reads API key from macOS Keychain               │
│    • parallel synthesis of ALL queued messages       │
│    • sequential playback in arrival order            │
│    • while sentence N plays, N+1, N+2... pre-render  │
│    • trap on SIGTERM cleans up on hard-kill          │
│    • exits when queue drains                         │
└──────────────────────────────────────────────────────┘
              │
              ▼
        OpenAI /v1/audio/speech (tts-1, nova) → MP3 → afplay
```

**Why a per-session queue?** Multiple Claude Code windows can run simultaneously. Each gets its own queue dir (`/tmp/claude-say-queue/<session_id>/`) so voices from different sessions never interleave.

**Why parallel pre-synthesis?** OpenAI TTS has ~0.5–1.5s roundtrip per sentence. If we synthesized one at a time, you'd hear a long gap between plan and DONE: lines. By kicking off synthesis for every queued message in parallel and playing in order, the daemon hides almost all latency.

**Why hard-cut on new prompt?** Without it, the prior turn's DONE: sentence can keep playing while the user is already typing the next task — confusing. `UserPromptSubmit` reads the daemon's PID from `daemon.pid`, kills its children (in-flight `curl` or `afplay`), then kills the daemon itself. Mid-word truncation is a small price for clean turn boundaries.

---

## Setup

### 1. Dependencies

Just `curl`, `python3`, `afplay`, `security` — all on macOS by default. No `pip install`, no `npm install`.

### 2. Store your ElevenLabs API key in Keychain

Get an API key from <https://elevenlabs.io/app/settings/api-keys>, then:

```bash
security add-generic-password \
  -a "$USER" \
  -s "claude-voice-elevenlabs-api-key" \
  -w "sk_YOUR_KEY_HERE" \
  -U
```

Verify it stored correctly:

```bash
security find-generic-password -s "claude-voice-elevenlabs-api-key" -w
```

The key never lives on disk in plaintext — only in macOS Keychain (encrypted at rest).

### 3. Clone into `~/.claude/voice-pipeline/`

```bash
git clone git@github.com:<your-user>/claude-voice-pipeline.git ~/.claude/voice-pipeline
chmod +x ~/.claude/voice-pipeline/*.sh ~/.claude/voice-pipeline/claude-say
```

### 4. Wire the hooks in `~/.claude/settings.json`

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

### 5. Restart Claude Code

Open a new session — on the first prompt, the agent should now narrate.

---

## Configuration

### Change voice or model

Edit the constants at the top of `claude-say-daemon.sh`:

```bash
DEFAULT_VOICE="pNInz6obpgDQGcFmaJgB"   # Adam (deep male)
MODEL="eleven_flash_v2_5"              # or: eleven_turbo_v2_5, eleven_multilingual_v2
STABILITY="0.45"                       # 0.0 expressive → 1.0 monotone
SIMILARITY_BOOST="0.75"                # voice fidelity
STYLE="0.30"                           # expressiveness
```

Common voice IDs (curated, deep masculine matching the original `onyx` vibe):

| Voice | ID | Character |
|---|---|---|
| Adam | `pNInz6obpgDQGcFmaJgB` | deep, narrator-like, energetic (default) |
| Brian | `nPczCjzI2devNBz1zQrb` | deep, mature, calm |
| Bill | `pqHfZKP75CvOlQylNhV4` | warm, deep, conversational |
| George | `JBFqnCBsd6RMkjVDRZzb` | calm, narrative, mature |

Browse the full library: <https://elevenlabs.io/app/voice-library>. Any voice ID from there works.

Model trade-offs:
- `eleven_flash_v2_5` — fastest (~75ms TTFB), Flash credit rate (50% cost), 32 languages incl. Lithuanian. Default.
- `eleven_turbo_v2_5` — slightly higher quality, ~250ms latency, full credit rate.
- `eleven_multilingual_v2` — best quality, slowest, full rate. Use for long-form content.

Lithuanian is forced via `language_code="lt"` when LT diacritics are detected, so the model doesn't auto-detect as Latvian or Polish for short text.

### Change voice rules / sentence style

The agent's instructions live in `userpromptsubmit-hook.sh` — the `additionalContext` heredoc. Edit it to change tone, sentence length cap, language behavior, when to be silent, etc.

### Disable temporarily

Comment out the hook entries in `settings.json` and restart Claude Code. Or run `pkill -f claude-say-daemon` to silence whatever's currently queued in the current session.

---

## Troubleshooting

**Nothing speaks.**
1. Verify Keychain key: `security find-generic-password -s "claude-voice-elevenlabs-api-key" -w` (should print your key)
2. Verify ElevenLabs TTS works: `KEY=$(security find-generic-password -s "claude-voice-elevenlabs-api-key" -w) && curl -X POST "https://api.elevenlabs.io/v1/text-to-speech/pNInz6obpgDQGcFmaJgB?output_format=mp3_44100_128" -H "xi-api-key: $KEY" -H "Content-Type: application/json" -H "Accept: audio/mpeg" -d '{"text":"test","model_id":"eleven_flash_v2_5"}' -o /tmp/t.mp3 && afplay /tmp/t.mp3`
3. Check hooks are wired: `python3 -c "import json; print(list(json.load(open('$HOME/.claude/settings.json'))['hooks'].keys()))"`
4. Manually fire: `bash ~/.claude/voice-pipeline/claude-say "test sentence" "" debugsession`

**Voice arrives way too late.**
The daemon already does parallel pre-synthesis. Remaining latency is the ElevenLabs API roundtrip (~75–500ms depending on model) + the fact that the DONE: hook fires only after the agent's full response is done. If your turns are long, the DONE: arrives only after all tools/text complete — that's by design (it's a *summary*, not a running commentary).

**Voice from previous turn plays after I send a new prompt.**
`UserPromptSubmit` reads `daemon.pid` and kills the daemon plus its children (in-flight `curl` and `afplay`). If you still hear bleed-through, check that the PID file is being written: `ls /tmp/claude-say-queue/<session>/daemon.pid`.

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

- **macOS only** (`afplay`, `security` for Keychain). Linux port would need an alternate audio player and key store (`secret-tool`/libsecret).
- **ElevenLabs dependency** — sentences are sent to ElevenLabs' API. Their privacy terms apply (no training on API audio by default, DPA available for enterprise). Don't enable this pipeline if your conversation sentences cannot leave your machine.
- **Cost** — `eleven_flash_v2_5` runs at the Flash credit rate (50% of standard). On the Creator plan (~$22/mo, 100k chars standard = 200k Flash chars), Plan + DONE: sentences averaging ~50 chars each = ~$0.011 per turn. A heavy day of 200 turns ≈ $2.20. Roughly 5–10× pricier than OpenAI `tts-1`, paid for in voice quality.
- **No streaming** — each sentence is synthesized to a full MP3 before playback starts. ~75–500ms minimum latency per sentence depending on model.
- **Lithuanian quality** — ElevenLabs `eleven_flash_v2_5` handles Lithuanian natively (forced via `language_code="lt"`). Much better LT pronunciation than OpenAI; native-grade for short narration.
