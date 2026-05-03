import SwiftUI

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
