# Jarvis Studio

Cross-platform desktop screen recorder with AI-driven annotations, transcription, agent-backed Q&A, and self-hosted sharing.

> **Status:** v0 — design phase. No code yet. See the [design doc](docs/plans/2026-05-01-jarvis-studio-design.md).

## What It Does

- Record screen + webcam + mic + system audio
- Live transcription via Whisper (cloud or local)
- **AI-driven annotations** — type *"circle the error message at 2:14"*, vision LLM places it
- Q&A over completed sessions via pluggable subprocess agents (Claude Code, Codex CLI, ...)
- Self-hosted sharing via S3-compatible storage (RustFS, MinIO, R2, B2)
- One portable executable — no installer required

## Why

Loom-style recording is good. Loom-style sharing is good. AI tools that understand your screen recordings are good. None of them are open source, self-hostable, or composable. Jarvis Studio is.

## Stack

- **App:** [Tauri 2](https://v2.tauri.app/) (Rust + system webview), portable build
- **Capture:** [`scap`](https://github.com/CapSoftware/scap) + ffmpeg sidecar
- **Transcription:** OpenAI Whisper API or local `whisper-rs`
- **AI annotations:** Claude Sonnet 4 / GPT-4o vision (direct API)
- **Agents:** subprocess-pluggable — Claude Code, [OpenAI Codex CLI](https://github.com/openai/codex), or any CLI you wire in
- **Storage:** any S3-compatible — [RustFS](https://rustfs.com) recommended for self-hosting

## Platform Support

| OS | v1 | Notes |
|---|---|---|
| macOS | ✅ | ScreenCaptureKit via scap; notarized |
| Windows | ✅ | WGC via scap; signed |
| Linux | 🔜 | Deferred — revisit when Wayland audio matures |

## Roadmap

- [x] Design document
- [ ] Implementation plan
- [ ] v0.1 — Recording pipeline + library UI
- [ ] v0.2 — AI annotation pipeline (vision LLM + non-destructive JSON)
- [ ] v0.3 — Agent Q&A panel (Claude Code / Codex backends)
- [ ] v0.4 — Sharing via S3-compatible storage
- [ ] v1.0 — Notarized macOS + signed Windows builds
- [ ] v2.0 — Linux, paid Studio Cloud tier, viewer page

## Configuration

All settings live in a single `jarvis-studio.config.json`. See §10 of the [design doc](docs/plans/2026-05-01-jarvis-studio-design.md#10-configuration-reference).

## Contributing

Project is in design phase. Issues and design feedback are welcome. Pull requests for code will open after the v0.1 plan is published.

## License

MIT — see [LICENSE](LICENSE).
