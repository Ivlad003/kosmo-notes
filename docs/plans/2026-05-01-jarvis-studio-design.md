# Jarvis Studio — Design Document

**Date:** 2026-05-01
**Status:** Draft (brainstorm validated, plan pending)
**Author:** ivlad003@gmail.com

---

## 1. Context & Motivation

The existing **Jarvis** is a Google Meet participant bot — Rust core + vexa-bot child process — that joins meetings, transcribes, and responds via voice. It is a *participant*.

**Jarvis Studio** is a *separate* product: a cross-platform desktop **screen recorder** with **AI-driven annotations**, **transcription**, **agent-backed Q&A**, and **self-hosted sharing**. It is a *creation tool*, not a meeting participant. The two apps share underlying crates (transcription, LLM, TTS) but are distinct distributions.

Per brainstorm: this is **Option D** (record-first, AI-second). The recording loop is primary; the AI is invoked on-demand by the user, not autonomously.

## 2. Goals & Non-Goals

**Goals (v1):**

- One portable executable per OS (no installer required)
- Record screen + webcam + mic + system audio with live transcription
- Post-recording editor with **AI-driven annotations** (vision LLM places arrows/boxes/labels/blur)
- Agent-backed Q&A on completed sessions via pluggable subprocess agents (Claude Code, Codex CLI)
- Self-hosted sharing via S3-compatible storage (RustFS), presigned URLs
- Configurable via single JSON file + settings UI

**Non-goals (v1, explicitly):**

- Live overlay drawing during recording (only AI-driven post-recording annotations)
- Voice input/output (text-mode only — different from Meet bot)
- Manual freehand drawing tools
- Custom viewer page for shared links
- Team workspaces, accounts, real-time collaboration
- Linux support (deferred — see §11)

## 3. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Tauri 2 App (single binary, ~30–50 MB target)                  │
│                                                                 │
│  ┌─────────────────┐   ┌──────────────────┐   ┌──────────────┐ │
│  │  Frontend       │   │  Rust Core       │   │  Subprocess  │ │
│  │  (Svelte/React) │◀─▶│  (Tauri commands)│──▶│  Manager     │ │
│  │                 │   │                  │   │              │ │
│  │  - Recorder UI  │   │  - capture (scap)│   │  - claude    │ │
│  │  - Editor UI    │   │  - encode (ffmpeg│   │  - codex     │ │
│  │  - Settings UI  │   │    sidecar)     │   │  - <plugin>  │ │
│  │  - Library UI   │   │  - transcribe    │   │              │ │
│  │                 │   │    (jarvis crate)│   │  Each as     │ │
│  │                 │   │  - vision LLM    │   │  pipe-driven │ │
│  │                 │   │    (annotation)  │   │  child proc  │ │
│  │                 │   │  - upload (S3)   │   │              │ │
│  └─────────────────┘   └──────────────────┘   └──────────────┘ │
│                                                                 │
│  Sidecar binaries (bundled, no install): ffmpeg                 │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                         ~/JarvisStudio/sessions/
                         (or user-configured path)
```

**Three core principles:**

1. **Reuse, don't rewrite.** Promote `jarvis/src/transcription/`, `llm.rs`, and `tts.rs` to standalone workspace crates. Both Meet-bot Jarvis and Jarvis Studio depend on them.
2. **FFmpeg as a sidecar**, not a system dependency. Tauri's bundled-binary feature ships ffmpeg with the app (~30 MB) so users never need to `brew install`.
3. **Agents are plug-ins, not first-class citizens.** A `backends/` registry: each backend is a TOML entry describing how to spawn a subprocess. Adding `gemini`, `aider`, etc. is a config change.

## 4. Recording Pipeline

```
┌──────────────┐   raw frames @ 30fps   ┌─────────────┐   H.265 MP4
│   scap       │───────────────────────▶│   ffmpeg    │───▶ recording.mp4
│  (capture)   │   raw audio (s16le)    │  (sidecar)  │
└──────────────┘───────────────────────▶└─────────────┘
       │              tee'd
       │              ▼
       │       ┌──────────────┐   16kHz mono PCM   ┌──────────────────┐
       └──────▶│  Mixer       │───────────────────▶│  jarvis_         │
               │  (mic+system │                    │  transcription   │
               │   ‑> 16kHz   │                    │  crate (reused)  │
               │   mono)      │                    │                  │
               └──────────────┘                    └──────────────────┘
                                                          │
                                                          ▼ live captions
                                                   transcript.jsonl
                                                   (timestamped)
