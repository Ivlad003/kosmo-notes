@preconcurrency import AVFoundation
import Foundation
import os

private let cameraBubbleLog = Logger(subsystem: "dev.jarvisnote.studio", category: "CameraBubble")

// MARK: - CameraBubble

/// Live front-camera capture for the Loom-style floating webcam bubble that
/// sits on top of the screen during a recording.
///
/// We deliberately do NOT push frames into the screen.mp4 here. The bubble is
/// rendered into a borderless, floating, click-through-when-not-focused
/// `NSWindow` that sits above all other content. Because `ScreenCaptureKit`
/// captures whatever is on the user's display, the camera window lands inside
/// `screen.mp4` automatically — same way Loom and CamBubble do it. No
/// real-time CIImage compositing required; the OS does the work for us.
///
/// The actor owns the AVCaptureSession and exposes the configured
/// `AVCaptureVideoPreviewLayer` to the SwiftUI host (via a `nonisolated` getter
/// since the layer is what the UI binds to and it's safe to read from the
/// main thread once `start()` has returned).
public actor CameraBubble {

    public struct Config: Sendable {
        /// Persistent unique ID of the AVCaptureDevice to use. Empty string
        /// (default) → pick the system default video device.
        public let deviceUniqueID: String
        /// Target session preset. `.high` (default) gives ~1280×720 @ 30 fps,
        /// which scales down to a 200pt circle without artifacts.
        public let preset: AVCaptureSession.Preset

        public init(deviceUniqueID: String = "", preset: AVCaptureSession.Preset = .high) {
            self.deviceUniqueID = deviceUniqueID
            self.preset = preset
        }
    }

    public enum CameraError: Error, Sendable {
        case permissionDenied
        case deviceNotFound(uniqueID: String?)
        case inputCreationFailed(underlying: Error)
        case inputNotAcceptedBySession
    }

    /// `AVCaptureVideoPreviewLayer` is what SwiftUI's `NSViewRepresentable`
    /// host attaches to render the live frame. Marked nonisolated(unsafe)
    /// because the layer is thread-safe to read once `start()` has returned
    /// (AVFoundation guarantees this); the SwiftUI thread reads, the actor
    /// thread writes, and we only write from inside the actor.
    public nonisolated(unsafe) private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    private let session = AVCaptureSession()
    private var currentDevice: AVCaptureDevice?
    private var isRunning: Bool = false

    public init() {}

    // MARK: - Lifecycle

    /// Spin up the capture session against the requested device. Idempotent —
    /// calling `start()` again with the same config is a no-op; with a
    /// different device, the input is swapped without tearing the layer down.
    public func start(config: Config) async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            break
        case .notDetermined:
            // Trigger the system Camera prompt. Caller already pre-flighted
            // via PermissionsHelper but we also handle the .notDetermined case
            // here so a programmatic start() works in tests / direct callers.
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                throw CameraError.permissionDenied
            }
        case .denied, .restricted:
            throw CameraError.permissionDenied
        @unknown default:
            throw CameraError.permissionDenied
        }

        let device = try resolveDevice(uniqueID: config.deviceUniqueID)
        cameraBubbleLog.info("CameraBubble.start: device=\(device.localizedName, privacy: .public) preset=\(config.preset.rawValue, privacy: .public)")

        session.beginConfiguration()
        session.sessionPreset = config.preset

        // Replace existing input if device changed.
        for existing in session.inputs {
            session.removeInput(existing)
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw CameraError.inputCreationFailed(underlying: error)
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.inputNotAcceptedBySession
        }
        session.addInput(input)
        currentDevice = device

        session.commitConfiguration()

        if previewLayer == nil {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            previewLayer = layer
        }

        if !session.isRunning {
            session.startRunning()
        }
        isRunning = true
    }

    /// Stop capture and tear down. Layer is preserved but goes blank — caller
    /// can `start` again to reuse it.
    public func stop() async {
        if session.isRunning {
            session.stopRunning()
        }
        for input in session.inputs {
            session.removeInput(input)
        }
        currentDevice = nil
        isRunning = false
        cameraBubbleLog.info("CameraBubble.stop: session torn down")
    }

    // MARK: - Device discovery

    /// All currently-connected video capture devices the user can pick from.
    /// `nonisolated` because `DiscoverySession` is thread-safe to query.
    public nonisolated static func availableDevices() -> [AVCaptureDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,   // FaceTime HD on Macs
                .deskViewCamera,           // Continuity-Camera Desk View on iPhone
                .external,                 // USB / iPhone-as-webcam (Continuity Camera)
            ],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices
    }

    // MARK: - Private

    private func resolveDevice(uniqueID: String) throws -> AVCaptureDevice {
        if !uniqueID.isEmpty,
           let match = AVCaptureDevice(uniqueID: uniqueID) {
            return match
        }
        if let preferred = AVCaptureDevice.default(for: .video) {
            return preferred
        }
        if let any = Self.availableDevices().first {
            return any
        }
        throw CameraError.deviceNotFound(uniqueID: uniqueID.isEmpty ? nil : uniqueID)
    }
}
