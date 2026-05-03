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
        // Google AI Studio key for Gemini multimodal audio transcription
        // (https://aistudio.google.com/apikey). Separate from any Vertex AI
        // service-account credentials.
        case gemini = "gemini.api_key"
        case s3AccessKey = "s3.access_key_id"
        case s3SecretKey = "s3.secret_access_key"
    }

    enum TranscriptionProviderChoice: String, CaseIterable, Identifiable {
        case deepgram
        case openaiWhisper
        case gemini
        case openrouterAudio

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .deepgram: return "Deepgram"
            case .openaiWhisper: return "OpenAI Whisper"
            case .gemini: return "Gemini (multimodal)"
            case .openrouterAudio: return "OpenRouter (multimodal)"
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

    /// Which backend drives the autonomous agent loop:
    ///   - `builtin`     → in-process Anthropic Messages API loop with bash/read/write tools (AgentRunner)
    ///   - `claudeCode`  → spawn `claude -p "<instruction>" --output-format stream-json --verbose` and stream stdout
    ///   - `codex`       → spawn `codex exec "<instruction>"` and stream stdout
    ///   - `copilot`     → spawn `gh copilot suggest -t shell "<instruction>"` (one-shot, no streaming loop)
    ///
    /// External CLIs run in the agent workspace folder as cwd; their own auth
    /// (claude.ai login, ChatGPT subscription, GitHub auth) is reused as-is.
    enum AgentBackendChoice: String, CaseIterable, Identifiable {
        case builtin
        case claudeCode
        case codex
        case copilot

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .builtin:    return "Built-in (Anthropic API)"
            case .claudeCode: return "Claude Code CLI"
            case .codex:      return "Codex CLI"
            case .copilot:    return "GitHub Copilot CLI"
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

    /// Audio + video codec preset for new recordings. Each profile picks the
    /// codec, sample rate, and bitrate; the screen recorder reads `videoCodec`
    /// + `videoBitrate`, the audio capture stack reads `audioCodec` +
    /// `audioBitrate` + `audioSampleRate`.
    ///
    /// Storage savings (vs Quality, per hour of meeting + screen):
    ///   - Quality:   ~1.74 GB (H.264 4 Mbps + AAC-LC 96k @ 48 kHz)
    ///   - Balanced:  ~870 MB (HEVC 2 Mbps + HE-AAC 48k @ 48 kHz)  default
    ///   - Compact:   ~430 MB (HEVC 1.5 Mbps + Opus 32k @ 24 kHz)
    enum StorageProfile: String, CaseIterable, Identifiable {
        case quality
        case balanced
        case compact

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .quality:  return "Quality"
            case .balanced: return "Balanced"
            case .compact:  return "Compact"
            }
        }
        var summary: String {
            switch self {
            case .quality:  return "H.264 4 Mbps + AAC-LC 96 kbps @ 48 kHz · ~1.74 GB/h"
            case .balanced: return "HEVC 2 Mbps + HE-AAC 48 kbps @ 48 kHz · ~870 MB/h (-50%)"
            case .compact:  return "HEVC 1.5 Mbps + Opus 32 kbps @ 24 kHz · ~430 MB/h (-75%)"
            }
        }
    }

    /// Audio codec — derived from StorageProfile but overridable.
    /// `aac` = AAC-LC (legacy default), `heAAC` = HE-AAC v1, `opus` = Opus (14+).
    enum AudioCodec: String, CaseIterable, Identifiable {
        case aac
        case heAAC
        case opus

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .aac:   return "AAC-LC"
            case .heAAC: return "HE-AAC v1"
            case .opus:  return "Opus"
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
        // Whether to run the meeting/voice-note transcript through an LLM cleanup
        // pass after Whisper/Deepgram. Reuses the configured llmProvider; default ON.
        static let transcriptCleanupEnabled = "transcriptCleanupEnabled"
        static let dictationMaxSeconds = "dictationMaxSeconds"
        static let voiceNoteKind = "voiceNoteKind"
        static let openrouterModel = "openrouterModel"
        static let semanticSearchEnabled = "semanticSearchEnabled"
        // Per-process Core Audio Tap source (14.4+ only). When false (or on <14.4),
        // SCKit whole-system mixdown is used. When true on 14.4+, only the configured
        // bundle IDs are captured.
        static let useProcessTap = "useProcessTap"
        static let processTapBundleIDs = "processTapBundleIDs"
        // Custom Core Audio input device for system-audio capture (e.g. BlackHole 2ch).
        // Empty string = use SCKit whole-system mixdown (default behavior).
        static let systemAudioDeviceUID = "systemAudioDeviceUID"
        // Loom-style floating webcam bubble during Audio + Screen recordings.
        static let cameraBubbleEnabled = "cameraBubbleEnabled"
        static let cameraDeviceUID = "cameraDeviceUID"
        static let cameraBubblePositionX = "cameraBubblePositionX"
        static let cameraBubblePositionY = "cameraBubblePositionY"
        static let cameraBubbleSize = "cameraBubbleSize"
        // Chat auto-frame sampling — when on, every chat message that
        // has an attached session with screen.mp4 gets N evenly-spaced
        // baseline frames added as vision context (in addition to any
        // timestamp-extracted frames).
        static let chatVideoAutoFramesEnabled = "chatVideoAutoFramesEnabled"
        static let chatVideoAutoFramesCount = "chatVideoAutoFramesCount"
        // Markdown export — at the end of every recording, run the cleaned
        // transcript through an LLM with the user-defined prompts and write
        // the result as a .md file at the chosen folder.
        static let markdownExportEnabled = "markdownExportEnabled"
        static let markdownExportFolder = "markdownExportFolder"
        static let markdownExportSystemPrompt = "markdownExportSystemPrompt"
        static let markdownExportUserPrompt = "markdownExportUserPrompt"
        // Push-to-Markdown — same hold-hotkey-and-talk pattern as Dictation,
        // but result is saved as a .md file (using the markdownExport*
        // prompts above) instead of pasted into the focused field.
        static let pushToMarkdownEnabled = "pushToMarkdownEnabled"
        // Autonomous agent — voice instruction → tool-using Claude loop.
        static let agentEnabled = "agentEnabled"
        static let agentSystemPrompt = "agentSystemPrompt"
        static let agentMaxIterations = "agentMaxIterations"
        static let agentWorkspaceFolder = "agentWorkspaceFolder"
        // Backend selector — built-in Anthropic-API loop, or spawn an
        // external CLI (Claude Code, Codex, GitHub Copilot).
        static let agentBackend = "agentBackend"
        static let agentClaudeCodeBin = "agentClaudeCodeBin"
        static let agentCodexBin = "agentCodexBin"
        static let agentCopilotBin = "agentCopilotBin"
        // S3 sharing
        static let s3Endpoint = "s3Endpoint"
        static let s3Region = "s3Region"
        static let s3Bucket = "s3Bucket"
        static let s3PresignTTLHours = "s3PresignTTLHours"
        // Storage profile + codec overrides
        static let storageProfile = "storageProfile"
        static let audioCodec = "audioCodec"
        static let audioBitrate = "audioBitrate"
        static let audioSampleRate = "audioSampleRate"
        static let videoUseHEVC = "videoUseHEVC"
        static let videoBitrate = "videoBitrate"
    }

    // MARK: Observable state — secrets read on demand from Keychain

    /// Mirror copies of the secrets so SwiftUI bindings have something to bind to.
    /// Saved to Keychain via `commit*` actions; never persisted to disk in plain text.
    var deepgramApiKey: String = ""
    var openaiApiKey: String = ""
    var anthropicApiKey: String = ""
    var ollamaBearer: String = ""   // optional bearer token for self-hosted Ollama frontends
    var openrouterApiKey: String = ""
    var geminiApiKey: String = ""
    var s3AccessKey: String = ""
    var s3SecretKey: String = ""

    /// Persistent UID of a custom Core Audio input device (e.g. BlackHole 2ch)
    /// used as the system-audio source instead of SCKit. Empty string = use
    /// SCKit whole-system mixdown (default). Set via Settings → Transcription.
    var systemAudioDeviceUID: String {
        didSet { UserDefaults.standard.set(systemAudioDeviceUID, forKey: Defaults.systemAudioDeviceUID) }
    }

    /// Show a Loom-style floating webcam bubble during Audio + Screen recordings.
    /// When on, a circular always-on-top NSWindow with the front camera feed
    /// appears at the saved position; ScreenCaptureKit then captures it as
    /// part of `screen.mp4`. Off by default — opt-in.
    var cameraBubbleEnabled: Bool {
        didSet { UserDefaults.standard.set(cameraBubbleEnabled, forKey: Defaults.cameraBubbleEnabled) }
    }
    /// Persistent UID of the AVCaptureDevice the bubble should use (FaceTime,
    /// USB cam, Continuity Camera, etc). Empty string = system default.
    var cameraDeviceUID: String {
        didSet { UserDefaults.standard.set(cameraDeviceUID, forKey: Defaults.cameraDeviceUID) }
    }
    /// On-screen position of the bubble's bottom-left corner (Cocoa coords).
    /// Persisted across launches so the bubble reappears where the user left it.
    var cameraBubblePosition: CGPoint {
        didSet {
            UserDefaults.standard.set(Double(cameraBubblePosition.x), forKey: Defaults.cameraBubblePositionX)
            UserDefaults.standard.set(Double(cameraBubblePosition.y), forKey: Defaults.cameraBubblePositionY)
        }
    }
    /// Side length in points of the (square) bubble window. 200 default;
    /// clamped to [120, 500] in the window controller.
    var cameraBubbleSize: Double {
        didSet { UserDefaults.standard.set(cameraBubbleSize, forKey: Defaults.cameraBubbleSize) }
    }

    /// When ON, every Chat message with an attached session that has
    /// screen.mp4 gets N evenly-spaced baseline frames automatically
    /// added as vision context — without the user needing to type a
    /// timestamp. Lets the LLM "see" the whole video instead of just
    /// the moments the user explicitly asked about. Off by default
    /// (opt-in: more tokens cost more $).
    var chatVideoAutoFramesEnabled: Bool {
        didSet { UserDefaults.standard.set(chatVideoAutoFramesEnabled, forKey: Defaults.chatVideoAutoFramesEnabled) }
    }
    /// Number of evenly-spaced baseline frames to sample. Clamped 1–10
    /// in the UI; combined with timestamp-extracted frames the total is
    /// hard-capped (in ChatState) to keep request size reasonable.
    var chatVideoAutoFramesCount: Int {
        didSet { UserDefaults.standard.set(chatVideoAutoFramesCount, forKey: Defaults.chatVideoAutoFramesCount) }
    }

    /// When ON, every finished recording is also formatted into a custom
    /// `.md` file via the user-defined system + user prompts (below) and
    /// saved to `markdownExportFolder`. Independent of the built-in
    /// `summary.md` — that uses our PromptTemplates; this one is whatever
    /// the user wants ("turn into Notion-style notes", "extract action
    /// items as JIRA tickets", "translate to English while reformatting").
    var markdownExportEnabled: Bool {
        didSet { UserDefaults.standard.set(markdownExportEnabled, forKey: Defaults.markdownExportEnabled) }
    }
    /// Filesystem path where exported `.md` files land. Empty = use the
    /// default `~/Documents/KosmoNotes`. Stored as POSIX path string;
    /// MarkdownExporter creates the dir if missing.
    var markdownExportFolder: String {
        didSet { UserDefaults.standard.set(markdownExportFolder, forKey: Defaults.markdownExportFolder) }
    }
    /// System prompt for the Markdown export pass. Editable in Settings.
    /// Defaults to a meeting-formatter prompt; user can replace with
    /// anything (the LLM gets `system` + `user{transcript}` and returns
    /// the `.md` body).
    var markdownExportSystemPrompt: String {
        didSet { UserDefaults.standard.set(markdownExportSystemPrompt, forKey: Defaults.markdownExportSystemPrompt) }
    }
    /// User-prompt template. Must contain `{transcript}` — that token is
    /// substituted with the actual cleaned transcript before sending to
    /// the LLM. Default keeps it simple: "Here is the transcript: {transcript}".
    var markdownExportUserPrompt: String {
        didSet { UserDefaults.standard.set(markdownExportUserPrompt, forKey: Defaults.markdownExportUserPrompt) }
    }

    /// Push-to-Markdown toggle. When ON, the global hotkey
    /// `KeyboardShortcuts.Name.pushToMarkdown` (default ⌘⇧Y) records
    /// while held; on release the cleaned transcript runs through the
    /// same MarkdownExporter flow (markdownExport* prompts + folder)
    /// and a new `.md` file is written. Off by default.
    var pushToMarkdownEnabled: Bool {
        didSet { UserDefaults.standard.set(pushToMarkdownEnabled, forKey: Defaults.pushToMarkdownEnabled) }
    }

    /// Autonomous agent toggle. When ON, the global hotkey
    /// `KeyboardShortcuts.Name.agentTrigger` (default ⌘⇧A) is push-to-talk
    /// for an agent loop: hold it, speak an instruction, release. Whisper
    /// transcribes; AgentSessionState spawns a Claude tool-use loop with
    /// bash/read_file/write_file tools restricted to the workspace folder.
    var agentEnabled: Bool {
        didSet { UserDefaults.standard.set(agentEnabled, forKey: Defaults.agentEnabled) }
    }
    /// System prompt the agent runs with. User-editable in Settings → Agent.
    var agentSystemPrompt: String {
        didSet { UserDefaults.standard.set(agentSystemPrompt, forKey: Defaults.agentSystemPrompt) }
    }
    /// Hard cap on agent loop iterations — runaway protection. Default 12.
    /// Each iteration = one round-trip to Claude + zero or more tool runs.
    var agentMaxIterations: Int {
        didSet { UserDefaults.standard.set(agentMaxIterations, forKey: Defaults.agentMaxIterations) }
    }
    /// Workspace directory the agent's bash/read/write tools are restricted
    /// to. Empty → `~/Documents/KosmoNotes-agent` (auto-created on first run).
    var agentWorkspaceFolder: String {
        didSet { UserDefaults.standard.set(agentWorkspaceFolder, forKey: Defaults.agentWorkspaceFolder) }
    }
    /// Which backend drives the agent loop. `.builtin` keeps the Anthropic-API
    /// AgentRunner; the other three spawn an external CLI as a subprocess.
    var agentBackend: AgentBackendChoice {
        didSet { UserDefaults.standard.set(agentBackend.rawValue, forKey: Defaults.agentBackend) }
    }
    /// Absolute path to the `claude` binary (Claude Code CLI). Empty = use $PATH lookup.
    var agentClaudeCodeBin: String {
        didSet { UserDefaults.standard.set(agentClaudeCodeBin, forKey: Defaults.agentClaudeCodeBin) }
    }
    /// Absolute path to the `codex` binary (OpenAI Codex CLI). Empty = $PATH lookup.
    var agentCodexBin: String {
        didSet { UserDefaults.standard.set(agentCodexBin, forKey: Defaults.agentCodexBin) }
    }
    /// Absolute path to the `gh` binary (GitHub CLI w/ Copilot extension). Empty = $PATH lookup.
    var agentCopilotBin: String {
        didSet { UserDefaults.standard.set(agentCopilotBin, forKey: Defaults.agentCopilotBin) }
    }

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

    /// Run the long-form meeting / voice-note transcript through an LLM cleanup
    /// pass after Whisper / Deepgram / Gemini transcribes. Reuses the configured
    /// `llmProvider`. On = ASR mistakes (numbers, names, double-words, missing
    /// punctuation) corrected; speaker voice and timing preserved. Off = raw
    /// transcript stored as-is. Default ON. Adds ~1–3 s + a small LLM cost per
    /// recording. Cleanup failures are non-fatal — raw transcript is kept.
    var transcriptCleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(transcriptCleanupEnabled, forKey: Defaults.transcriptCleanupEnabled) }
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

    // MARK: Storage profile + codec overrides

    /// User-facing preset that picks codec + bitrate combos. Setting this also
    /// rewrites the individual codec fields below — they remain user-editable
    /// after a preset is picked, the preset is just the starting point.
    var storageProfile: StorageProfile {
        didSet {
            UserDefaults.standard.set(storageProfile.rawValue, forKey: Defaults.storageProfile)
            applyStorageProfile()
        }
    }

    /// Audio codec for new recordings. AAC-LC is the universal-compatibility default.
    var audioCodec: AudioCodec {
        didSet { UserDefaults.standard.set(audioCodec.rawValue, forKey: Defaults.audioCodec) }
    }
    /// Audio bitrate in bits/sec. AAC-LC: 96k default. HE-AAC: 48k. Opus: 32k.
    var audioBitrate: Int {
        didSet { UserDefaults.standard.set(audioBitrate, forKey: Defaults.audioBitrate) }
    }
    /// Audio sample rate Hz. 48000 captures full-band, 24000 is voice-only and ~⅔ size.
    var audioSampleRate: Int {
        didSet { UserDefaults.standard.set(audioSampleRate, forKey: Defaults.audioSampleRate) }
    }
    /// Use HEVC instead of H.264 for screen.mp4 video stream. ~50% smaller at same quality.
    /// Hardware-accelerated on all Apple Silicon Macs.
    var videoUseHEVC: Bool {
        didSet { UserDefaults.standard.set(videoUseHEVC, forKey: Defaults.videoUseHEVC) }
    }
    /// Video bitrate in bits/sec. Default 4_000_000 (H.264). HEVC defaults to 2_000_000.
    var videoBitrate: Int {
        didSet { UserDefaults.standard.set(videoBitrate, forKey: Defaults.videoBitrate) }
    }

    /// Rewrite codec fields to match the active StorageProfile.
    private func applyStorageProfile() {
        switch storageProfile {
        case .quality:
            audioCodec = .aac
            audioBitrate = 96_000
            audioSampleRate = 48_000
            videoUseHEVC = false
            videoBitrate = 4_000_000
        case .balanced:
            // Was HE-AAC 48 kbps — encoder fails on the macOS AAC HE path with
            // "Cannot Encode Media" for our mono PCM input. Use AAC-LC at the
            // same 48 kbps; for voice mono the difference is small enough to
            // accept until HE-AAC is properly debugged.
            audioCodec = .aac
            audioBitrate = 48_000
            audioSampleRate = 48_000
            videoUseHEVC = true
            videoBitrate = 2_000_000
        case .compact:
            audioCodec = .opus
            audioBitrate = 32_000
            audioSampleRate = 24_000
            videoUseHEVC = true
            videoBitrate = 1_500_000
        }
    }

    // MARK: - Default prompts (Markdown export)

    /// Sane starter for the Markdown export system prompt. The user can
    /// fully replace it in Settings → Markdown Export. Kept generic on
    /// purpose so it works for meetings, voice notes, and dictation.
    static let defaultMarkdownExportSystemPrompt: String = """
    You are a transcript-to-Markdown formatter. The user gives you a raw \
    transcript from a meeting, voice note, or dictation. Produce a clean \
    Markdown document that is easy to skim later.

    Required structure:
    1. `# <Concise title>` — invent one from the content; no boilerplate.
    2. A 2–4 sentence executive summary, italicized.
    3. `## Key points` — bullet list of the main ideas.
    4. `## Decisions` — bullet list, only if any were made; omit otherwise.
    5. `## Action items` — checkbox list (`- [ ] …`), with owner in **bold** \
       when nameable; omit if none.
    6. `## Open questions` — bullet list, only if any were raised.
    7. `## Full transcript (cleaned)` — copy the transcript with light \
       cleanup: punctuation, paragraph breaks, removed filler words.

    Rules:
    - Output language: same as the transcript.
    - Use only standard CommonMark; no front matter, no HTML, no code fences \
      around the whole document.
    - Do not invent facts. If a section would be empty, leave it out.
    - Keep headings consistent so the file is greppable.
    """

    /// User-message template. `{transcript}` is substituted at send-time.
    /// Kept short — the system prompt does the heavy lifting.
    static let defaultMarkdownExportUserPrompt: String = """
    Transcript follows. Format it according to the rules.

    {transcript}
    """

    /// Default system prompt for the autonomous agent. Editable in
    /// Settings → Agent. Errs on the side of being explicit about safety
    /// + the read-only-allowlist that BashTool enforces.
    static let defaultAgentSystemPrompt: String = """
    You are KosmoNotes's local assistant agent. The user has spoken a task \
    via push-to-talk; you now have a small toolbox to accomplish it on their Mac.

    Tools you can call:
    - bash      — run a single shell command (allowlisted: ls, cat, echo, pwd, \
      which, head, tail, wc, file, find, grep, rg, sed, awk, date, uname, env, \
      git, swift, xcodebuild, make, npm, node, python). No mutating commands.
    - read_file — read a UTF-8 text file inside the workspace folder.
    - write_file — write a UTF-8 text file inside the workspace folder.

    Behaviour:
    1. Plan briefly before acting. State the plan in one sentence, then run.
    2. Prefer small, observable steps over big batches — call one tool, read the \
       result, decide the next move.
    3. Stay inside the workspace directory provided in the system context. Path \
       traversal is rejected with an error.
    4. When you've answered the user's request or hit a wall, finish your reply \
       with a concise summary and stop calling tools.
    5. If a step needs information you don't have (a credential, a file location), \
       ask the user — they can inject a follow-up message via the console.
    """

    // MARK: Init

    private let keychain: Keychain

    init() {
        // Keychain service must match the bundle identifier.
        self.keychain = Keychain(service: "dev.kosmonotes.studio")
            .accessibility(.afterFirstUnlockThisDeviceOnly)
            .synchronizable(false)

        let providerRaw = UserDefaults.standard.string(forKey: Defaults.transcriptionProvider) ?? TranscriptionProviderChoice.openaiWhisper.rawValue
        self.transcriptionProvider = TranscriptionProviderChoice(rawValue: providerRaw) ?? .openaiWhisper

        self.systemAudioDeviceUID = UserDefaults.standard.string(forKey: Defaults.systemAudioDeviceUID) ?? ""

        self.cameraBubbleEnabled = (UserDefaults.standard.object(forKey: Defaults.cameraBubbleEnabled) as? Bool) ?? false
        self.cameraDeviceUID = UserDefaults.standard.string(forKey: Defaults.cameraDeviceUID) ?? ""
        let cbX = UserDefaults.standard.object(forKey: Defaults.cameraBubblePositionX) as? Double ?? 100
        let cbY = UserDefaults.standard.object(forKey: Defaults.cameraBubblePositionY) as? Double ?? 100
        self.cameraBubblePosition = CGPoint(x: cbX, y: cbY)
        let savedSize = UserDefaults.standard.double(forKey: Defaults.cameraBubbleSize)
        self.cameraBubbleSize = savedSize > 0 ? savedSize : 200

        self.chatVideoAutoFramesEnabled = (UserDefaults.standard.object(forKey: Defaults.chatVideoAutoFramesEnabled) as? Bool) ?? false
        let savedFrames = UserDefaults.standard.integer(forKey: Defaults.chatVideoAutoFramesCount)
        self.chatVideoAutoFramesCount = savedFrames > 0 ? savedFrames : 4

        self.markdownExportEnabled = (UserDefaults.standard.object(forKey: Defaults.markdownExportEnabled) as? Bool) ?? false
        self.markdownExportFolder = UserDefaults.standard.string(forKey: Defaults.markdownExportFolder) ?? ""
        self.markdownExportSystemPrompt = UserDefaults.standard.string(forKey: Defaults.markdownExportSystemPrompt)
            ?? AppSettings.defaultMarkdownExportSystemPrompt
        self.markdownExportUserPrompt = UserDefaults.standard.string(forKey: Defaults.markdownExportUserPrompt)
            ?? AppSettings.defaultMarkdownExportUserPrompt
        self.pushToMarkdownEnabled = (UserDefaults.standard.object(forKey: Defaults.pushToMarkdownEnabled) as? Bool) ?? false

        self.agentEnabled = (UserDefaults.standard.object(forKey: Defaults.agentEnabled) as? Bool) ?? false
        self.agentSystemPrompt = UserDefaults.standard.string(forKey: Defaults.agentSystemPrompt) ?? AppSettings.defaultAgentSystemPrompt
        let savedIters = UserDefaults.standard.integer(forKey: Defaults.agentMaxIterations)
        self.agentMaxIterations = savedIters > 0 ? savedIters : 12
        self.agentWorkspaceFolder = UserDefaults.standard.string(forKey: Defaults.agentWorkspaceFolder) ?? ""
        let backendRaw = UserDefaults.standard.string(forKey: Defaults.agentBackend) ?? AgentBackendChoice.builtin.rawValue
        self.agentBackend = AgentBackendChoice(rawValue: backendRaw) ?? .builtin
        self.agentClaudeCodeBin = UserDefaults.standard.string(forKey: Defaults.agentClaudeCodeBin) ?? ""
        self.agentCodexBin = UserDefaults.standard.string(forKey: Defaults.agentCodexBin) ?? ""
        self.agentCopilotBin = UserDefaults.standard.string(forKey: Defaults.agentCopilotBin) ?? ""

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
        self.transcriptCleanupEnabled = (UserDefaults.standard.object(forKey: Defaults.transcriptCleanupEnabled) as? Bool) ?? true
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

        // Storage profile defaults to .balanced for new installs (50 % smaller than
        // the legacy "Quality" default). Existing installs that have no UserDefaults
        // entry get .balanced too — but their per-field overrides (audioCodec etc)
        // also have no entry so applyStorageProfile-equivalent values are loaded.
        let profileRaw = UserDefaults.standard.string(forKey: Defaults.storageProfile) ?? StorageProfile.balanced.rawValue
        self.storageProfile = StorageProfile(rawValue: profileRaw) ?? .balanced

        // Auto-migrate away from HE-AAC: the macOS AAC encoder rejects the PCM
        // input we feed AVAssetWriterInput with kAudioFormatMPEG4AAC_HE under
        // certain mono/48 kHz/48 kbps configurations ("Cannot Encode Media",
        // status=.failed on first append). Until that's properly diagnosed,
        // any stored .heAAC preference is rewritten to .aac so recordings
        // actually produce segments. Users can flip back via Storage Profile.
        let codecRaw = UserDefaults.standard.string(forKey: Defaults.audioCodec) ?? AudioCodec.aac.rawValue
        var resolvedCodec = AudioCodec(rawValue: codecRaw) ?? .aac
        if resolvedCodec == .heAAC {
            resolvedCodec = .aac
            UserDefaults.standard.set(resolvedCodec.rawValue, forKey: Defaults.audioCodec)
        }
        self.audioCodec = resolvedCodec

        let abr = UserDefaults.standard.integer(forKey: Defaults.audioBitrate)
        self.audioBitrate = abr > 0 ? abr : 48_000
        let asr = UserDefaults.standard.integer(forKey: Defaults.audioSampleRate)
        self.audioSampleRate = asr > 0 ? asr : 48_000

        // HEVC default true on a fresh install — well-supported on macOS 14+.
        self.videoUseHEVC = (UserDefaults.standard.object(forKey: Defaults.videoUseHEVC) as? Bool) ?? true
        let vbr = UserDefaults.standard.integer(forKey: Defaults.videoBitrate)
        self.videoBitrate = vbr > 0 ? vbr : 2_000_000

        loadKeysFromKeychain()
    }

    // MARK: Persistence

    private func loadKeysFromKeychain() {
        deepgramApiKey = (try? keychain.get(KeychainAccount.deepgram.rawValue)) ?? ""
        openaiApiKey = (try? keychain.get(KeychainAccount.openaiWhisper.rawValue)) ?? ""
        anthropicApiKey = (try? keychain.get(KeychainAccount.anthropic.rawValue)) ?? ""
        ollamaBearer = (try? keychain.get(KeychainAccount.ollama.rawValue)) ?? ""
        openrouterApiKey = (try? keychain.get(KeychainAccount.openrouter.rawValue)) ?? ""
        geminiApiKey = (try? keychain.get(KeychainAccount.gemini.rawValue)) ?? ""
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
        commit(.gemini, value: geminiApiKey)
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
