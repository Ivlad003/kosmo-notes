
# KosmoNotes audit: architecture, code review, and spec conformance

**Date:** 2026-05-03  
**Scope:** repository-wide audit against the current code, `docs/plans/2026-05-02-kosmonotes-design.md`, `.omc/plans/2026-05-02-kosmonotes-v1-implementation.md`, `CLAUDE.md`, `README.md`, and `docs/release/v1.0-checklist.md`

## Executive verdict

The codebase is **substantially more capable than the scope-reduced v1.0 implementation plan**, and its **runtime architecture is mostly coherent**, but the documentation is no longer internally consistent.

The strongest parts are the **filesystem-first storage model**, the **actor-based capture / transcription / storage boundaries**, and the **provider abstractions** across AI, transcription, embeddings, and sharing. The weakest parts are **document drift**, **large orchestration objects**, and a few places where the shipped behavior no longer matches the spec literally.

The most important conclusion is this:

1. **The code is ahead of the scope-cut implementation plan.**
2. **The implementation plan is no longer an accurate picture of what is in the repo.**
3. **The release checklist is still empty, so “implemented” is not the same as “release-proven.”**

## Which documents are authoritative

### Recommended source order

1. **Architecture decisions:** `docs/plans/2026-05-02-kosmonotes-design.md`
2. **Original v1.0 scope cut:** `.omc/plans/2026-05-02-kosmonotes-v1-implementation.md:14-23`
3. **Current repo reality:** `CLAUDE.md:7-20`
4. **User-facing overview only:** `README.md`
5. **Release proof, not product truth:** `docs/release/v1.0-checklist.md`

### Why this matters

The implementation plan explicitly says the scope was cut: per-process Core Audio Tap, Voice Note Mode, Sharing, and embeddings were deferred to v1.1 in that document (`.omc/plans/2026-05-02-kosmonotes-v1-implementation.md:14-23`, `40-45`).  

But `CLAUDE.md` says those features were added on 2026-05-03 and describes them as present in code (`CLAUDE.md:9-20`). The code confirms that `CLAUDE.md` is closer to present reality than the old implementation plan.

## What the architecture actually looks like

### High-level structure

The repo follows a sensible four-layer shape:

| Layer | Main files | Notes |
|---|---|---|
| App shell | `App/KosmoNotesApp.swift` | App lifecycle, status item, windows, bootstrap |
| App state | `App/State/*.swift` | `@Observable` orchestration objects for recorder, dictation, library, chat, settings |
| Domain kits | `Sources/{CaptureKit,TranscriptionKit,AIKit,StorageKit,DictationKit,SharingKit}` | Mostly clean feature/module boundaries |
| Persistence / external systems | SQLite, filesystem sidecars, cloud providers, S3 | Provider protocols hide most network details |

### Architectural strengths

1. **Filesystem sidecars are the real source of truth.** `SessionStore` writes `session.json` atomically before updating SQLite, which is exactly the invariant the design calls for (`Sources/StorageKit/SessionStore.swift:5-10`, `24-40`, `46-66`; `CLAUDE.md:97-104`).

2. **The storage layer is solid.** `AppDatabase` uses WAL mode, FTS5, and a separate embeddings table (`Sources/StorageKit/Database.swift:83-88`, `93-129`). That is a pragmatic split: sidecars for durability, SQLite for indexing.

3. **Crash recovery is a first-class design concern.** `RecoveryService` scans orphan segment folders and rebuilds `audio.m4a` with AVFoundation instead of an external ffmpeg dependency (`Sources/StorageKit/RecoveryService.swift:6-18`, `50-59`, `112-200`).

4. **Capture has a clear fallback chain.** `CaptureSession` prefers a user-selected loopback device, then Core Audio Tap on 14.4+, then ScreenCaptureKit mixdown (`Sources/CaptureKit/CaptureSession.swift:156-193`). That is a strong operational design even if it increases test surface.

5. **Provider abstraction is consistently applied.** There is a single `AIProvider` protocol (`Sources/AIKit/Provider.swift:5-8`), a `TranscriptionProvider` for streaming (`Sources/TranscriptionKit/Provider.swift:5-12`), batch providers in the recorder path, and an `EmbeddingProvider` for semantic search (`Sources/AIKit/EmbeddingProvider.swift:5-21`).

6. **Tests are broad, not symbolic.** The current suite covers capture, transcription, AI providers, storage, dictation signposts, and S3 SigV4. The latest run passed with **235 tests in 52 suites** (`/var/.../copilot-tool-output-1777809562746-hpmvek.txt:646-654`).

### Architectural deviations from the design

