@preconcurrency import AVFoundation
import SwiftUI
import AIKit
import CaptureKit
import DictationKit
import KeyboardShortcuts

// MARK: - SettingsView

/// Top-level Settings window content. Embedded in the @main App's `Settings`
/// scene — opens automatically on Cmd+, or via the menu-bar item action.
@available(macOS 14.0, *)
struct SettingsView: View {

    @Bindable var settings: AppSettings

    var body: some View {
        TabView {
            TranscriptionTab(settings: settings)
                .tabItem { Label("Transcription", systemImage: "waveform") }

            AIProvidersTab(settings: settings)
                .tabItem { Label("AI Providers", systemImage: "sparkles") }

            DictationTab(settings: settings)
                .tabItem { Label("Dictation", systemImage: "keyboard") }

            VoiceNoteTab(settings: settings)
                .tabItem { Label("Voice Note", systemImage: "note.text") }

            HotkeysTab()
                .tabItem { Label("Hotkeys", systemImage: "command") }

            SharingTab(settings: settings)
                .tabItem { Label("Sharing", systemImage: "square.and.arrow.up") }

            PrivacyTab()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 360)
    }
}

// MARK: - Transcription tab

@available(macOS 14.0, *)
private struct TranscriptionTab: View {
    @Bindable var settings: AppSettings

    @State private var deepgramTestState: ConnectionTestState = .idle

