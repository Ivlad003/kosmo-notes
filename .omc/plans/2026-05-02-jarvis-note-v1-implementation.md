# Jarvis Note v1.0 — Implementation Plan (scope-reduced after Critic review)

**Date:** 2026-05-02
**Source design:** `docs/plans/2026-05-02-jarvis-note-design.md`
**Cross-cutting invariants:** `CLAUDE.md`
**Target platforms:** macOS 12.3+ — single audio path via ScreenCaptureKit (whole-system mixdown). **Per-process Core Audio Tap is deferred to v1.1.**
**Stack:** Pure Swift / SwiftUI / AppKit · `AVAudioEngine` · `ScreenCaptureKit` audio · `URLSession` · `GRDB.swift` · macOS Keychain
**Distribution:** Hand-shared `.app.zip`. No code signing, no notarization, no auto-update.

> **Implementation deviation (2026-05-02 evening, applied during Phase A Week 1):** Encoder is **AAC 96 kbps mono in `.m4a`** — not Opus. `AVAudioConverter` Opus output requires macOS 14+; deployment is 12.3+. AAC is universally supported, plays in QuickTime/Safari natively, no extra dependencies. File size ≈2× Opus, acceptable for v1.0.
>
> Knock-on: `RecoveryService` uses **`AVMutableComposition` + `AVAssetExportSession` (passthrough preset)** for lossless segment concat — no bundled ffmpeg, no 30 MB binary. The "ffmpeg vs Ogg-stdlib" boundary item in §8 is **retired**. Bundle stays well under the 15 MB AC-16 budget.