```

**Defaults (all configurable):**

| Setting | Default | Rationale |
|---|---|---|
| Video codec | **H.265 (HEVC)** via `libx265` | ~50% smaller files than H.264 |
| Resolution | Source native, max 1440p | Lossless on macOS via ScreenCaptureKit |
| Frame rate | 30 fps | 60 fps doubles file size, rarely needed |
| Audio sources | **Mic + system, separate tracks** | Track 0 = mic, track 1 = system. Lets transcript label "user said" vs "app said" |
| Audio format | 48kHz stereo for video, 16kHz mono fork for Whisper | Standard; fork avoids re-encode |
| Live transcription | **On**, reuses `transcription/cloud.rs` | Battle-tested in Meet bot |
| Pause/resume | Yes | MP4 segments stitched on stop |

**Capture library:** `scap` (CapSoftware) — pre-1.0 (0.0.8) but used in production by Cap. Pin to a known-good commit, design FFmpeg-direct fallback path.

## 5. Webcam Overlay (Talking Head)

```
                          ┌──────────────────┐
  webcam (getUserMedia)──▶│  Frontend        │
                          │  preview (WebGL  │── pipe over WebSocket
                          │  draggable PiP)  │   to Rust core (raw frames)
                          └──────────────────┘
                                   │
                                   ▼
                          ┌──────────────────┐
                          │  ffmpeg overlay  │ -filter_complex
                          │  filter (PiP)    │  "[1:v]scale=240:-1[pip];
                          │                  │   [0:v][pip]overlay=W-w-20:H-h-20"
                          └──────────────────┘
                                   │
                                   ▼
                          composited H.265 MP4 (single track)
```

**Why `getUserMedia` over a Rust webcam crate (`nokhwa`):** Tauri 2's webview has native `getUserMedia` on macOS and Windows — no extra binary, no platform glue, hot-reloadable preview. Frames stream to the Rust side via a WebSocket sidechannel.

| Setting | Default | Notes |
|---|---|---|
| Webcam toggle | Off | Per-recording, sticky last-used |
| Position | Bottom-right | 4 corners, drag to reposition before record |
| Shape | Circle | Circle / rounded rect / rect |
| Size | 240px wide | 160 / 240 / 320 / custom |
| Mirror | On | Standard webcam UX |
| Chroma key | Skip v1 | `ffmpeg colorkey` filter, defer |

**v1 tradeoff:** webcam **baked into the MP4** at record time. Simpler, but no post-edit reposition. Defer to v2 if needed.

## 6. AI Annotation Pipeline

User opens recording in editor → types prompt like *"circle the error message at around 2 minutes"* → AI returns structured annotation → editor renders instantly. **Annotations are non-destructive JSON metadata** until export.

```
User prompt ─┬───────────────▶ Frame sampler
             │                  (extract N frames from
             │                   prompt's time hint, or
             │                   3 candidates around it)
             │                              │
             │                              ▼
             │                  ┌────────────────────┐
             │                  │  Vision LLM API    │   Direct call
             └─────────────────▶│  (Claude Sonnet 4  │   (NOT subprocess —
                                │   or GPT-4o-vision)│    needs structured
                                └────────────────────┘    JSON, low latency)
                                              │
                                              ▼
                                  {type, bbox, t_start, t_end, color}
                                              │
                                              ▼
                                  ┌────────────────────┐
                                  │  Annotation store  │
                                  │  annotations.json  │ ← single source of truth
                                  └────────────────────┘
                                              │
                            ┌─────────────────┴─────────────────┐
                            ▼                                   ▼
                    Editor preview                       Export (FFmpeg)
                    (HTML canvas overlay,                drawbox/drawtext or
                     no re-render needed)                pre-rendered PNG
                                                         overlay filter
