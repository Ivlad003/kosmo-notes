# Jarvis Studio — Vibe Test Simulation

**Date:** 2026-05-01
**Method:** [vibe-testing skill](../../) — scenario-driven validation against pre-implementation specs
**Specs under test:** `2026-05-01-jarvis-studio-design.md`, `CLAUDE.md`, `README.md`

Four named-persona scenarios, each varying across user type / network / provider mix / risk surface. Each simulated step-by-step against the design doc; gaps tagged BLOCKING / DEGRADED / COSMETIC.

---

## VT-1 — Marcus, privacy-paranoid solo dev (Ollama, offline)

**Persona:** Senior backend engineer at a healthcare startup. Refuses cloud LLMs. M3 Pro 36GB, runs `llava:13b` locally. Outbound firewall blocks Anthropic / OpenAI.

**Environment:** macOS 14.5 · Ollama at `http://localhost:11434` · `sharing.backend = "none"` · home WiFi but cloud-LLM hosts blocked.

**Goal:**
> "Record a 20-minute walkthrough of an auth bug, annotate the failing line at 14:23 with a red box, and never send a byte to any cloud LLM."

**Steps & questions:**

1. **Configure providers, disable cloud.** §10, §6.
   - Q1.1 ✓ COVERED — dropdown is auto-populated from enabled providers (§10).
   - Q1.2 GAP — how does the app discover Ollama models? `GET /api/tags` or freehand input? Undefined.
   - Q1.3 GAP — `transcription_mode = "cloud"` + OpenAI disabled = silent failure or warning?

2. **Record with live transcription.** §4.
   - Q2.1 GAP — fall back to local `whisper-rs` automatically, crash, or disable captions silently?
   - Q2.2 AMBIGUITY — `transcription_mode` enum lists `"cloud"` but `"local"` not documented in §10.
   - Q2.3 GAP — local Whisper model file: bundled, downloaded on first use, or BYO?

3. **scap@0.0.8 misbehaves mid-recording.** §4, §11.
   - Q3.1 BLOCKING — §11 says "FFmpeg-direct fallback designed in" but it isn't.
   - Q3.2 GAP — backpressure: dropped frame → pad / drop / stall? Undefined.

4. **Annotate via Ollama llava:13b.** §6.
   - Q4.1 GAP — 3 frames in one request or 3 sequential? Affects local-GPU throughput.
   - Q4.2 GAP — structured-output strategy per provider (Anthropic tool-use, OpenAI `json_schema`, Ollama prompt-only) undefined.
   - Q4.3 GAP — coord-mapping (model normalized 336×336 → 1440p screen).

5. **Try to share — backend = none.** §8.
   - Q5.1 ✓ — disabled state covered, but tooltip UX missing.
   - Q5.2 GAP — no separate "Export to disk" flow, only "Share."

| Spec Section | Steps | Status |
|---|---|---|
| §4 Recording | 2,3 | Concurrency, scap fallback BLOCKING |
| §6 Annotation | 4 | Provider matrix covered; structured-output gap |
| §8 Sharing | 5 | backend=none covered; export-to-disk missing |
| §10 Config | 1,2 | `transcription_mode` enum incomplete |
| §11 Risk register | 3 | scap fallback "designed" but absent |

---

## VT-2 — Priya, bug-fix screencaster sharing externally

**Persona:** Frontend engineer recording 6–8 min repros for GitHub issues. Recipients use Chrome/macOS, Firefox/Linux, Safari/iOS.

**Environment:** macOS Apple Silicon · Anthropic + OpenAI keys configured · self-hosted RustFS at `storage.priya-team.com` behind Cloudflare · default expiration 7d.

**Goal:**
> "Record a 6-minute repro of issue #4521, blur the JWT visible in the network tab, and paste a working link into the GitHub issue within 5 minutes."

**Steps & questions:**

