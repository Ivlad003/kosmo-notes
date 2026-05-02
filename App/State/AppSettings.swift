import Foundation
@preconcurrency import KeychainAccess
import Observation

// MARK: - AppSettings
//
// Reads / writes user-configurable settings:
//   - API keys (Keychain-backed, never written to disk in plain text)
//   - default transcription provider, default summary language
//
// The Keychain service name is locked to the bundle ID per design §13 —
// changing it post-ship would orphan all existing entries.

@available(macOS 14.0, *)
@Observable
@MainActor
final class AppSettings {

    // MARK: Keychain accounts

    enum KeychainAccount: String, CaseIterable {
        case deepgram = "deepgram.api_key"
        case openaiWhisper = "openai.api_key"           // shared between Whisper transcription + GPT LLM
        case anthropic = "anthropic.api_key"
    }

    enum TranscriptionProviderChoice: String, CaseIterable, Identifiable {
        case deepgram
        case openaiWhisper

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .deepgram: return "Deepgram"
            case .openaiWhisper: return "OpenAI Whisper"
            }
        }
    }

    enum LLMProviderChoice: String, CaseIterable, Identifiable {
        case anthropic
        case openai

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .anthropic: return "Anthropic Claude"
            case .openai: return "OpenAI"
            }
        }
    }

    enum RecordingMode: String, CaseIterable, Identifiable {
        case audioOnly
        case audioAndScreen

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .audioOnly: return "Audio only"
            case .audioAndScreen: return "Audio + Screen"
            }
        }
    }

    // MARK: UserDefaults-backed prefs (non-secret)

    private enum Defaults {
        static let transcriptionProvider = "transcriptionProvider"
        static let llmProvider = "llmProvider"
        static let summaryLanguage = "summaryLanguage"
        static let recordingMode = "recordingMode"
    }

    // MARK: Observable state — secrets read on demand from Keychain

    /// Mirror copies of the secrets so SwiftUI bindings have something to bind to.
    /// Saved to Keychain via `commit*` actions; never persisted to disk in plain text.
    var deepgramApiKey: String = ""
    var openaiApiKey: String = ""
    var anthropicApiKey: String = ""

    var transcriptionProvider: TranscriptionProviderChoice {
        didSet { UserDefaults.standard.set(transcriptionProvider.rawValue, forKey: Defaults.transcriptionProvider) }
    }
    var llmProvider: LLMProviderChoice {
        didSet { UserDefaults.standard.set(llmProvider.rawValue, forKey: Defaults.llmProvider) }
    }
    /// BCP-47 code (e.g. "en", "uk", "auto"). "auto" = no override.
    var summaryLanguage: String {
        didSet { UserDefaults.standard.set(summaryLanguage, forKey: Defaults.summaryLanguage) }
    }
    /// Whether new recordings include screen capture alongside audio.
    var recordingMode: RecordingMode {
        didSet { UserDefaults.standard.set(recordingMode.rawValue, forKey: Defaults.recordingMode) }
    }

    // MARK: Init

    private let keychain: Keychain

    init() {
        // Keychain service must match the bundle identifier.
        self.keychain = Keychain(service: "dev.jarvisnote.studio")
            .accessibility(.afterFirstUnlockThisDeviceOnly)
            .synchronizable(false)

        let providerRaw = UserDefaults.standard.string(forKey: Defaults.transcriptionProvider) ?? TranscriptionProviderChoice.openaiWhisper.rawValue
        self.transcriptionProvider = TranscriptionProviderChoice(rawValue: providerRaw) ?? .openaiWhisper

        let llmRaw = UserDefaults.standard.string(forKey: Defaults.llmProvider) ?? LLMProviderChoice.anthropic.rawValue
        self.llmProvider = LLMProviderChoice(rawValue: llmRaw) ?? .anthropic

        self.summaryLanguage = UserDefaults.standard.string(forKey: Defaults.summaryLanguage) ?? "auto"

        let modeRaw = UserDefaults.standard.string(forKey: Defaults.recordingMode) ?? RecordingMode.audioOnly.rawValue
        self.recordingMode = RecordingMode(rawValue: modeRaw) ?? .audioOnly

        loadKeysFromKeychain()
    }

    // MARK: Persistence

    private func loadKeysFromKeychain() {
        deepgramApiKey = (try? keychain.get(KeychainAccount.deepgram.rawValue)) ?? ""
        openaiApiKey = (try? keychain.get(KeychainAccount.openaiWhisper.rawValue)) ?? ""
        anthropicApiKey = (try? keychain.get(KeychainAccount.anthropic.rawValue)) ?? ""
    }

    /// Persist all currently-loaded values to Keychain. Empty strings are
    /// treated as "remove" so users can clear a key from the UI.
    func commitAllKeys() {
        commit(.deepgram, value: deepgramApiKey)
        commit(.openaiWhisper, value: openaiApiKey)
        commit(.anthropic, value: anthropicApiKey)
    }

    func commit(_ account: KeychainAccount, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try keychain.remove(account.rawValue)
            } else {
                try keychain.set(trimmed, key: account.rawValue)
            }
        } catch {
            // Surfacing per-key save errors goes through the UI banner once that exists.
            // For v0 we silently swallow — the next read will show whether it stuck.
        }
    }
}
