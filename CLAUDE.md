# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

**v0 — Phase A Weeks 2–3 storage + transcription complete.** The Swift Package exists, **96 tests pass across 19 suites**, and `xcodebuild` produces a `.app`. Read `docs/plans/2026-05-02-jarvis-note-design.md` first — it is the canonical source of truth for all architectural decisions, and `.omc/plans/2026-05-02-jarvis-note-v1-implementation.md` for the phase-by-phase plan.

Phase A Week 2 (TranscriptionKit + recovery):
- `Sources/StorageKit/RecoveryService.swift` — orphan-segment scanner + `AVMutableComposition` + `AVAssetExportSession` (`AppleM4A` preset) concat. Replaces the design-doc's bundled-ffmpeg approach (AAC-in-`.m4a` is natively concatenable).
- `Sources/TranscriptionKit/{Models,WebSocketTransport,Provider,DeepgramProvider,TranscriptStore}.swift` — happy-path Deepgram pipeline: typed config / segments / errors, transport abstraction (`URLSessionWebSocketTransport` + injectable mock), `TranscriptionSession` actor with `events: AsyncStream<TranscriptSegment>`, Deepgram URL builder + JSON `Results` parser, `TranscriptStore` actor writing JSONL + atomic TXT.
- `Sources/TranscriptionKit/ReconnectingSession.swift` — resilient layer on top of the happy-path session: 5-s audio ring buffer, exponential backoff (0.25→0.5→1→2→4 s, capped, max 5 retries), stable `events` stream across reconnects, injectable `ReconnectClock` for tests. `DeepgramProvider.openResilientSession(config:clock:)` is the production entry point; `openSession(config:)` remains for tests/single-shot use.

Phase A Week 3 (StorageKit DB + session store):
- `Sources/StorageKit/Database.swift` — GRDB-backed schema v1: `sessions` (id, recorded_at, duration_secs, mode, language, status) + `transcripts_fts` FTS5 virtual table. WAL journal mode. Idempotent migration via `DatabaseMigrator`.
- `Sources/StorageKit/SessionStore.swift` — actor that creates `<root>/<sid>/`, writes `session.json` atomically via `AtomicWriter`, inserts/updates DB rows, indexes transcript text into FTS.

**Still to land in Phase A:** `RecorderState` actor wiring CaptureKit → TranscriptionKit → SessionStore, popover Record button, mic level meter (Phase A Week 3 finish), Settings → Transcription panel + Test connection (Phase A Week 4).

Phase A Week 1 deliverables implemented (CaptureKit):
- `Sources/CaptureKit/AudioEngine.swift` — `AVAudioEngine` mic input, mono Float32 PCM @ 48 kHz, ~100 ms buffers via `AsyncStream`
- `Sources/CaptureKit/ScreenCaptureKitAudio.swift` — `SCStream`-backed whole-system mixdown, `AsyncStream<AVAudioPCMBuffer>` (TCC required at runtime; CI tests gated)
- `Sources/CaptureKit/AACEncoder.swift` — `AVAudioConverter` PCM→AAC encoder, 96 kbps mono. **See "Encoder deviation" below.**
- `Sources/CaptureKit/SegmentWriter.swift` — 5 s rolling 2-track `.m4a` segments via `AVAssetWriter` (track 0 = mic, track 1 = system audio per AC-5). Crash bound: ≤5 s on SIGKILL
- `Sources/CaptureKit/CaptureSession.swift` — actor coordinating mic + SCKit feeds into a single `SegmentWriter`; public API `start / pause / resume / stop`

Phase 0 deliverables (still in place):
- `.github/workflows/ci.yml` — GitHub Actions CI on push/PR (xcodegen + swift build + swift test + xcodebuild)
- `App/Views/Onboarding/OnboardingView.swift` + `App/JarvisNoteApp.swift` — first-launch permission-education modal
- `Sources/StorageKit/` — `AtomicWriter` + `KeychainStore`
- `Sources/DependencyLifecycle/` — state machine + `StatePersistence` actor