1. **Record with system audio.** §4.
   - Q1.1 GAP — macOS needs a virtual audio device (BlackHole / Loopback) for system audio. Does scap handle transparently, or does Priya install a kext?
   - Q1.2 GAP — multi-track AAC playback in browser `<video>` is inconsistent. Default track? Mixed?

2. **AI auto-blur the JWT.** §6.
   - Q2.1 GAP — "blur all JWTs between 2:00 and 4:30" with default $0.50 cap = which frames? Cost-cap interaction with range-prompt undefined.
   - Q2.2 **BLOCKING** — annotations are non-destructive JSON until export (§6). The share pipeline (§8) uploads `recording.mp4`. **If "Share" uploads the source MP4 without re-rendering blur, recipients see the unblurred JWT.** Spec must either (a) force re-export-with-blur on share, or (b) say share uploads the *exported* MP4. Currently silent.
   - Q2.3 GAP — verify-blur preview step?

3. **Share, transcode H.265 → H.264.** §8, §11.
   - Q3.1 GAP — transcode is multi-minute on M-series; pre-share modal shows no transcoding progress.
   - Q3.2 AMBIGUITY — multipart 50 MB threshold pre- or post-transcode?
   - Q3.3 GAP — local-library schema for shared recordings (where Priya manages links).

4. **Recipient on Firefox Linux / iOS Safari.** §11, §2.
   - Q4.1 GAP — content-type metadata on S3 PutObject? Spec doesn't specify `video/mp4`.
   - Q4.2 GAP — H.264 baseline profile + `+faststart` flag for mobile playback? Not specified.

5. **Recipient asks for link extension.** §8.
   - Q5.1 dup of Q3.3.
   - Q5.2 GAP — re-share preserves bucket key, or fresh key per share?

| Spec Section | Steps | Status |
|---|---|---|
| §4 Recording | 1 | macOS system-audio capture undefined |
| §6 Annotation | 2 | **G-B1: blur-bake-vs-overlay BLOCKING** |
| §8 Sharing | 3,4,5 | Transcode UX, library schema, content-type all gaps |
| §11 Risks | 4 | Transcode flags missing |

---

## VT-3 — Anika, indie consultant using agent Q&A

**Persona:** Independent consultant. Records 45-min client calls (with consent), spawns Claude Code to draft follow-up emails.

**Environment:** macOS · Anthropic key · `claude` v0.6.4 in PATH · `default_backend = "claude"`.

**Goal:**
> "Record a 45-minute client call, then ask Claude Code to summarize action items and draft a follow-up email."

**Steps & questions:**

1. **Long recording, ffmpeg crashes at minute 30.** §4, §13.
   - Q1.1 **BLOCKING** — §13 lists crash-safety as open. §4 hints at "MP4 segments stitched on stop" but no segment-duration or stitch-failure spec.
   - Q1.2 GAP — when ffmpeg dies, scap behavior?

2. **Spawn Claude Code with cwd=session.** §7.
   - Q2.1 GAP-OUTDATED — `args = ["--print", "--cwd", "."]`. Real Claude Code v0.6.4 print mode is `claude -p "<prompt>"` or stdin; `--print` alone prints session ID. Example may be aspirational.
   - Q2.2 GAP — cancellation: kill child only, or process group? On macOS needs `setpgid` + `kill -- -pgid`; on Windows a Job Object. Not specified.

3. **Agent modifies files in cwd.** §7.
   - Q3.1 GAP — agent edits `transcript.txt`. Editor reload? Or stale view?
   - Q3.2 GAP — write quota (5GB into `frames/`)?
   - Q3.3 GAP — `..` traversal (other sessions, user home)?

4. **Stream stdout to UI.** §7.
   - Q4.1 **BLOCKING** — Claude Code `--output-format stream-json` emits JSONL with tool-use events; Codex emits prose. §7 says "stream stdout to UI" — but rendering needs a per-backend parser. No spec layer.
   - Q4.2 GAP — render tool-use events, or wait for next text chunk?

