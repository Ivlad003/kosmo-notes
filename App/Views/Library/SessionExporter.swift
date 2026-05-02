import AppKit
import Foundation
import UniformTypeIdentifiers
import StorageKit

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

        // Transcript block
        let transcriptURL = sessionDir.appendingPathComponent("transcript.txt")
        if let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8), !transcript.isEmpty {
            parts.append("## Transcript\n\n\(transcript)")
        }

        return parts.joined(separator: "\n\n")
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
