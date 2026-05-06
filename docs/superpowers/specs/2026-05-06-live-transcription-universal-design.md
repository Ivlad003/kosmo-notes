# Universal live transcription design

## Problem

KosmoNotes records audio in several modes, but transcription is still batch-oriented in the recorder path. That blocks the main user need: seeing text appear while recording, including during screen recording. The same live behavior must also work in audio-only recording, Voice Note, Dictation, Push-to-Markdown, and Agent trigger flows.

The design must support three transcription backends with one user-facing model:

1. WhisperKit local transcription
2. OpenAI Whisper
3. OpenAI `gpt-4o-transcribe` family

The user wants live transcription, not a separate post-stop reprocess. The transcript may rewrite the most recent 10–30 seconds if that improves quality, but older text should stabilize.

## Recommendation

Build a **universal micro-batch live transcription engine** instead of provider-native streaming.

Every few seconds, the app re-transcribes a short rolling audio window and merges only the mutable tail of the transcript. This gives one live UX across all supported providers, including providers that do not expose a native streaming API.

## Why this approach

### Option A — universal micro-batch live engine **(recommended)**

- Capture audio once
- Re-transcribe a short rolling window every 3–5 seconds
- Keep a stable prefix and a mutable tail
- Let the tail rewrite within a fixed horizon

**Pros**

- Same live UX for WhisperKit, OpenAI Whisper, and `gpt-4o-transcribe`
- No dependence on provider-specific WebSocket APIs
- Works for both long recorder sessions and short hold-to-talk flows
- Keeps the current provider abstraction viable

**Cons**

- More STT requests than pure batch mode
- Requires careful merge logic to avoid flicker
- Re-transcribes overlapping audio by design

### Option B — provider-native streaming where available

- Use WebSocket streaming for providers that support it
- Add separate fallback paths for providers that do not

**Pros**

- Lowest latency for the streaming-capable provider

**Cons**

- Different engines for different providers
- Different transcript behavior by provider
- More code, more edge cases, less testability

This does not match the requirement for one live UX across all three providers.

### Option C — local live only, cloud degraded

- WhisperKit does live transcription
- Cloud providers stay batch or near-batch

**Pros**

- Simplest implementation

**Cons**

- Fails the product requirement
- Produces inconsistent behavior across modes and providers

## Architecture

### 1. Shared core

Introduce a new shared component:

- `LiveTranscriptEngine`

This engine is responsible for:

- keeping a rolling audio buffer
- scheduling transcription cadence
- exporting the current transcription window
- sending the window to the active provider
- merging the new result into transcript state
- exposing `stablePrefix`, `mutableTail`, and health state

The engine must not know whether it is running in Meeting, Voice Note, Dictation, Push-to-Markdown, or Agent mode. It only knows how to turn a stream of short audio windows into a live transcript.

### 2. Adapters over the core

Add two orchestration layers:

- `RecorderLiveAdapter`
- `HoldToTalkLiveAdapter`

`RecorderLiveAdapter` covers:

- Meeting
- Voice Note
- audio-only recording
- audio + screen recording

`HoldToTalkLiveAdapter` covers:

- Dictation
- Push-to-Markdown
- Agent trigger

These adapters reuse the same live engine but differ in lifecycle and output handoff:

- recorder modes keep a visible transcript surface for the duration of the session
- hold-to-talk modes use shorter windows and hand off the final live state to the existing downstream pipeline

### 3. Audio source model

`CaptureSession` should expose a **PCM tee**:

- one branch continues into the existing recording pipeline
- one branch feeds the live engine

This avoids rebuilding capture logic per mode and ensures recording remains the source of truth.

For hold-to-talk flows that do not use the full recorder stack today, the adapter should still produce the same kind of short PCM window input expected by `LiveTranscriptEngine`.

## Transcript model

The transcript has two regions:

- `stablePrefix`
- `mutableTail`

The engine locks older text and only rewrites a fixed recent horizon.

### Proposed timing defaults