5. **Q&A history.** §7.
   - Q5.1 AMBIGUITY — "Each Q&A turn appended to .jarvis/conversations/" — written by agent or Jarvis Studio?
   - Q5.2 GAP — multi-backend on same session: shared folder or per-backend?

| Spec Section | Steps | Status |
|---|---|---|
| §4 Recording | 1 | Crash-safety BLOCKING (matches §13) |
| §7 Agent backends | 2,3,4,5 | Streaming format BLOCKING; cwd boundaries, cancel, history all gaps |

---

## VT-4 — Jordan, first-time user, fresh install

**Persona:** Designer trying Jarvis Studio for the first time. Has only an OpenAI key. Doesn't know what RustFS is.

**Environment:** Windows 11 · just downloaded `jarvis-studio.exe` · no agents, no S3.

**Goal:**
> "Just record my screen and send the link to a designer friend without reading docs."

**Steps & questions:**

1. **First launch.** §3, §10.
   - Q1.1 GAP — no first-run / onboarding flow specified. CLAUDE.md mentions sharing first-run prompt only. What does Jordan see?
   - Q1.2 GAP — Windows WGC permission prompt: surfaced upfront or as confusing OS dialog mid-record?

2. **Click record without configuring providers.** §6, §10.
   - Q2.1 GAP — defaults have Anthropic+OpenAI `enabled: true`. Jordan has only OpenAI. Block? Warn? Record anyway?
   - Q2.2 GAP — `live_transcription: true` + missing OpenAI key → fail, silent skip, or warn?

3. **Try to share, doesn't have storage.** §8.
   - Q3.1 GAP — first-run prompt assumes the user *has* a server. Most won't. No "Use Cloudflare R2 (cheapest)" preset; no Studio Cloud tier yet.
   - Q3.2 GAP — Test connection requires an endpoint Jordan doesn't have.

4. **Try AI annotation.** §6, §13.
   - Q4.1 AMBIGUITY — running cost tally surfaced where in editor?
   - Q4.2 GAP — OpenAI rate-limit (free-tier 429): toast, retry, silent fail? Matches §13 open Q.

5. **Give up, uninstall.** §9, §10.
   - Q5.1 GAP — `data_dir: "~/JarvisStudio"` is POSIX. Windows resolution? Cleaned on uninstall?
   - Q5.2 GAP — keychain entries cleaned on Windows uninstall?

| Spec Section | Steps | Status |
|---|---|---|
| §3 Architecture | 1 | First-run flow undefined |
| §6 Annotation | 4 | Rate-limit UX gap (matches §13) |
| §8 Sharing | 3 | Onboarding for users without infra missing |
| §9 Distribution | 1,5 | Permissions, uninstall undefined |
| §10 Config | 1,2,5 | Defaults vs reality; data_dir Windows path |

---

## Aggregate gap report

### BLOCKING

| ID | Gap | Tests | Recommended fix |
|---|---|---|---|
| **G-B1** | §6: annotations are non-destructive JSON until "export." §8 share pipeline does not specify export-on-share. **If Share uploads `recording.mp4` without re-rendering blur, recipients see unblurred PII.** | VT-2 | §8 must mandate: Share = export-with-annotations-baked-in → upload that file. Source `recording.mp4` is never the shared object. |
| **G-B2** | §4 + §13: crash-safe recording is unspecified. v1 cannot ship without it. | VT-1, VT-3 | Commit to fragmented MP4 with periodic moov flush, OR segmented record-with-stitch (declare segment duration). Promote from §13 to §4 with concrete spec. |
| **G-B3** | §7: per-backend stdout parser layer is required (Claude Code JSONL ≠ Codex prose) but spec says "stream stdout to UI" with no parser tier. | VT-3 | Add `parse_stream` field to `backends.toml`: `text` \| `claude-jsonl` \| `codex-stream`. Define rendering for tool-use events. |
| **G-B4** | §4: recording-pipeline concurrency model undefined. Backpressure between scap → ffmpeg → transcribe forks not specified; failure of one fork can take down the recording. | VT-1, VT-3 | Spec the channel model: bounded `tokio::mpsc` per stage, transcription is best-effort fail-open, scap → ffmpeg is must-not-drop. |
| **G-B5** | §7: `backends.toml` example commands may be out of date with actual Claude Code / Codex CLI flags; no version detection. | VT-3 | Add `min_version` + `version_command` per backend. Show actual `claude -p` invocation (not `claude --print`). |

