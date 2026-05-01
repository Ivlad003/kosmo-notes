# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

**v0 — design phase. No code, no Xcode project, no Swift Package, no Cargo workspace.** The repository contains design documentation only. Read `docs/plans/2026-05-02-jarvis-note-design.md` first — it is the canonical source of truth for all architectural decisions.

Open the design doc before answering any "how do I implement X" question. Every concrete decision (capture API, transcription provider, encoding format, IPC shape, file layout, dependency lifecycle) is recorded there. Open questions are listed in §16; everything else is decided.

## Pivot history

This repository started as **Jarvis Studio** — a cross-platform Tauri/iced screen recorder in Rust. After ~5 weeks of work (37 passing tests, working v0.1.1) the scope was pivoted on 2026-05-02 to a smaller voice-first macOS-native product called **Jarvis Note**.

- The complete Rust workspace is preserved on branch `archive/jarvis-studio-rust`. Do not check that branch out unless explicitly asked for historical reference.
- The Jarvis Studio design doc (`docs/plans/2026-05-01-jarvis-studio-design.md`) is retained on `main` for cross-references — sections §3.1 (External Dependency Lifecycle) and §8 (Sharing pipeline) are reused conceptually in Jarvis Note's design.
- The Jarvis Studio implementation plan (was in `.omc/plans/`) is **not** on main — it lives in archive only. Do not reference it for new development.
- The vibe-test report (`docs/plans/2026-05-01-vibe-tests.md`) and Chrome Extension analysis (`docs/plans/2026-05-01-chrome-extension-analysis-uk.md`) are retained for the journey trail but apply to Jarvis Studio, not Jarvis Note.

When the user asks about "the project" or "implementation", they mean **Jarvis Note** unless they explicitly say "Jarvis Studio" or "the archive."

## Stack invariants (load-bearing — do not violate)

These come from §3 of the Jarvis Note design doc.

- **Pure Swift / SwiftUI / AppKit.** No Rust, no FFI, no webview, no Tauri / iced / Electron. Native frameworks only: `AVAudioEngine`, `AVPlayer` / `AVPlayerView`, `URLSession`, `GRDB.swift`, Swift concurrency. Bundle target: 5–15 MB. Single `.app`.
- **Cloud-only transcription.** No local Whisper, no WhisperKit, no on-device CoreML model. The privacy posture is partial; see §12 — every recorded second leaves the machine. Ollama covers the LLM stage only.
- **Filesystem sidecars are source of truth, SQLite is rebuildable index.** Sessions live in `~/Library/Application Support/JarvisNote/recordings/<sid>/` with `audio.opus`, `transcript.jsonl`, `summary.md`, `actions.json`. SQLite (`sessions.sqlite`) backs FTS5 + filtering and must be rebuildable from sidecars.
- **macOS 12.3+ supported, 14.4+ preferred.** `<12.3` blocked at startup. Core Audio Tap on 14.4+, ScreenCaptureKit audio fallback on 12.3–14.3.
- **No code signing, no notarization, no auto-update.** Single-user product positioning. Document Gatekeeper bypass (`xattr -d com.apple.quarantine`) for hand-shared binaries.
- **Secrets in macOS Keychain.** Configuration JSON stores only Keychain account references; never plain-text secrets.
- **Provider abstraction is one protocol.** `Provider` (in §7 of design doc) covers Anthropic / OpenAI / OpenRouter / Ollama. Default LLM: Anthropic Claude Sonnet (latest at ship time). Default transcription: Deepgram Nova-2 with EU residency.
- **Ollama is REST-only.** No bundled inference. User configures their own endpoint. v1 supports both `/v1/chat/completions` (OpenAI-compat) and `/api/chat` (native) — picked at runtime, not compile time.
- **No hosted viewer page for shared links.** Presigned URLs point at the raw audio / markdown bundle. Recipients open in browser.

## Build and run

The build system does not exist yet. When it lands it will be a standard macOS Xcode / SwiftPM project:

- `xed .` — open in Xcode
- `swift build` — SwiftPM build (for the library targets, before the `.app` is bundled)
- `xcodebuild -scheme JarvisNote -configuration Release` — release build
- Distribution: `.app` produced by Xcode → `ditto -c -k --keepParent JarvisNote.app JarvisNote.zip` → hand-share.

Until the project is scaffolded, treat any "run it" / "test it" request as a sign that bootstrapping is the actual task.

## Editing the design doc

`docs/plans/2026-05-02-jarvis-note-design.md` is the spec, not a draft. Don't silently change decisions there to match implementation drift — if implementation diverges, that's a discussion, and the design doc gets a new dated revision rather than an in-place edit. The §15 Decision Log is load-bearing: it records what was settled and what would cause revisit.

## Pivot-time discipline

The Jarvis Studio → Jarvis Note pivot happened after three stack pivots in three days (Tauri → iced → Swift) and four review rounds. **The Swift / cloud-transcription / no-screen-recording decisions are settled.** Reverting to a screen-recording product, a Rust core, or a webview frontend is **out of scope** for v1 and would invalidate the entire spec. If the user proposes another pivot, surface it as a major decision needing a separate design pass — don't quietly accommodate.

## Editing this file

If `docs/plans/2026-05-02-jarvis-note-design.md` is the spec, this file is the operating manual for working in the repo. Update it when the stack invariants change, when new sections are added to the design doc, or when a recurring user instruction emerges. Don't pad it with code-style preferences (those go in repo-level config like `.swiftlint.yml`) or feature wishlists (those go in the design doc's open-questions section).
