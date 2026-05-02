import Foundation
import AIKit
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
        case openrouter = "openrouter.api_key"
        case s3AccessKey = "s3.access_key_id"
        case s3SecretKey = "s3.secret_access_key"
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
        case openrouter
        case ollama

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .anthropic: return "Anthropic Claude"
            case .openai: return "OpenAI"
            case .openrouter: return "OpenRouter"
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
        static let voiceNoteKind = "voiceNoteKind"
        static let openrouterModel = "openrouterModel"
        static let semanticSearchEnabled = "semanticSearchEnabled"
        // Per-process Core Audio Tap source (14.4+ only). When false (or on <14.4),
        // SCKit whole-system mixdown is used. When true on 14.4+, only the configured
        // bundle IDs are captured.
        static let useProcessTap = "useProcessTap"
        static let processTapBundleIDs = "processTapBundleIDs"
        // S3 sharing
        static let s3Endpoint = "s3Endpoint"
        static let s3Region = "s3Region"
        static let s3Bucket = "s3Bucket"
        static let s3PresignTTLHours = "s3PresignTTLHours"
    }

    // MARK: Observable state — secrets read on demand from Keychain

    /// Mirror copies of the secrets so SwiftUI bindings have something to bind to.
    /// Saved to Keychain via `commit*` actions; never persisted to disk in plain text.
    var deepgramApiKey: String = ""
    var openaiApiKey: String = ""
    var anthropicApiKey: String = ""
    var ollamaBearer: String = ""   // optional bearer token for self-hosted Ollama frontends
    var openrouterApiKey: String = ""
    var s3AccessKey: String = ""
    var s3SecretKey: String = ""

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

    /// Capture system audio (SCKit mixdown) alongside the mic. Off by default —
    /// requires Screen Recording permission and captures whole-system audio.
    var systemAudioEnabled: Bool {
        didSet { UserDefaults.standard.set(systemAudioEnabled, forKey: Defaults.systemAudioEnabled) }
    }
    /// Run an LLM cleanup pass on the Whisper transcript before pasting (Dictation Mode).
    /// On = cleaner output, slower (extra round-trip). Off = paste raw transcript.
    var dictationLLMCleanup: Bool {
        didSet { UserDefaults.standard.set(dictationLLMCleanup, forKey: Defaults.dictationLLMCleanup) }
    }
    /// Hard cap on a single Dictation utterance length, in seconds. Default 60.
    var dictationMaxSeconds: Int {
        didSet { UserDefaults.standard.set(dictationMaxSeconds, forKey: Defaults.dictationMaxSeconds) }
    }

    /// Default Voice Note kind. The user can override per session.
    var voiceNoteKind: PromptTemplates.VoiceNoteKind {
        didSet { UserDefaults.standard.set(voiceNoteKind.rawValue, forKey: Defaults.voiceNoteKind) }
    }

    /// Default OpenRouter model. Free-text — OpenRouter accepts vendor/model strings like
    /// `anthropic/claude-3.5-sonnet` or `openai/gpt-4o-mini`.
    var openrouterModel: String {
        didSet { UserDefaults.standard.set(openrouterModel, forKey: Defaults.openrouterModel) }
    }

    /// Enable embedding-based semantic search alongside FTS5. Off by default — requires an
    /// OpenAI API key (uses text-embedding-3-small).
    var semanticSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(semanticSearchEnabled, forKey: Defaults.semanticSearchEnabled) }
    }

    /// Use per-process Core Audio Tap (macOS 14.4+) instead of SCKit whole-system mixdown.
    /// Off by default; turning it on requires picking bundle IDs in `processTapBundleIDs`.
    var useProcessTap: Bool {
        didSet { UserDefaults.standard.set(useProcessTap, forKey: Defaults.useProcessTap) }
    }

    /// Comma-separated list of bundle IDs to capture when `useProcessTap` is on.
    /// Default common targets: Zoom, Meet (via Chrome/Safari), Teams, Slack.
    var processTapBundleIDs: String {
        didSet { UserDefaults.standard.set(processTapBundleIDs, forKey: Defaults.processTapBundleIDs) }
    }

    /// S3 endpoint URL (e.g. https://s3.amazonaws.com or https://<account>.r2.cloudflarestorage.com).
    var s3Endpoint: String {
        didSet { UserDefaults.standard.set(s3Endpoint, forKey: Defaults.s3Endpoint) }
    }
    /// S3 region (e.g. us-east-1, auto for R2).
    var s3Region: String {
        didSet { UserDefaults.standard.set(s3Region, forKey: Defaults.s3Region) }
    }
    /// S3 bucket name.
    var s3Bucket: String {
        didSet { UserDefaults.standard.set(s3Bucket, forKey: Defaults.s3Bucket) }
    }
    /// Presigned URL TTL in hours. Default 168 (7 days, the S3 max for sigv4).
    var s3PresignTTLHours: Int {
        didSet { UserDefaults.standard.set(s3PresignTTLHours, forKey: Defaults.s3PresignTTLHours) }
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

        self.systemAudioEnabled = UserDefaults.standard.bool(forKey: Defaults.systemAudioEnabled)
        // Default true for cleanup; UserDefaults.bool returns false for missing keys, so check object presence.
        self.dictationLLMCleanup = (UserDefaults.standard.object(forKey: Defaults.dictationLLMCleanup) as? Bool) ?? true
        let maxSecs = UserDefaults.standard.integer(forKey: Defaults.dictationMaxSeconds)
        self.dictationMaxSeconds = maxSecs > 0 ? maxSecs : 60

        let kindRaw = UserDefaults.standard.string(forKey: Defaults.voiceNoteKind) ?? PromptTemplates.VoiceNoteKind.freeform.rawValue
        self.voiceNoteKind = PromptTemplates.VoiceNoteKind(rawValue: kindRaw) ?? .freeform

        self.openrouterModel = UserDefaults.standard.string(forKey: Defaults.openrouterModel) ?? "anthropic/claude-3.5-sonnet"
        self.semanticSearchEnabled = UserDefaults.standard.bool(forKey: Defaults.semanticSearchEnabled)

        self.useProcessTap = UserDefaults.standard.bool(forKey: Defaults.useProcessTap)
        self.processTapBundleIDs = UserDefaults.standard.string(forKey: Defaults.processTapBundleIDs)
            ?? "us.zoom.xos,com.microsoft.teams2,com.tinyspeck.slackmacgap,com.google.Chrome,com.apple.Safari"

        self.s3Endpoint = UserDefaults.standard.string(forKey: Defaults.s3Endpoint) ?? ""
        self.s3Region = UserDefaults.standard.string(forKey: Defaults.s3Region) ?? "us-east-1"
        self.s3Bucket = UserDefaults.standard.string(forKey: Defaults.s3Bucket) ?? ""
        let ttl = UserDefaults.standard.integer(forKey: Defaults.s3PresignTTLHours)
        self.s3PresignTTLHours = ttl > 0 ? ttl : 168

        loadKeysFromKeychain()
    }

    // MARK: Persistence

    private func loadKeysFromKeychain() {
        deepgramApiKey = (try? keychain.get(KeychainAccount.deepgram.rawValue)) ?? ""
        openaiApiKey = (try? keychain.get(KeychainAccount.openaiWhisper.rawValue)) ?? ""
        anthropicApiKey = (try? keychain.get(KeychainAccount.anthropic.rawValue)) ?? ""
        ollamaBearer = (try? keychain.get(KeychainAccount.ollama.rawValue)) ?? ""
        openrouterApiKey = (try? keychain.get(KeychainAccount.openrouter.rawValue)) ?? ""
        s3AccessKey = (try? keychain.get(KeychainAccount.s3AccessKey.rawValue)) ?? ""
        s3SecretKey = (try? keychain.get(KeychainAccount.s3SecretKey.rawValue)) ?? ""
    }

    /// Persist all currently-loaded values to Keychain. Empty strings are
    /// treated as "remove" so users can clear a key from the UI.
    func commitAllKeys() {
        commit(.deepgram, value: deepgramApiKey)
        commit(.openaiWhisper, value: openaiApiKey)
        commit(.anthropic, value: anthropicApiKey)
        commit(.ollama, value: ollamaBearer)
        commit(.openrouter, value: openrouterApiKey)
        commit(.s3AccessKey, value: s3AccessKey)
        commit(.s3SecretKey, value: s3SecretKey)
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