**Empty / next:** `Sources/TranscriptionKit/`, `Sources/AIKit/`, `Sources/DictationKit/` are stubs (`lib.swift` only). `Sources/StorageKit/` still needs `Database.swift`, `SessionStore.swift`, `RecoveryService.swift`. Phase A Week 2 (Deepgram + RecoveryService) is next.

### Encoder deviation: AAC, not Opus

The plan and design doc originally specified Opus 96 kbps mono in an Ogg or `.opus` container. Implementation pivoted to **AAC 96 kbps mono in `.m4a`** because `AVAudioConverter` Opus output requires macOS 14+ and the deployment target is macOS 12.3+. AAC is universally supported, plays in QuickTime/Safari natively, requires zero extra dependencies. File size is roughly 2× larger than equivalent Opus — acceptable for v1.0.

Knock-on effect: **`RecoveryService` no longer needs a bundled `ffmpeg` subprocess.** AAC segments in `.m4a` can be concatenated losslessly via `AVMutableComposition` + `AVAssetExportSession` with `AVAssetExportPresetPassthrough` — no re-encode, no 30 MB ffmpeg static binary. The §8 boundary item ("ffmpeg vs Ogg-stdlib concat") is retired. Bundle stays well under the 15 MB AC-16 budget.

If Opus is required in a future version, raise the deployment target to macOS 14+ and switch `AVAudioFormat` settings to `kAudioFormatOpus`.

Open the design doc before answering any "how do I implement X" question. Every concrete decision (capture API, transcription provider, encoding format, IPC shape, file layout, dependency lifecycle) is recorded there. Open questions are listed in §16; everything else is decided.

## Pivot history

This repository started as **Jarvis Studio** — a cross-platform Tauri/iced screen recorder in Rust. After ~5 weeks of work (37 passing tests, working v0.1.1) the scope was pivoted on 2026-05-02 to a smaller voice-first macOS-native product called **Jarvis Note**.

### 2026-05-02 (evening): Screen recording reinstated

The original Jarvis Note pivot deferred screen recording. The user reversed that
decision after using the v0 audio-only build — the chat is much more useful when
it can answer "what was on screen at minute X" by extracting a frame and sending
it to a vision-capable model.

What changed:
- `Sources/CaptureKit/ScreenRecorder.swift` adds SCStream-based screen + system
  audio capture, writing to `<sessionDir>/screen.mp4` via AVAssetWriter (H.264
  + AAC, 24 fps, 4 Mbps).
- `AppSettings.RecordingMode` toggle: Audio only / Audio + Screen.
- `AIKit.ChatMessage` now has structured parts (text + image), Anthropic + OpenAI
  providers handle base64 image blocks.
- `ChatState` parses timestamp references in user messages, extracts frames from
  screen.mp4 of attached sessions via `FrameExtractor`, attaches them as image
  parts. Cap: 3 frames/send.

Stack invariant updates:
- The "no screen recording" line in §"Stack invariants" is REMOVED.
- Recording mode is configurable in Settings → Transcription; audio-only stays the default.

- The complete Rust workspace is preserved on branch `archive/jarvis-studio-rust`. Do not check that branch out unless explicitly asked for historical reference.
- The Jarvis Studio design doc (`docs/plans/2026-05-01-jarvis-studio-design.md`) is retained on `main` for cross-references — sections §3.1 (External Dependency Lifecycle) and §8 (Sharing pipeline) are reused conceptually in Jarvis Note's design.
- The Jarvis Studio implementation plan (was in `.omc/plans/`) is **not** on main — it lives in archive only. Do not reference it for new development.
- The vibe-test report (`docs/plans/2026-05-01-vibe-tests.md`) and Chrome Extension analysis (`docs/plans/2026-05-01-chrome-extension-analysis-uk.md`) are retained for the journey trail but apply to Jarvis Studio, not Jarvis Note.

When the user asks about "the project" or "implementation", they mean **Jarvis Note** unless they explicitly say "Jarvis Studio" or "the archive."

## Stack invariants (load-bearing — do not violate)

These come from §3 of the Jarvis Note design doc.