1. **App shell implementation diverged from the design diagram.**  
   The design doc shows a `MenuBarExtra` popover shell (`docs/plans/2026-05-02-kosmonotes-design.md:92-100`), but the real app uses `NSStatusItem` + `NSMenu` in `AppDelegate` (`App/KosmoNotesApp.swift:185-199`, `216-256`).  
   This is not necessarily bad; it is a concrete implementation choice for LSUIElement reliability. It does mean the architecture doc is no longer literally accurate at the shell layer.

2. **The repo has grown beyond the original product envelope.**  
   Settings now expose tabs for **Sharing**, **Markdown**, and **Agent** in addition to the core product tabs (`App/Views/Settings/SettingsView.swift:18-45`). `AppSettings` also contains full agent-related configuration (`App/State/AppSettings.swift:223-244`, `360-397`).  
   These are real features, but they are outside the original narrow KosmoNotes v1.0 story and add architectural weight.

## Code review: what is implemented well

### Good implementations

1. **Recorder pipeline wiring is complete.**  
   `RecorderState` creates the session, starts capture, finalizes segments, chooses a batch transcription provider, persists transcripts, indexes FTS, optionally indexes embeddings, writes summary, and finalizes the session (`App/State/RecorderState.swift:214-279`, `307-437`, `530-664`).

2. **Library behavior is materially implemented, not stubbed.**  
   The Library window supports search, mode filters, waveform thumbnails, AVPlayer playback, click-to-seek transcript rows, live segment highlighting, export, share, and delete (`App/Views/Library/LibraryView.swift:17-62`, `147-204`, `263-299`, `469-598`).

3. **Per-process tap is not a placeholder.**  
   `CoreAudioTap` resolves bundle IDs to running processes, creates a process tap, wraps it in an aggregate device, and streams PCM via `AVAudioEngine` (`Sources/CaptureKit/CoreAudioTap.swift:8-25`, `40-145`).

4. **Screen recording is real and integrated.**  
   `CaptureSession` can start `ScreenRecorder` (`Sources/CaptureKit/CaptureSession.swift:196-208`), and `ScreenRecorder` writes `screen.mp4` via `SCStream` + `AVAssetWriter` (`Sources/CaptureKit/ScreenRecorder.swift:16-25`, `82-191`, `193-309`).

5. **Sharing is real and not just UI chrome.**  
   The Library view shows a Share button (`App/Views/Library/LibraryView.swift:276-284`), `ShareCoordinator` validates settings and uploads a session (`App/State/ShareCoordinator.swift:23-61`), and `SharingService` uploads audio / summary / transcript and returns presigned URLs (`Sources/SharingKit/SharingService.swift:38-79`). `S3Client` implements actual SigV4 signing (`Sources/SharingKit/S3Client.swift:42-182`).

6. **Semantic search is real and wired.**  
   The DB has an embeddings migration (`Sources/StorageKit/Database.swift:114-128`), `RecorderState` indexes vectors (`App/State/RecorderState.swift:638-663`), and `LibraryState` merges semantic hits into FTS results (`App/State/LibraryState.swift:81-93`, `198-223`).

## Code review: the main weaknesses

### 1. `RecorderState` and `AppSettings` are too large

- `RecorderState` is doing capture orchestration, transcription selection, transcript cleanup, summary generation, semantic indexing, cost-cap UI, and teardown in one class (`App/State/RecorderState.swift:26-717`).
- `AppSettings` is both a settings store and a feature surface inventory. It carries provider choices, hotkeys, recording mode, sharing config, camera bubble config, markdown export config, and agent config (`App/State/AppSettings.swift:19-257`, `360-871`).

This is not broken, but it is the main maintainability risk. The codebase still feels understandable because the modules under `Sources/` are reasonably separated. The app-layer state objects are where complexity has pooled.

### 2. Silent partial failures are common

Examples:

- `LibraryState.refresh()` catches and prints instead of surfacing UI state (`App/State/LibraryState.swift:119-123`).
- `LibraryState.semanticHits()` returns `[]` on any failure (`App/State/LibraryState.swift:201-223`).
- `RecorderState.indexSemantic` silently skips failures (`App/State/RecorderState.swift:640-663`).
- Summary generation and transcript cleanup intentionally degrade softly, which is reasonable, but the user often gets no visibility into which enhancement failed (`App/State/RecorderState.swift:375-388`, `530-633`).

This makes the product resilient, but it also makes it hard to tell the difference between “no result” and “degraded result.”

### 3. Some comments are stale enough to mislead a reviewer

