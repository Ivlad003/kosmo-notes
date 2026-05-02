import SwiftUI
import AppKit
import StorageKit

@main
struct JarvisNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Stub Settings scene — required by SwiftUI App. Real Settings UI
        // is hosted in a custom NSWindow managed by AppDelegate, because
        // the SwiftUI Settings window doesn't reliably surface from a
        // menu-bar-only app (LSUIElement: true).
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var chatWindow: NSWindow?

    // Shared app singletons. Created on launch, kept for the lifetime of the
    // process. macOS-14-only — guarded by `if #available` at construction.
    private var sharedSettings: AnyObject?      // AppSettings (macOS 14+)
    private var recorderHolder: AnyObject?       // RecorderState (macOS 14+)
    private var databaseHolder: AnyObject?       // AppDatabase
    private var sessionStoreHolder: AnyObject?   // SessionStore
    private var chatHolder: AnyObject?           // ChatState (macOS 14+)

    // Library window controller. Stored as AnyObject to avoid @available on
    // a stored property (Swift disallows that). Cast at use-site with #available.
    private var libraryControllerHolder: AnyObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureMenu()

        if #available(macOS 14.0, *) {
            bootstrapAppState()
        }

        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            showOnboarding()
        }
    }

    // MARK: - Status item + menu

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Jarvis Note") {
            item.button?.image = image
        }
        item.button?.title = "JN"
        item.button?.imagePosition = .imageLeading
        item.length = NSStatusItem.variableLength
        item.isVisible = true
        self.statusItem = item
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let recordItem = NSMenuItem(title: "Start Recording",
                                    action: #selector(recordToggleAction),
                                    keyEquivalent: "r")
        recordItem.keyEquivalentModifierMask = [.command, .shift]
        recordItem.target = self
        recordItem.identifier = NSUserInterfaceItemIdentifier("recordToggle")
        menu.addItem(recordItem)

        menu.addItem(.separator())

        let openLastSessionItem = NSMenuItem(title: "Open last session in Finder",
                                             action: #selector(openLastSessionAction),
                                             keyEquivalent: "")
        openLastSessionItem.target = self
        openLastSessionItem.identifier = NSUserInterfaceItemIdentifier("openLastSession")
        menu.addItem(openLastSessionItem)

        let libraryItem = NSMenuItem(title: "Library…",
                                     action: #selector(openLibraryAction),
                                     keyEquivalent: "l")
        libraryItem.target = self
        menu.addItem(libraryItem)

        menu.addItem(.separator())

        let chatItem = NSMenuItem(title: "Chat…",
                                  action: #selector(openChat),
                                  keyEquivalent: "t")
        chatItem.keyEquivalentModifierMask = [.command]
        chatItem.target = self
        menu.addItem(chatItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Jarvis Note",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        // Leave target = nil so the responder chain reaches NSApp.terminate(_:).
        menu.addItem(quitItem)

        statusItem?.menu = menu
        self.menu = menu
    }

    // MARK: - App state bootstrap (macOS 14+)

    @available(macOS 14.0, *)
    private func bootstrapAppState() {
        let appSupport: URL
        do {
            appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            presentFatalSetupError("Could not locate Application Support directory.", error: error)
            return
        }

        let appDir = appSupport.appendingPathComponent("JarvisNote", isDirectory: true)
        let recordingsDir = appDir.appendingPathComponent("recordings", isDirectory: true)
        let dbPath = appDir.appendingPathComponent("sessions.sqlite")

        do {
            try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        } catch {
            presentFatalSetupError("Could not create recordings directory at \(recordingsDir.path).", error: error)
            return
        }

        let database: AppDatabase
        do {
            database = try AppDatabase(path: dbPath)
        } catch {
            presentFatalSetupError("Could not open database at \(dbPath.path).", error: error)
            return
        }
        self.databaseHolder = database

        let sessionStore: SessionStore
        do {
            sessionStore = try SessionStore(rootDir: recordingsDir, database: database)
        } catch {
            presentFatalSetupError("Could not create session store at \(recordingsDir.path).", error: error)
            return
        }
        self.sessionStoreHolder = sessionStore

        let settings = AppSettings()
        self.sharedSettings = settings

        let recorder = RecorderState(database: database, sessionStore: sessionStore, settings: settings)
        self.recorderHolder = recorder

        Task { @MainActor in
            do {
                try await database.migrate()
            } catch {
                presentFatalSetupError("Could not migrate database.", error: error)
            }
        }
    }

    private func presentFatalSetupError(_ message: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = "Jarvis Note setup failed"
        alert.informativeText = "\(message)\n\n\(error.localizedDescription)"
        alert.alertStyle = .critical
        alert.runModal()
    }

    @available(macOS 14.0, *)
    private var recorderState: RecorderState? {
        recorderHolder as? RecorderState
    }

    @available(macOS 14.0, *)
    private var appSettings: AppSettings? {
        sharedSettings as? AppSettings
    }

    @available(macOS 14.0, *)
    private var appDatabase: AppDatabase? {
        databaseHolder as? AppDatabase
    }

    @available(macOS 14.0, *)
    private var appSessionStore: SessionStore? {
        sessionStoreHolder as? SessionStore
    }

    // Returns the shared LibraryWindowController, creating it on first access.
    @available(macOS 14.0, *)
    private var libraryWindowController: LibraryWindowController {
        if let existing = libraryControllerHolder as? LibraryWindowController {
            return existing
        }
        let controller = LibraryWindowController()
        libraryControllerHolder = controller
        return controller
    }

    // MARK: - Menu actions

    @objc private func recordToggleAction() {
        guard #available(macOS 14.0, *) else {
            let alert = NSAlert()
            alert.messageText = "Recording requires macOS 14.0+"
            alert.runModal()
            return
        }
        guard let recorder = recorderState else { return }
        Task { @MainActor in
            await recorder.toggle()
            switch recorder.status {
            case .complete(_, let audioFile, let preview):
                NSWorkspace.shared.activateFileViewerSelecting([audioFile])
                let alert = NSAlert()
                alert.messageText = "Recording complete"
                alert.informativeText = preview.isEmpty ? "Transcript saved to the session folder." : preview
                alert.alertStyle = .informational
                alert.runModal()
            case .failed(let message):
                let alert = NSAlert()
                alert.messageText = "Recording failed"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.runModal()
            default:
                break  // .recording / .transcribing / .idle — no popup
            }
        }
    }

    @objc private func openLastSessionAction() {
        guard #available(macOS 14.0, *), let recorder = recorderState else { return }
        if case .complete(_, let audioFile, _) = recorder.status {
            NSWorkspace.shared.activateFileViewerSelecting([audioFile])
        }
    }

    @MainActor
    @objc private func openLibraryAction() {
        guard #available(macOS 14.0, *) else {
            let alert = NSAlert()
            alert.messageText = "Library requires macOS 14.0+"
            alert.runModal()
            return
        }
        guard let database = databaseHolder as? AppDatabase,
              let sessionStore = sessionStoreHolder as? SessionStore else { return }
        libraryWindowController.open(database: database, sessionStore: sessionStore, windowDelegate: self)
    }

    @MainActor
    @objc private func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        guard #available(macOS 14.0, *), let settings = appSettings else {
            let alert = NSAlert()
            alert.messageText = "Settings require macOS 14.0+"
            alert.runModal()
            return
        }

        let view = SettingsView(settings: settings)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Jarvis Note Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        self.settingsWindow = window
    }

    @MainActor
    @objc private func openChat() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let existing = chatWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        guard #available(macOS 14.0, *),
              let settings = appSettings,
              let database = appDatabase,
              let sessionStore = appSessionStore else {
            let alert = NSAlert()
            alert.messageText = "Chat requires macOS 14.0+"
            alert.runModal()
            return
        }

        let chatState = ChatState(settings: settings, database: database, sessionStore: sessionStore)
        self.chatHolder = chatState

        let view = ChatView(chat: chatState, settings: settings)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Jarvis Note Chat"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 540, height: 700))
        window.minSize = NSSize(width: 540, height: 600)
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("chat")
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        self.chatWindow = window
    }

    private func showOnboarding() {
        let didOnboardBinding = Binding<Bool>(
            get: { UserDefaults.standard.bool(forKey: "didOnboard") },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: "didOnboard")
                if newValue {
                    self.onboardingWindow?.close()
                    self.onboardingWindow = nil
                    if self.settingsWindow == nil {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        )

        let contentView = OnboardingView(didOnboard: didOnboardBinding)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Jarvis Note"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("onboarding")
        window.delegate = self

        NSApp.setActivationPolicy(.regular)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.onboardingWindow = window
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let recordItem = menu.items.first(where: { $0.identifier?.rawValue == "recordToggle" }) else { return }
        guard let openLastItem = menu.items.first(where: { $0.identifier?.rawValue == "openLastSession" }) else { return }

        if #available(macOS 14.0, *), let recorder = recorderState {
            switch recorder.status {
            case .idle:
                recordItem.title = "Start Recording"
                recordItem.isEnabled = true
            case .recording:
                recordItem.title = "Stop Recording"
                recordItem.isEnabled = true
            case .transcribing:
                recordItem.title = "Transcribing…"
                recordItem.isEnabled = false
            case .complete:
                recordItem.title = "Start Recording"
                recordItem.isEnabled = true
            case .failed:
                recordItem.title = "Start Recording (last failed — see Settings)"
                recordItem.isEnabled = true
            }

            if case .complete = recorder.status {
                openLastItem.isEnabled = true
            } else {
                openLastItem.isEnabled = false
            }
        } else {
            recordItem.title = "Recording (macOS 14+ required)"
            recordItem.isEnabled = false
            openLastItem.isEnabled = false
        }
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        switch window.identifier?.rawValue {
        case "settings":
            settingsWindow = nil
            if onboardingWindow == nil && chatWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
        case "library":
            if #available(macOS 14.0, *) {
                // Only call didClose if the controller was actually created.
                (libraryControllerHolder as? LibraryWindowController)?.didClose()
            }
            if settingsWindow == nil, onboardingWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
        case "onboarding":
            onboardingWindow = nil
        case "chat":
            chatWindow = nil
            chatHolder = nil
            if settingsWindow == nil && onboardingWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
        default:
            break
        }
    }
}