### DEGRADED

| ID | Gap | Tests | Workaround |
|---|---|---|---|
| G-D1 | Link expiry has no extension/revocation UX (presigned URLs are immutable) | VT-2 | Local library tracks key + expiry; "Re-share" button re-presigns same object |
| G-D2 | H.265 → H.264 transcode UX placement undefined; share modal shows no transcoding progress | VT-2 | Add transcoding stage to §8 flow with progress indicator |
| G-D3 | Auto-blur cost-cap interaction undefined for range prompts | VT-2 | Cap accountant must estimate cost before running; surface "this will cost $X" confirmation |
| G-D4 | First-run / onboarding for users without S3 infra missing | VT-4 | §8 add presets (Cloudflare R2, Backblaze B2) with starter walkthroughs |
| G-D5 | Provider-specific structured-output strategy undefined | VT-1 | `VisionProvider` trait exposes capability flags; per-impl strategy |
| G-D6 | Whisper transcription `cloud` vs `local` toggle, local-model bootstrap UX | VT-1 | §10 enum `transcription_mode: "cloud" \| "local"`; §4 spec for whisper-rs model auto-download with progress |
| G-D7 | Local-library schema for shared recordings | VT-2 | Spec a "Library → Shared" tab with per-recording link metadata |
| G-D8 | Agent cwd write boundaries (writes to frames/, `..` traversal, transcript.txt edits) | VT-3 | Convention: agent only writes under `.jarvis/conversations/`. Diff-and-warn on other modifications. |
| G-D9 | Cancellation: kill process group not just child (macOS pgid, Windows Job Object) | VT-3 | §7 cancel = SIGTERM to process group, then SIGKILL after 3s |
| G-D10 | macOS system-audio capture (BlackHole/Loopback) undefined | VT-2 | Document required system-audio source; bundle setup helper or use macOS 14.4+ Tap API |
| G-D11 | H.264 transcode flags (`+faststart`, baseline profile) for mobile | VT-2 | §11 mitigation row: explicit ffmpeg args for shared exports |
| G-D12 | `data_dir` cross-platform path semantics (Windows `%USERPROFILE%`) | VT-4 | §10 spec: tilde-expanded on POSIX, `%USERPROFILE%` on Windows |
| G-D13 | Ollama-model discovery: `GET /api/tags` or freehand | VT-1 | Settings panel calls `/api/tags`; fallback freehand input |
| G-D14 | Vision-LLM rate-limit UX (matches §13) | VT-4 | Exponential backoff, surface 429 with "retry in N s" toast |

### COSMETIC

- G-C1 — Disabled share-button needs tooltip ("Configure storage in Settings →") (VT-1)
- G-C2 — Separate "Export to disk" flow (only "Share" exists) (VT-1)
- G-C3 — Multi-track audio default-track behavior in browser `<video>` (VT-2)
- G-C4 — Q&A history schema: per-backend folder vs shared; tool-use events captured? (VT-3)
- G-C5 — Uninstall cleanup of `data_dir` + keychain entries (VT-4)
- G-C6 — Vision-coords mapping (model normalized → screen pixel) (VT-1)

---

## Spec coverage union

