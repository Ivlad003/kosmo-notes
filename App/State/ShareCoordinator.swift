import AppKit
import Foundation
import Observation
import SharingKit
import StorageKit

// MARK: - ShareCoordinator

/// Builds an `S3Client` from the user's `AppSettings` and uploads a session's
/// sidecars. Surfaces a result modal with copy-to-pasteboard buttons.
@available(macOS 14.0, *)
@MainActor
final class ShareCoordinator {

    private let settings: AppSettings
    private let sessionStore: SessionStore

    init(settings: AppSettings, sessionStore: SessionStore) {
        self.settings = settings
        self.sessionStore = sessionStore
    }

    /// Validate config + upload + present URLs. Surfaces an alert on success or failure.
    func share(sessionId: String) async {
        // Validate required fields up front so users see a clear error before we
        // try to encode an empty endpoint into a URL.
        guard let url = URL(string: settings.s3Endpoint), !settings.s3Endpoint.isEmpty else {
            alert("Set the S3 endpoint in Settings → Sharing first.")
            return
        }
        let bucket = settings.s3Bucket.trimmingCharacters(in: .whitespaces)
        guard !bucket.isEmpty else {
            alert("Set the S3 bucket name in Settings → Sharing first.")
            return
        }
        let access = settings.s3AccessKey.trimmingCharacters(in: .whitespaces)
        let secret = settings.s3SecretKey.trimmingCharacters(in: .whitespaces)
        guard !access.isEmpty, !secret.isEmpty else {
            alert("Set the S3 Access Key + Secret Access Key in Settings → Sharing first.")
            return
        }

        let client = S3Client(
            endpoint: url,
            region: settings.s3Region.isEmpty ? "us-east-1" : settings.s3Region,
            bucket: bucket,
            credentials: SigV4.Credentials(accessKeyId: access, secretAccessKey: secret)
        )
        let service = SharingService(
            s3: client,
            keyPrefix: "jarvis-note/",
            presignTTLSeconds: max(1, settings.s3PresignTTLHours) * 3600
        )

        do {
            let available = await sessionStore.availableShareArtifacts(for: sessionId)
            guard !available.isEmpty else {
                alert("No shareable artifacts were found for this session.")
                return
            }

            guard let selected = selectArtifacts(from: available) else {
                return
            }

            let artifacts = try SessionSharePlanning.validatedSelection(selected)
            let dir = await sessionStore.sessionDir(for: sessionId)
            let result = try await service.shareSession(
                sessionDir: dir,
                sessionId: sessionId,
                artifacts: artifacts
            )
            let snapshot = SessionSharePlanning.snapshot(from: result, sharedAt: Date())
            try await sessionStore.saveSharedLinksSnapshot(snapshot, for: sessionId)
            presentResult(result)
        } catch SessionSharePlanning.SelectionError.emptySelection {
            alert("Select at least one file to share.")
        } catch {
            alert("Upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - UI

    private func presentResult(_ result: SharingService.ShareResult) {
        let alert = NSAlert()
        alert.messageText = "Session shared"
        alert.alertStyle = .informational

        var lines: [String] = []
        if let u = result.audioURL { lines.append("Audio: \(u.absoluteString)") }
        if let u = result.videoURL { lines.append("Video: \(u.absoluteString)") }
        if let u = result.summaryURL { lines.append("Summary: \(u.absoluteString)") }
        if let u = result.transcriptURL { lines.append("Transcript: \(u.absoluteString)") }

        alert.informativeText = lines.isEmpty
            ? "No artifacts uploaded — the session folder was empty."
            : lines.joined(separator: "\n\n")

        if let primary = result.videoURL ?? result.audioURL ?? result.summaryURL ?? result.transcriptURL {
            alert.addButton(withTitle: "Copy primary link")
            alert.addButton(withTitle: "Copy all")
            alert.addButton(withTitle: "Done")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                copyToPasteboard(primary.absoluteString)
            case .alertSecondButtonReturn:
                copyToPasteboard(result.allLinks.map(\.absoluteString).joined(separator: "\n"))
            default:
                break
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func selectArtifacts(from available: [SharedArtifactKind]) -> [SharedArtifactKind]? {
        let alert = NSAlert()
        alert.messageText = "Choose files to share"
        alert.informativeText = "Only the selected files will be uploaded to S3."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Share")
        alert.addButton(withTitle: "Cancel")

        let buttons = available.map { kind in
            let button = NSButton(checkboxWithTitle: kind.displayName, target: nil, action: nil)
            button.state = .on
            return button
        }

        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        return zip(available, buttons).compactMap { kind, button in
            button.state == .on ? kind : nil
        }
    }

    private func alert(_ message: String) {
        let a = NSAlert()
        a.messageText = "Share"
        a.informativeText = message
        a.alertStyle = .warning
        a.runModal()
    }
}
