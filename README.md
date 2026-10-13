# Claude Code Voice Pipeline

Hands-free voice narration for Claude Code. Hooks enqueue short plan / completion
sentences, `claude-say` starts a per-session daemon, and the daemon synthesizes
speech with Google Cloud Text-to-Speech (Chirp 3 HD).

## Credential Mapping

The voice pipeline intentionally uses the same Google credential shape as the
other local Gemini / Vertex workflows:

1. Project id:
   - `GOOGLE_CLOUD_PROJECT`
   - `GCP_PROJECT`
   - `CLOUDSDK_CORE_PROJECT`
   - fallback: `gcloud config get-value project`
2. Access token:
   - `GOOGLE_ACCESS_TOKEN`
   - fallback: `gcloud auth print-access-token`
   - fallback: `gcloud auth application-default print-access-token`

There is no hardcoded Google account in the pipeline. Configure the active
Google account/project once, or export the project env var in your shell:

```bash
gcloud config set project silotech-workspace
gcloud auth print-access-token >/dev/null

# Optional explicit mapping, useful for non-interactive shells.
export GOOGLE_CLOUD_PROJECT=silotech-workspace
```

If credentials are missing, the daemon exits silently and logs `auth-missing` to
`~/.claude/voice-pipeline/voice.log`.

## Architecture

```text
Claude hook
  -> claude-say "text" [voice_override] [session_id]
  -> /tmp/claude-say-queue/<session>/messages/*.msg
  -> claude-say-daemon.sh
  -> Google Cloud Text-to-Speech text:synthesize
  -> ffmpeg optional pitch shift
  -> ffplay, falling back to afplay
```

Each Claude session has its own queue under `/tmp/claude-say-queue`, so multiple
windows do not interleave speech. The daemon writes `daemon.pid`; prompt-submit
hooks can interrupt active playback cleanly.

## Configuration

Environment variables:

```bash
GOOGLE_CLOUD_PROJECT=silotech-workspace
GOOGLE_TTS_VOICE=lt-LT-Chirp3-HD-Enceladus
GOOGLE_TTS_DEEPEN_FACTOR=0.85
GOOGLE_TTS_PLAYBACK_VOLUME=0.7
GOOGLE_TTS_ENDPOINT=https://texttospeech.googleapis.com/v1/text:synthesize
```

Global voice toggle:

```bash
~/.claude/voice-pipeline/voicetoggle status
~/.claude/voice-pipeline/voicetoggle off
~/.claude/voice-pipeline/voicetoggle on
```

`voice.state` is local runtime state and is intentionally ignored by git.

## Manual Test

```bash
bash ~/.claude/voice-pipeline/claude-say "test sentence" "" debugsession
tail -n 20 ~/.claude/voice-pipeline/voice.log
```

If nothing speaks:

```bash
gcloud config get-value project
gcloud auth print-access-token >/dev/null
bash -n ~/.claude/voice-pipeline/claude-say-daemon.sh
```

## Files

| File | Role |
|---|---|
| `claude-say` | Queue entry point and daemon spawner |
| `claude-say-daemon.sh` | Google TTS synthesis and playback daemon |
| `userpromptsubmit-hook.sh` | Interrupts active playback on a new prompt |
| `speak-from-transcript.sh` | Reads final `DONE:` / `SAY:` lines |
| `voicetoggle` | Global local on/off switch |

## Runtime Files

Ignored local files:

- `voice.log`
- `voice.state`
- `state/`
- `option-state`
- `*.bak`

## Viena eilė ir sustabdymas

- Visos sesijos (Claude ir Codex) groja po vieną sakinį: sintezė vyksta lygiagrečiai,
  grojimas laukia bendro užrakto `/tmp/claude-say-play.lock`.
- Codex frazė prasideda žodžiu „Codex.“ (`codex/speak-from-stop.sh`, diegti į
  `~/.codex/voice-pipeline/`).
- Sustabdyti viską dabar: laikyti Control+Option+Command, komanda `voicestop` arba
  SwiftBar meniu „Tylėk dabar“. Balsas lieka įjungtas kitiems atsakymams.
- Option laikymas pristabdo prieš kitą sakinį, `voicetoggle off` išjungia visai.
