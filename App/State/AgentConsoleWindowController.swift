import AppKit
import SwiftUI

// MARK: - AgentConsoleWindowController

/// Floating window that hosts the AgentConsoleView. Mirror of
/// LibraryWindowController + CameraBubbleWindowController patterns: single
/// NSWindow stored weakly, opened on demand, kept alive across show/hide.
///
/// Window characteristics:
///   - normal-size titled window (not a borderless bubble — this one is for
///     reading + typing, not glanceable)
///   - level = .floating so it stays on top of the user's editor while the
///     agent works
///   - canJoinAllSpaces so it survives Mission Control / fullscreen
///     transitions during long sessions
@available(macOS 14.0, *)
@MainActor
final class AgentConsoleWindowController {

    private weak var window: NSWindow?

    /// Open the console (creating it if needed) and bring to front.
    func open(session: AgentSessionState, windowDelegate: NSWindowDelegate) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = AgentConsoleView(session: session)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Agent Console"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 540, height: 480))
        win.minSize = NSSize(width: 380, height: 280)
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]
        win.center()
        win.identifier = NSUserInterfaceItemIdentifier("agentConsole")
        win.delegate = windowDelegate
        self.window = win

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// Called by AppDelegate's windowWillClose so we drop the strong cycle.
    func didClose() {
        window = nil
    }

    /// True when the window is on screen — used by maybeDemoteToAccessory().
    var isVisible: Bool {
        window?.isVisible == true
    }
}
