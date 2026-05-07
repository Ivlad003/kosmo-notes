# KosmoNotes

macOS menu-bar voice-first AI capture tool. Records mic + system audio (optional screen), transcribes in real-time or batch, and runs AI processing for summaries, action items, dictation, and multi-turn chat.

> **Status:** v1.0 feature-complete. All capture, transcription, AI, library, sharing, and chat features are wired. Manual smoke test pending before tagging. See the [design doc](docs/plans/2026-05-02-jarvis-note-design.md) and [v1.0 checklist](docs/release/v1.0-checklist.md).

## Building and installing

### Prerequisites

- macOS 14.0+ (both build machine and target)
- Xcode 15.4+ — download from [developer.apple.com/xcode](https://developer.apple.com/xcode/)
- `xcodegen` — `brew install xcodegen`
- Apple Development certificate in your keychain (for signed builds that persist TCC permissions across updates)

### Install to /Applications (recommended)

```bash
make install
```

This builds a Release binary, signs it with your Apple Development certificate, and copies it to `/Applications/KosmoNotes.app`. TCC permissions (microphone, screen recording, accessibility) are preserved across subsequent `make install` runs because the code-signing identity stays stable.

### Run tests

```bash
make test
# or: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

280 tests pass in ~0.5 s. A FTS5 perf benchmark is gated behind `JN_RUN_PERF=1`.

### Open in Xcode

```bash
xed .
```

### Notes

- `KosmoNotes.xcodeproj` is **gitignored** — only `project.yml` is committed. Run `xcodegen generate` after cloning.
- App Sandbox is **off** (required for Accessibility paste in Dictation Mode).
- The build is signed with an Apple Development cert (not notarized). First launch from a hand-shared zip still requires Gatekeeper bypass: `xattr -d com.apple.quarantine /Applications/KosmoNotes.app`.

## What it does

| Mode | Duration | Audio | Output |
|---|---|---|---|
| **Meeting** | 30 min – 3 hr | Mic + system | AI summary, action items, transcript |
| **Voice Note** | 1 – 15 min | Mic | Structured note / task / journal / checklist |
| **Dictation** | < 60 s | Mic | Paste to active app, < 1.5 s latency |

Additional features:
- **Live transcription** — real-time text as you speak (Deepgram WebSocket)
- **Multi-turn chat** — ask questions about any session; vision-capable if screen recording is enabled
- **Library** — full-text + semantic search across all sessions
- **Multi-language** — UA / RU / EN / FR; record in one language, summarise in another
- **S3 sharing** — presigned URLs, compatible with AWS / R2 / B2 / MinIO
- **Global hotkeys** — ⌘⇧R Meeting · ⌘⇧N Voice Note · ⌘⇧L Library (rebindable)
- **Optional screen recording** — H.264 screen.mp4 alongside audio; used for vision-chat frame extraction

## Stack

- **App:** Pure Swift / SwiftUI / AppKit. No Rust, no FFI, no webview. Single `.app`, ~16 MB installed.
- **Capture:** `AVAudioEngine` (mic) + Core Audio Tap on macOS 14.4+ / ScreenCaptureKit on 14.0–14.3 (system audio). Optional SCStream screen recording.
- **Transcription:** Deepgram Nova-2 (default, EU residency), OpenAI Whisper, Gemini, OpenRouter, **WhisperKit** (on-device CoreML, opt-in)
- **AI processing:** Anthropic / OpenAI / OpenRouter / **Ollama (REST)** — single `Provider` protocol
- **Storage:** GRDB.swift / SQLite FTS5 + filesystem sidecars (`audio.m4a`, `transcript.jsonl`, `summary.md`, `actions.json`, optional `screen.mp4`)
- **Sharing:** Hand-rolled AWS Sig V4. `S3Client.putObject` + presigned GET URLs. No aws-sdk dependency.

## Platform support

| OS | Status | Notes |
|---|---|---|
| macOS 14.4+ | ✅ | Core Audio Tap (per-process system audio) |
| macOS 14.0–14.3 | ✅ | ScreenCaptureKit whole-system mixdown |
| macOS < 14.0 | ❌ | `LSMinimumSystemVersion` blocks launch |

## Privacy

**Default (cloud transcription):** Audio leaves the machine for Deepgram / OpenAI / Gemini / OpenRouter. The LLM stage can be local via Ollama.

**Opt-in fully local:** Switch to **WhisperKit** in Settings → Transcription. Models download on demand (~250 MB – 3 GB depending on variant) to `~/Library/Application Support/KosmoNotes/whisperkit/`. Nothing leaves the machine.

## Configuration

API keys live in **macOS Keychain**. Settings are in `~/Library/Preferences/dev.kosmonotes.studio.plist` (UserDefaults). See §13 of the design doc.

## Permissions

On first launch the app shows a permission-education dialog. On each new version install the app automatically re-requests any missing permissions (microphone, screen recording, accessibility) so macOS surfaces the system dialogs without requiring a manual visit to System Settings.

## Distribution

Hand-shared binary. No notarization, no auto-update. Pack for sharing:

```bash
ditto -c -k --keepParent /Applications/KosmoNotes.app KosmoNotes.zip
```

Recipients: `xattr -d com.apple.quarantine /Applications/KosmoNotes.app`

## Archive

The original **Jarvis Studio** Rust implementation (Tauri → iced pivot, 9 crates, 37 passing tests, working v0.1.1) is preserved at `archive/jarvis-studio-rust`. Do not check out that branch for new development.

## License

MIT — see [LICENSE](LICENSE).
