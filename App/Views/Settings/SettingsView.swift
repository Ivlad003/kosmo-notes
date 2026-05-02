import SwiftUI
import AIKit
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

            if isMacOS14_4OrLater() {
                Section("System audio source (macOS 14.4+)") {
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
    var body: some View {
        Form {
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
