import Foundation

public enum SharedArtifactKind: String, Codable, CaseIterable, Sendable, Equatable {
    case audio
    case video
    case summary
    case transcript

    public var fileName: String {
        switch self {
        case .audio: return "audio.m4a"
        case .video: return "screen.mp4"
        case .summary: return "summary.md"
        case .transcript: return "transcript.txt"
        }
    }

    public var displayName: String {
        switch self {
        case .audio: return "Audio (.m4a)"
        case .video: return "Screen recording (.mp4)"
        case .summary: return "Summary (.md)"
        case .transcript: return "Transcript (.txt)"
        }
    }
}

public struct SharedLinkRecord: Codable, Equatable, Sendable {
    public let kind: SharedArtifactKind
    public let url: URL

    public init(kind: SharedArtifactKind, url: URL) {
        self.kind = kind
        self.url = url
    }
}

public struct SharedLinksSnapshot: Codable, Equatable, Sendable {
    public let sharedAt: Date
    public let links: [SharedLinkRecord]

    public init(sharedAt: Date, links: [SharedLinkRecord]) {
        self.sharedAt = sharedAt
        self.links = links
    }
}