`RecorderState` still documents itself as “Whisper-only batch transcription” and “Mic only” in its top comment (`App/State/RecorderState.swift:33-38`), but the implementation below supports multiple batch providers and optional system audio / screen recording (`App/State/RecorderState.swift:147-172`, `184-205`, `225-239`, `350-368`).  

This is small, but it matters in a repo where the docs already drift.

### 4. The product surface has expanded faster than the docs

The repo now contains:

- Voice Note mode
- Screen recording
- Per-process audio tap
- S3 sharing
- Semantic search
- Markdown export
- Agent / push-to-markdown features

That makes the app more interesting, but it also means the original scope docs are no longer a reliable implementation map.

## Spec conformance: what matches, what drifted, what is missing

### Features implemented in code even though the old v1.0 plan deferred them

| Feature | Old plan status | Code status | Evidence |
|---|---|---|---|
| Voice Note mode | Deferred to v1.1 (`.omc/...implementation.md:16-17`, `40-45`) | Implemented | `SessionMode.voiceNote` (`Sources/StorageKit/Database.swift:6-18`), `VoiceNoteTab` (`App/Views/Settings/SettingsView.swift:28-30`), voice-note summary branch (`App/State/RecorderState.swift:547-555`) |
| Per-process Core Audio Tap | Deferred to v1.1 (`.omc/...implementation.md:15`, `43`) | Implemented | `CoreAudioTap.swift` (`Sources/CaptureKit/CoreAudioTap.swift:8-25`), fallback wiring in `CaptureSession` (`Sources/CaptureKit/CaptureSession.swift:179-193`) |
| S3 sharing | Deferred to v1.1 (`.omc/...implementation.md:17`, `42`) | Implemented | `SharingTab` (`App/Views/Settings/SettingsView.swift:34-35`), `ShareCoordinator` (`App/State/ShareCoordinator.swift:23-61`), `SharingService` (`Sources/SharingKit/SharingService.swift:38-79`) |
| Embedding semantic search | Deferred to v1.1+ (`.omc/...implementation.md:23`, `44`) | Implemented | embeddings migration (`Sources/StorageKit/Database.swift:114-128`), indexing (`App/State/RecorderState.swift:638-663`), search merge (`App/State/LibraryState.swift:81-93`, `198-223`) |

### Major spec mismatches

#### 1. The actual deployment target is 14.0+, not real 12.3+

The package and Xcode project both pin macOS 14 (`Package.swift:6-8`, `project.yml:6-8`, `27`, `53`). The app code is heavily gated with `@available(macOS 14.0, *)`, and the repo’s own operating manual now says 14.0+ is the actual target (`CLAUDE.md:95-104`).

That means older 12.3 fallback language in the design doc, implementation plan, and release checklist is now mostly **historical documentation**, not a realistic shipped contract.

This has two concrete consequences:

1. `docs/release/v1.0-checklist.md` still contains rows for `12.5 Intel` and `<12.3` behavior (`docs/release/v1.0-checklist.md:9-17`, `23-56`), but those rows are not aligned with the actual build target.
2. The startup `<12.3` modal path is effectively defensive dead code in a 14.0-targeted app, which `CLAUDE.md` already calls out (`CLAUDE.md:98-99`).

#### 2. The production recording path is batch transcription, not the planned live Deepgram streaming path

The old plan expects Deepgram streaming in the Meeting path (`.omc/plans/2026-05-02-kosmonotes-v1-implementation.md:237-242`), and the repository does contain a live `DeepgramProvider` and resilient reconnect layer (`Sources/TranscriptionKit/DeepgramProvider.swift:5-71`).

But `RecorderState.stop()` clearly uses a **batch** provider selection at the end of recording (`App/State/RecorderState.swift:342-373`), and its own comment says Deepgram streaming is not exposed on the current capture API (`App/State/RecorderState.swift:343-345`).

So the transcription architecture is:

- **streaming infrastructure exists**
- **production recorder path is batch**
- **the implementation does not yet match the original streaming-centric spec**

This is the most important runtime deviation from the spec.

#### 3. AC-13 is not met literally by the Markdown exporter

The implementation plan says Markdown export should contain YAML frontmatter, summary, and transcript with `[mm:ss]` timestamps (`.omc/plans/2026-05-02-kosmonotes-v1-implementation.md:68`).

The current exporter does write YAML frontmatter and optionally includes summary text, but for transcript it simply copies `transcript.txt` into a `## Transcript` section (`App/Views/Library/SessionExporter.swift:96-121`).

`TranscriptStore` writes `transcript.txt` as plain concatenated text or a cleaned override, **without timestamps** (`Sources/TranscriptionKit/TranscriptStore.swift:45-74`).

