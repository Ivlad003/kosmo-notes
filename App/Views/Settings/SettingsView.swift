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
}

// MARK: - AI Providers tab

@available(macOS 14.0, *)
private struct AIProvidersTab: View {
    @Bindable var settings: AppSettings

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