    var body: some View {
        Form {
            Section("Recording mode") {
                Picker("Mode", selection: $settings.recordingMode) {
                    ForEach(AppSettings.RecordingMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                if settings.recordingMode == .audioAndScreen {
                    Text("Records the entire screen + system audio at 24 fps. Requires Screen Recording permission. The first time you start a recording, macOS will prompt you to grant access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Capture system audio alongside mic", isOn: $settings.systemAudioEnabled)
                Text("Mixes Spotify, video calls, browser audio etc. into the recording. Off by default; toggle on for meeting / call capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System audio source") {
                SystemAudioSourcePicker(settings: settings)
            }

            Section("Webcam bubble (Loom-style)") {
                CameraBubbleSettings(settings: settings)
            }

            if isMacOS14_4OrLater() {
                Section("System audio source — per-process tap (macOS 14.4+)") {
                    Toggle("Capture only specific apps (per-process Core Audio Tap)", isOn: $settings.useProcessTap)
                    if settings.useProcessTap {
                        TextField("Bundle IDs (comma-separated)", text: $settings.processTapBundleIDs, axis: .vertical)
                            .lineLimit(3, reservesSpace: true)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                        Text("Examples: us.zoom.xos, com.microsoft.teams2, com.tinyspeck.slackmacgap, com.google.Chrome, com.apple.Safari. Apps not running at record time are silently skipped. Falls back to whole-system mixdown on tap failure.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Off: ScreenCaptureKit captures whole-system audio, including unrelated apps (Spotify, notifications). On: only the bundle IDs you list are recorded — quieter, more private.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Storage profile") {
                Picker("Profile", selection: $settings.storageProfile) {
                    ForEach(AppSettings.StorageProfile.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.storageProfile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Picking a profile rewrites the codec and bitrate fields below. Tweak them after if you need finer control.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Audio codec") {
                Picker("Codec", selection: $settings.audioCodec) {
                    ForEach(AppSettings.AudioCodec.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Bitrate (kbps)")
                    Spacer()
                    TextField("kbps", value: Binding(
                        get: { settings.audioBitrate / 1000 },
                        set: { settings.audioBitrate = $0 * 1000 }
                    ), format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Sample rate")
                    Spacer()
                    Picker("", selection: $settings.audioSampleRate) {
                        Text("48 kHz").tag(48_000)
                        Text("24 kHz (voice)").tag(24_000)
                        Text("16 kHz (voice, very compact)").tag(16_000)
                    }
                    .frame(width: 240)
                    .labelsHidden()
                }
                Text("Opus falls back to HE-AAC inside .m4a containers (Opus muxing requires a different container).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Video codec (when Audio + Screen mode)") {
                Toggle("Use HEVC (H.265)", isOn: $settings.videoUseHEVC)
                HStack {
                    Text("Bitrate (Mbps)")
                    Spacer()
                    TextField("Mbps", value: Binding(
                        get: { Double(settings.videoBitrate) / 1_000_000 },
                        set: { settings.videoBitrate = Int($0 * 1_000_000) }
                    ), format: .number.precision(.fractionLength(1)))
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }
                Text("HEVC is hardware-accelerated on all Apple Silicon Macs and is roughly 50% smaller than H.264 at equivalent visual quality.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Default provider") {
                Picker("Provider", selection: $settings.transcriptionProvider) {
                    ForEach(AppSettings.TranscriptionProviderChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                Text(footerForProvider(settings.transcriptionProvider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcript LLM cleanup") {
                Toggle("Clean transcript with LLM after transcription", isOn: $settings.transcriptCleanupEnabled)
                Text("Runs the raw ASR output through your configured LLM (AI Providers tab) to fix mishearing — wrong numbers, names, technical terms, doubled words, missing punctuation. Speaker voice and timing are preserved. Adds ~1–3 s + a small LLM cost per recording. Saved separately as `transcript.raw.txt` for audit. Cleanup failures are non-fatal — raw transcript stays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Deepgram") {
                APIKeyField(
                    title: "API key",
                    text: $settings.deepgramApiKey,
                    onCommit: { settings.commit(.deepgram, value: settings.deepgramApiKey) }
                )
                Link("Get a Deepgram API key", destination: URL(string: "https://console.deepgram.com/")!)
                    .font(.caption)
                ConnectionTestRow(label: "Test connection", state: deepgramTestState) {
                    Task { await testDeepgram() }
                }
            }

            Section("OpenAI (Whisper transcription + GPT LLM)") {
                APIKeyField(
                    title: "API key",
                    text: $settings.openaiApiKey,
                    onCommit: { settings.commit(.openaiWhisper, value: settings.openaiApiKey) }
                )
                Text("This key is shared by Whisper transcription and the OpenAI LLM provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Get an OpenAI API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.caption)
            }

            Section("Gemini (multimodal audio)") {
                APIKeyField(
                    title: "API key",
                    text: $settings.geminiApiKey,
                    onCommit: { settings.commit(.gemini, value: settings.geminiApiKey) }
                )
                Text("Used when 'Default provider' is set to Gemini. Sends the recording's audio.m4a directly to Gemini 2.5 Flash, which returns transcript + segments in one shot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Get a Gemini API key (Google AI Studio)", destination: URL(string: "https://aistudio.google.com/apikey")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    /// Per-process Core Audio Tap requires macOS 14.4+. We use ProcessInfo here
    /// rather than `#available` so the SwiftUI conditional can render dynamically.
    private func isMacOS14_4OrLater() -> Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion > 14 { return true }
        return v.majorVersion == 14 && v.minorVersion >= 4
    }

    private func footerForProvider(_ choice: AppSettings.TranscriptionProviderChoice) -> String {
        switch choice {
        case .deepgram:
            return "Deepgram streams partial transcripts during recording (live). Best fit for Dictation Mode."
        case .openaiWhisper:
            return "OpenAI Whisper transcribes after the recording stops (batch). Higher latency, broad language coverage."
        case .gemini:
            return "Google Gemini ingests the audio file directly via its multimodal API. One round-trip = transcript + segments. Inline upload caps at ~18 MB (~3–4 h of HE-AAC mono); longer recordings fail until we wire the resumable File API."
        case .openrouterAudio:
            return "Routes audio through OpenRouter to a multimodal model (defaults to google/gemini-2.5-flash, configurable in AI Providers → OpenRouter model). Same OpenRouter API key as LLM cleanup. Inline cap ~18 MB. Use this if you want one billing relationship for everything."
        }
    }

    /// Minimal probe: GET /v1/projects with Token auth. 200 → success.
    private func testDeepgram() async {
        deepgramTestState = .testing
        let key = settings.deepgramApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            deepgramTestState = .failed("No API key set")
            return
        }
        var req = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                deepgramTestState = http.statusCode == 200 ? .success : .failed("HTTP \(http.statusCode)")
            } else {
                deepgramTestState = .failed("Non-HTTP response")
            }
        } catch {
            deepgramTestState = .failed(error.localizedDescription)
        }
    }
}

// MARK: - AI Providers tab

@available(macOS 14.0, *)
private struct AIProvidersTab: View {
    @Bindable var settings: AppSettings

    // Per-provider connection-test state; kept local so they don't pollute AppSettings.
    @State private var anthropicTestState: ConnectionTestState = .idle
    @State private var openaiTestState: ConnectionTestState = .idle
    @State private var ollamaTestState: ConnectionTestState = .idle
    @State private var openrouterTestState: ConnectionTestState = .idle

    var body: some View {
        Form {
            Section("Default LLM provider") {
                Picker("Provider", selection: $settings.llmProvider) {
                    ForEach(AppSettings.LLMProviderChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Anthropic Claude") {
                APIKeyField(
                    title: "API key",
                    text: $settings.anthropicApiKey,
                    onCommit: { settings.commit(.anthropic, value: settings.anthropicApiKey) }
                )
                Link("Get an Anthropic API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)
                ConnectionTestRow(label: "Test connection", state: anthropicTestState) {
                    Task { await testAnthropic() }
                }
            }

            Section("OpenAI") {
                APIKeyField(
                    title: "API key",
                    text: $settings.openaiApiKey,
                    onCommit: { settings.commit(.openaiWhisper, value: settings.openaiApiKey) }
                )
                Text("Same key as the Whisper transcription field — managed in one place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ConnectionTestRow(label: "Test connection", state: openaiTestState) {
                    Task { await testOpenAI() }
                }
            }

            Section("OpenRouter") {
                APIKeyField(
                    title: "API key",
                    text: $settings.openrouterApiKey,
                    onCommit: { settings.commit(.openrouter, value: settings.openrouterApiKey) }
                )
                HStack {
                    Text("Default model")
                    Spacer()
                    TextField("anthropic/claude-3.5-sonnet", text: $settings.openrouterModel)
                        .frame(width: 240)
                        .textFieldStyle(.roundedBorder)
                }
                Text("OpenRouter routes to many providers via vendor/model identifiers (e.g. openai/gpt-4o-mini, anthropic/claude-3.5-sonnet, meta-llama/llama-3.3-70b).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Get an OpenRouter API key", destination: URL(string: "https://openrouter.ai/keys")!)
                    .font(.caption)
                ConnectionTestRow(label: "Test connection", state: openrouterTestState) {
                    Task { await testOpenRouter() }
                }
            }

            Section("Ollama (local)") {
                HStack {
                    Text("Endpoint")
                    Spacer()
                    TextField("http://localhost:11434", text: $settings.ollamaEndpoint)
                        .frame(width: 240)
                        .textFieldStyle(.roundedBorder)
                }
                Picker("API mode", selection: $settings.ollamaApiMode) {
                    ForEach(AppSettings.OllamaAPIMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Default model")
                    Spacer()
                    TextField("qwen2.5:14b", text: $settings.ollamaModel)
                        .frame(width: 200)
                        .textFieldStyle(.roundedBorder)
                }
                APIKeyField(
                    title: "Bearer token (optional)",
                    text: $settings.ollamaBearer,
                    onCommit: { settings.commit(.ollama, value: settings.ollamaBearer) }
                )
                Text("HTTP only allowed for localhost / 10.x / 172.16-31.x / 192.168.x. Use HTTPS for any other host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ConnectionTestRow(label: "Test connection", state: ollamaTestState) {
                    Task { await testOllama() }
                }
            }

            Section("Cost cap") {
                HStack {
                    Text("Per-session limit")
                    Spacer()
                    TextField("USD", value: $settings.costCapUSD, format: .currency(code: "USD"))
                        .frame(width: 100)
                        .textFieldStyle(.roundedBorder)
                }
                Text("AI summary requests above this estimate are silently skipped. Default $1.00.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Semantic search") {
                Toggle("Enable embedding-based semantic search", isOn: $settings.semanticSearchEnabled)
                Text("On finalize, sessions are embedded via OpenAI text-embedding-3-small (~$0.02 per 1M tokens) and stored locally. Searches augment FTS5 with cosine-similar matches. Requires an OpenAI API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Default summary language") {
                Picker("Language", selection: $settings.summaryLanguage) {
                    Text("Auto detected").tag("auto")
                    Text("English").tag("en")
                    Text("Українська").tag("uk")
                    Text("Русский").tag("ru")
                    Text("Français").tag("fr")
                    Text("Deutsch").tag("de")
                    Text("Español").tag("es")
                }
                Text("This is the default. Each recording can override at start time (Phase B Week 1 Day 4 — UI lands later).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Connection probe helpers

    /// Minimal probe: POST /v1/messages with max_tokens=5. 200 → success, else fail.
    private func testAnthropic() async {
        anthropicTestState = .testing
        let key = settings.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            anthropicTestState = .failed("No API key set")
            return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-4-6",
            "max_tokens": 5,
            "messages": [["role": "user", "content": "hi"]],
        ])
        anthropicTestState = await probe(request: req)
    }

    /// Minimal probe: GET /v1/models with Bearer auth. 200 → success.
    private func testOpenAI() async {
        openaiTestState = .testing
        let key = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            openaiTestState = .failed("No API key set")
            return
        }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        openaiTestState = await probe(request: req)
    }

    /// Minimal probe: GET /api/tags on the configured Ollama endpoint. Surfaces
    /// the RFC1918-validation error inline if the user typed a public-IP HTTP URL.
    private func testOllama() async {
        ollamaTestState = .testing
        guard let url = URL(string: settings.ollamaEndpoint) else {
            ollamaTestState = .failed("Invalid URL")
            return
        }
        // Re-use the provider-level RFC1918 check so the error message matches reality.
        do {
            try OllamaProvider.validate(endpoint: url)
        } catch {
            ollamaTestState = .failed("Endpoint not allowed (use HTTPS or RFC1918)")
            return
        }
        var req = URLRequest(url: url.appendingPathComponent("api/tags"))
        req.httpMethod = "GET"
        let bearer = settings.ollamaBearer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bearer.isEmpty {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        ollamaTestState = await probe(request: req)
    }

    /// Minimal probe: GET /api/v1/models on OpenRouter. 200 → success.
    private func testOpenRouter() async {
        openrouterTestState = .testing
        let key = settings.openrouterApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            openrouterTestState = .failed("No API key set")
            return
        }
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        openrouterTestState = await probe(request: req)
    }

    /// Fires the request and maps the HTTP status to a ConnectionTestState.
    private func probe(request: URLRequest) async -> ConnectionTestState {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    return .success
                } else {
                    return .failed("HTTP \(http.statusCode)")
                }
            }
            return .failed("Non-HTTP response")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - ConnectionTestState

/// State machine for a single Test-connection button.
private enum ConnectionTestState: Equatable {
    case idle
    case testing
    case success
    case failed(String)
}

// MARK: - ConnectionTestRow

/// A row with a "Test connection" button and a small inline status indicator.
@available(macOS 14.0, *)
private struct ConnectionTestRow: View {
    let label: String
    let state: ConnectionTestState
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(label, action: action)
                .disabled(state == .testing)
            switch state {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let msg):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Dictation tab

@available(macOS 14.0, *)
private struct DictationTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Hotkey") {
                Text("Press and hold the global hotkey to dictate. Release to paste a cleaned transcript into the focused text field.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Default: ⌘⇧D — change in System Settings → Keyboard → Shortcuts → App Shortcuts (custom binding lands in v1.1).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cleanup") {
                Toggle("Run LLM cleanup pass before pasting", isOn: $settings.dictationLLMCleanup)
                Text("Uses the configured AI Provider (Anthropic / OpenAI / Ollama) to fix punctuation, casing, and remove disfluencies. Adds ~1–2 s latency. Off = paste raw Whisper transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Limits") {
                Stepper(value: $settings.dictationMaxSeconds, in: 10...120, step: 5) {
                    Text("Max utterance: \(settings.dictationMaxSeconds) seconds")
                }
                Text("Hard cap on a single dictation press-and-hold. Hitting the cap stops the recording automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permission") {
                Text("First press triggers a macOS Accessibility permission prompt. Grant in System Settings → Privacy & Security → Accessibility, then quit + relaunch Jarvis Note for the trust to take effect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Voice Note tab

@available(macOS 14.0, *)
private struct VoiceNoteTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Default note kind") {
                Picker("Kind", selection: $settings.voiceNoteKind) {
                    ForEach(PromptTemplates.VoiceNoteKind.allCases, id: \.rawValue) { kind in
                        Text(kindDisplay(kind)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                Text(footerForKind(settings.voiceNoteKind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hotkey") {
                Text("Press ⌘⇧N to start a Voice Note. Press again to stop. The recording posts to the configured LLM provider with the note kind selected above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func kindDisplay(_ kind: PromptTemplates.VoiceNoteKind) -> String {
        switch kind {
        case .freeform: return "Freeform"
        case .task: return "Task"
        case .journal: return "Journal"
        case .checklist: return "Checklist"
        }
    }

    private func footerForKind(_ kind: PromptTemplates.VoiceNoteKind) -> String {
        switch kind {
        case .freeform: return "Light cleanup; preserves the speaker's voice."
        case .task: return "Single actionable task with title, body, and optional due / tags."
        case .journal: return "First-person journal entry with a date header."
        case .checklist: return "Bulleted checklist (`- [ ]` items). Drops pure observations."
        }
    }
}

// MARK: - Hotkeys tab

@available(macOS 14.0, *)
private struct HotkeysTab: View {
    var body: some View {
        Form {
            Section("Global hotkeys") {
                KeyboardShortcuts.Recorder("Meeting record toggle", name: .toggleMeeting)
                KeyboardShortcuts.Recorder("Voice Note toggle", name: .toggleVoiceNote)
                KeyboardShortcuts.Recorder("Open Library", name: .openLibrary)
                KeyboardShortcuts.Recorder("Dictation (push-to-talk)", name: .dictation)
            }

            Section("Defaults") {
                Text("⌘⇧R — Meeting record · ⌘⇧N — Voice Note · ⌘⇧L — Library · ⌘⇧D — Dictation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sharing tab

@available(macOS 14.0, *)
private struct SharingTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("S3-compatible upload") {
                HStack {
                    Text("Endpoint")
                    Spacer()
                    TextField("https://s3.amazonaws.com", text: $settings.s3Endpoint)
                        .frame(width: 280)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Region")
                    Spacer()
                    TextField("us-east-1", text: $settings.s3Region)
                        .frame(width: 140)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Bucket")
                    Spacer()
                    TextField("jarvis-recordings", text: $settings.s3Bucket)
                        .frame(width: 200)
                        .textFieldStyle(.roundedBorder)
                }
                APIKeyField(
                    title: "Access Key ID",
                    text: $settings.s3AccessKey,
                    onCommit: { settings.commit(.s3AccessKey, value: settings.s3AccessKey) }
                )
                APIKeyField(
                    title: "Secret Access Key",
                    text: $settings.s3SecretKey,
                    onCommit: { settings.commit(.s3SecretKey, value: settings.s3SecretKey) }
                )
                Stepper(value: $settings.s3PresignTTLHours, in: 1...168) {
                    Text("Presigned link TTL: \(settings.s3PresignTTLHours)h")
                }
                Text("Works with AWS S3, Cloudflare R2 (region: auto), Backblaze B2, MinIO, RustFS — any S3-compatible endpoint. Sig V4 auth. Recipients open the presigned URL in a browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy tab

@available(macOS 14.0, *)
private struct PrivacyTab: View {
    /// Bumped on every appear and after each "Refresh" tap so the cached
    /// permission badges re-read CGPreflightScreenCaptureAccess /
    /// AVCaptureDevice.authorizationStatus / AXIsProcessTrusted.
    @State private var refreshTick: Int = 0
    @State private var confirmReset: Bool = false
    @State private var resetResult: String? = nil

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRow(
                    title: "Microphone",
                    systemImage: "mic.fill",
                    detail: "Required for every recording — captures your voice.",
                    status: micStatusText,
                    granted: micGranted,
                    requestLabel: "Request",
                    onRequest: { Task { _ = await PermissionsHelper.requestMicAccess(); refreshTick &+= 1 } },
                    onOpen: { PermissionsHelper.openMicSettings() }
                )

                PermissionRow(
                    title: "Screen Recording",
                    systemImage: "rectangle.dashed.badge.record",
                    detail: "Required for Audio + Screen mode and for system-audio capture (e.g. recording call participants).",
                    status: screenStatusText,
                    granted: PermissionsHelper.screenRecordingGranted(),
                    requestLabel: "Request",
                    onRequest: {
                        PermissionsHelper.requestScreenRecordingAccess()
                        refreshTick &+= 1
                    },
                    onOpen: { PermissionsHelper.openScreenRecordingSettings() }
                )

                PermissionRow(
                    title: "Accessibility",
                    systemImage: "accessibility",
                    detail: "Only needed for Dictation Mode — pastes the cleaned transcript into the focused text field.",
                    status: axStatusText,
                    granted: PermissionsHelper.accessibilityGranted(),
                    requestLabel: "Open Settings",
                    onRequest: { PermissionsHelper.openAccessibilitySettings() },
                    onOpen: { PermissionsHelper.openAccessibilitySettings() }
                )

                PermissionRow(
                    title: "Camera",
                    systemImage: "video.fill",
                    detail: "Only needed for the Loom-style webcam bubble during Audio + Screen recordings.",
                    status: cameraStatusText,
                    granted: PermissionsHelper.cameraGranted(),
                    requestLabel: "Request",
                    onRequest: { Task { _ = await PermissionsHelper.requestCameraAccess(); refreshTick &+= 1 } },
                    onOpen: { PermissionsHelper.openCameraSettings() }
                )

                HStack {
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        Label("Reset all permissions", systemImage: "arrow.counterclockwise.circle")
                    }
                    .help("Runs `tccutil reset All dev.jarvisnote.studio` so macOS will re-prompt fresh on the next recording. Use this when you granted access but the app still refuses (cdhash mismatch from rebuild).")

                    Spacer()
                    Button("Refresh status") { refreshTick &+= 1 }
                        .buttonStyle(.borderless)
                }

                Text("Tip: ad-hoc-signed dev builds change their code-signature hash on every rebuild, which can leave a stale TCC entry that shows as granted in System Settings but isn't honored at runtime. Click **Reset all permissions** to clear the slate, then re-grant on the next macOS prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .id(refreshTick)
            .confirmationDialog(
                "Reset all JarvisNote permissions?",
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    runTCCReset()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Microphone, Screen Recording, and Accessibility grants for `dev.jarvisnote.studio` will be cleared. macOS will prompt for them again the next time you start recording. JarvisNote will need to be quit & relaunched after the prompts.")
            }
            .alert("Permissions reset", isPresented: Binding(
                get: { resetResult != nil },
                set: { if !$0 { resetResult = nil } }
            )) {
                Button("OK", role: .cancel) { resetResult = nil }
            } message: {
                Text(resetResult ?? "")
            }

            Section("How Jarvis Note handles your audio") {
                Text("""
                Recordings stay on your Mac at:

                ~/Library/Application Support/JarvisNote/recordings/

                Transcription and AI summarisation are cloud-only — every recorded \
                second of audio is uploaded to the provider you configure on the \
                Transcription / AI Providers tabs. There is no on-device transcription \
                in v1.0.

                If you do not want a recording leaving your machine, do not start it.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            }

            Section("Screen recording") {
                Text("""
                When "Audio + Screen" mode is enabled, Jarvis Note captures your \
                entire display alongside audio and saves a screen.mp4 sidecar next \
                to the audio file. Screen content is used locally for vision-chat \
                frame extraction — it is never uploaded to any cloud service. \
                macOS will request Screen Recording permission on the first recording.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshTick &+= 1 }
    }

    // MARK: - Status helpers

    private var micGranted: Bool {
        PermissionsHelper.micAuthStatus() == .authorized
    }

    private var micStatusText: String {
        switch PermissionsHelper.micAuthStatus() {
        case .authorized: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    private var screenStatusText: String {
        PermissionsHelper.screenRecordingGranted() ? "Granted" : "Not granted"
    }

    private var axStatusText: String {
        PermissionsHelper.accessibilityGranted() ? "Granted" : "Not granted"
    }

    private var cameraStatusText: String {
        switch PermissionsHelper.cameraAuthStatus() {
        case .authorized: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    /// Spawn `/usr/bin/tccutil reset All dev.jarvisnote.studio` and report
    /// the verdict via the alert. Runs synchronously on a background queue so
    /// SwiftUI doesn't stall during the ~50ms IPC. No admin needed — tccutil
    /// works at the user-level for app-scoped resets.
    private func runTCCReset() {
        let bundleID = "dev.jarvisnote.studio"
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", "All", bundleID]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
                task.waitUntilExit()
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Task { @MainActor in
                    if task.terminationStatus == 0 {
                        resetResult = "All Microphone, Screen Recording, and Accessibility entries for \(bundleID) were cleared. Quit JarvisNote and re-launch from /Applications, then start a recording — macOS will prompt fresh for each permission."
                    } else {
                        resetResult = "tccutil exited with status \(task.terminationStatus). Output:\n\(output.isEmpty ? "<empty>" : output)"
                    }
                    refreshTick &+= 1
                }
            } catch {
                Task { @MainActor in
                    resetResult = "Could not run tccutil: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// One row per TCC permission. Status badge + Request + Open System Settings.
@available(macOS 14.0, *)
private struct PermissionRow: View {
    let title: String
    let systemImage: String
    let detail: String
    let status: String
    let granted: Bool
    let requestLabel: String
    let onRequest: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.body.weight(.medium))
                Spacer()
                StatusBadge(text: status, granted: granted)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(requestLabel, action: onRequest)
                    .buttonStyle(.bordered)
                Button("Open System Settings", action: onOpen)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

@available(macOS 14.0, *)
private struct StatusBadge: View {
    let text: String
    let granted: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(granted ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
            )
            .foregroundStyle(granted ? Color.green : Color.orange)
    }
}

// MARK: - APIKeyField

/// SecureField with a Show/Hide eye and a Save button that commits to Keychain.
@available(macOS 14.0, *)
private struct APIKeyField: View {
    let title: String
    @Binding var text: String
    let onCommit: () -> Void

    @State private var revealed = false

    var body: some View {
        HStack {
            Group {
                if revealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()

            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealed ? "Hide" : "Show")

            Button("Save", action: onCommit)
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - SystemAudioSourcePicker

/// Picker for the system-audio source (Settings → Transcription).
///
/// "Default (ScreenCaptureKit)" reads system audio via SCStream — captures
/// whatever speakers play. The downside: if you record without headphones,
/// the mic picks up the speakers' output, doubling the recorded audio.
///
/// Picking a virtual loopback device (BlackHole 2ch / Loopback) lets the user
/// route system audio through a software cable that the mic doesn't hear.
/// Setup: install BlackHole (`brew install blackhole-2ch`), in Audio MIDI Setup
/// create a Multi-Output Device (BlackHole + headphones), set system output
/// to it, then pick BlackHole here. Echo gone.
@available(macOS 14.0, *)
private struct SystemAudioSourcePicker: View {
    @Bindable var settings: AppSettings
    @State private var devices: [AudioInputDevice] = []
    @State private var refreshTick: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Source", selection: $settings.systemAudioDeviceUID) {
                Text("Default (ScreenCaptureKit)").tag("")
                if !devices.isEmpty {
                    Divider()
                    ForEach(devices) { device in
                        HStack {
                            Image(systemName: device.isVirtualLoopback ? "waveform.path.ecg" : "mic")
                                .foregroundStyle(device.isVirtualLoopback ? .green : .secondary)
                            Text(device.name)
                            if device.isVirtualLoopback {
                                Text("loopback").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(device.uid)
                    }
                }
            }
            .id(refreshTick)

            HStack(spacing: 8) {
                Button("Refresh device list") {
                    devices = AudioInputDevice.fresh()
                    refreshTick &+= 1
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                if !settings.systemAudioDeviceUID.isEmpty,
                   !devices.contains(where: { $0.uid == settings.systemAudioDeviceUID }) {
                    Label("Selected device not connected", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Default route is ScreenCaptureKit's whole-system mixdown — captures whatever your speakers play. Without headphones, the mic picks up that audio too, doubling voices in the recording.")
                Text("Pick a virtual loopback device (BlackHole 2ch, Loopback) to route system audio through a software cable the mic doesn't hear. Setup:")
                Text("1. brew install blackhole-2ch")
                    .font(.system(.caption2, design: .monospaced))
                Text("2. Audio MIDI Setup → Create Multi-Output Device with BlackHole + your real output (speakers/headphones)")
                Text("3. System Settings → Sound → Output: pick the Multi-Output Device")
                Text("4. Refresh this list and pick BlackHole below.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear {
            devices = AudioInputDevice.fresh()
        }
    }
}

@available(macOS 14.0, *)
private extension AudioInputDevice {
    /// Tiny convenience wrapper so the view can call `.fresh()` instead of
    /// touching the enumerator directly.
    static func fresh() -> [AudioInputDevice] {
        AudioDeviceEnumerator.inputDevices()
    }
}

// MARK: - CameraBubbleSettings

/// Toggle + camera-device picker + size slider for the Loom-style webcam
/// bubble. Lives inside the Transcription tab. The bubble itself is a
/// floating circular NSWindow that opens during Audio + Screen recordings;
/// ScreenCaptureKit captures the window as part of screen.mp4.
@available(macOS 14.0, *)
private struct CameraBubbleSettings: View {
    @Bindable var settings: AppSettings
    @State private var devices: [AVCaptureDevice] = []
    @State private var refreshTick: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show webcam bubble during Audio + Screen recordings", isOn: $settings.cameraBubbleEnabled)

            if settings.cameraBubbleEnabled {
                Picker("Camera", selection: $settings.cameraDeviceUID) {
                    Text("System default").tag("")
                    if !devices.isEmpty {
                        Divider()
                        ForEach(devices, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID)
                        }
                    }
                }
                .id(refreshTick)

                HStack {
                    Text("Size")
                    Slider(value: $settings.cameraBubbleSize, in: 120...400, step: 10)
                    Text("\(Int(settings.cameraBubbleSize)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }

                Button("Refresh camera list") {
                    devices = CameraBubble.availableDevices()
                    refreshTick &+= 1
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Text("Floating circular window with your front camera, draggable anywhere on screen. Captured by ScreenCaptureKit alongside the screen, so it lands inside `screen.mp4` automatically. Position and size are remembered between recordings. Camera permission is requested on first use.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            devices = CameraBubble.availableDevices()
        }
    }
}
