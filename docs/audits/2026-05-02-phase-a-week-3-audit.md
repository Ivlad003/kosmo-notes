# Phase A Week 3 audit — RecorderState completeness

**Date:** 2026-05-02
**Auditor:** Claude Code (inline, in-session)
**Branch at audit time:** `feature/dictation-and-polish` (HEAD `b40e0bf`)
**Scope:** verify the five Phase A Week 3 acceptance criteria against the canonical spec (`.omc/plans/2026-05-02-jarvis-note-v1-implementation.md` §5 Phase A Week 3, lines 246–252).

## Executive verdict

**⚠ Substantively complete in code, but CI is red.**

The five Phase A Week 3 deliverables are all implemented and shape-correct. The `RecorderState` actor wires `CaptureSession` + `SessionStore` + `AppDatabase` + a transcription provider; the popover Record button calls `RecorderState.toggle()`; mic-level metering is implemented as a separate `AVAudioEngine` tap with ~33 ms RMS windows broadcast through `@Observable`.

**However, `swift build` and `swift test` both fail at HEAD** because of issues in *other* phases:

1. `Sources/DictationKit/HotkeyMonitor.swift` (Phase C) imports `KeyboardShortcuts`, but the package isn't declared as a target dep in `Package.swift:62-68` (a `// KeyboardShortcuts added when HotkeyMonitor.swift lands in Phase C` comment marks the omission, but the file already lands).
2. `Tests/AIKitTests/OllamaProviderTests.swift` (Phase B) has multi-line-string-literal syntax errors at lines 316 and 618.

Neither is in Phase A scope. Both are blockers for unblocking CI. **Phase A modules build clean in isolation** (`swift build --target AIKit` etc., 0.33 s, only an unused-dep warning).

## Per-criterion findings

| # | Criterion (plan §5 Week 3) | Status | Evidence |
|---|---|---|---|
| 1 | `RecorderState` actor coordinating CaptureKit → TranscriptionKit → SessionStore | ✅ | `App/State/RecorderState.swift:27` — `@Observable @MainActor final class RecorderState`. Status state machine at L31–54. `start(mode:)` at L100–145 wires `CaptureSession`, `SessionStore.createSession`, `MicLevelMeter`. `stop()` at L148–224 finalizes via `RecoveryService`, runs Whisper, writes `TranscriptStore`, calls `sessionStore.indexTranscript` + `sessionStore.finalize`. |
| 2 | Popover Record button → `RecorderState.toggle()` | ✅ | `App/JarvisNoteApp.swift:69-75` declares menu item `recordToggle` with selector `recordToggleAction`. L244–272 dispatches `await recorder.toggle()`. The "popover" is a menu-bar `NSMenu`, not a `MenuBarExtra` popover, but the wiring intent of plan §5 is satisfied. Menu state updates dynamically in `menuNeedsUpdate` (L412–447) reflecting `recorder.status`. |
| 3 | Mic level meter — `AVAudioEngine` tap → RMS over 33 ms windows → broadcast via `@Observable` | ✅ | `App/State/MicLevelMeter.swift:16` — `final class MicLevelMeter`. Buffer size at L27: `max(256, 0.033 * sampleRate)` ≈ 33 ms. RMS computed at L34–39. `RecorderState.swift:132-138` starts the meter and hops the callback to `@MainActor` setting `self.micLevel`, which is `@Observable` (L60). One nit: the meter is a *separate* `AVAudioEngine` from CaptureKit's recording engine — by-design per the file's docstring ("isolates the UI concern"), not a deviation. |
| 4 | Session folder created on start, `session.json` finalized atomically on stop | ✅ | `RecorderState.swift:117` — `sessionStore.createSession(mode:language:)`. `RecorderState.swift:215` — `sessionStore.finalize(id:status:durationSecs:)` on success or `.failed` on error. Atomicity is implemented in `StorageKit.AtomicWriter` (already-shipped, not re-audited here). |
| 5 | `swift build` + `swift test` pass under Xcode toolchain | ❌ | Full-package build fails on `DictationKit` (KeyboardShortcuts module missing). Full-package test fails on `OllamaProviderTests` syntax. **Phase A modules pass in isolation** (see Build/test output below). |

## Bonus — beyond plan §5

The shipped `RecorderState` does **more** than plan §5 specified:

