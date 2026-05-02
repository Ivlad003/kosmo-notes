import SwiftUI
import AppKit

@main
struct JarvisNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform.circle",
            accessibilityDescription: "Jarvis Note"
        )
        item.button?.action = #selector(statusItemClicked)
        item.button?.target = self
        self.statusItem = item

        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            showOnboarding()
        }
    }

    @objc func statusItemClicked() {
        // Phase 0 Day 1: no-op. Popover lands in Phase A.
    }

    private func showOnboarding() {
        let didOnboardBinding = Binding<Bool>(
            get: { UserDefaults.standard.bool(forKey: "didOnboard") },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: "didOnboard")
                if newValue {
                    self.onboardingWindow?.close()
                    self.onboardingWindow = nil
                }
            }
        )

        let contentView = OnboardingView(didOnboard: didOnboardBinding)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Jarvis Note"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.onboardingWindow = window
    }
}