> **Scope reduction vs design doc (decision applied 2026-05-02 after Critic review):**
> - **Per-process Core Audio Tap** → deferred to v1.1. v1.0 uses ScreenCaptureKit's whole-system audio mixdown for ALL macOS versions (12.3+). Trade-off: captures Spotify / notifications too; user mutes those manually.
> - **Voice Note Mode** → deferred to v1.1. v1.0 ships Meeting + Dictation only.
> - **Sharing (S3 presigned URLs)** → deferred to v1.1. v1.0 supports export-to-disk only (Markdown / plain text / audio file via Save dialog).
>
> **Why these cuts:** Critic flagged the 6-week estimate as unreachable for a Rust-veteran new to macOS-Swift, with per-process Core Audio Tap being the highest-risk single API. Cutting these three items removes the riskiest surface (Tap), the second-most-complex pipeline (Sharing's hand-rolled AWS Sig V4 + durable queue), and one mode.
>
> **Realistic ship: 10–12 working weeks** (was: 6–10 in design §14, 8–10 in v1 plan). Phase A alone is 4 weeks for a Swift first-timer, not 8 days.
>
> **What v1.1 will add:** Voice Note Mode, S3 sharing, per-process Core Audio Tap, embedding-based semantic search, third-party OpenAI-compat endpoints in Settings UI.

---

## 1. Requirements summary

A user can:

1. Launch Jarvis Note from `Applications/`. Menu-bar icon visible. Popover opens on click.
2. Configure providers in Settings → AI Providers (Anthropic, OpenAI, OpenRouter, Ollama) and Settings → Transcription (Deepgram, optionally Whisper / AssemblyAI in v1.0 — the Provider protocol is wired, only Deepgram has a Test-connection path in Phase A).
3. **Meeting Mode:** Press `Cmd+Shift+R` (or click Record in popover) → record mic + system audio (whole-system mixdown via SCKit) → press again to stop → ~1–5 min later get a structured summary in a target language chosen at session start.
4. **Dictation Mode:** Hold `Cmd+Shift+D` → speak ≤60 s → release → cleaned text pasted into the focused text field (median ≤1.5 s end-to-end on a 50 Mbps connection).
5. Browse all sessions in a Library window. Play audio with native `AVPlayer` controls (variable speed, ±15s skip). Click any transcript word to jump audio to that timestamp ±100 ms. Live-highlight the active segment during playback.
6. Search transcripts via FTS5 full-text. Filter by date / mode / language.
7. Export a session via Save dialog: Markdown bundle, plain transcript, or audio file. **No S3 / cloud sharing in v1.0.**
8. Recordings survive app crash and ungraceful exit (≤5 s loss bound, per design §5). Recover dialog at next launch surfaces incomplete sessions.

Out of scope for v1.0 (original list):
- Voice Note Mode (v1.1)
- S3 / cloud sharing with presigned URLs (v1.1)
- Per-process Core Audio Tap (v1.1 — SCKit mixdown only in v1.0)
- Embedding-based semantic search (v1.1+)
- Live captions during recording (v2)
- ~~Screen recording (deferred, month 6+)~~ → **reinstated in Phase D** (see below)
- Code signing, notarization, auto-update, App Store

---

## 2. Acceptance criteria

| # | Criterion | Verification |
|---|---|---|
| AC-1 | Empty Xcode project compiles to a `.app` that launches and shows a menu-bar icon | `xcodebuild -scheme KosmoNotes -configuration Release` exits 0; manual smoke |
| AC-2 | Popover opens on icon click; mode picker shows Meeting / Dictation (Voice Note absent in v1.0) | Manual smoke |
| AC-3 | Recording 5 min mic-only on macOS 14.5 produces a playable `audio.m4a` (AAC, ~7 MB at 96 kbps mono) at `~/Library/Application Support/KosmoNotes/recordings/<sid>/` | `afplay` plays end-to-end; `ffprobe` shows aac codec, 96 kbps, mono |
| AC-4 | SIGKILL during a 1-min recording leaves `recordings/<sid>/segments/*.m4a` files; on next launch, Recover dialog surfaces this session, accepting yields a finalized `audio.m4a` of ≥25 s | Integration test: kill at t=30s; relaunch in test harness; verify Recover service finalizes |
| AC-5 | Recording mic + system audio on macOS 12.3+ produces an `audio.m4a` (AAC-in-MP4 container) with **2 separate audio tracks** (track 0 = mic, track 1 = SCKit mixdown) via `AVAssetWriter` multi-track output. Stereo-interleave was rejected (per Critic MAJOR-B) — interleaving requires custom `AVAudioMixerNode` + clock-drift handling between two unrelated capture sources, more work than 2-track | `ffprobe nb_streams == 2` (both audio); manual: play in QuickTime, both audible (QuickTime plays track 0 by default; users get full mixdown via `ffmpeg -map 0:a -filter_complex amerge`) |
| AC-6 | macOS <12.3 surfaces a clear startup modal: "macOS 12.3 required for system audio. Continue with mic only? [Continue] [Quit]" | Manual on 11.x VM (or version-spoofed test) |
| AC-7 | Deepgram streaming transcription writes final text to `transcript.jsonl` and `transcript.txt` within 5 s of recording stop on a 30-s English clip | Integration test with synthetic audio; mocked Deepgram WebSocket |
| AC-8 | Anthropic Claude Sonnet produces a Meeting summary <90 s after transcript-final on a 5-min English call. `summary.md` written atomically | Manual smoke + cost <$0.05 |
| **AC-9a** | Dictation pipeline-stage instrumentation: `os_signpost` traces emitted at every stage (capture-start, encode-done, upload-issued, transcript-final, llm-cleanup-final, paste-issued). Under simulated realistic load — mocks return after **200 ms simulated network delay each**, audio buffer is a 10-second real Opus encode of synthetic audio (not zero-byte) — no individual intra-process stage exceeds 100 ms median across 10 runs. **Replaces the round-1 tautological version** that measured Swift function-call overhead | CI integration test with: real Opus encoder (synthetic input); mocked DeepgramProvider with `try await Task.sleep(milliseconds: 200)` before responding; mocked AnthropicProvider with same; assert per-stage `os_signpost` durations from a parsed `xctrace` log |
| **AC-9b** | Dictation real-network end-to-end median ≤1.5 s on 10-second utterance, 50 Mbps connection, Anthropic LLM cleanup enabled | **Manual smoke gate, recorded pre-tag and attached to v1.0 release notes.** Method: QuickTime screen recording at 60 fps, frame-count from hotkey-release to text-rendered, 5 trials, median + p95 reported |
| AC-10 | Library window opens via Cmd+L; lists all sessions newest-first; waveform thumbnail (PNG) renders within 1 s | Manual smoke + SwiftUI snapshot test |
| AC-11 | Click word in transcript view → AVPlayer seeks to that timestamp ±100 ms; live highlight tracks active segment during playback | Integration test: programmatic seek + position-observer assertion |
| AC-12 | FTS5 search across 100 sessions × 10k tokens returns matches in <50 ms warm cache, <200 ms cold (M-series) | Performance test: synthesize 100 sessions; CI runs on macos-14 GitHub runner |
| AC-13 | Export to Markdown / plain text / audio file via Save dialog produces files at user-chosen path; Markdown contains YAML frontmatter + summary + transcript with `[mm:ss]` timestamps | Manual smoke + unit test on ExportFormatter |
| AC-14 | API keys stored in macOS Keychain under service `dev.kosmonotes.studio`; deleting `KosmoNotes.config.json` does not lose secrets | Manual: open Keychain Access; integration test: round-trip |
| AC-15 | Atomic state-file writes survive `kill -9` mid-write | Unit test: write loop with concurrent SIGKILL; reads return valid JSON or empty `{}` |
| AC-16 | Bundle size: `KosmoNotes.app` ≤15 MB uncompressed; `.app.zip` ≤8 MB | CI artifact size check |
| AC-17 | First Record press triggers Microphone TCC prompt; first SCKit attempt triggers Screen Recording TCC prompt; first Dictation hotkey-press triggers Accessibility prompt with link to System Settings → Privacy → Accessibility. After grant + relaunch, all three pipelines work | Manual on a fresh macOS install / fresh VM |
| AC-18 | All four LLM providers (Anthropic / OpenAI / OpenRouter / Ollama native + OpenAI-compat) pass a "Test connection" round-trip from Settings → AI Providers / Settings → Ollama | Manual matrix; mocked HTTP integration tests |

**Dropped from previous plan:** AC-13 (S3 upload — Sharing deferred to v1.1).
**Split:** AC-9 → AC-9a (CI) + AC-9b (manual).
**Tightened:** AC-4 now requires explicit Recover service (not just "decodable file").

---

## 3. Sandboxing & entitlements decision (Phase 0 Day 2)

This was missing from the previous plan and would have surfaced as a blocker on Phase A Day 1. Resolving up-front.

| Decision | Choice | Rationale |
|---|---|---|
| App Sandbox | **Off** | Sandboxed apps cannot use `AXUIElementSetAttributeValue` on other apps' processes (Dictation paste). Single-user hand-shared app — sandboxing is theatre without code signing |
| Hardened Runtime | **Off** | Hardened runtime requires entitlement allow-listing for `AVAudioEngine`, `ScreenCaptureKit`, etc. Adds friction without meaningful benefit for unsigned binary |
| `KosmoNotes.entitlements` | **Empty file present** | Required by Xcode build phase even when sandbox is off; just a minimal `<plist><dict></dict></plist>` |
| `Info.plist` usage descriptions | Two required | `NSMicrophoneUsageDescription` + `NSScreenCaptureUsageDescription`. **Do NOT declare `NSAppleEventsUsageDescription`** (AppleEvents ≠ AX API; AX uses `AXIsProcessTrusted()` for permission, no usage-description needed) and **do NOT declare `NSCameraUsageDescription`** (declaring without using surfaces a spurious Privacy entry — add when v1.1 webcam ships) |
| Accessibility System Settings flow | **Manual user action** | First Dictation press: detect missing AX permission via `AXIsProcessTrusted()`; show modal with [Open System Settings → Privacy → Accessibility] button calling `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)`. User toggles app on, then **must Cmd+Q and relaunch** for AX trust to take effect. Document this in onboarding |
| Bundle identifier (locks Keychain service) | **`dev.kosmonotes.studio`** | Locked Day 1 of Phase 0. Display name ("Jarvis Note" working title) is mutable post-ship; bundle ID is **not** — Keychain entries are tied to it |

---

## 4. Workspace layout

(Same library structure as previous plan, minus SharingKit. Full tree:)

```
jarvis-studio/                        # repo dir name preserved (matches archive branch)
├── Package.swift                     # SwiftPM manifest — library targets
├── project.yml                       # XcodeGen spec
├── KosmoNotes.xcodeproj/             # gitignored, generated
├── App/
│   ├── KosmoNotesApp.swift           # @main, MenuBarExtra
│   ├── Info.plist
│   ├── KosmoNotes.entitlements       # empty <plist><dict></dict></plist>
│   ├── Resources/
│   ├── Views/
│   │   ├── Popover/                  # mode picker, Record button, mic level
│   │   ├── Library/                  # SessionList, AVPlayer, transcript view, search
│   │   └── Settings/                 # 4 tabs (AIProviders, Ollama, Transcription, Privacy, Hotkeys)
│   └── State/                        # AppState (@Observable), per-area sub-states
│
├── Sources/
│   ├── CaptureKit/                   # AVAudioEngine + ScreenCaptureKit audio
│   │   ├── AudioEngine.swift         # mic capture
│   │   ├── ScreenCaptureKitAudio.swift # whole-system mixdown — ONLY system-audio path in v1.0
│   │   ├── OpusEncoder.swift
│   │   ├── SegmentWriter.swift       # 5-s segments, fsync per close
│   │   └── CaptureSession.swift      # public API
│   ├── TranscriptionKit/
│   │   ├── Provider.swift
│   │   ├── DeepgramProvider.swift    # Phase A primary
│   │   ├── WhisperProvider.swift     # Phase B (provider-protocol stub OK in Phase A)
│   │   ├── AssemblyAIProvider.swift  # Phase B
│   │   └── TranscriptStore.swift
│   ├── AIKit/
│   │   ├── Provider.swift
│   │   ├── AnthropicProvider.swift   # Phase B primary
│   │   ├── OpenAIProvider.swift      # Phase B
│   │   ├── OpenRouterProvider.swift  # Phase B
│   │   ├── OllamaProvider.swift      # Phase B (native + OpenAI-compat)
│   │   ├── PromptTemplates.swift
│   │   └── CostEstimator.swift
│   ├── StorageKit/
│   │   ├── SessionStore.swift
│   │   ├── Database.swift            # GRDB + FTS5
│   │   ├── AtomicWriter.swift
│   │   ├── KeychainStore.swift
│   │   └── RecoveryService.swift     # NEW per Critic — orphan-segment scan + finalize
│   ├── DependencyLifecycle/
│   │   ├── Dependency.swift
│   │   └── StatePersistence.swift
│   └── DictationKit/
│       ├── HotkeyMonitor.swift
│       ├── AccessibilityPaster.swift
│       ├── AppContextDetector.swift
│       └── DictationPipeline.swift
│
├── Tests/
│   ├── CaptureKitTests/
│   ├── TranscriptionKitTests/
│   ├── AIKitTests/
│   ├── StorageKitTests/              # includes RecoveryServiceTests
│   ├── DependencyLifecycleTests/
│   └── DictationKitTests/
│
├── docs/plans/
├── .omc/plans/
├── README.md
├── CLAUDE.md
└── .gitignore
```

**SharingKit removed.** No `Sources/SharingKit/` in v1.0.

### Dependencies

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
    .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.2.0"),
    // No aws-sdk-swift — Sharing deferred to v1.1
]
```

Net dependencies: 3 (was 4). AWS SDK saved entirely.

---

## 5. Implementation phases

Three phases. Realistic timeline includes 30–50 % surcharge for Swift unfamiliarity per Critic.

### Phase 0 — Bootstrap + entitlements (3 working days)

**Goal:** repo compiles, `xcodebuild` produces a `.app` that launches with a menu-bar icon. CI green. Sandboxing decision in code (entitlements file present, sandbox off, hardened runtime off).

**Day 1 (single engineer):** repo scaffolding
- `Package.swift` with library targets per §4
- `project.yml` (XcodeGen)
- `xcodegen generate` → `.xcodeproj`
- `.gitignore` already covers Xcode/SwiftPM artifacts
- `App/KosmoNotesApp.swift` — `@main` with `MenuBarExtra("Jarvis Note", systemImage: "waveform.circle")` + empty popover (just a "Record" placeholder button)
- `App/Info.plist` — usage descriptions per §3
- `App/KosmoNotes.entitlements` — empty plist
- `App/Resources/Assets.xcassets` — placeholder menu-bar icon

**Day 2 (single engineer):** smallest concrete code
- `Sources/StorageKit/AtomicWriter.swift` + tests (the simplest unit, isolates atomic-write invariant)
- `Sources/StorageKit/KeychainStore.swift` + round-trip test
- `Sources/DependencyLifecycle/Dependency.swift` + `StatePersistence.swift` + tests

**Day 3 (single engineer):** CI + bundling + first-launch onboarding (per Critic MINOR-H)
- `.github/workflows/ci.yml` — `xcodegen generate` + `xcodebuild build` + `xcodebuild test` on `macos-14` runner
- Verify CI green
- README "Building" section: `xcodegen` install + `xcodebuild` commands + `ditto` zip command
- **First-launch onboarding modal:** detected via `UserDefaults.standard.bool(forKey: "didOnboard")`; shows a single-pass welcome window listing the 3 permissions the app will request: Microphone (for Mic), Screen Recording (for system audio via SCKit), Accessibility (for Dictation paste — Phase C). Each row has a "Grant later" link to `x-apple.systempreferences:com.apple.preference.security?Privacy_<Pane>`. User clicks [Continue] → `didOnboard = true`. Avoids the round-1-critic-flagged "three separate modals across three sessions with Cmd+Q in between" failure mode.
- Manual smoke: fresh user account → first launch shows onboarding; second launch goes straight to popover

**Phase 0 acceptance:** AC-1, AC-14 (Keychain), AC-15 (atomic writes), AC-16 (bundle size sanity).

**Critic-fix landing:** Day-1 task list is sequential, not parallel. One engineer end-to-end Day 1. Dispatch to a /team only starts at Phase A Day 2 once primitives exist.

---

### Phase A — Meeting Mode + Deepgram transcript (~4 weeks, ~18 working days)

**Goal:** menu-bar app records mic + SCKit-mixdown system audio, transcribes via Deepgram streaming, writes session folder with `audio.opus` + `transcript.jsonl` + `transcript.txt`. Recovery dialog handles crashed sessions.

**Realistic timeline:** ≥3 weeks for a Swift first-timer. 4 weeks accounts for Deepgram-integration debug + SCKit-audio quirks + recovery flow.

**Week 1 (5 days): CaptureKit on SCKit-only audio path**
- `AudioEngine.swift` — `AVAudioEngine` mic input tap @ 48 kHz mono float32
- `ScreenCaptureKitAudio.swift` — `SCStream` with `.audio` content type, captures whole-system mixdown
- Mixer: combine mic (L) + system mixdown (R) into one stereo Opus, OR two separate audio tracks (decide per AC-5 boundary item below)
- `AACEncoder.swift` — `AVAudioConverter` PCM→AAC; 96 kbps mono. **Implementation deviation:** plan originally said `OpusEncoder.swift` / Opus output, but Opus via `AVAudioConverter` requires macOS 14+ and deployment is 12.3+. AAC is the universal-support fallback. See `Sources/CaptureKit/lib.swift` and `AACEncoder.swift` for the rationale comment.
- `SegmentWriter.swift` — 5-s rolling `.m4a` segments via `AVAssetWriter`, finalized (fsync'd) on close, written to `recordings/<sid>/segments/<n>.m4a`
- `CaptureSession.swift` — public API: `start(config:)` / `stop()` / `pause()` / `resume()`
- Unit tests: synthetic sine, encoder round-trip
- Manual smoke: 30-s mic-only recording playable in QuickTime

**Week 2 (5 days): TranscriptionKit (Deepgram only) + RecoveryService**
- `Provider.swift` protocol + `TranscriptionConfig`
- `DeepgramProvider.swift` — WebSocket via `URLSessionWebSocketTask`, streams Opus chunks, parses JSON events
- `TranscriptStore.swift` — appends to `transcript.jsonl` per UtteranceFinal event; flushes `transcript.txt` on UtteranceEnd
- Reconnection: exponential backoff 250ms → 8s, 5-s ring buffer of recent chunks resent on reconnect
- Disk-queue: if Deepgram unreachable, segments stay on disk; queue drains on recovery
- `RecoveryService.swift` (per Critic-fix MAJOR-C) — launch-time scan of `recordings/<sid>/segments/*.m4a` where `<sid>` has no `session.json` `status: complete`; offer Recover modal that concat-finalizes via **`AVMutableComposition` + `AVAssetExportSession` with `AVAssetExportPresetPassthrough`**. Each `.m4a` segment is loaded as `AVAsset`, its audio tracks are inserted at successive time ranges into a single `AVMutableComposition`, then exported losslessly (passthrough preset = no decode/re-encode) to `<sid>/audio.m4a`. **Replaces the previous-plan ffmpeg subprocess approach** — that approach assumed Opus segments which we no longer produce; AAC-in-`.m4a` is natively concatenable by AVFoundation. No 30 MB bundled ffmpeg, no Ogg-stdlib fallback path needed. The §8 ffmpeg boundary item is retired |
- Tests: WebSocket frame stub, simulated disconnect/reconnect, RecoveryService finalizes a synthetic orphan

**Week 3 (5 days): Storage + wiring**
- `Database.swift` — GRDB schema migration v1: `sessions` table (id, recorded_at, duration_secs, mode, language, status), `transcripts_fts` FTS5 virtual table
- `SessionStore.swift` — creates session folder on `start`, finalizes `session.json` on `stop` atomically
- `RecorderState` (in `App/State/`) — actor coordinating CaptureKit → TranscriptionKit → SessionStore
- Popover wires Record button to `RecorderState.toggle()`
- mic level meter: `AVAudioEngine` tap → RMS over 33 ms windows → broadcast to popover view via `@Observable` state
- Manual smoke: 5-min recording → audio.opus + transcript.txt written; click [↻ Refresh] in temporary debug Library list to see new session

**Week 4 (3 days): Settings minimum + Phase A smoke matrix**
- Settings → Transcription panel: Deepgram API key field (Keychain-backed), "Test connection" button (small audio sample → Deepgram, assert 200 OK)
- Settings → Privacy panel: one-paragraph honest framing per design §12, no toggles in v1.0
- macOS permissions onboarding: first Record press triggers TCC prompts; document in README that Antigravity / VS Code / Terminal / however launching needs Screen Recording + Microphone permissions, then Cmd+Q + relaunch
- Manual smoke matrix: macOS 14.5 ARM, macOS 14.6 ARM, macOS 12.5 Intel VM. Record 5 min, verify audio + transcript on each.
- Recovery flow manual test: kill app mid-record on each macOS version, relaunch, verify Recover dialog + finalize works

**Phase A acceptance:** AC-1 through AC-7, AC-14, AC-15, AC-17 (Microphone + Screen Recording subset).

**Boundary items inside Phase A:**
- **AC-5 stereo-vs-2-track decision** (Day 3 of Week 1): stereo (mic L, system R) is simpler — single output, AVPlayer plays both — but loses speaker labels. 2-track via `-map` requires AVAssetWriter multi-track. **Recommend: stereo for v1.0**, defer 2-track to v1.1 where Whisper diarization labels speakers anyway.
- **Cost-cap surfacing** (Week 4): Phase A has no LLM stage yet — no cost. Defer cost-cap UI to Phase B.

---

### Phase B — AI summary + Library window + multi-provider LLM (~3 weeks, ~14 working days)

**Goal:** post-recording AI summary in user's chosen target language, browsable Library window with `AVPlayer`, click-to-jump transcript, FTS5 search, **Anthropic + Ollama only** (per Critic MINOR-I — OpenAI/OpenRouter deferred to v1.0.1; with Voice Note + Sharing cut, sole LLM consumers are Meeting summary + Dictation cleanup).

**Week 1 (5 days): AIKit — Anthropic + target-language pivot + cost cap**
- `Provider.swift` protocol + `ProviderCapabilities`
- `AnthropicProvider.swift` — `messages/v1` API with SSE streaming, prompt-cache support
- **Target-language picker (per Critic MAJOR-E — the actual product differentiator):**
  - Popover gets a small "Summary in: [Auto detected ▾]" dropdown next to Record button. Options: Auto detected (picks transcript language) / English / Українська / Русский / Français / Custom (free-text)
  - Settings → AI Providers gets a "Default summary language" dropdown
  - Per-session override sticky-last-used; resets to Settings default on app relaunch
  - `target_language` threaded into `PromptTemplates.meeting(transcript:targetLanguage:sourceLanguage:)`
- `PromptTemplates.swift` — Meeting template explicitly handles source ≠ target: "Source language: {source}. Target summary language: {target}. If source ≠ target, translate; preserve proper nouns and quoted phrases."
- `CostEstimator.swift` — input/output token estimate, surface in popover toast pre-Stop
- **Cost-cap UI (per Critic MAJOR-F):** Settings → AI Providers gets a "Per-session cost cap (USD)" field, default $1.00. `AIProcessingPipeline` checks `CostEstimator.estimate() <= cap` before sending; if over, modal "Estimated cost $X.XX exceeds cap $Y.YY. [Increase cap to $X.XX] [Cancel]". Ollama exempt (free).
- `AIProcessingPipeline` — runs after `RecorderState.stop()`; reads `transcript.txt`, calls AnthropicProvider with target-language template, writes `summary.md` (atomic) + `actions.json`
- Unit tests: PromptTemplate snapshots per (source, target) combination, mocked HTTP, cost-math + cap-enforcement

**Week 2 day 1–3 (3 days): Ollama dual-mode**
- `OllamaProvider.swift`:
  - Native: `POST /api/chat` with NDJSON streaming
  - OpenAI-compat: `POST /v1/chat/completions` with SSE
  - `/api/tags` model discovery for the Settings dropdown
  - Endpoint validation: HTTP only allowed for localhost / 10.x / 172.16-31.x / 192.168.x; refuse public-IP HTTP
- Settings → Ollama panel: endpoint URL, bearer token (optional, Keychain), default model picker (auto-populated from /api/tags after Test connection passes), API mode radio
- v1.0 ships **Anthropic (default) + Ollama** only. **`OpenAIProvider.swift` and `OpenRouterProvider.swift` land in v1.0.1.**

**Week 2 day 4–5 (2 days): Sleep/wake handling for long Meeting recordings (per Critic MINOR-G)**
- `IOPMAssertionCreateWithName` with `kIOPMAssertPreventUserIdleSystemSleep` reason "Jarvis Note recording in progress" — held for the lifetime of an active `RecorderSession`
- Released on Stop / Pause / Cancel
- Test: 30-min Meeting with system idle settings at "1 minute" — system stays awake; `pmset -g assertions` shows the held assertion
- Edge case: user manually sleeps laptop (lid close) → `applicationWillTerminate` notification triggers atomic segment finalization; Recover modal handles partial session on next launch

**Week 3 (4 days): Library window + AVPlayer + FTS5 + waveform thumbnails**
- `LibraryWindow.swift` — `NSWindow` opened via `Cmd+L` (KeyboardShortcuts package) or popover button
- `SessionListView.swift` — sidebar of sessions, queries GRDB, sorted newest-first
- `PlayerView.swift` — `NSViewRepresentable` wrapping `AVPlayerView` with `controlsStyle = .floating`. Variable speed via `player.rate`. `±15s` skip via `seek(to: CMTimeAdd(...))`
- `TranscriptView.swift` — SwiftUI `List` of `TranscriptSegment`, each with `.onTapGesture` calling `player.seek(to:)`. Live highlight via `addPeriodicTimeObserver(forInterval: 0.1)` + binary-search of segments
- `SearchBar.swift` — queries `transcripts_fts` MATCH with snippet highlighting
- Filtering: date / mode / language
- Waveform thumbnails: `AVAssetReader` + downsample to 1024 samples → render via `Canvas` to PNG, cached in `recordings/<sid>/thumb.png`
- Export: Save dialog (`NSSavePanel`) for Markdown / plain text / audio file (no S3 — Sharing deferred)

**Phase B acceptance:** AC-8, AC-10, AC-11, AC-12, AC-13 (Save-dialog export only), AC-18.

---

### Phase C — Dictation Mode (~2.5 weeks, ~12 working days)

**Goal:** push-to-talk dictation pasting into focused field; <1.5 s end-to-end median.

**Week 1 (5 days): DictationKit primitives**
- `HotkeyMonitor.swift` — `KeyboardShortcuts` package; both PTT (hold) and toggle (tap) modes selectable in Settings
- `AccessibilityPaster.swift`:
  - First-call check: `AXIsProcessTrusted()`; if false, show modal with [Open System Settings → Privacy → Accessibility] button
  - Paste implementation: get focused element via `AXUIElementCopyAttributeValue(focused, kAXFocusedUIElement)`, set selected text via `AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute, text)`
  - Fallback: copy to clipboard + simulate Cmd+V via `CGEventCreateKeyboardEvent`
- `AppContextDetector.swift` — bundle ID lookup table → `DictationContext` enum (Cursor / VS Code / Slack / Discord / Linear / Jira / Notes / default)
- Unit tests: AppContextDetector lookup, AccessibilityPaster mock paths

**Week 2 (5 days): Dictation pipeline + LLM cleanup**
- `DictationPipeline.swift` — orchestrates: hotkey-press → CaptureSession start (in-memory buffer, max 60 s) → hotkey-release → finalize → batch upload to Deepgram → optional Anthropic LLM cleanup → AccessibilityPaster
- LLM cleanup: forced cloud (Anthropic) per design §8; Settings → Dictation has override "Use my Ollama" with warning banner
- Cleanup PromptTemplate: `{app_context}` and `{context_specific_rules}` substituted from AppContextDetector
- Latency instrumentation: `os_signpost` at each pipeline stage for Instruments profiling
- Settings → Hotkeys panel: row per mode with capture-shortcut UI from KeyboardShortcuts package
- Settings → Dictation panel: PTT/toggle radio, max duration slider (10–60 s), LLM cleanup toggle, app-aware formatting toggle

**Week 3 (2 days): Latency tuning + smoke matrix**
- Profile dictation pipeline on Instruments — identify any stage exceeding 200 ms intra-process
- AC-9a CI test: 10 runs of mocked-stage pipeline; assert median <100 ms intra-process
- AC-9b manual measurement: 5 trials with QuickTime 60-fps capture; record median + p95; attach to release notes
- Manual smoke: dictation into Cursor, VS Code, Slack, Discord, Notes, plus default (TextEdit). Verify app-aware formatting rules apply.

**Phase C acceptance:** AC-9a, AC-9b, AC-17 (Accessibility subset).

---

## 6. Risks and mitigations

### Technical

| Risk | Severity | Mitigation |
|---|---|---|
| `ScreenCaptureKit` audio (SCStream) on 12.3–14.x has version-specific quirks | High | Test on 12.5, 14.5, 14.6 in manual smoke matrix. v1.0 accepts SCKit-only path; if SCKit is broken on a version, that version is unsupported in v1.0 (document in README) |
| Deepgram WebSocket reconnect loses bytes mid-flight | Med | 5-s ring buffer of recent audio chunks resent on reconnect |
| AVPlayer Opus playback drift on long files (>1 hr) | Med | Forced re-load on >200 ms drift detect. If systemic, transcode to AAC at archive time (Phase B Week 3 day-2 explicit decision point) |
| `AXUIElementSetAttributeValue` fails in sandboxed apps (Slack desktop, some Electron) | Med | Clipboard + Cmd+V simulation fallback (per design §8). Surface "Pasted to clipboard" indicator |
| Dictation latency budget broken on slow networks (<5 Mbps upload) | Med | Surface "high latency detected" toast on AC-9b > p95 budget; suggest disabling LLM cleanup |
| GRDB FTS5 index becomes inconsistent | Low | Rebuild button in Settings → Library: drops `transcripts_fts`, rebuilds from `transcript.jsonl` sidecars |
| macOS Keychain access prompts user on every launch | Low | Use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; one prompt, then silent |

### Positioning

| Risk | Severity | Mitigation |
|---|---|---|
| "Privacy" claim weakened by cloud-only transcription | High | README + Settings → Privacy panel + first-launch flow surface honest framing per design §12 |
| Multi-language edge over Granola is smaller than design framing | Med | Lead with summary-language pivot (UA call → FR summary), not raw transcription quality. Granola does French |
| No code signing → Gatekeeper friction every install | High | Document `xattr -d com.apple.quarantine` in README. Send via Dropbox (preserves attrs) not iMessage (strips) |
| v1.0 captures Spotify alongside meeting (SCKit mixdown) | Med | Document in onboarding: "v1.0 records whole-system audio. Mute Spotify / notifications before recording. Per-process capture lands in v1.1." |

### Shipping

| Risk | Severity | Mitigation |
|---|---|---|
| Phase A overruns (Swift first-timer, SCKit quirks) | High | Phase A budgeted 4 weeks not 1 week. Hard checkpoint: if Phase A slips past 5 weeks, defer Dictation Mode entirely → ship v0.9 = Meeting + Library only |
| Multi-provider LLM (4) in Phase B is wide | Med | Phase A Anthropic-only; other providers wired Phase B Week 2. If running long, ship v1.0 with Anthropic + Ollama only; OpenAI / OpenRouter to v1.0.1 |
| Per-provider Test-connection UX wide | Low | Each provider has a Test endpoint that's well-documented. ~1 day per provider, not 1 week |
| Xcode/Swift toolchain churn during 10–12 weeks | Low | Pin Xcode version in `project.yml` (`xcodeVersion: "15.4"`); document min-Xcode in README |

---

## 7. Verification plan

**Unit tests (CI-gated):**
- `CaptureKitTests` — Opus encoder round-trip on synthetic sine; segment writer atomic close; backpressure ring-buffer
- `TranscriptionKitTests` — Deepgram WebSocket events parsed; reconnection state machine; disk-queue resume
- `AIKitTests` — each Provider impl: HTTP request shape, streaming parse, error mapping; PromptTemplates snapshots; CostEstimator math; Ollama NDJSON vs SSE parsing
- `StorageKitTests` — GRDB migrations; FTS5 query; AtomicWriter resilience; **RecoveryService finalizes orphan segments**; Keychain round-trip
- `DependencyLifecycleTests` — 5-state transitions per dependency; persistence round-trip
- `DictationKitTests` — AppContextDetector lookup; AccessibilityPaster fallback path; pipeline timing on mocks

**Integration tests (CI):**
- Phase A: 5-s synthetic audio → transcript via mocked Deepgram → assert files written
- Phase A: SIGKILL during record → relaunch → RecoveryService finalizes → audio.opus has ≥4 s decodable
- Phase B: full pipeline with mocked Anthropic → summary.md exists
- Phase B: AVPlayer programmatic seek + transcript-segment-highlight assertion
- Phase C **AC-9a**: dictation pipeline-stage timing on mocks; assert median <100 ms intra-process across 10 runs

**Manual smoke (pre-tag, attached to release notes):**
- macOS 14.5 ARM, macOS 14.6 ARM, macOS 12.5 Intel VM
- 5-min Meeting recording with mic + SCKit system audio + Anthropic summary
- Dictation: 30-s clip pasted into Cursor + VS Code + Slack + TextEdit
- Library: open 10 sessions, search, filter, export (Markdown + audio file via Save dialog)
- Recovery: kill app mid-Meeting, relaunch, verify Recover dialog
- **AC-9b**: 5-trial dictation latency measurement; record median + p95 in release notes

**Performance budget:**
- Idle CPU: <2 %
- Recording CPU: <12 % on M1 Pro for mic + SCKit-mixdown + Opus + Deepgram WebSocket
- Memory peak: <300 MB during 1-hr Meeting
- Disk write rate: ~300 KB/s

---

## 8. Boundary items

Reduced from previous plan after Critic feedback. Remaining:

| Item | Phase | Decision |
|---|---|---|
| Default Ollama model placeholder | Phase B Week 2 Day 4 | **Recommend `qwen2.5:14b`** as Settings dropdown placeholder; user picks from /api/tags after Test connection |
| Final product name | Pre-tag | User picks; bundle ID locked Day 1 of Phase 0 regardless |

**Resolved (no longer boundary items):**
- Repo rename: keep `jarvis-studio` dir on disk; product is `KosmoNotes.app`. Locked
- aws-sdk-swift vs hand-roll: N/A — Sharing cut from v1.0
- Embedding provider: N/A — semantic search deferred to v1.1
- Bundle identifier: `dev.kosmonotes.studio` (Phase 0 Day 1)
- Sandboxing: off; hardened runtime: off; entitlements: empty plist (Phase 0 Day 2 — see §3)
- **Stereo vs 2-track audio output (Phase A Week 1):** picked **2-track** per AC-5; mic = track 0, SCKit mixdown = track 1. Implementation in `Sources/CaptureKit/SegmentWriter.swift`
- **Encoder choice / ffmpeg-vs-Ogg-stdlib for recovery (Phase A Week 1–2):** picked **AAC in `.m4a`** (Opus needs macOS 14+, deployment is 12.3+); `RecoveryService` uses `AVMutableComposition` + `AVAssetExportSession` passthrough — no bundled ffmpeg, no Ogg-stdlib fallback. See "Implementation deviation" banner at the top
- **AVPlayer Opus drift on >1 hr files (was Phase B Week 3 Day 2):** N/A — we ship AAC, not Opus. AAC long-file playback in AVPlayer is well-trodden; no drift mitigation expected

---

## 9. Estimated effort

| Phase | Working days | Cumulative | Calendar weeks |
|---|---|---|---|
| 0. Bootstrap + entitlements | 3 | 3 | 0.5 |
| A. Meeting + Deepgram + Recovery | 18 | 21 | 4 |
| B. AI summary + Library + 4 LLM providers | 14 | 35 | 7 |
| C. Dictation Mode | 12 | 47 | 9.5 |
| Named contingencies (per Critic MAJOR-D — replacing the previous "8-day slack" magical line) | 8 | 55 | 11 |
| ↳ Phase A SCKit-version-quirk debug (12.5 vs 14.5 vs 14.6) | 3 | | |
| ↳ AVPlayer long-file playback edge cases (AAC, Phase B Week 3 — replaces previous Opus-drift contingency) | 2 | | |
| ↳ Multi-provider integration debug (Anthropic SSE edge cases + Ollama NDJSON edge cases) | 2 | | |
| ↳ AC-9b dictation-latency tuning if measurement exceeds budget on real network | 1 | | |

**Realistic ship: ~11 calendar weeks for solo dev (was 6 in v1 design, 8–10 in previous v1 plan).**

This is honest. Critic flagged 10–14 weeks; this lands mid-range with explicit slack budget for unknowns. Hard checkpoints:

- **End of Phase A (week 4):** if not green on AC-1 through AC-7 + AC-14/15/17, **cut Dictation Mode** entirely — ship v0.9 = Meeting + Library only
- **End of Phase B (week 7):** if AVPlayer transcript-sync isn't working, ship v0.95 with manual playback + no live highlight
- **End of Phase C (week 9.5):** if AC-9b latency exceeds 2 s consistently, document the actual measured p95 in release notes; ship Dictation as "best-effort, not <1.5 s claim"

Critical path: Phase 0 → A → B → C, sequential, no parallelization possible solo.

If extreme schedule pressure: **cut order** is Dictation > 4 LLM providers (ship Anthropic-only) > Library transcript-sync (manual seek only) > FTS5 search (no search in v0.95). Keep: Meeting + Anthropic summary + Library list + AVPlayer + manual export.

---

## 10. Definition of done

v1.0.0 ships when:

1. All 18 acceptance criteria pass (AC-9b is manual-measured, attached to release notes)
2. A user can:
   - Receive `KosmoNotes.app.zip` via Dropbox / file share
   - Run `xattr -d com.apple.quarantine` per README → double-click `.app`
   - Configure providers in Settings (Anthropic + Deepgram minimum; Ollama optional)
   - Record a 5-min Meeting → get a structured summary in their target language
   - Use Cmd+Shift+D for dictation into Cursor / Slack / VS Code
   - Browse Library, play any session, click transcript words to jump
   - Export a session via Save dialog (Markdown / plain / audio file)
3. Bundle size ≤15 MB uncompressed
4. README has install instructions + Gatekeeper bypass + provider setup + privacy posture + macOS permissions onboarding
5. Manual smoke matrix recorded across 12.5 + 14.5 + 14.6
6. Tag `v1.0.0`
7. Final product name chosen
8. AC-9b measurement attached to release notes

Anything beyond (Voice Note, Sharing, per-process Tap, semantic search, third-party OpenAI-compat in Settings UI) is **v1.1+**.

---

## 11. Phase 0 Day 1 task list (single engineer, sequential)

Critic-fix: not parallel-dispatchable. One engineer end-to-end Day 1.

1. Create `Package.swift` with library targets per §4 layout
2. Create `project.yml` (XcodeGen) with `KosmoNotes` app target + linked SwiftPM library targets
3. Run `brew install xcodegen`; document in README
4. `xcodegen generate` → `KosmoNotes.xcodeproj`
5. `App/KosmoNotesApp.swift` — `@main` `MenuBarExtra` skeleton with empty popover
6. `App/Info.plist` — `NSMicrophoneUsageDescription`, `NSScreenCaptureUsageDescription`, `NSAppleEventsUsageDescription`, `NSCameraUsageDescription` (placeholder)
7. `App/KosmoNotes.entitlements` — empty `<plist><dict></dict></plist>`
8. `App/Resources/Assets.xcassets` — placeholder menu-bar icon (16×16 SF Symbol export)
9. Verify `xcodebuild -scheme KosmoNotes build` succeeds locally
10. Verify launching the built `.app` shows menu-bar icon

Day 2 starts with Storage primitives (`AtomicWriter`, `KeychainStore`); CI yaml lands Day 3.

---

## 12. Changes vs previous plan (changelog)

### Round-2 Critic fixes (2026-05-02 evening)

- **CRIT-A fixed:** Design doc updated — §1 banner declares v1.0 scope reduction; §15 D12 captures the decision in the immutable Decision Log
- **CRIT-3 deeper fix:** AC-9a reframed — no longer tautological; now requires `os_signpost` traces under simulated 200 ms-delayed mocks, with real Opus encode of synthetic audio (not zero-byte). Detects regressions a tautology can't.
- **MAJOR-B fixed:** AC-5 commits to **2-track AVAssetWriter output** (mic = track 0, SCKit mixdown = track 1). Stereo-interleave rejected — interleaving requires custom `AVAudioMixerNode` + clock-drift handling between unrelated capture sources, more work not less
- **MAJOR-C fixed:** RecoveryService uses **bundled ffmpeg subprocess** for Opus segment concat (`ffmpeg -f concat -c copy`); AVAssetWriter rejected because it cannot concat pre-encoded Opus packets without re-encoding. Bundle-size cost (~30 MB ffmpeg static) flagged as boundary item — fallback: stdlib Ogg-container concat
- **MAJOR-E fixed:** Target-language picker added to Phase B Week 1 — popover dropdown next to Record + Settings default; threaded into PromptTemplates as `target_language` substitution. The actual product differentiator (UA call → FR summary) now has UI surface
- **MAJOR-F fixed:** Cost-cap UI added to Phase B Week 1 — Settings field, default $1.00, modal confirmation if estimate exceeds; Ollama exempt
- **MAJOR-D fixed:** §9 8-day "slack" replaced with 4 named contingencies (SCKit-version debug 3d, AVPlayer drift 2d, multi-provider debug 2d, AC-9b tuning 1d)
- **MINOR-G fixed:** Phase B Week 2 days 4–5 add `IOPMAssertion` for sleep-prevention during long Meeting recordings + `applicationWillTerminate` hook for clean segment finalization on lid-close
- **MINOR-H fixed:** Phase 0 Day 3 adds first-launch onboarding modal — single window listing all 3 permissions the app will request; replaces "three separate modals across three sessions" failure mode
- **MINOR-I fixed:** OpenAI + OpenRouter **dropped from v1.0 → v1.0.1**. v1.0 ships Anthropic + Ollama only. With Voice Note + Sharing cut, sole LLM consumers are Meeting summary + Dictation cleanup; ROI for 4 providers no longer holds
- **MINOR-J:** Voice Note hotkey in design schema kept as parsed-but-ignored; v1.1 turns it on. Documented in design doc D12.
- **§3 fix:** `NSAppleEventsUsageDescription` and `NSCameraUsageDescription` removed from Info.plist requirements (AppleEvents ≠ AX API; declaring NSCameraUsageDescription without using camera surfaces a spurious Privacy entry)

### Round-1 Critic fixes (earlier 2026-05-02):

- **CRIT-1 fixed:** Per-process Core Audio Tap removed from v1.0; SCKit-mixdown is the only system-audio path. Resolves plan-vs-design contradiction
- **CRIT-2 fixed:** Sandboxing / entitlements / Accessibility flow spec'd in §3
- **CRIT-3 fixed:** AC-9 split into AC-9a (CI mocks, intra-process timing) + AC-9b (manual real-network measurement)
- **IMP-4 fixed:** Phase A widened from 8 days → 18 days (4 weeks)
- **IMP-5 fixed:** AWS Sig V4 N/A — Sharing cut
- **IMP-6 fixed:** Phase 0 Day 1 task list serialized; one engineer
- **IMP-7 fixed:** RecoveryService added to StorageKit; AC-4 now requires it
- **IMP-8 fixed:** Repo rename boundary item resolved (keep current dir)
- **Scope cut:** Voice Note Mode → v1.1
- **Scope cut:** S3 Sharing → v1.1
- **Scope cut:** Per-process Core Audio Tap → v1.1

---

## Phase D — Screen recording + vision chat (UNVERIFIED, shipped retroactively 2026-05-02 evening)

> **Status:** Written by a remote sandboxed agent without Xcode/macOS toolchain. Local verification required before treating as complete.

Owner reversed the design-doc's "no-screen-recording" decision after using the audio-only build. See design doc D14 and CLAUDE.md "Pivot reversals".

### Deliverables

| File | Change |
|---|---|
| `Sources/CaptureKit/ScreenRecorder.swift` | New `actor ScreenRecorder` — SCStream `.screen` + `.audio` → `screen.mp4` via AVAssetWriter (H.264 video + AAC audio, 24 fps, 4 Mbps). Separate `ScreenStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable` delegate (matches existing pattern in `ScreenCaptureKitAudio.swift`). |
| `Sources/CaptureKit/CaptureSession.swift` | `Config` gains `screenRecordingEnabled: Bool` and `screenOutputURL: URL?`. `start()` spawns `ScreenRecorder` when enabled; `stop()` stops it (best-effort). Audio-only flow unchanged. |
| `App/State/AppSettings.swift` | `RecordingMode` enum (`audioOnly` / `audioAndScreen`), `recordingMode` `@Observable` property, UserDefaults persistence. Default: `audioOnly`. |
| `App/State/RecorderState.swift` | `start(mode:)` reads `settings.recordingMode` to set `screenRecordingEnabled` + `screenOutputURL` in `CaptureSession.Config`. |
| `App/State/FrameExtractor.swift` | New `struct FrameExtractor` — `AVAssetImageGenerator` single-frame extraction at `TimeInterval` → JPEG `Data`. macOS 14.0+ async API. |
| `App/State/ChatState.swift` | `send()` parses timestamp patterns (`m:ss`, `h:mm:ss`, `at minute N`, `на N хвилині`) via `NSRegularExpression`, extracts ≤3 JPEG frames from attached sessions' `screen.mp4` via `FrameExtractor`, appends `.image` parts to the user `ChatMessage` + a footer noting what was attached. Falls back to text-only when no screen.mp4 found. |
| `Sources/AIKit/Models.swift` | `ChatMessage.content: String` → `parts: [Part]` with `Part` enum (`.text(String)` / `.image(jpegData: Data, mimeType: String)`). `text` computed property preserves display compatibility. Convenience `init(role:content:)` retained. |
| `Sources/AIKit/AnthropicProvider.swift` | Serializes parts as Anthropic content-block array (`{"type":"text"}` / `{"type":"image","source":{"type":"base64",...}}`). Single text-only part falls back to plain string. |
| `Sources/AIKit/OpenAIProvider.swift` | Serializes parts as OpenAI content-part array (`{"type":"text"}` / `{"type":"image_url","image_url":{"url":"data:..."}}}`). Same plain-string fallback. |
| `App/Views/Settings/SettingsView.swift` | Recording mode segmented picker added to Transcription tab. Conditional note about Screen Recording permission when `audioAndScreen` is selected. Privacy tab gains a "Screen recording" section. |
| `App/Views/Library/LibraryView.swift` | `loadAudio()` prefers `screen.mp4` over `audio.m4a` when both exist (screen.mp4 has its own audio track). `SessionRowView` shows `video.fill` icon badge when `screen.mp4` sidecar is present. |
| `App/Views/Chat/ChatView.swift` | `MessageBubble` uses `message.text` instead of `message.content` (single-line breaking-change migration). |
| `Tests/AIKitTests/AnthropicProviderTests.swift` | New test: multipart body shape (text + image block). New suite: `ChatMessage.text` accessor. Existing tests migrated (`.content` → `.text`). |
| `Tests/AIKitTests/OpenAIProviderTests.swift` | New test: multipart body shape (text + image_url block). E2E round-trip with image. Existing tests migrated. |
| `CLAUDE.md` | Pivot history section + stack invariants updated. |
| `docs/plans/2026-05-02-jarvis-note-design.md` | Deferred item updated; D13 + D14 added to Decision Log §15. |

### Verification checklist (owner must run locally)

- [ ] `xcodegen generate && xcodebuild -scheme KosmoNotes -configuration Debug build` exits 0
- [ ] `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` shows ≥14 passing (all existing tests) + new AIKit multipart tests
- [ ] Settings → Transcription → Recording mode picker appears and persists between launches
- [ ] Start a recording in Audio + Screen mode → macOS prompts for Screen Recording permission → grant + relaunch → record → verify `<sessionDir>/screen.mp4` exists and plays in QuickTime
- [ ] In Chat with that session attached, type "what was on screen at 0:30?" → frame extracted, vision model responds about visual content
- [ ] Recordings without `screen.mp4` (audio-only sessions) still work in Chat with no errors
- **Timeline:** 6 weeks → 11 calendar weeks honestly