```

| Concern | Decision |
|---|---|
| AI for annotations | **Direct vision API** (Claude Sonnet 4 / GPT-4o), not subprocess |
| Annotation storage | **JSON sidecar** in session folder (non-destructive) |
| Annotation types v1 | arrow, box, freehand line, text label, **blur (privacy)** |
| Manual nudge | Drag handles on each annotation in editor |
| Time precision | Snap to nearest 100ms |
| Animation | Fade-in 200ms, hold, fade-out 200ms (configurable per annotation) |
| Cost ceiling | Soft per-session cap in config (e.g. $0.50). Running tally in editor |
| Auto-blur | Triggered by *"blur all visible API keys / emails"* prompt. Critical for sharing. |

## 7. Pluggable Agent Backends (Q&A)

User asks: *"draft an email summarizing this client call"* → spawned agent has full session context (transcript, frames, audio) + their own native tools (file system, terminal, HTTP).

**Key insight:** Claude Code and Codex already ship with terminal, file, HTTP, and code-edit tools built in. **We don't reimplement tools — we spawn the agent with the session folder as cwd, and the agent reads what it needs.**

```
┌────────────────────────────────────────────────────────────┐
│  Session folder (becomes the agent's cwd)                  │
│   2026-05-01_143000/                                       │
│     ├── recording.mp4                                      │
│     ├── transcript.txt        ← timestamped + speakers     │
│     ├── transcript.jsonl      ← machine-readable           │
│     ├── frames/0001.png ...   ← keyframes for vision       │
│     ├── annotations.json                                   │
│     └── .jarvis/                                           │
│          ├── system_prompt.md ← "You are answering Qs..."  │
│          └── conversations/   ← Q&A history                │
└────────────────────────────────────────────────────────────┘
                          │
                          │ spawn with cwd=session folder
                          ▼
        ┌─────────────────┴─────────────────┐
        │     Backend Registry (TOML)       │
        ├───────────────────────────────────┤
        │ [[backend]]                       │
        │ name = "claude"                   │
        │ command = "claude"                │
        │ args = ["--print", "--cwd", "."] │
        │ system_prompt_file = ".jarvis/..."│
        │                                   │
        │ [[backend]]                       │
        │ name = "codex"                    │
        │ command = "codex"                 │
        │ args = ["exec", "--cd", "."]     │
        │                                   │
        │ # extensions: gemini, aider, etc. │
        └───────────────────────────────────┘
```

| Concern | Decision |
|---|---|
| Backend interface | Generic: spawn process, pipe prompt to stdin, stream stdout to UI. Same contract for all agents. |
| Context delivery | **Session folder = agent's cwd.** No prompt-stuffing, no token waste. |
| Backend selector | Dropdown in Q&A panel. Sticky last-used. Per-session override. |
| Custom backends | TOML file in user config. **No app rebuild needed.** |
| Streaming | Stdout → frontend via Tauri events (token-by-token). Cancel kills child. |
| Auth/keys | Each agent uses its own auth (Claude Code login, OPENAI_API_KEY env). App does not proxy. |
| Sandboxing | Pass through agent's own sandbox flags (`codex --sandbox`, `claude --permission-mode`). |
| History | Each Q&A turn appended to `.jarvis/conversations/<timestamp>.md` for replay. |

## 8. Sharing via Self-Hosted RustFS

```
┌──────────────────────────────────────────────────────────────┐
│  Editor: [Share] button                                      │
│           │                                                  │
│           ▼                                                  │
│  ┌──────────────────────────────────┐                       │
│  │  Pre-share checklist (modal)     │                       │
│  │  ┌────────────────────────────┐  │                       │
│  │  │  Final size: 47 MB         │  │                       │
│  │  │  Annotations: 3 baked      │  │                       │
│  │  │  ⚠ Auto-blur not run       │  │ ← run blur prompt?    │
│  │  │     [Run blur first]       │  │                       │
│  │  │  Expiration: 7 days ▾      │  │                       │
│  │  │  Password: [        ]      │  │ (deferred — viewer v2)│
│  │  │  Include transcript: ☑     │  │                       │
│  │  │            [Cancel] [Share]│  │                       │
│  │  └────────────────────────────┘  │                       │
│  └──────────────────────────────────┘                       │
│                  │                                          │
│                  ▼                                          │
│         Multipart upload (aws-sdk-s3)                       │
│         → RustFS bucket                                     │
│                  │                                          │
│                  ▼                                          │
│         Generate presigned URL (S3 GetObject)               │
│                  │                                          │
│                  ▼                                          │
│   "https://share.your-server.com/v/{key}"                   │
│   Copied to clipboard. Toast notification.                  │
└──────────────────────────────────────────────────────────────┘
```

**Configuration block:**

```json
{
  "sharing": {
    "backend": "s3",
    "endpoint": "https://storage.your-server.com",
    "region": "auto",
    "bucket": "jarvis-recordings",
    "access_key_id": "...",
    "secret_access_key": "...",
    "public_url_template": "https://share.your-server.com/v/{key}",
    "default_expiration_hours": 168,
    "max_upload_mb": 500
  }
}
```

| Concern | Decision |
|---|---|
| Upload library | `aws-sdk-s3` (Rust). Works with any S3-compatible (RustFS, MinIO, R2, B2). |
| URL form | **Presigned URL** (GET, time-limited). |
| Viewer page | **Defer to v2.** |
| Multipart threshold | Files > 50 MB. Resumable uploads for flaky networks. |
| Pre-share checklist | Auto-blur reminder + size + expiration + transcript toggle. |
| Transcript inclusion | Upload `.txt` alongside, link both. |
| Failure handling | Local-first: file always exists locally. Retry queue. |
| Backend = "none" | Disables share button. Local-only mode is valid. |

## 9. Distribution & Packaging

```
                       ┌────────────────────────┐
                       │  Single Tauri binary   │
                       │  (~30–50 MB target)    │
                       │                        │
                       │  + bundled ffmpeg      │
                       │    sidecar             │
                       └────────────────────────┘
                                │
                ┌───────────────┴───────────────┐
                ▼                               ▼
          ┌──────────┐                   ┌──────────┐
          │  macOS   │                   │ Windows  │
          │ .app.zip │                   │ .exe     │
          │ portable │                   │ portable │
          │ notarized│                   │ signed   │
          └──────────┘                   └──────────┘
```

| Concern | Decision |
|---|---|
| Format | Portable per-OS: `.app.zip` (Mac), `.exe` (Win NSIS `--portable`). |
| Code signing | Mac: Developer ID + notarization (~$99/yr). Win: EV cert (~$200/yr). |
| Auto-update | Tauri's built-in updater — signed updates, signature verified on launch. |
| Telemetry | **Off by default**, opt-in. |

## 10. Configuration Reference

Single `jarvis-studio.config.json`:

```json
{
  "openai_api_key": "...",
  "anthropic_api_key": "...",

  "recording": {
    "video_codec": "h265",
    "max_resolution": "1440p",
    "frame_rate": 30,
    "audio_mic": true,
    "audio_system": true,
    "live_transcription": true,
    "transcription_mode": "cloud",
    "transcription_language": "auto"
  },

  "webcam": {
    "enabled": false,
    "position": "bottom-right",
    "shape": "circle",
    "width_px": 240,
    "mirror": true
  },

  "annotations": {
    "vision_model": "claude-sonnet-4",
    "default_color": "#ff3b30",
    "fade_ms": 200,
    "session_cost_cap_usd": 0.50
  },

  "agents": {
    "default_backend": "claude",
    "backends_file": "backends.toml"
  },

  "sharing": { /* §8 */ },

  "data_dir": "~/JarvisStudio"
}
```

## 11. Risk Register

| Risk | Severity | Mitigation |
|---|---|---|
| `scap` is at 0.0.8 | **High** | Lock to specific commit; FFmpeg-direct fallback path designed in |
| `claude` / `codex` CLI breaking changes | Med | Pin via backend TOML; thin adapter layer |
| Vision LLM cost runaway | Med | Hard per-session cap + running tally in editor |
| Cross-platform webcam permissions | Med | Tauri's `getUserMedia` handles, fail gracefully if denied |
| RustFS distributed mode unstable | Low | Single-node only for v1 |
| H.265 patent / browser playback | Med | Transcode-on-share to H.264 if `viewer_compat=true` |
| macOS Gatekeeper / no-install | High | Notarization is mandatory ($99/yr Apple Developer) |
| Linux deferred | Accepted | v2 milestone; revisit when Wayland audio matures |

## 12. Decisions Summary (from brainstorm)

| # | Decision | Choice |
|---|---|---|
| Q1 | Standalone vs evolution | **A: Standalone new app** |
| Q2 | Use case | **D: Hybrid record-first, AI-second, configurable** |
| Q3 | Platform scope | **C: Cross-platform from day one** (revised to macOS + Windows in §11) |
| Q4 | Stack | **A: Tauri 2** |
| Q5 | Distribution priority | **B: Distributable to other users** |
| Q6 | Annotation mechanism | **D: AI-driven, text-mode only** (no manual drawing) |
| Q7 | Agent backends | **Claude Code + Codex CLI, pluggable, easy to extend** |
| Q8 | AI vision approach | **A: Vision LLM on screenshots only** (no accessibility API) |
| — | Naming | **Jarvis Studio** |
| — | Pricing | Free (OSS), paid hosted "Studio Cloud" tier later |

## 13. Open Questions for Plan Phase

- Which Tauri 2 frontend framework? (Svelte recommended for size; React for ecosystem)
- Internal session DB — JSON files, SQLite, or both?
- Should session library be flat (just folders) or have tags / projects / pinning?
- How to handle vision API rate limits during bulk auto-annotate?
- Crash-safe recording: write keyframes to disk continuously vs. flush-on-stop?

## 14. References

- [scap (CapSoftware)](https://github.com/CapSoftware/scap) — cross-platform Rust screen capture
- [Cap](https://capsoftware.io) — open-source Loom alternative, reference implementation in Tauri+Rust
- [Tauri 2.0 docs](https://v2.tauri.app/)
- [OpenAI Codex CLI](https://developers.openai.com/codex/cli) — agent backend
- [Codex GitHub](https://github.com/openai/codex)
- [RustFS](https://rustfs.com) — S3-compatible Rust object storage, Apache 2.0
- [aws-sdk-s3 (Rust)](https://crates.io/crates/aws-sdk-s3) — S3 client crate
