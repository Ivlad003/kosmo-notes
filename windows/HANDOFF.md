# Windows port — handoff & task tracker

**Last updated:** 2026-05-04
**Branch:** `develop`
**Phase:** 1 of 7 (platform-agnostic core libs) — **complete on macOS**

## TL;DR

The Windows version of KosmoNotes lives under [`windows/`](.) as a new
.NET 8 + WinUI 3 client per
[`docs/superpowers/specs/2026-05-03-windows-feature-parity-design.md`](../docs/superpowers/specs/2026-05-03-windows-feature-parity-design.md).

Phase 1 (everything that doesn't need Windows APIs) was implemented and
verified on macOS via `dotnet build` / `dotnet test`. Phase 2+ (WinUI 3 shell,
WASAPI capture, Graphics Capture, hotkeys, DPAPI) needs a Windows 11 machine.

```
windows/
├── KosmoNotes.Windows.sln          # Mac-buildable solution (excludes WinUI App)
├── README.md                       # Build instructions, layout, mirroring map
├── HANDOFF.md                      # This file
├── global.json                     # Pins .NET 8.0.420
├── Directory.Build.props           # Nullable + warnings-as-errors
├── setup-env.sh                    # `source` before running `dotnet` on macOS
├── src/
│   ├── KosmoNotes.Core/            # ✅ Phase 1
│   ├── KosmoNotes.Sharing/         # ✅ Phase 1
│   ├── KosmoNotes.Secrets/         # ✅ Phase 1
│   ├── KosmoNotes.Providers/       # ✅ Phase 1
│   ├── KosmoNotes.Storage/         # ✅ Phase 1
│   └── KosmoNotes.App/             # ⛔ Windows-only stub (TODO.md inside)
└── tests/
    └── KosmoNotes.{Core,Sharing,Secrets,Providers,Storage}.Tests/
```

## Phase 1 — DONE on macOS (2026-05-04)

All 257 tests pass. `dotnet build KosmoNotes.Windows.sln` and
`dotnet test KosmoNotes.Windows.sln` are clean: 0 warnings, 0 errors.

| Project              | Source files | Tests | Coverage of |
| -------------------- | ------------ | ----- | ----------- |
| `KosmoNotes.Core`    | 17           | 64    | `ChatMessage` (text + image parts), `AIConfig`, `AIException` hierarchy, `SessionRecord` (+ JSON converter for old sidecars), `SessionMode` / `Status` / `EnhancementStatus`, `SearchHit`, `TranscriptSegment`, `BatchTranscriptResult`, `TranscriptionConfig`, `AtomicWriter`, `CostEstimator` (+ token heuristic + transcription pricing), `PromptTemplates` (byte-fidelity vs Swift), `EmbeddingMath` |
| `KosmoNotes.Sharing` | 2            | 47    | `SigV4` (SHA-256, HMAC, AWS-encode, signing key, canonical request, string-to-sign), `S3Client.PutObjectAsync`, `S3Client.PresignedGetUrl`, `S3Exception`. **Cross-validated byte-for-byte with the Swift impl** for the canonical AWS sample (presigned GET with path-style addressing). |
| `KosmoNotes.Secrets` | 5            | 24    | `ISecretsStore`, `InMemorySecretsStore` (thread-safe), `SecretsKey` (8 well-known keys), `TrySetAsync`, `GetRequiredAsync`, `SecretNotFoundException`. **Real DPAPI impl is `KosmoNotes.App`'s job.** |
| `KosmoNotes.Providers` | 12         | 93    | `IAIProvider` / `IEmbeddingProvider` / `IBatchTranscriptionProvider` interfaces. `AnthropicProvider` (Messages API, system field routing, multipart text+image), `OpenAIProvider` (Chat Completions + multipart), `OpenRouterProvider` (HTTP-Referer + X-Title), `OllamaProvider` (Native + OpenAI-compat modes, RFC-1918 endpoint validation, `ListModelsAsync`), `OpenAIEmbeddingProvider` (text-embedding-3-small, 1536 dims), `DeepgramBatchProvider` (Nova-2 batch, 5-second segment grouping). |
| `KosmoNotes.Storage` | 4            | 29    | `Database` (SQLite, WAL, single-conn + semaphore), schema migrations `v1`/`v2_embeddings`/`v3_enhancement_status`, sessions CRUD, FTS5 (porter unicode61), embeddings upsert/list/has, `Fts5Pattern.MatchingAllTokensIn`, `SessionStore` (atomic JSON sidecars + DB row coordination). |
| **TOTAL**            | **40**       | **257** | |

### Documented deviations from the Swift reference

These are intentional — keep an eye out when porting changes from the Swift
side; bidirectional updates need to land in both:

1. **`AtomicWriter` parent-dir fsync omitted on .NET.** Swift `fsync`s the
   parent directory before AND after the rename for power-loss durability.
   .NET 8 has no portable equivalent (`File.Move(overwrite:true)` is atomic
   on all platforms but the directory-entry fsync requires P/Invoke). Since
   the helper is used for human-edited config + per-session sidecars (not
   crash-critical bookkeeping), v1 ships without it. Documented inline in
   `windows/src/KosmoNotes.Core/IO/AtomicWriter.cs`.

2. **`S3Client` host-header port handling**: when an endpoint uses a
   non-default port (e.g. MinIO on `localhost:9000`), the C# client signs
   `host:localhost:9000` whereas the Swift client signs just `host:localhost`.
   The C# behavior is more correct against MinIO; AWS / R2 / B2 are all on
   default 443 so the difference is invisible there. Consider updating the
   Swift side to match.

3. **`ChatMessage.Text(role, content)` factory** in Swift becomes
   `ChatMessage.FromText(role, content)` in C# — the property `Text` and the
   factory `Text` collide on the same type in C#, so the factory got renamed.

4. **JSON enum encoding** uses per-enum `JsonConverter<T>` subclasses since
   `JsonStringEnumMemberName` only landed in .NET 9 (we're pinned to 8). Wire
   format identical (`"meeting"`, `"voiceNote"`, etc.).

5. **`DeepgramBatchProvider` errors** thread through the unified
   `AIException` hierarchy (`AuthenticationFailedException`, etc.) rather
   than a separate `DeepgramBatchError` enum, so callers can use one
   `try { ... } catch (AIException) { ... }` across all providers.

## Phase 2–7 — TODO (Windows machine required)

Per [§11 Recommended Rollout](../docs/superpowers/specs/2026-05-03-windows-feature-parity-design.md#11-recommended-rollout)
of the design doc.

### Phase 2: App shell + secrets plumbing
- [ ] Add `KosmoNotes.App` to the solution (`dotnet sln add src/KosmoNotes.App/KosmoNotes.App.csproj`).
- [ ] WinUI 3 shell skeleton: `App.xaml`, `App.xaml.cs`, `MainWindow.xaml`, `Package.appxmanifest`.
- [ ] System tray presence (`H.NotifyIcon` or native `Shell_NotifyIcon` P/Invoke).
- [ ] Settings window scaffolding — empty tabs for Providers, Transcription, Hotkeys, Sharing, Voice Note.
- [ ] `DpapiSecretsStore : ISecretsStore` — real impl via Windows Credential Manager (or DPAPI for cross-user). Plumb into a `IServiceProvider` so the rest of the app can resolve `ISecretsStore`.
- [ ] Settings → Providers tab with API-key fields backed by `ISecretsStore`.

### Phase 3: Meeting mode (mic + system audio)
- [ ] `RecorderCoordinator` state machine: idle → starting → recording → paused → processing → complete → failed.
- [ ] Microphone capture via `MediaCapture` (or WASAPI shared-mode capture for lower latency).
- [ ] **System audio capture via WASAPI loopback** (`IAudioClient` with `AUDCLNT_STREAMFLAGS_LOOPBACK`).
- [ ] AAC encoding to `.m4a` segments via Media Foundation (`IMFSinkWriter`).
- [ ] Recovery service: scan orphan segments on launch, concat surviving 5-second chunks into a single `.m4a` via Media Foundation.
- [ ] Wire `KosmoNotes.Storage.SessionStore` for sidecar/DB persistence.
- [ ] Recorder flyout UI with mic level meter.
- [ ] Cost-cap modal before sending audio for transcription.

### Phase 4: Dictation mode + text insertion
- [ ] Dictation flyout with push-to-talk / toggle modes.
- [ ] Clipboard capture + restore (`Clipboard.SetText` / `GetText` with format preservation).
- [ ] Paste simulation via `SendInput` (Ctrl+V). Detect failure (target app blocks paste) and surface clearly.

### Phase 5: Voice Note mode
- [ ] Voice Note kind picker in the recorder flyout (`PromptTemplates.VoiceNoteKind`: Freeform / Task / Journal / Checklist).
- [ ] Wire `PromptTemplates.VoiceNote` into the post-record AI summary path.

### Phase 6: Library + chat
- [ ] Library window: list view bound to `Database.ListSessionsAsync`.
- [ ] Detail view: transcript, summary, action items, audio playback (`MediaPlayerElement`).
- [ ] Search: FTS5 via `Database.SearchTranscriptsAsync`, with embeddings as optional second source (cosine top-K via `EmbeddingMath`).
- [ ] Chat tab on session detail: uses the configured `IAIProvider`. Wires timestamp references into frame extraction (Phase 7 dependency).

### Phase 7: Screen recording + sharing + polish
- [ ] **Screen capture via Windows Graphics Capture** (`GraphicsCaptureItem`, `Direct3D11CaptureFramePool`).
- [ ] H.264 + AAC encode to `.mp4` via Media Foundation (`IMFSinkWriter`).
- [ ] Frame extraction at timestamps for vision-chat (analog of Swift `FrameExtractor`).
- [ ] Sharing: hook `KosmoNotes.Sharing.S3Client` into a Settings → Sharing tab; presigned URLs go to clipboard.
- [ ] Embeddings auto-index after enhancement: hook `KosmoNotes.Providers.OpenAIEmbeddingProvider` into the post-stop pipeline.
- [ ] Global hotkeys: `RegisterHotKey` for Meeting (⌃⇧R) / Voice Note (⌃⇧N) / Library (⌃⇧L) / Dictation toggle. Conflict surfaces in Settings → Hotkeys with rebind.

### Phase 8: Hardening (independent work that can happen in parallel)
- [ ] Onboarding modal for first-launch permission education (microphone, screen recording when enabled).
- [ ] App icon + Square150x150 / Square44x44 logos in `Package.appxmanifest`.
- [ ] Code signing certificate + signing flow (deferred per macOS posture but Windows SmartScreen is more aggressive).
- [ ] CI on Windows runner: GitHub Actions `windows-latest` running `dotnet build` + `dotnet test`. Add `KosmoNotes.App` build to the matrix.
- [ ] Error-handling audit per [§8 of design doc](../docs/superpowers/specs/2026-05-03-windows-feature-parity-design.md#8-error-handling-and-fallbacks): every "fails honestly" path must have a UI surface and an integration test.

## Quick start on Windows 11

After `git pull` on a Windows 11 machine:

```powershell
# Prerequisites
# - Visual Studio 2022 17.10+ with ".NET Desktop" + "Windows App SDK" workloads
#   OR standalone .NET 8 SDK + WinAppSDK 1.6+ + Windows 11 SDK (10.0.22621+)

cd windows
dotnet restore KosmoNotes.Windows.sln
dotnet build   KosmoNotes.Windows.sln
dotnet test    KosmoNotes.Windows.sln  # expect 257/257 passing

# To start working on the WinUI shell:
dotnet sln add src/KosmoNotes.App/KosmoNotes.App.csproj
dotnet build src/KosmoNotes.App/KosmoNotes.App.csproj
```

Open `windows/KosmoNotes.Windows.sln` in Visual Studio for the full IDE
experience (XAML designer, Hot Reload, etc.).

## Cross-platform parity rules

The product contract lives in
[`docs/superpowers/specs/2026-05-03-windows-feature-parity-design.md`](../docs/superpowers/specs/2026-05-03-windows-feature-parity-design.md).
The Swift implementation under [`Sources/`](../Sources/) is the source of
truth. When updating either side:

1. **Provider request shapes** must match byte-for-byte (validated by JSON
   inspection tests on both sides).
2. **Sidecar JSON layout** (`session.json`) must round-trip cleanly across
   both platforms — the C# tests already verify older Swift sidecars (without
   `enhancementStatus`) decode correctly.
3. **FTS5 schema + tokenizer** must match (`porter unicode61`).
4. **Sig V4 signing** must produce identical presigned URLs for identical
   inputs (validated by snapshot tests against pinned credentials + clock).
5. **Prompt templates** must produce byte-identical output for identical
   inputs (validated by snapshot tests in `KosmoNotes.Core.Tests`).

If a behavior diverges, document it in this file's "Documented deviations"
section above and reference an issue or design-doc revision.

## Implementation history

| Date       | Change |
| ---------- | ------ |
| 2026-05-03 | Windows feature-parity design doc landed in `docs/superpowers/specs/`. |
| 2026-05-04 | Phase 1 implemented on macOS: 5 platform-agnostic libs (Core, Sharing, Secrets, Providers, Storage), 257 tests, 0 warnings. WinUI 3 App project stubbed with TODO.md. |
