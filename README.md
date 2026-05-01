# Jarvis Note

macOS menu-bar voice-first AI capture tool. Records audio (mic + system), transcribes via cloud APIs, runs AI processing for summaries / action items / dictation.

> **Status:** v0 — design phase. No code yet. See the [design doc](docs/plans/2026-05-02-jarvis-note-design.md).
>
> **Pivot history:** This project started as **Jarvis Studio** — a cross-platform Tauri/iced screen recorder. After ~5 weeks of build (37 passing tests, working v0.1.1) the scope was pivoted to a smaller voice-first product. The complete Rust workspace is preserved on the `archive/jarvis-studio-rust` branch.

## What it does

- **Meeting Mode** — long-form (30 min – 3 hr), mic + system audio, post-call AI summary in your client's language
- **Dictation Mode** — short bursts (<60 s), mic only, paste-to-active-app, <1.5 s end-to-end latency
- **Voice Note Mode** — medium-form (1–15 min), AI structures into note / task / journal / checklist
- **Multi-language native** — UA / RU / EN / FR. Record UA-language call → FR summary for client.
- **Self-hosted LLM via Ollama REST** — local or remote (Hetzner GPU box), bring your own
- **Developer-context paste** — Cursor / VS Code / GitHub / Linear / Jira aware

## Stack

- **App:** Pure Swift / SwiftUI / AppKit. No Rust, no FFI, no webview. Single `.app`, ~5–15 MB.
- **Capture:** `AVAudioEngine` (mic) + Core Audio Tap on macOS 14.4+ / ScreenCaptureKit on 12.3–14.3 (system audio)
- **Transcription:** Cloud only — Deepgram Nova-2 (default), OpenAI Whisper, AssemblyAI
- **AI processing:** Anthropic / OpenAI / OpenRouter / **Ollama (REST)** — single `Provider` protocol
- **Storage:** GRDB.swift / SQLite (index, FTS5) + filesystem sidecars (transcript.jsonl, summary.md, audio.opus)
- **Sharing:** Any S3-compatible — RustFS / MinIO / R2 / B2. Presigned URLs, no hosted viewer.

## Platform Support

| OS | v1 | Notes |
|---|---|---|
| macOS 14.4+ | ✅ | Core Audio Tap, full per-process system audio |
| macOS 12.3–14.3 | ✅ | ScreenCaptureKit fallback (whole-system mixdown) |
| macOS <12.3 | ❌ | Unsupported (no system audio API) |
| Windows | ❌ | Out of scope |
| Linux | ❌ | Out of scope |

## Privacy posture

**Honest version:** Audio always leaves the machine for transcription (Deepgram / OpenAI / AssemblyAI). The LLM stage can be local via Ollama, or cloud. **Privacy is partial** — see §12 of the design doc. If you require fully-local audio processing, this is not your tool — try Macwhisper or Aiko.

## Roadmap

- [x] Design document (Jarvis Note)
- [ ] v0.1 — Meeting Mode + transcript only (~2 weeks)
- [ ] v0.2 — AI summary + Library window (~2 weeks)
- [ ] v0.3 — Dictation Mode + Sharing (~2 weeks)
- [ ] v1.0 — All three modes ship together
- [ ] v1.1+ — Embedding-based semantic search, configurable third-party OpenAI-compat endpoints

## Distribution

Hand-shared binary. **No code signing, no notarization, no auto-update.** First-launch: right-click `.app` → Open to bypass Gatekeeper, or `xattr -d com.apple.quarantine /Applications/JarvisNote.app`. Single-user, personal-tool positioning.

## Configuration

API keys live in macOS Keychain. Other settings in `UserDefaults` + `~/Library/Application Support/JarvisNote/JarvisNote.config.json`. See §13 of the design doc.

## Contributing

Project is in design phase. Pull requests for code will open after v0.1 implementation begins.

## Archive

The Jarvis Studio Rust implementation (Tauri → iced pivot, 9 crates, 37 passing tests, 5 review rounds, audio-only mode, Whisper Cloud transcription, Settings tab, error-banner UX) is preserved at branch `archive/jarvis-studio-rust`. Out of scope for new development; checkout that branch only for historical reference.

## License

MIT — see [LICENSE](LICENSE).