| Section | Hit by | Coverage status |
|---|---|---|
| §1 Context | — | Descriptive, not testable |
| §2 Goals/Non-goals | — | Not exercised |
| §3 Architecture | VT-4 | Light — first-run gap surfaced |
| §4 Recording | VT-1, VT-2, VT-3 | Heavy — multiple BLOCKING |
| **§5 Webcam overlay** | — | **NOT EXERCISED — recommend VT-5** |
| §6 Annotation | VT-1, VT-2, VT-4 | Heavy — many DEGRADED + 1 BLOCKING |
| §7 Agent backends | VT-3 | Single deep test — multiple BLOCKING |
| §8 Sharing | VT-1, VT-2, VT-4 | Heavy |
| §9 Distribution | VT-4 | Light |
| §10 Configuration | VT-1, VT-2, VT-4 | Heavy |
| §11 Risk register | VT-1, VT-2 | Light |
| §12 Decisions | — | Historical record, not testable |
| §13 Open questions | VT-1, VT-3, VT-4 | Two open Qs confirmed as gaps in real scenarios |

**Recommendation:** add VT-5 covering §5 (Webcam overlay) — talking-head record, drag-to-reposition, mirror toggle, baked-into-MP4 trade-off. Without it, §5 is a blind spot.

---

## VT-5 — Diego, talking-head screencaster (added post-Critic, addresses §5 coverage gap)

> **Post-pivot annotation (2026-05-01):** the implementation pivoted from Tauri 2 to `iced` after VT-5 was written. The pivot **resolves G-V1 (WebView2 permission semantics — N/A, no webview), G-V5 (BGRA vs NV12 wire format — moot, normalized in-process by `nokhwa`), and G-V6 (WebSocket vs Tauri IPC — moot, no IPC because no webview).** Questions about `getUserMedia` / WKWebView / WebView2 permission flow below are reframed: the same TCC / Info.plist / entitlement concerns still apply, but they target `nokhwa`'s AVFoundation / Media Foundation calls, not the webview. **G-V2 (PiP drag-vs-bake), G-V3 (mask filter), G-V4 (disconnect) remain in scope and are addressed in §5 post-pivot.**

**Persona:** Diego — DevRel engineer who records 3-minute "tip of the day" videos with face overlay. Records on both his MacBook (work) and his Windows desktop (home) so he expects parity. Streams to YouTube monthly.

**Environment:** macOS 14.5 (work) and Windows 11 (home) · external Logitech C920 on Windows, built-in FaceTime HD on macOS · Anthropic vision configured · self-hosted RustFS for sharing.

**Goal:**
> "Record a 3-minute tip with my face in the bottom-right corner, drag to bottom-left if it covers something important, then share — and have it look the same whether I'm on my Mac or my PC."

**Steps & questions:**

1. **First launch on macOS — webcam permission flow.** §5.
   - Q1.1 **GAP** — §5 currently claims "no platform glue" for `getUserMedia`. Reality: WKWebView in Tauri 2 requires `NSCameraUsageDescription` in `Info.plist` AND the host app to be camera-entitled. If the Tauri build config is missing either, `getUserMedia` rejects with `NotAllowedError` without surfacing an OS prompt — Diego sees a blank webcam preview and has no idea why. Spec must list the build-config requirements.
   - Q1.2 GAP — when Diego clicks the webcam toggle on first launch, does the macOS TCC permission prompt fire? Or does it fire only when `getUserMedia` is actually invoked (after the toggle is on)? Different placement = different UX.
   - Q1.3 GAP — if Diego previously denied camera access in macOS System Settings, the webcam toggle in the app will appear to work but `getUserMedia` rejects. What's the fallback UI? "Grant access in System Settings →" link?

2. **Same flow on Windows — WebView2 permission semantics differ.** §5.
   - Q2.1 **GAP** — §5 says permission "fails gracefully if denied," but on Windows the WebView2 permission dialog renders **inside the webview viewport**, not the Tauri host shell. The Tauri permission events do NOT fire — frontend code must observe the `getUserMedia` promise. Spec doesn't say which side handles this.
   - Q2.2 GAP — Logitech C920 exposes 8+ resolutions and frame rates. The constraint object handed to `getUserMedia` is unspecified — does Jarvis Studio request `1280×720@30`, `640×480@30`, or accept whatever default? The recorder UI shows no resolution selector for webcam.

