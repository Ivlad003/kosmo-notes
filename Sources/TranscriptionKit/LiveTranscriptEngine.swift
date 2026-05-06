import Foundation
import os

private let engineLog = Logger(subsystem: "dev.kosmonotes.studio", category: "LiveTranscriptEngine")

// MARK: - LiveTranscriptEngine

/// Orchestrates live transcription for a recording session.
///
/// The engine manages:
/// - Cadence scheduling (transcribe every N seconds)
/// - Window export (rolling 5–10 second windows)
/// - Provider calls (batch transcription of each window)
/// - Merge logic (applying new results to the growing transcript state)
/// - Health tracking (delayed state when provider is slow)
///
/// ## Usage
///
/// 1. Create the engine with a provider, exporter, and cadence settings.
/// 2. `attach(audioFile:)` to set the source recording file.
/// 3. `ingest(sampleTime:pcmData:)` to signal audio progress.
/// 4. `tick(now:config:)` periodically to trigger transcription.
/// 5. `finish(now:config:)` to force a final flush at session end.
/// 6. `snapshot()` to get the current transcript state for UI.
///
/// The engine respects cadence: `tick` only transcribes if `now - lastTranscribeTime >= cadence`.
/// The first tick always runs to provide immediate feedback.
///
/// Degraded state: If a transcription call takes longer than `delayThreshold`,
/// the engine enters `.delayed` state. It returns to `.healthy` when the call completes.
public actor LiveTranscriptEngine {
    
    // MARK: Types
    
    public enum EngineError: Error, LocalizedError {
        case noAudioFileAttached
        case exportFailed(underlying: String)
        case transcriptionFailed(underlying: String)
        
        public var errorDescription: String? {
            switch self {
            case .noAudioFileAttached:
                return "No audio file attached to the live transcript engine."
            case .exportFailed(let s):
                return "Window export failed: \(s)"
            case .transcriptionFailed(let s):
                return "Live transcription failed: \(s)"
            }
        }
    }
    
    // MARK: Properties
    
    private let provider: any LiveTranscriptionProvider
    private let exporter: LiveWindowExporter
    
    /// Duration of each rolling window in seconds (e.g., 5–10).
    private let windowDuration: TimeInterval
    
    /// Minimum time between transcription calls in seconds.
    public let cadence: TimeInterval
    
    /// How many seconds of draft text remain mutable before locking.
    private let mutableHorizon: TimeInterval
    
    /// If a transcription call takes longer than this, mark state as `.delayed`.
    private let delayThreshold: TimeInterval
    
    /// The attached audio file (set via `attach`).
    private var audioFile: URL?
    
    /// Latest sample time ingested (tracks recording progress).
    private(set) var latestSampleTime: TimeInterval = 0
    
    /// Current transcript state.
    private var state = LiveTranscriptState.empty
    
    /// Last time a transcription was started.
    private var lastTranscribeTime: TimeInterval?
    
    /// Cleanup list for temporary window exports.
    private var tempFiles: [URL] = []
    
    // MARK: Init
    
    public init(
        provider: any LiveTranscriptionProvider,
        exporter: LiveWindowExporter,
        windowDuration: TimeInterval = 5,
        cadence: TimeInterval = 3,
        mutableHorizon: TimeInterval = 10,
        delayThreshold: TimeInterval = 5
    ) {
        self.provider = provider
        self.exporter = exporter
        self.windowDuration = windowDuration
        self.cadence = cadence
        self.mutableHorizon = mutableHorizon
        self.delayThreshold = delayThreshold
    }
    
    // MARK: Public API
    
    /// Attach the source recording file.
    ///
    /// The engine will export windows from this file during `tick` calls.
    public func attach(audioFile: URL) {
        self.audioFile = audioFile
        engineLog.info("LiveTranscriptEngine.attach: file=\(audioFile.lastPathComponent, privacy: .public)")
    }
    
    /// Ingest a signal that audio has progressed.
    ///
    /// Tracks the latest sample time so the engine knows how much audio is available.
    /// The PCM data itself is not used in this implementation (the engine reads from the file).
    public func ingest(sampleTime: TimeInterval, pcmData: Data) {
        latestSampleTime = max(latestSampleTime, sampleTime)
    }
    
    /// Tick the engine to potentially trigger a transcription.
    ///
    /// Respects cadence: only transcribes if `now - lastTranscribeTime >= cadence`,
    /// or if this is the first tick (to provide immediate feedback).
    ///
    /// - Parameters:
    ///   - now: Current session time in seconds.
    ///   - config: Transcription configuration.
    public func tick(now: TimeInterval, config: TranscriptionConfig) async throws {
        guard let audioFile else {
            throw EngineError.noAudioFileAttached
        }
        
        // Check cadence gate
        if let lastTime = lastTranscribeTime {
            let elapsed = now - lastTime
            if elapsed < cadence {
                // Cadence not met, skip
                return
            }
        }
        
        // Start transcription
        lastTranscribeTime = now
        
        // Compute window bounds
        let windowEnd = min(now, latestSampleTime)
        let windowStart = max(0, windowEnd - windowDuration)
        
        guard windowEnd > windowStart else {
            // No audio available yet
            return
        }
        
        engineLog.info("LiveTranscriptEngine.tick: now=\(now, privacy: .public)s windowStart=\(windowStart, privacy: .public)s windowEnd=\(windowEnd, privacy: .public)s")
        
        // Export window
        let windowFile: URL
        do {
            windowFile = try await exporter.export(
                audioFile: audioFile,
                windowStart: windowStart,
                windowDuration: windowEnd - windowStart
            )
            tempFiles.append(windowFile)
        } catch {
            throw EngineError.exportFailed(underlying: error.localizedDescription)
        }
        
        // Transcribe with timeout detection
        let result: LiveTranscriptWindowResult
        do {
            result = try await transcribeWithTimeout(
                windowFile: windowFile,
                windowStart: windowStart,
                windowEnd: windowEnd,
                config: config
            )
        } catch {
            state.status = .failed(lastError: error.localizedDescription)
            throw EngineError.transcriptionFailed(underlying: error.localizedDescription)
        }
        
        // Merge result into state
        state = state.merging(result, mutableHorizon: mutableHorizon)
        
        // Return to healthy if we were delayed
        if state.status == .delayed {
            state.status = .healthy
        }
    }
    
    /// Force a final transcription flush, ignoring cadence.
    ///
    /// Used at session end to capture the last few seconds of audio.
    public func finish(now: TimeInterval, config: TranscriptionConfig) async throws {
        guard let audioFile else {
            throw EngineError.noAudioFileAttached
        }
        
        // Compute final window bounds
        let windowEnd = min(now, latestSampleTime)
        let windowStart = max(0, windowEnd - windowDuration)
        
        guard windowEnd > windowStart else {
            // No audio to transcribe
            return
        }
        
        engineLog.info("LiveTranscriptEngine.finish: windowStart=\(windowStart, privacy: .public)s windowEnd=\(windowEnd, privacy: .public)s")
        
        // Export window
        let windowFile: URL
        do {
            windowFile = try await exporter.export(
                audioFile: audioFile,
                windowStart: windowStart,
                windowDuration: windowEnd - windowStart
            )
            tempFiles.append(windowFile)
        } catch {
            throw EngineError.exportFailed(underlying: error.localizedDescription)
        }
        
        // Transcribe
        let result: LiveTranscriptWindowResult
        do {
            result = try await provider.transcribeLiveWindow(
                audioFile: windowFile,
                windowStart: windowStart,
                windowEnd: windowEnd,
                config: config
            )
        } catch {
            state.status = .failed(lastError: error.localizedDescription)
            throw EngineError.transcriptionFailed(underlying: error.localizedDescription)
        }
        
        // Merge result
        state = state.merging(result, mutableHorizon: mutableHorizon)
        
        // Final flush always returns to healthy (or keeps failed if merge failed)
        if state.status == .delayed {
            state.status = .healthy
        }
    }
    
    /// Get a snapshot of the current transcript state.
    public func snapshot() -> LiveTranscriptState {
        return state
    }
    
    /// Clean up temporary window files.
    public func cleanup() {
        for file in tempFiles {
            try? FileManager.default.removeItem(at: file)
        }
        tempFiles.removeAll()
    }
    
    // MARK: Private
    
    private func transcribeWithTimeout(
        windowFile: URL,
        windowStart: TimeInterval,
        windowEnd: TimeInterval,
        config: TranscriptionConfig
    ) async throws -> LiveTranscriptWindowResult {
        // Race transcription against timeout using TaskGroup
        let result: LiveTranscriptWindowResult? = try await withThrowingTaskGroup(of: TaskResult.self) { group in
            // Task 1: Actual transcription
            group.addTask {
                let result = try await self.provider.transcribeLiveWindow(
                    audioFile: windowFile,
                    windowStart: windowStart,
                    windowEnd: windowEnd,
                    config: config
                )
                return .success(result)
            }
            
            // Task 2: Timeout watchdog
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.delayThreshold * 1_000_000_000))
                return .timeout
            }
            
            // Wait for first result
            var transcriptionResult: LiveTranscriptWindowResult?
            var timedOut = false
            
            while let taskResult = try await group.next() {
                switch taskResult {
                case .success(let r):
                    transcriptionResult = r
                    group.cancelAll()
                    break
                case .timeout:
                    timedOut = true
                    // Mark as delayed but keep waiting for transcription to finish
                }
            }
            
            if timedOut {
                await self.markDelayed()
            }
            
            return transcriptionResult
        }
        
        guard let result else {
            throw EngineError.transcriptionFailed(underlying: "No result from transcription task")
        }
        
        return result
    }
    
    private func markDelayed() {
        state.status = .delayed
    }
    
    private enum TaskResult {
        case success(LiveTranscriptWindowResult)
        case timeout
    }
}