- transcription cadence: every 3–5 seconds
- rolling window length: 15–30 seconds
- mutable rewrite horizon: 10–30 seconds

These values should be constants in code for v1, not user settings.

### Merge policy

Do **not** diff raw strings for the full transcript.

Instead, the engine tracks transcript units with window metadata:

- source window start
- source window end
- text
- state: `draft` or `stable`

When a new result arrives:

1. any draft units fully outside the mutable horizon become `stable`
2. draft units inside the mutable horizon are replaced by the new provider output
3. stable units are never rewritten

This makes transcript behavior predictable and avoids full-text churn.

## Provider strategy

Use one short-window abstraction for all providers:

- `LiveTranscriptionProvider`

Suggested contract:

- `transcribeWindow(...) async throws -> LiveTranscriptWindowResult`

The provider receives a short audio window plus context and returns normalized text for that window.

### WhisperKit

- Run directly on short local windows
- No network dependency
- Lowest latency path

### OpenAI Whisper

- Export each short window to temporary `.m4a`
- Upload as a normal transcription request
- Normalize output into the shared window result type

### `gpt-4o-transcribe`

- Same short-window export path as OpenAI Whisper
- Use the existing OpenAI transcription stack
- Long-recording chunking limits do not apply in practice because each request is already short

`AudioChunker` remains useful for long batch uploads, but the live path should use a lighter **window exporter** built for short rolling slices.

## Failure behavior

Recording is always more important than live transcription.

If a live STT request fails, times out, or returns too slowly:

- recording continues
- the transcript engine marks that cycle as degraded
- the UI shows a lightweight delayed/degraded state
- the next cadence retries with a fresh window

Do not stop recording because live transcription failed.

This rule applies to all modes, including Dictation and Agent trigger.

## Mode-specific behavior

### Recorder-based modes

Meeting, Voice Note, audio-only, and audio + screen modes should show a live transcript surface while recording. The visible transcript is the engine state: stable prefix plus mutable tail.

When the session stops, the final transcript is the last live state, optionally followed by one final flush of the same rolling-window logic. There is no separate full-audio batch reprocess in v1.

### Hold-to-talk modes

Dictation, Push-to-Markdown, and Agent trigger should use the same engine but with shorter-lived sessions. The key difference is orchestration:

- start engine on press
- accumulate live state while recording
- stop and flush on release
- hand off final transcript to the existing destination pipeline

That keeps one transcription core while preserving the UX expectations of each mode.

## UI scope for v1

### Included

- live transcript in recorder UI
- stable text plus rewriting tail
- degraded/delayed indicator when provider falls behind
- one final flush on stop/release

### Excluded

- speaker labels
- word-level timing UI
- provider-specific transcript behavior
- user-configurable cadence/window settings
- separate post-stop full re-transcription pass

## Testing

### Unit tests

- merge behavior across overlapping windows
- stable-prefix locking behavior
- mutable-tail rewrite behavior
- delayed or failed request handling
- final flush behavior
- adapter behavior for recorder and hold-to-talk flows

### Integration tests

- recorder mode produces live transcript updates during active capture
- screen recording does not block live transcript updates
- Dictation / Push-to-Markdown / Agent receive final handoff from the shared engine
- provider switching preserves the same transcript state model

### Failure tests

- one failed live request does not stop recording
- repeated slow windows surface degraded UI state
- engine recovery after a temporary provider outage

## Rollout plan

Implement this in phases:

1. add `LiveTranscriptEngine` and transcript merge model
2. add short-window export path and provider abstraction
3. wire recorder-based modes
4. wire hold-to-talk adapters
5. add UI surfaces and degraded-state handling
6. remove or downgrade old assumptions that transcription only happens after stop

## Decision

KosmoNotes should adopt **universal micro-batch live transcription** as the single transcription model across recorder-based and hold-to-talk flows. This is the simplest design that satisfies all of the following at once:

- live transcript during recording
- one UX across WhisperKit, OpenAI Whisper, and `gpt-4o-transcribe`
- no mandatory post-stop batch pass
- shared behavior across all transcription-driven modes