3. **Position & size of the PiP overlay.** §5.
   - Q3.1 GAP — §5 says "drag to reposition before record" but doesn't say what the dragging affects: the *preview* (frontend canvas) only, or the *baked overlay coordinates* sent to ffmpeg? If only the preview, recording bakes from the default position — UX bug. If both, where is the position serialized — config file, session sidecar, both?
   - Q3.2 GAP — the ffmpeg command in §5 is `[1:v]scale=240:-1[pip]; [0:v][pip]overlay=W-w-20:H-h-20`. This hard-codes bottom-right (W-w-20, H-h-20). What command runs when Diego drags to bottom-left? Spec doesn't show the variants.
   - Q3.3 GAP — circle shape (default per §5 table) requires a mask. The ffmpeg filter chain shows none — `geq` for circle masking is slow at 30fps; alpha-merging a static circle PNG is the standard. Spec doesn't specify the masking technique.

4. **Mid-record — Diego's webcam disconnects (cable jolted on Windows).** §5.
   - Q4.1 GAP — webcam stream ends mid-record. Does the recording continue without the PiP for the remainder, or does ffmpeg's filter graph error and crash the whole encode? The §4 concurrency model handles audio/transcription faults but doesn't address webcam-stream death.
   - Q4.2 GAP — when scene resumes and webcam reconnects, does PiP resume? Or is it baked-off for the rest of the session? UX needs a decision.

5. **Cross-platform output parity.** §5.
   - Q5.1 GAP — Logitech on Windows emits NV12 by default; FaceTime HD emits BGRA. The WebSocket sidechannel (or Tauri IPC) carrying frames to Rust must normalize, or ffmpeg's filter graph must handle both. Spec is silent on the wire format between webview and Rust core.
   - Q5.2 **AMBIGUITY** — §5 says WebSocket sidechannel; the architect review flagged this as "wrong channel" because (a) bound localhost ports trigger macOS firewall prompts and Windows Defender SmartScreen warnings users read as malware signals, (b) Tauri's native IPC can pass raw `ArrayBuffer`. Decide: WebSocket or Tauri IPC. (Not deciding = the user-visible firewall dialog ships with the app.)

| Spec Section | Steps | Status |
|---|---|---|
| §5 Webcam overlay | 1, 2, 3, 4, 5 | Heavy — multiple GAPS in permission flow, dragging semantics, masking technique, disconnect handling, wire format |
| §4 Concurrency | 4 | Webcam-stream-death not covered by existing fault-tolerance spec |

### Aggregate gaps from VT-5 (added to main report)

| ID | Gap | Severity | Recommended fix |
|---|---|---|---|
| **G-V1** | §5: Tauri build-config requirements for webcam (Info.plist, entitlements, WebView2 permission semantics) not documented | Important | Add subsection "Platform glue (macOS / Windows)" enumerating exact config — already partially added in §5 update post-Critic |
| **G-V2** | §5: PiP dragging semantics — preview-only vs baked-overlay position serialization undefined | Important | Spec: position is per-session, sticky last-used, written to config; ffmpeg overlay coords are derived at record-start time |
| **G-V3** | §5: ffmpeg filter chain for circle/rounded-rect masking not specified | Soft | Use static alpha-mask PNG composited via `overlay`, not `geq` |
| **G-V4** | §5: webcam disconnect mid-record handling undefined | Important | Webcam fork is fail-open like transcription — recording continues sans PiP, surface `webcam_disconnected` event |
| **G-V5** | §5: webcam-frame wire format (BGRA vs NV12 vs YUV420) between webview and Rust unspecified | Soft | Normalize in webview before send (canvas → ImageBitmap → uniform pixel format), or pin one format and reject others |
| **G-V6** | §5: WebSocket vs Tauri IPC sidechannel — firewall-prompt risk on macOS / Defender SmartScreen on Windows | Important | Decide before implementation; favor Tauri IPC custom URI scheme to avoid OS-level network prompts |
