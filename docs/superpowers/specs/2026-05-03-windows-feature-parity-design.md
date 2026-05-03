# KosmoNotes Windows Feature-Parity Design

**Date:** 2026-05-03  
**Status:** Draft approved in chat  
**Target:** Windows 11  
**Goal:** Ship a native Windows client with feature parity at the user-flow level, not API-level parity with the macOS app.

## 1. Problem

KosmoNotes is a macOS-first product. Its current implementation depends on Swift, AppKit, AVFoundation, ScreenCaptureKit, Core Audio, and other macOS-only APIs. A Windows version with full functionality cannot be a straightforward port. It needs a separate native client that preserves the product contract while using Windows-native capture, UI, storage, and integration paths.

## 2. Design Goal

The Windows app must preserve the same user-facing capabilities:

- Meeting mode
- Dictation mode
- Voice Note mode
- Global hotkeys
- Session library with search and playback
- Session chat and AI summaries
- Export flows
- S3-compatible sharing
- Provider configuration for transcription, LLM, embeddings, and sharing
- Cost gates and other product safeguards

The Windows app does not need to preserve the same internal APIs, package structure, or OS-specific implementation choices.

## 3. Recommended Approach

Build a separate native Windows 11 client on **.NET 8 + WinUI 3**.

This is the best fit for the product:

- It gives the app a native Windows desktop shell.
- It supports tray-based UX, settings windows, library windows, and global shortcuts well.
- It works with Windows-native media and system integration APIs.
- It keeps the current macOS code stable instead of forcing a cross-platform rewrite.

Rejected alternatives:

- **Rust + Tauri/tao/Wry:** workable, but slower to reach reliable media and system-integration parity.
- **Electron/React:** faster for UI, weaker for low-level capture and native desktop behavior.

## 4. Architectural Shape

The Windows version should be a **sister client**, not a port of the Swift codebase.

Recommended repository shape:

- Keep the existing macOS app unchanged.
- Add a new `windows/` application.
- Share product contracts, file formats, and provider behavior through documentation and tests, not through forced shared runtime code.

High-level layers:

1. **WinUI shell** for tray UI, recorder flyout, library, settings, and chat.
2. **Capture services** for mic, system audio, screen recording, hotkeys, and text insertion.
3. **Processing services** for transcription, AI summarization, embeddings, export, and sharing.
4. **Storage services** for sidecars, local SQLite indexing, and session recovery.

## 5. Core Windows Components

### 5.1 App shell

- WinUI 3 desktop app
- System tray presence
- Recorder flyout
- Library window
- Settings window
- Session detail and chat views

### 5.2 Recording orchestration

`RecorderCoordinator` owns the state machine:

- idle
- starting
- recording
- paused
- processing
- complete
- failed

This mirrors the product behavior on macOS while allowing a Windows-specific implementation.

### 5.3 Audio capture

- **Microphone:** Windows-native capture path via `MediaCapture` or WASAPI capture
- **System audio:** **WASAPI loopback**

This replaces the macOS Core Audio Tap and ScreenCaptureKit audio path. The product requirement is "capture mic + system audio," not "use the same API."

### 5.4 Screen recording

- **Capture:** Windows Graphics Capture
- **Encode:** H.264 + AAC through a Windows-native encoder path such as Media Foundation

This provides feature parity for the optional screen recording flow used by session playback and vision-capable chat. As on macOS, screen recording stays optional and off by default.

### 5.5 Dictation insertion

Baseline strategy:

1. Copy generated text to the clipboard
2. Restore prior clipboard state only when that can be done reliably
3. Simulate paste into the focused app

If paste automation fails or the target app blocks it, the app must report that clearly and leave the text in the clipboard instead of pretending the insertion succeeded.

### 5.6 Global hotkeys

Provide the same product-level triggers:

- Meeting toggle
- Voice Note toggle
- Library open
- Dictation push-to-talk or toggle mode

Hotkey conflicts must surface in settings with a clear rebind path.

### 5.7 Secrets and credentials

Store provider secrets with **Windows Credential Manager** or **DPAPI-backed secure storage**. Do not store plaintext secrets in app settings.

## 6. Product Data Contract

The Windows app should preserve the same data model as the macOS app where practical:

- Session root under a Windows-appropriate app-data directory
- Session directory per recording
- Stable sidecar file names for transcript, summary, actions, and optional screen media
- Transcript sidecars
- Summary sidecars
- Action-item sidecars
- Optional screen recording sidecar
- SQLite index as a rebuildable cache

The key rule stays the same:

**Filesystem sidecars are the source of truth. SQLite is a rebuildable index.**

This keeps export, reindex, share, and chat behavior conceptually aligned across both platforms.

## 7. Feature-Parity Mapping

| Product area | Windows design |
| --- | --- |
| Meeting mode | Mic + WASAPI loopback + optional screen capture |
| Dictation mode | Mic capture + fast transcription + paste into focused app |
| Voice Note mode | Mic capture + transcript + AI note shaping |
| Library | Native Windows list/detail UI + local playback + transcript search |
| Search | SQLite FTS as baseline, embeddings optional |
| AI summary/chat | Same remote providers and product prompts, Windows-native client implementations |
| Sharing | S3-compatible upload + presigned URLs |
| Hotkeys | Global Windows hotkey service |
| Cost controls | Same user-facing gates and warnings |

## 8. Error Handling and Fallbacks

The Windows client must fail honestly.

- If screen capture is unavailable, disable the screen feature and say why.
- If loopback initialization fails, block Meeting start and show recovery guidance.
- If a hotkey cannot bind, surface the conflict and keep the app usable.
- If dictation cannot paste into the target app, report that and leave the text in the clipboard.
- If embeddings fail, keep FTS search working.
- If provider calls fail, surface the real provider error rather than a generic success-shaped message.

No silent skips. No "it probably worked" behavior.

## 9. Testing Strategy

### 9.1 Unit tests

- State machine transitions
- Provider request/response handling
- Transcript parsing
- Cost estimation and gating
- Sidecar persistence
- SQLite indexing
- Sharing request signing

### 9.2 Integration tests

- Mic recording path
- Mic + system audio recording path
- Screen recording path
- Session persistence and reindex
- Export and sharing flows

### 9.3 Manual test matrix

- Meeting without screen
- Meeting with screen
- Dictation into common Windows apps
- Voice Note flow
- Library playback and search
- Provider permutations
- Failure cases for permissions, hotkeys, audio init, and network errors

## 10. Scope Boundaries

This design does **not** require:

- Shared runtime code with the Swift app
- A cross-platform rewrite
- API-level parity with macOS frameworks
- Windows 10 support in the first delivery

This design **does** require:

- Windows 11 as the initial supported platform
- A separate Windows-native implementation
- Feature parity at the user-flow level
- Preservation of the product's storage and provider contracts

## 11. Recommended Rollout

Build the Windows app in phases, but hold the parity bar at the product level:

1. App shell, settings, secrets, and provider plumbing
2. Meeting mode with mic + system audio
3. Dictation mode and text insertion
4. Voice Note mode
5. Library, search, playback, and chat
6. Screen recording
7. Export, sharing, embeddings, and polish

## 12. Decision Summary

The Windows version should ship as a new native Windows 11 client on .NET 8 + WinUI 3. It should preserve the same product behavior, storage model, and provider surface as the macOS app, while using Windows-native capture and integration services under the hood.
