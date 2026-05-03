import SwiftUI
import AppKit
import KeyboardShortcuts
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
    private var dictationHolder: AnyObject?      // DictationState (macOS 14+)
    private var pushToMarkdownHolder: AnyObject? // PushToMarkdownState (macOS 14+)

    // Library window controller. Stored as AnyObject to avoid @available on
    // a stored property (Swift disallows that). Cast at use-site with #available.
    private var libraryControllerHolder: AnyObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AC-6: minimum-OS gate. Deployment target is 12.3+; Recording / Library / Settings
        // require 14.0+. Anything older surfaces a single explanatory modal then quits.
        if !checkMinimumOS() {
            return
        }

        configureStatusItem()
        configureMenu()

        if #available(macOS 14.0, *) {
            bootstrapAppState()
            bootstrapHotkeys()
        }

        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            showOnboarding()
        }
    }

    /// Register global hotkeys for Meeting / Voice Note record + Library open.
    /// Defaults: ⌘⇧R / ⌘⇧N / ⌘⇧L. Users can rebind via System Settings (Wallop's
    /// approach — KeyboardShortcuts persists overrides in UserDefaults under the
    /// shortcut's name).
    @available(macOS 14.0, *)
    private func bootstrapHotkeys() {
        KeyboardShortcuts.onKeyDown(for: .toggleMeeting) { [weak self] in
            Task { @MainActor in self?.recordToggleAction() }
        }
        KeyboardShortcuts.onKeyDown(for: .toggleVoiceNote) { [weak self] in
            Task { @MainActor in self?.voiceNoteToggleAction() }
        }
        KeyboardShortcuts.onKeyDown(for: .openLibrary) { [weak self] in
            Task { @MainActor in self?.openLibraryAction() }
        }
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // If a recording is in progress, defer termination until stop() finishes
        // so segments are finalized and SleepAssertion is released. Returning
        // .terminateLater suspends the quit until we call NSApp.reply(...).
        if #available(macOS 14.0, *), let recorder = recorderState, recorder.status.isBusy {
            Task { @MainActor in
                await recorder.stop()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }

    /// Returns true when the OS is supported. On unsupported OS, surfaces a
    /// modal and terminates the app.
    @MainActor
    private func checkMinimumOS() -> Bool {
        let info = ProcessInfo.processInfo.operatingSystemVersion
        let major = info.majorVersion
        let minor = info.minorVersion

        // <12.3 — strictly unsupported (binary is built for 12.3+, but defensive).
        let isBelow12_3 = (major < 12) || (major == 12 && minor < 3)
        // 12.3-13.x — "best-effort" but the recorder/library/settings gate on 14.0+,
        // so the app is functionally inert. Tell the user clearly.
        let isBelow14 = major < 14

        if isBelow12_3 {
            let alert = NSAlert()
            alert.messageText = "macOS 12.3 or newer required"
            alert.informativeText = "Jarvis Note needs macOS 12.3 or newer for system audio capture. The recorder, Library, and Settings additionally require macOS 14.0 — please upgrade to use this build."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return false
        }

        if isBelow14 {
            let alert = NSAlert()
            alert.messageText = "macOS 14.0 or newer recommended"
            alert.informativeText = "You're on macOS \(major).\(minor). Recording, Library, and Settings require macOS 14.0+. The menu-bar icon will appear, but core features will be disabled. [Quit] to upgrade, [Continue] to inspect a stub UI."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Quit")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                NSApp.terminate(nil)
                return false
            }
        }

        return true
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

        // Version header — disabled menu item that shows what build is actually
        // running. Useful when rebuilding ad-hoc dev binaries: confirms whether
        // the app you're talking to is the latest one or a stale relaunch.
        let versionItem = NSMenuItem(title: "Jarvis Note \(Self.appVersionLine())", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let copyVersionItem = NSMenuItem(title: "Copy version info",
                                         action: #selector(copyVersionAction),
                                         keyEquivalent: "")
        copyVersionItem.target = self
        menu.addItem(copyVersionItem)

        menu.addItem(.separator())

        let recordItem = NSMenuItem(title: "Start Recording",
                                    action: #selector(recordToggleAction),
                                    keyEquivalent: "r")
        recordItem.keyEquivalentModifierMask = [.command, .shift]
        recordItem.target = self
        recordItem.identifier = NSUserInterfaceItemIdentifier("recordToggle")
        menu.addItem(recordItem)

        let voiceNoteItem = NSMenuItem(title: "Start Voice Note",
                                       action: #selector(voiceNoteToggleAction),
                                       keyEquivalent: "n")
        voiceNoteItem.keyEquivalentModifierMask = [.command, .shift]
        voiceNoteItem.target = self
        voiceNoteItem.identifier = NSUserInterfaceItemIdentifier("voiceNoteToggle")
        menu.addItem(voiceNoteItem)

        // Live mic mute — only meaningful while a recording is active.
        // menuNeedsUpdate enables / disables it based on RecorderState.status
        // and toggles the title between "Mute mic" and "Unmute mic".
        let muteItem = NSMenuItem(title: "Mute mic",
                                  action: #selector(toggleMicMuteAction),
                                  keyEquivalent: "m")
        muteItem.keyEquivalentModifierMask = [.command, .shift]
        muteItem.target = self
        muteItem.identifier = NSUserInterfaceItemIdentifier("toggleMicMute")
        menu.addItem(muteItem)

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

        let sessionStore: SessionStore
        do {
            sessionStore = try SessionStore(rootDir: recordingsDir, database: database)
        } catch {
            presentFatalSetupError("Could not create session store at \(recordingsDir.path).", error: error)
            return
        }

        // Settings load from UserDefaults / Keychain — pure read, safe to do
        // before migration. Stored on the side so the migration Task can pick
        // it up without recapturing.
        let settings = AppSettings()
        self.sharedSettings = settings

        // CRITICAL: do NOT publish recorder/dictation/database/sessionStore until
        // database.migrate() finishes. menuNeedsUpdate, hotkeys, and UI all read
        // recorderState; the moment that returns non-nil, an INSERT INTO sessions
        // can race the schema migration. Holding back the assignment is the only
        // reliable way to gate that path.
        Task { @MainActor in
            do {
                try await database.migrate()
            } catch {
                presentFatalSetupError("Could not migrate database.", error: error)
                return
            }

            // Migration complete — publish everything.
            self.databaseHolder = database
            self.sessionStoreHolder = sessionStore

            let recorder = RecorderState(database: database, sessionStore: sessionStore, settings: settings)
            self.recorderHolder = recorder

            // Dictation: register the global hotkey monitor. The pipeline itself
            // is rebuilt on every press so settings changes apply without relaunch.
            let dictation = DictationState(settings: settings)
            dictation.install()
            self.dictationHolder = dictation

            // Push-to-Markdown: same press/hold/release shape as Dictation,
            // saves a `.md` file at markdownExportFolder via MarkdownExporter
            // instead of pasting into the focused field.
            let p2md = PushToMarkdownState(settings: settings, sessionStore: sessionStore)
            p2md.install()
            self.pushToMarkdownHolder = p2md

            // Force a menu refresh so any stale "Recording requires macOS 14+"
            // labels flip to the real recorder-ready titles.
            statusItem?.menu?.update()

            // After migration, scan for orphan sessions and offer recovery.
            let coordinator = RecoveryCoordinator(sessionStore: sessionStore, database: database)
            let recoveryResult = await coordinator.runAtLaunch(rootDir: recordingsDir)
            switch recoveryResult {
            case .noOrphans, .userDeclined:
                break
            case .recovered(let n):
                let alert = NSAlert()
                alert.messageText = "Recovered \(n) session(s)"
                alert.informativeText = "Audio files were rebuilt from interrupted recordings. Open the Library to review."
                alert.alertStyle = .informational
                alert.runModal()
            case .partial(let r, let f):
                let alert = NSAlert()
                alert.messageText = "Recovery partial"
                alert.informativeText = "\(r) recovered, \(f) failed. Failed sessions remain on disk under \(recordingsDir.path)."
                alert.alertStyle = .warning
                alert.runModal()
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

    /// "0.0.2 (build 2)" — read at runtime from the bundle's Info.plist so the
    /// menu always reflects what's actually loaded, not a stale source-coded
    /// constant. Sole reason this exists: rebuild loops where the user can't
    /// tell whether the running instance is the latest binary or a stale one.
    @MainActor
    static func appVersionLine() -> String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        return "\(short) (build \(build))"
    }

    /// Copy a one-line version + system summary to the clipboard. Useful when
    /// reporting issues — paste it into chat / GitHub and the recipient knows
    /// exactly which build of which OS produced the problem.
    @MainActor
    @objc private func copyVersionAction() {
        let line = "Jarvis Note \(Self.appVersionLine()) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(line, forType: .string)
    }

    @MainActor
    @objc private func toggleMicMuteAction() {
        guard #available(macOS 14.0, *), let recorder = recorderState else { return }
        Task { @MainActor in await recorder.toggleMicMute() }
    }

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

    /// Toggle Voice Note Mode recording (⌘⇧N). Same lifecycle as Meeting toggle,
    /// but starts the recorder in `.voiceNote` mode so the post-process pipeline
    /// uses the voice-note prompt template.
    @MainActor
    @objc private func voiceNoteToggleAction() {
        guard #available(macOS 14.0, *) else { return }
        guard let recorder = recorderState else { return }
        Task { @MainActor in
            switch recorder.status {
            case .idle, .complete, .failed:
                await recorder.start(mode: .voiceNote)
            case .recording:
                await recorder.stop()
            case .transcribing:
                break
            }
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
        libraryWindowController.open(
            database: database,
            sessionStore: sessionStore,
            settings: appSettings,
            windowDelegate: self
        )
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

        guard let recorder = recorderState else {
            // recorderState is guarded by #available above; this path is unreachable in practice.
            return
        }

        let chatState = ChatState(
            settings: settings,
            database: database,
            sessionStore: sessionStore,
            recorder: recorder
        )
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
        let voiceNoteItem = menu.items.first(where: { $0.identifier?.rawValue == "voiceNoteToggle" })
        let muteItem = menu.items.first(where: { $0.identifier?.rawValue == "toggleMicMute" })
        guard let openLastItem = menu.items.first(where: { $0.identifier?.rawValue == "openLastSession" }) else { return }

        // Mute item: only meaningful while a recording is in flight.
        if #available(macOS 14.0, *), let recorder = recorderState, case .recording = recorder.status {
            muteItem?.isEnabled = true
            muteItem?.title = recorder.micMuted ? "Unmute mic" : "Mute mic"
        } else {
            muteItem?.isEnabled = false
            muteItem?.title = "Mute mic"
        }

        if #available(macOS 14.0, *), let recorder = recorderState {
            switch recorder.status {
            case .idle:
                recordItem.title = "Start Recording"
                recordItem.isEnabled = true
                voiceNoteItem?.title = "Start Voice Note"
                voiceNoteItem?.isEnabled = true
            case .recording:
                recordItem.title = "Stop Recording"
                recordItem.isEnabled = true
                voiceNoteItem?.title = "Stop Voice Note"
                voiceNoteItem?.isEnabled = true
            case .transcribing:
                recordItem.title = "Transcribing…"
                recordItem.isEnabled = false
                voiceNoteItem?.isEnabled = false
            case .complete:
                recordItem.title = "Start Recording"
                recordItem.isEnabled = true
                voiceNoteItem?.title = "Start Voice Note"
                voiceNoteItem?.isEnabled = true
            case .failed:
                recordItem.title = "Start Recording (last failed — see Settings)"
                recordItem.isEnabled = true
                voiceNoteItem?.title = "Start Voice Note"
                voiceNoteItem?.isEnabled = true
            }

            if case .complete = recorder.status {
                openLastItem.isEnabled = true
            } else {
                openLastItem.isEnabled = false
            }
        } else {
            recordItem.title = "Recording (macOS 14+ required)"
            recordItem.isEnabled = false
            voiceNoteItem?.isEnabled = false
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
        case "library":
            if #available(macOS 14.0, *) {
                // Only call didClose if the controller was actually created.
                (libraryControllerHolder as? LibraryWindowController)?.didClose()
            }
        case "onboarding":
            onboardingWindow = nil
        case "chat":
            chatWindow = nil
            chatHolder = nil
        default:
            break
        }
        maybeDemoteToAccessory()
    }

    /// Demote the app to .accessory only when no app-owned window is still on
    /// screen. The previous per-case checks each only knew about a subset of the
    /// other windows, so closing Settings while the Library was open would
    /// demote and yank the Library out of the foreground.
    @MainActor
    private func maybeDemoteToAccessory() {
        let libraryVisible: Bool = {
            if #available(macOS 14.0, *),
               let controller = libraryControllerHolder as? LibraryWindowController {
                return controller.isVisible
            }
            return false
        }()
        let anyVisible = settingsWindow != nil
            || onboardingWindow != nil
            || chatWindow != nil
            || libraryVisible
        if !anyVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