- **AI summary post-pipeline** (plan §5 leaves this for Phase B Week 1, but it's already wired). `tryGenerateSummary` at L231–301 calls Anthropic / OpenAI / Ollama after Whisper, writes `summary.md` atomically, enforces `settings.costCapUSD` cap.
- **Provider switching** through `AppSettings.llmProvider` (anthropic/openai/ollama) — plan §5 didn't cover this.
- **Screen recording wiring** (Phase D — reinstated 2026-05-02 evening). `start(mode:)` reads `settings.recordingMode` and threads `screenRecordingEnabled` + `screenOutputURL` into `CaptureSession.Config` (RecorderState.swift:120-127).

These are not gaps — they're scope creep from later phases that landed early.

## Honest deviations

- **Whisper batch, not Deepgram streaming.** Plan §5 Week 2 wires `DeepgramProvider`; `RecorderState.swift:192` uses `WhisperProvider` for the post-stop transcription. The file's docstring (L19–23) calls this out explicitly and points at the missing CaptureSession PCM tee as the blocker. **`Sources/CaptureKit/CaptureSession.swift` confirms** — its `start()` consumes `AsyncStream<AVAudioPCMBuffer>` from `AudioEngine` and `SCKitAudioCapture` directly into a `SegmentWriter`, with no second consumer (tee) exposed. Landing Deepgram streaming requires a CaptureKit refactor; this is correctly deferred to v1.1 of CaptureKit.
- **Plan §5 says the Library is a "temporary debug list with [↻ Refresh]"** — actual implementation has a full Library window with `AVPlayer`, click-to-seek transcript, FTS search, export. That's Phase B Week 3 scope shipped early.

## Build/test output

### `swift build` (full package) — ❌ FAILED

```
Sources/DictationKit/HotkeyMonitor.swift:1:8: error: no such module 'KeyboardShortcuts'
 1 | import KeyboardShortcuts
   |        `- error: no such module 'KeyboardShortcuts'
[22/22] Compiling DictationKit HotkeyMonitor.swift
```

Root cause: `Package.swift:62-68` declares the `DictationKit` target with empty `dependencies: []` (the line `// KeyboardShortcuts added when HotkeyMonitor.swift lands in Phase C` is a stale gate — the file landed but the dep wire didn't). Fix: add `.product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")` to the DictationKit target deps.

### `swift build --target AIKit` (Phase A scope) — ✅ PASSED

```
warning: 'jarvis-studio': dependency 'keyboardshortcuts' is not used by any target
[0/1] Planning build
Building for debugging...
Build of target: 'AIKit' complete! (0.33s)
```

(Same picture for `--target StorageKit` / `CaptureKit` / `TranscriptionKit` — Phase A modules all build clean.)

### `swift test --filter 'CaptureKitTests|StorageKitTests|TranscriptionKitTests'` — ❌ FAILED to compile

```
Tests/AIKitTests/OllamaProviderTests.swift:316:23: error: multi-line string literal content must begin on a new line
316 |         let json = """{"model":"q","done":true}"""
    |                       `- error: multi-line string literal content must begin on a new line

Tests/AIKitTests/OllamaProviderTests.swift:618:33: error: multi-line string literal content must begin on a new line
618 |                 return (Data("""{"models":[]}""".utf8), resp)
```

Root cause: SwiftPM compiles all test targets before applying `--filter`, so the AIKit test errors block Phase A test execution. Fix: change `"""{...}"""` to either standard-string `"{...}"` or proper multi-line syntax with newlines after the opening `"""`.

## Recommended next steps

Ordered by blast radius, smallest first:

1. **Fix `OllamaProviderTests.swift` syntax** (3 lines, 2 minutes). Unblocks `swift test` for the whole package.
2. **Wire `KeyboardShortcuts` to `DictationKit` target** in `Package.swift` (1 line). Unblocks `swift build`.
3. **Re-run `swift test` once 1 + 2 land** — confirm Phase A test count is intact (CLAUDE.md claims "96 tests across 19 suites").
4. **Phase A Week 3 work itself: nothing further required.** The five plan-§5 deliverables are all in place.
5. **Decide on the Dictation worktree branch.** Branch `feature/dictation-and-polish` has incomplete work merged. Either finish the Dictation feature properly (add the missing dep + smoke-test) or revert it back to the develop merge-base before declaring Phase A "done."

## Files audited

- `App/State/RecorderState.swift` (320 lines)
- `App/State/MicLevelMeter.swift` (56 lines)
- `App/JarvisNoteApp.swift` (480 lines)
- `Sources/CaptureKit/CaptureSession.swift` (203 lines)
- `Package.swift` (only DictationKit target + KeyboardShortcuts dep section)
- `.omc/plans/2026-05-02-jarvis-note-v1-implementation.md` §5 Phase A Week 3
