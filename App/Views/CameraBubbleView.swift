@preconcurrency import AVFoundation
import AppKit
import CaptureKit
import SwiftUI

// MARK: - CameraBubbleView

/// SwiftUI view that hosts the live camera feed inside a circular mask.
/// Wraps an `AVCaptureVideoPreviewLayer` via `NSViewRepresentable`, then
/// applies a `Circle()` clip + thin border so it reads as a Loom-style
/// floating webcam bubble.
@available(macOS 14.0, *)
struct CameraBubbleView: View {

    let bubble: CameraBubble

    var body: some View {
        ZStack {
            // Solid black behind the layer so any letter-boxing edge looks
            // intentional rather than transparent.
            Circle()
                .fill(Color.black)

            CameraPreviewNSView(bubble: bubble)
                .clipShape(Circle())

            // Thin white ring + soft outer shadow — same visual language as
            // Loom's bubble, makes the circle pop on dark / busy desktops.
            Circle()
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 3)
        .padding(4)
    }
}

// MARK: - CameraPreviewNSView

/// `NSViewRepresentable` that hosts the AVCaptureVideoPreviewLayer pulled
/// off the `CameraBubble` actor. The layer is owned by the actor; this view
/// just attaches it to a backing `CALayer` tree.
@available(macOS 14.0, *)
private struct CameraPreviewNSView: NSViewRepresentable {

    let bubble: CameraBubble

    func makeNSView(context: Context) -> NSView {
        let view = LayerHostView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        attachPreview(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attachPreview(to: nsView)
    }

    private func attachPreview(to view: NSView) {
        // CameraBubble.previewLayer is nonisolated(unsafe) — safe to read
        // from main thread once start() has returned.
        guard let preview = bubble.previewLayer else { return }
        guard preview.superlayer !== view.layer else { return }
        preview.removeFromSuperlayer()
        preview.frame = view.bounds
        view.layer?.addSublayer(preview)
    }
}

/// Trivial NSView subclass that resizes the preview layer when the window
/// changes size (drag-to-resize, etc.). NSView's default layer does NOT
/// auto-resize sublayers, so we hand-fix the frame on each layout pass.
@available(macOS 14.0, *)
private final class LayerHostView: NSView {
    override func layout() {
        super.layout()
        guard let sublayers = layer?.sublayers else { return }
        for sub in sublayers {
            sub.frame = bounds
        }
    }
}
