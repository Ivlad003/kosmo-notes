import Foundation
import AIKit

// MARK: - RecorderState — semantic embedding indexing
//
// Pulled out of RecorderState.swift so the main file stays focused on
// capture lifecycle. The method is invoked from `stop()` after the
// transcript is persisted; FTS5 is the primary search index, so any
// embedding failure here is silently swallowed and search keeps working.
//
// Access modifier dropped from `private` to module-internal so the call
// site in `RecorderState.stop()` can see it across files.

@available(macOS 14.0, *)
extension RecorderState {

    /// Embed the transcript and persist the vector under the session ID.
    /// Best-effort: any failure (no API key, network, etc) is silently skipped.
    func indexSemantic(sid: String, transcript: String) async {
        let key = settings.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Truncate at ~6000 chars (~1500 tokens at 4 chars/tok ratio for Latin)
        // — enough for a meaningful semantic vector without going near the
        // 8192-token API limit. Long meetings still get a single vector that
        // captures the overall topic.
        let snippet = String(trimmed.prefix(6000))

        let provider = OpenAIEmbeddingProvider(apiKey: key)
        do {
            let vector = try await provider.embed(snippet)
            let blob = EmbeddingMath.pack(vector)
            try await database.upsertEmbedding(
                sid: sid,
                vector: blob,
                model: provider.modelIdentifier
            )
        } catch {
            // Silent failure — FTS5 still works.
        }
    }
}
