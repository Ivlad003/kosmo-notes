import AppKit
import Foundation
import UniformTypeIdentifiers
import StorageKit
import TranscriptionKit

// MARK: - SessionExporter

@available(macOS 14.0, *)
@MainActor
enum SessionExporter {

    // MARK: - Format

    enum Format: String, CaseIterable, Identifiable {
        case markdown
        case plainText
        case audio
        case screenVideo

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .markdown: return "Markdown bundle (.md)"
            case .plainText: return "Plain transcript (.txt)"
            case .audio: return "Audio file (.m4a)"
            case .screenVideo: return "Screen recording (.mp4)"
            }
        }

        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .plainText: return "txt"
            case .audio: return "m4a"
            case .screenVideo: return "mp4"
            }
        }

        // UTType for the NSSavePanel allowed content types.
        var contentType: UTType {
            switch self {
            case .markdown: return .plainText
            case .plainText: return .plainText
            case .audio: return UTType(filenameExtension: "m4a") ?? .audio
            case .screenVideo: return UTType(filenameExtension: "mp4") ?? .mpeg4Movie
            }
        }
    }

    // MARK: - Export

    /// Show NSSavePanel and write the chosen format to the chosen URL.
    /// Returns true on success, false on user cancellation, throws on I/O error.
    @discardableResult
    static func exportSession(
        _ session: SessionRecord,
        sessionDir: URL,
        format: Format
    ) async throws -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(formattedRecordedAt(session.recordedAt))-\(session.mode.rawValue).\(format.fileExtension)"
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true

        // runModal is acceptable per spec; no sheet needed for v0.
        let response = panel.runModal()
        guard response == .OK, let destination = panel.url else { return false }

        switch format {
        case .markdown:
            let content = buildMarkdown(session: session, sessionDir: sessionDir)
            try AtomicWriter.write(Data(content.utf8), to: destination)

        case .plainText:
            let src = sessionDir.appendingPathComponent("transcript.txt")
            try copyItem(from: src, to: destination)

        case .audio:
            let src = sessionDir.appendingPathComponent("audio.m4a")
            try copyItem(from: src, to: destination)

        case .screenVideo:
            let src = sessionDir.appendingPathComponent("screen.mp4")
            guard FileManager.default.fileExists(atPath: src.path) else {
                throw ExportError.missingFile(src)
            }
            try copyItem(from: src, to: destination)
        }

        return true
    }

    // MARK: - Helpers

    // Build the combined Markdown string: YAML frontmatter + summary + transcript.
    private static func buildMarkdown(session: SessionRecord, sessionDir: URL) -> String {
        var parts: [String] = []

        // YAML frontmatter
        var front = "---\n"
        front += "recordedAt: \(iso8601(session.recordedAt))\n"
        front += "mode: \(session.mode.rawValue)\n"
        if let lang = session.language { front += "language: \(lang)\n" }
        front += "durationSecs: \(Int(session.durationSecs))\n"
        front += "---\n"
        parts.append(front)

        // Optional summary block
        let summaryURL = sessionDir.appendingPathComponent("summary.md")
        if let summary = try? String(contentsOf: summaryURL, encoding: .utf8), !summary.isEmpty {
            parts.append(summary)
        }

        // Transcript block: prefer timestamped segments from `transcript.jsonl`
        // (per AC-13 — `[mm:ss]` markers per segment). Fall back to plain
        // `transcript.txt` for sessions whose JSONL is missing or unreadable
        // (e.g. transcription failed, or the user had us overwrite the txt
        // with an LLM-cleaned version via TranscriptStore.close(overrideText:)).
        if let timestamped = formattedTranscript(sessionDir: sessionDir) {
            parts.append("## Transcript\n\n\(timestamped)")
        } else {
            let transcriptURL = sessionDir.appendingPathComponent("transcript.txt")
            if let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8), !transcript.isEmpty {
                parts.append("## Transcript\n\n\(transcript)")
            }
        }

        return parts.joined(separator: "\n\n")
    }

    /// Read `transcript.jsonl` and render one `[mm:ss] text` line per final
    /// segment. Returns nil when the JSONL is missing, empty, or undecodable —
    /// callers fall back to the plain `transcript.txt` rendering.
    static func formattedTranscript(sessionDir: URL) -> String? {
        let jsonlURL = sessionDir.appendingPathComponent("transcript.jsonl")
        guard let data = try? Data(contentsOf: jsonlURL), !data.isEmpty else { return nil }

        let decoder = JSONDecoder()
        var lines: [String] = []
        // JSONL = one JSON object per line, separated by \n. Skip blank lines
        // and any line that fails to decode (defensive — the file is append-only
        // and a torn write at SIGKILL could leave a partial trailing line).
        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let lineData = Data(raw)
            guard let segment = try? decoder.decode(TranscriptSegment.self, from: lineData) else { continue }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("\(formatTimestamp(segment.start)) \(text)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Format `seconds` as `[mm:ss]` (zero-padded). Minutes can exceed 60 for
    /// long sessions — `[90:42]` for a 1.5-hour meeting is intentionally
    /// readable rather than wrapped to `[01:30:42]`.
    static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let mm = total / 60
        let ss = total % 60
        return String(format: "[%02d:%02d]", mm, ss)
    }

    // Copy src to destination, replacing any existing file at destination.
    private static func copyItem(from src: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: src, to: destination)
    }

    // Format date as yyyy-MM-dd_HH-mm for use in the default filename.
    static func formattedRecordedAt(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    // ISO-8601 string for YAML frontmatter.
    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - ExportError

enum ExportError: LocalizedError {
    case missingFile(URL)

    var errorDescription: String? {
        switch self {
        case .missingFile(let url): return "File not found: \(url.lastPathComponent)"
        }
    }
}