- **Pure Swift / SwiftUI / AppKit.** No Rust, no FFI, no webview, no Tauri / iced / Electron. Native frameworks only: `AVAudioEngine`, `AVPlayer` / `AVPlayerView`, `URLSession`, `GRDB.swift`, Swift concurrency. Bundle target: 5–15 MB. Single `.app`.
- **Cloud-only transcription.** No local Whisper, no WhisperKit, no on-device CoreML model. The privacy posture is partial; see §12 — every recorded second leaves the machine. Ollama covers the LLM stage only.
- **Filesystem sidecars are source of truth, SQLite is rebuildable index.** Sessions live in `~/Library/Application Support/JarvisNote/recordings/<sid>/` with `audio.m4a` (AAC; was `audio.opus` in design — see "Encoder deviation"), `transcript.jsonl`, `summary.md`, `actions.json`. Optional: `screen.mp4` when recording mode is Audio + Screen. SQLite (`sessions.sqlite`) backs FTS5 + filtering and must be rebuildable from sidecars.
- **macOS 12.3+ supported, 14.4+ preferred.** `<12.3` blocked at startup. Core Audio Tap on 14.4+, ScreenCaptureKit audio fallback on 12.3–14.3.
- **Screen recording is optional, configurable, and off by default.** `AppSettings.recordingMode` controls whether screen.mp4 is captured alongside audio. Requires Screen Recording TCC permission when enabled. Screen frames are used locally for vision-chat only — never uploaded.
- **No code signing, no notarization, no auto-update.** Single-user product positioning. Document Gatekeeper bypass (`xattr -d com.apple.quarantine`) for hand-shared binaries.
- **Secrets in macOS Keychain.** Configuration JSON stores only Keychain account references; never plain-text secrets.
- **Provider abstraction is one protocol.** `Provider` (in §7 of design doc) covers Anthropic / OpenAI / OpenRouter / Ollama. Default LLM: Anthropic Claude Sonnet (latest at ship time). Default transcription: Deepgram Nova-2 with EU residency.
- **Ollama is REST-only.** No bundled inference. User configures their own endpoint. v1 supports both `/v1/chat/completions` (OpenAI-compat) and `/api/chat` (native) — picked at runtime, not compile time.
- **No hosted viewer page for shared links.** Presigned URLs point at the raw audio / markdown bundle. Recipients open in browser.

## Build and run

**Toolchain requirement:** `swift test` requires Xcode's toolchain, not Command Line Tools. Plain `swift test` with the CLT active will run zero tests (the `__swift5_tests` section that Swift Testing needs is only emitted by Xcode's toolchain). Always prefix with `DEVELOPER_DIR`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Both exit 0. All 96 tests pass in ~0.6 s.

Other commands:
- `xed .` — open in Xcode
- `xcodebuild -scheme JarvisNote -configuration Release` — release build (once `.app` target exists)
- Distribution: `.app` produced by Xcode → `ditto -c -k --keepParent JarvisNote.app JarvisNote.zip` → hand-share.

## Editing the design doc

`docs/plans/2026-05-02-jarvis-note-design.md` is the spec, not a draft. Don't silently change decisions there to match implementation drift — if implementation diverges, that's a discussion, and the design doc gets a new dated revision rather than an in-place edit. The §15 Decision Log is load-bearing: it records what was settled and what would cause revisit.

## Pivot-time discipline

The Jarvis Studio → Jarvis Note pivot happened after three stack pivots in three days (Tauri → iced → Swift) and four review rounds. **The Swift / cloud-transcription decisions are settled.** A Rust core or webview frontend is **out of scope** for v1 and would invalidate the entire spec.

Screen recording was originally deferred but was reinstated on 2026-05-02 evening (see "Pivot history" above) — it is now an opt-in feature, not a product direction change. If the user proposes another pivot, surface it as a major decision needing a separate design pass — don't quietly accommodate.

## Editing this file

If `docs/plans/2026-05-02-jarvis-note-design.md` is the spec, this file is the operating manual for working in the repo. Update it when the stack invariants change, when new sections are added to the design doc, or when a recurring user instruction emerges. Don't pad it with code-style preferences (those go in repo-level config like `.swiftlint.yml`) or feature wishlists (those go in the design doc's open-questions section).
