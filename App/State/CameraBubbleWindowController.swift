import AppKit
import CaptureKit
import SwiftUI

// MARK: - CameraBubbleWindowController

/// Owns the floating Loom-style camera bubble window during a recording.
///
/// Window characteristics:
///   - borderless, no title bar
///   - clear background, with shadow
///   - `level = .floating` so it sits above app windows but below system UI
///   - `isMovableByWindowBackground = true` so the user can grab anywhere
///     inside the circle and drag the bubble around
///   - `collectionBehavior` includes `.canJoinAllSpaces` + `.fullScreenAuxiliary`
///     so the bubble survives Mission Control / fullscreen app transitions
///     during a long recording
///
/// Because the bubble is a real on-screen NSWindow, ScreenCaptureKit picks
/// it up automatically — no real-time CIImage compositing needed. Same trick
/// Loom and CamBubble use.
@available(macOS 14.0, *)
@MainActor
final class CameraBubbleWindowController {

    private weak var window: NSWindow?
    private let bubble = CameraBubble()
    private var settings: AppSettings?
    private var moveObserver: Any?
    private var resizeObserver: Any?

    // MARK: - Public API

    /// Open the bubble window and start the camera capture. Idempotent —
    /// if the bubble is already up, just brings it to front.
    func show(settings: AppSettings) async {
        self.settings = settings

        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Start the capture session first so the preview layer exists by the
        // time the SwiftUI view tries to attach it.
        do {
            try await bubble.start(config: .init(deviceUniqueID: settings.cameraDeviceUID))
        } catch {
            // Permission denied / no device / etc — silently abort. The
            // recording continues without the bubble. PermissionsHelper
            // surfaces the alert; here we just don't open the window.
            return
        }

        let size = max(120, min(500, settings.cameraBubbleSize))
        let origin = settings.cameraBubblePosition

        let frame = NSRect(x: origin.x, y: origin.y, width: size, height: size)
        let win = NSWindow(
            contentRect: frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false  // we draw the shadow inside the SwiftUI view
        win.level = .floating
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.minSize = NSSize(width: 120, height: 120)
        win.identifier = NSUserInterfaceItemIdentifier("cameraBubble")
        // Hide from window-cycling and Mission Control thumbnails.
        win.isExcludedFromWindowsMenu = true

        let host = NSHostingController(rootView: CameraBubbleView(bubble: bubble))
        win.contentViewController = host

        win.orderFrontRegardless()
        self.window = win

        // Persist the user's drag/resize back into settings so the bubble
        // appears in the same spot next session.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            guard let win = self?.window, let settings = self?.settings else { return }
            settings.cameraBubblePosition = win.frame.origin
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            guard let win = self?.window, let settings = self?.settings else { return }
            // Force square — keep width = height even when user drags a corner.
            let edge = max(win.frame.width, win.frame.height)
            if win.frame.width != edge || win.frame.height != edge {
                var f = win.frame
                f.size.width = edge
                f.size.height = edge
                win.setFrame(f, display: true)
            }
            settings.cameraBubbleSize = Double(edge)
        }
    }

    /// Tear down the window and stop the camera. Safe to call when nothing
    /// is open — no-op in that case.
    func hide() async {
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
            moveObserver = nil
        }
        if let observer = resizeObserver {
            NotificationCenter.default.removeObserver(observer)
            resizeObserver = nil
        }
        await bubble.stop()
        if let win = window {
            win.orderOut(nil)
            win.contentViewController = nil
        }
        window = nil
    }

    /// True while the bubble is on screen.
    var isVisible: Bool {
        window?.isVisible == true
    }
}