So the current status is:

- **frontmatter:** implemented
- **summary inclusion:** implemented
- **timestamped transcript block:** **not implemented as specified**

#### 4. The app shell does not match the architecture diagram literally

The design document shows a popover-style `MenuBarExtra` shell (`docs/plans/2026-05-02-kosmonotes-design.md:92-100`), but the repo uses `NSStatusItem` + `NSMenu` (`App/KosmoNotesApp.swift:185-256`).  

This is a design-doc drift issue, not a product bug.

## What is implemented from the spec

### Clearly implemented

| Area | Status | Evidence |
|---|---|---|
| Meeting recording | Implemented | `RecorderState.start/stop` (`App/State/RecorderState.swift:139-279`, `282-441`) |
| Dictation mode | Implemented | `DictationState` install / press / release flow (`App/State/DictationState.swift:49-79`, `92-143`) |
| Voice Note mode | Implemented | `SessionMode.voiceNote`, settings tab, voice-note summary path |
| Library playback and click-to-seek | Implemented | transcript tap seeks (`App/Views/Library/LibraryView.swift:485-488`), time observer (`552-598`) |
| FTS5 search | Implemented | `AppDatabase.searchTranscripts` (`Sources/StorageKit/Database.swift:203-221`) |
| Recovery of interrupted sessions | Implemented | `RecoveryService` + launch coordinator bootstrap (`Sources/StorageKit/RecoveryService.swift:50-59`, `112-200`; `App/KosmoNotesApp.swift:390-408`) |
| LLM providers | Implemented | Anthropic / OpenAI / OpenRouter / Ollama selection in settings and dispatch in `ChatState` / `RecorderState` |
| S3 sharing | Implemented | share UI + upload stack |
| Semantic search | Implemented | embeddings migration + indexing + retrieval |
| Screen recording | Implemented | `ScreenRecorder` + `screen.mp4` loading in Library (`App/Views/Library/LibraryView.swift:346-367`) |

### Implemented, but still “unverified” in the release sense

`docs/release/v1.0-checklist.md` is still an empty manual-gate document (`docs/release/v1.0-checklist.md:7-89`). That means the repo has **code coverage and unit/integration coverage**, but it does **not** yet have completed hardware smoke evidence for the release matrix.

## Release-readiness assessment

### What looks release-credible

1. The build and test baseline is healthy: **235 tests in 52 suites passed**.
2. Core product flows are wired end-to-end in code.
3. The storage / recovery path is better than typical for a small app.
4. The feature set is broader than the old plan suggests.

### What still blocks a clean “spec-complete and release-ready” claim

1. **Docs are out of sync with each other.**
2. **Streaming-vs-batch transcription drift remains unresolved at the spec level.**
3. **AC-13 timestamped Markdown export is not met literally.**
4. **The manual release checklist is unfilled.**
5. **The 12.3 support story should be simplified or removed from release docs because the build target is 14.0.**

## Bottom-line recommendations

### Highest priority

1. **Rewrite the source-of-truth docs.**  
   Keep the design doc as architecture truth, but update or supersede the old implementation plan. Right now it is the main source of confusion.

2. **Decide the official transcription story.**  
   Either:
   - say v1.0 uses batch transcription and keep Deepgram streaming as future work, or
   - finish wiring the live path into `RecorderState`.

3. **Fix AC-13 or relax AC-13.**  
   The exporter needs timestamped transcript lines if the acceptance criterion stays as written.

4. **Trim the release checklist to the real platform contract.**  
   If the product is 14.0+, stop pretending 12.3 support is an active release target.

### Next priority

5. **Split `RecorderState` into smaller pipelines.**  
   A dedicated recording finalization / transcript cleanup / summary pipeline would lower risk.

6. **Split `AppSettings` into feature-scoped settings objects.**  
   The current class is workable but has become the repository’s main coupling point.

7. **Surface partial-failure state in the UI.**  
   Silent degradation is acceptable for internal development, but weak for a user-facing release.

## Final assessment

This repository is **not a half-implemented spec**. It is the opposite: it is a **mostly working codebase whose implementation has outrun its scope documentation**.

From an architecture standpoint, the repo is in decent shape. From a code-review standpoint, the main concerns are **scope growth, document drift, and app-layer object size**, not bad low-level engineering.

If the question is “what is implemented according to the specification?”, the honest answer is:

- **most of the broader product vision is already present in code**
- **the scope-reduced implementation plan is stale**
- **a few literal acceptance criteria are still mismatched**
- **release proof is still incomplete because the manual matrix is empty**
