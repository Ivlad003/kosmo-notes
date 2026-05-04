# KosmoNotes — Windows client

Native Windows 11 sister-app to the macOS Swift client. Targets feature
parity at the **user-flow level**, not API parity. Stack: **.NET 8 +
WinUI 3**. Design doc: [docs/superpowers/specs/2026-05-03-windows-feature-parity-design.md](../docs/superpowers/specs/2026-05-03-windows-feature-parity-design.md).

## Repository layout

```
windows/
  KosmoNotes.Windows.sln          # Mac-buildable solution (excludes WinUI App)
  global.json                     # Pins .NET 8 SDK
  Directory.Build.props           # Shared MSBuild config (Nullable, LangVersion, warnings-as-errors)
  setup-env.sh                    # Source before running `dotnet` on macOS
  src/
    KosmoNotes.Core/              # Domain models, sidecar I/O, prompts, cost gating
    KosmoNotes.Providers/         # Anthropic / OpenAI / OpenRouter / Ollama / Deepgram / Embeddings
    KosmoNotes.Storage/           # SQLite + FTS5 + embeddings, atomic JSON sidecars
    KosmoNotes.Sharing/           # AWS Sig V4 + S3 PutObject + presigned GET
    KosmoNotes.Secrets/           # ISecretsStore abstraction + InMemory impl (DPAPI lives in App)
    KosmoNotes.App/               # WinUI 3 desktop shell — Windows-only, NOT in sln
  tests/
    KosmoNotes.{Core,Providers,Storage,Sharing,Secrets}.Tests/
```

## Building on macOS

The platform-agnostic libraries (everything except `KosmoNotes.App`) build and
test on macOS, Linux, and Windows.

```sh
# One-time SDK install (no sudo)
curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 8.0 --install-dir "$HOME/.dotnet"

# In every shell that runs dotnet
source windows/setup-env.sh

# Build + test
cd windows
dotnet build KosmoNotes.Windows.sln
dotnet test KosmoNotes.Windows.sln
```

## Building the WinUI 3 shell (Windows machine required)

`KosmoNotes.App` is excluded from the solution because WinUI 3 requires the
Windows App SDK + Windows 11 SDK, neither of which is available on macOS.

On a Windows 11 machine:

1. Install Visual Studio 2022 17.10+ with the **".NET Desktop"** and **"Windows App SDK"** workloads, or install [WinAppSDK 1.6+](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/) standalone.
2. Add the project to the solution:
   ```
   cd windows
   dotnet sln add src/KosmoNotes.App/KosmoNotes.App.csproj
   ```
3. Build:
   ```
   dotnet build src/KosmoNotes.App/KosmoNotes.App.csproj
   ```

See `src/KosmoNotes.App/TODO.md` for the implementation backlog (capture,
hotkeys, secrets, screen recording).

## Layered architecture

```
KosmoNotes.App (WinUI 3, Windows-only)
        │
        ▼
┌──────────────────┬──────────────┬──────────────┐
│ Providers        │ Storage      │ Sharing      │
│ (HTTP + Models)  │ (SQLite/FTS) │ (S3 SigV4)   │
└────────┬─────────┴──────┬───────┴──────┬───────┘
         │                │              │
         └────────────────┼──────────────┘
                          ▼
                  KosmoNotes.Core
                  (models, sidecar I/O,
                   prompts, cost gating)
```

`KosmoNotes.Secrets` is independent — only `KosmoNotes.App` consumes it (and
provides the real DPAPI implementation).

## Mirroring the Swift codebase

This project mirrors the design and behavior of the Swift modules in `Sources/`.
Specifically:

| Windows project          | Swift counterpart            |
| ------------------------ | ---------------------------- |
| `KosmoNotes.Core`        | `Sources/AIKit/Models.swift`, `Sources/AIKit/CostEstimator.swift`, `Sources/AIKit/PromptTemplates.swift`, `Sources/StorageKit/AtomicWriter.swift` |
| `KosmoNotes.Providers`   | `Sources/AIKit/{Anthropic,OpenAI,OpenRouter,Ollama,EmbeddingProvider}.swift`, `Sources/TranscriptionKit/DeepgramBatchProvider.swift` |
| `KosmoNotes.Storage`     | `Sources/StorageKit/Database.swift`, `Sources/StorageKit/SessionStore.swift` |
| `KosmoNotes.Sharing`     | `Sources/SharingKit/SigV4.swift`, `Sources/SharingKit/S3Client.swift` |
| `KosmoNotes.Secrets`     | `Sources/StorageKit/KeychainStore.swift` (interface only; DPAPI replaces Keychain on Windows) |

The product contract — sidecar layout, FTS5 schema, provider behavior, prompt
templates — must match the Swift implementation. Tests should cross-check
known outputs (e.g. AWS Sig V4 test vectors, prompt snapshots).

## Status (2026-05-04)

Phase 1 of the rollout — platform-agnostic core libraries — is complete and
verified on macOS:

| Project              | Source files | Tests | Notes |
| -------------------- | ------------ | ----- | ----- |
| `KosmoNotes.Core`    | 17           | 64    | Models, AtomicWriter, CostEstimator, PromptTemplates (byte-fidelity vs Swift), EmbeddingMath |
| `KosmoNotes.Sharing` | 2            | 47    | SigV4 + S3Client; presigned URL byte-equal to Swift output |
| `KosmoNotes.Secrets` | 5            | 24    | `ISecretsStore` + `InMemorySecretsStore`; DPAPI lives in App |
| `KosmoNotes.Providers` | 12         | 93    | Anthropic / OpenAI / OpenRouter / Ollama / Embeddings / Deepgram batch |
| `KosmoNotes.Storage` | 4            | 29    | SQLite + FTS5 + embeddings + atomic JSON sidecars |
| **Total**            | **40**       | **257** | 0 warnings, 0 failures, ~0.5s test run |

`KosmoNotes.App` (WinUI 3 shell, capture, hotkeys, real DPAPI) is **not yet
implemented** — it requires a Windows 11 machine. See `src/KosmoNotes.App/TODO.md`
for the backlog.
