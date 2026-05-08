import Foundation
import SharingKit
import StorageKit

@available(macOS 14.0, *)
enum SessionSharePlanning {

    enum SelectionError: Error {
        case emptySelection
    }

    static func validatedSelection(_ artifacts: [SharedArtifactKind]) throws -> [SharedArtifactKind] {
        guard !artifacts.isEmpty else {
            throw SelectionError.emptySelection
        }
        return artifacts
    }

    static func snapshot(
        from result: SharingService.ShareResult,
        sharedAt: Date
    ) -> SharedLinksSnapshot {
        let links = [
            result.audioURL.map { SharedLinkRecord(kind: .audio, url: $0) },
            result.videoURL.map { SharedLinkRecord(kind: .video, url: $0) },
            result.summaryURL.map { SharedLinkRecord(kind: .summary, url: $0) },
            result.transcriptURL.map { SharedLinkRecord(kind: .transcript, url: $0) },
        ].compactMap { $0 }

        return SharedLinksSnapshot(sharedAt: sharedAt, links: links)
    }
}
