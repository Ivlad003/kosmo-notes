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
        case ollama = "ollama.bearer_token"             // optional; some self-hosted setups require auth
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
        case ollama

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .anthropic: return "Anthropic Claude"
            case .openai: return "OpenAI"
            case .ollama: return "Ollama (local)"
            }
        }
    }

    enum OllamaAPIMode: String, CaseIterable, Identifiable {
        case native
        case openaiCompat

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .native: return "Native (/api/chat)"
            case .openaiCompat: return "OpenAI-compat (/v1/chat/completions)"
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
        static let costCapUSD = "costCapUSD"
        static let ollamaEndpoint = "ollamaEndpoint"
        static let ollamaApiMode = "ollamaApiMode"
        static let ollamaModel = "ollamaModel"
        // ollamaBearer is Keychain-backed; this constant is the account name reference.
        static let ollamaBearer = "ollamaBearer"
        static let systemAudioEnabled = "systemAudioEnabled"
        static let dictationLLMCleanup = "dictationLLMCleanup"
        static let dictationMaxSeconds = "dictationMaxSeconds"
    }

    // MARK: Observable state — secrets read on demand from Keychain

    /// Mirror copies of the secrets so SwiftUI bindings have something to bind to.
    /// Saved to Keychain via `commit*` actions; never persisted to disk in plain text.
    var deepgramApiKey: String = ""
    var openaiApiKey: String = ""
    var anthropicApiKey: String = ""
    var ollamaBearer: String = ""   // optional bearer token for self-hosted Ollama frontends

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

    /// Per-session AI summary cost cap in USD. Requests estimated above this are silently skipped.
    var costCapUSD: Double {
        didSet { UserDefaults.standard.set(costCapUSD, forKey: Defaults.costCapUSD) }
    }

    /// Base URL of the Ollama server (default: http://localhost:11434).
    var ollamaEndpoint: String {
        didSet { UserDefaults.standard.set(ollamaEndpoint, forKey: Defaults.ollamaEndpoint) }
    }
    /// API mode: native /api/chat or OpenAI-compat /v1/chat/completions.
    var ollamaApiMode: OllamaAPIMode {
        didSet { UserDefaults.standard.set(ollamaApiMode.rawValue, forKey: Defaults.ollamaApiMode) }
    }
    /// Default model name sent to Ollama (e.g. "qwen2.5:14b").
    var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: Defaults.ollamaModel) }
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

        // Default $1.00; treat stored 0.0 as "never set" and use the default.
        let cap = UserDefaults.standard.double(forKey: Defaults.costCapUSD)
        self.costCapUSD = cap > 0 ? cap : 1.00

        self.ollamaEndpoint = UserDefaults.standard.string(forKey: Defaults.ollamaEndpoint) ?? "http://localhost:11434"

        let apiModeRaw = UserDefaults.standard.string(forKey: Defaults.ollamaApiMode) ?? OllamaAPIMode.native.rawValue
        self.ollamaApiMode = OllamaAPIMode(rawValue: apiModeRaw) ?? .native

        self.ollamaModel = UserDefaults.standard.string(forKey: Defaults.ollamaModel) ?? "qwen2.5:14b"

        loadKeysFromKeychain()
    }

    // MARK: Persistence

    private func loadKeysFromKeychain() {
        deepgramApiKey = (try? keychain.get(KeychainAccount.deepgram.rawValue)) ?? ""
        openaiApiKey = (try? keychain.get(KeychainAccount.openaiWhisper.rawValue)) ?? ""
        anthropicApiKey = (try? keychain.get(KeychainAccount.anthropic.rawValue)) ?? ""
        ollamaBearer = (try? keychain.get(KeychainAccount.ollama.rawValue)) ?? ""
    }

    /// Persist all currently-loaded values to Keychain. Empty strings are
    /// treated as "remove" so users can clear a key from the UI.
    func commitAllKeys() {
        commit(.deepgram, value: deepgramApiKey)
        commit(.openaiWhisper, value: openaiApiKey)
        commit(.anthropic, value: anthropicApiKey)
        commit(.ollama, value: ollamaBearer)
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
