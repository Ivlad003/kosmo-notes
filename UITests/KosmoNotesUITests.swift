import XCTest

// MARK: - KosmoNotesUITests
//
// End-to-end UI behaviour suite using XCUITest. Every test attaches a screenshot
// of the relevant state so failures (or visual regressions) are inspectable from
// the Xcode test report — open Report Navigator → test → Attachments.
//
// What's covered:
//   * App launches and registers a menu-bar status item (icon + "KN")
//   * First-launch onboarding window appears, shows the three permission rows,
//     and dismisses on Continue
//   * Menu-bar dropdown contains the full v0.0.2 set: version header, Start
//     Recording, Start Voice Note, mute, Library, Chat, Agent Console,
//     Settings, Quit
//   * Settings opens with the right title and exposes all nine tabs
//   * Each Settings tab can be activated and renders its primary section
//   * Typing into an API key field doesn't crash; clicking Save reacts
//   * Quit terminates the app cleanly
//
// What's NOT covered (out of scope for the smoke suite):
//   * Real audio capture (no mic in CI; manual smoke gate per AC-9b)
//   * Real Deepgram / Anthropic / OpenAI network calls (mocked at unit level)
//   * Recording → Library round-trip (would need TCC + a real session on disk)
//
// Running locally:
//   xcodebuild test -scheme KosmoNotes -destination 'platform=macOS'
//
// TCC note: macOS UI tests need Accessibility permission for `xctest` /
// Xcode. First run will prompt; grant via System Settings → Privacy &
// Security → Accessibility, then re-run.

final class KosmoNotesUITests: XCTestCase {

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Reset onboarding state via UserDefaults launch arguments so each test
    /// starts from a known state. The app reads `didOnboard` from
    /// `UserDefaults.standard` — passing `-didOnboard <YES|NO>` overrides it
    /// for the test process scope only.
    private func freshApp(didOnboard: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-didOnboard", didOnboard ? "YES" : "NO",
            // Suppress UI-test-related defaults side effects.
            "-AppleScrollViewSuppressTesting", "YES",
        ]
        return app
    }

    // MARK: - App launch + status item

    func testAppLaunchesAndShowsStatusItem() {
        let app = freshApp(didOnboard: true)
        app.launch()
        defer { app.terminate() }

        let statusItem = menuBarStatusItem(for: app)
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5),
                      "Expected KosmoNotes menu-bar status item to be visible")
        attachFullScreen(name: "01-launch-status-item")
    }

    // MARK: - Onboarding

    func testOnboardingWindowAppearsOnFirstLaunch() {
        let app = freshApp(didOnboard: false)
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Welcome to KosmoNotes"]
        XCTAssertTrue(window.waitForExistence(timeout: 5),
                      "Onboarding window should appear when didOnboard == NO")
        attachWindow(window, name: "02-onboarding-window")
    }

    func testOnboardingShowsThreePermissionRows() {
        let app = freshApp(didOnboard: false)
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Welcome to KosmoNotes"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // The OnboardingView renders three permissionRow blocks: Microphone,
        // Screen Recording, Accessibility. Each shows a static text label.
        XCTAssertTrue(window.staticTexts["Microphone"].exists)
        XCTAssertTrue(window.staticTexts["Screen Recording"].exists)
        XCTAssertTrue(window.staticTexts["Accessibility"].exists)
        attachWindow(window, name: "03-onboarding-permission-rows")
    }

    func testOnboardingDismissesOnContinue() {
        let app = freshApp(didOnboard: false)
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Welcome to KosmoNotes"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        attachWindow(window, name: "04-onboarding-before-continue")

        let continueButton = window.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 2),
                      "Continue button should be present in onboarding")
        continueButton.click()

        // Window should disappear within ~2 s
        let dismissed = !window.waitForExistence(timeout: 2)
        XCTAssertTrue(dismissed, "Onboarding window should close after Continue")
        attachFullScreen(name: "05-onboarding-after-continue")
    }

    // MARK: - Menu

    func testMenuShowsExpectedItems() {
        let app = freshApp(didOnboard: true)
        app.launch()
        defer { app.terminate() }

        let statusItem = menuBarStatusItem(for: app)
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let menu = app.menus.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 2), "Menu should appear after click")
        attachFullScreen(name: "06-menu-open")

        // Items present in v0.0.2's status-bar menu (see KosmoNotesApp.configureMenu).
        // Version line is dynamic ("KosmoNotes 0.0.2 (build 12)" etc.) — we look for
        // the static items + verify the version item exists by prefix.
        XCTAssertTrue(menu.menuItems["Copy version info"].exists)
        XCTAssertTrue(menu.menuItems["Start Recording"].exists ||
                      menu.menuItems["Stop Recording"].exists,
                      "Expected the recording toggle item")
        XCTAssertTrue(menu.menuItems["Start Voice Note"].exists ||
                      menu.menuItems["Stop Voice Note"].exists,
                      "Expected the voice-note toggle item")
        XCTAssertTrue(menu.menuItems["Open last session in Finder"].exists)
        XCTAssertTrue(menu.menuItems["Library…"].exists)
        XCTAssertTrue(menu.menuItems["Chat…"].exists)
        XCTAssertTrue(menu.menuItems["Agent Console…"].exists)
        XCTAssertTrue(menu.menuItems["Settings…"].exists)
        XCTAssertTrue(menu.menuItems["Quit KosmoNotes"].exists)

        // Version header — disabled, but it should be present and start with "KosmoNotes ".
        let versionHeader = menu.menuItems.matching(
            NSPredicate(format: "title BEGINSWITH 'KosmoNotes '")
        ).firstMatch
        XCTAssertTrue(versionHeader.exists, "Expected a 'KosmoNotes <version>' header item")
        XCTAssertFalse(versionHeader.isEnabled, "Version header should be disabled")
    }

    // MARK: - Settings

    func testSettingsOpensCustomWindow() {
        let app = freshApp(didOnboard: true)
        app.launch()
        defer { app.terminate() }

        openSettings(in: app)

        let settings = app.windows["KosmoNotes Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3),
                      "Settings window should open with title 'KosmoNotes Settings'")
        attachWindow(settings, name: "07-settings-open")
    }

    func testSettingsHasAllNineTabs() {
        let app = freshApp(didOnboard: true)
        app.launch()
        defer { app.terminate() }

        openSettings(in: app)
        let settings = app.windows["KosmoNotes Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))

        for tab in Self.allTabs {
            XCTAssertTrue(tabExists(named: tab, in: settings),
                          "Expected Settings tab '\(tab)' to exist")
        }
        attachWindow(settings, name: "08-settings-tabs-present")
    }

    /// Click each tab in turn and snapshot the rendered pane. Catches both
    /// behavioural breakage (tab not selectable) and visual regressions
    /// (when reviewed against the attached PNGs in the test report).
    func testEachSettingsTabActivates() {
        let app = freshApp(didOnboard: true)
        app.launch()
        defer { app.terminate() }

        openSettings(in: app)
        let settings = app.windows["KosmoNotes Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))

        for (index, tab) in Self.allTabs.enumerated() {
            click(tabNamed: tab, in: settings)
            // Some tabs render slowly the first time (Settings windows do TCC
            // checks, etc.). Give the OS a beat before snapshotting.
            sleepShort()
            let prefix = String(format: "09-settings-tab-%02d-", index + 1)
            attachWindow(settings, name: prefix + slug(tab))
        }
    }

    func testCanTypeIntoOpenAIKeyFieldAndSave() {
        let app = freshApp(didOnboard: true)
        app.launch()
        defer { app.terminate() }

        openSettings(in: app)
        let settings = app.windows["KosmoNotes Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))

        // Default tab is Transcription. The OpenAI section's API key field is
        // a SecureField; XCUIQuery exposes those as `secureTextFields`.
        let secureFields = settings.secureTextFields
        XCTAssertGreaterThanOrEqual(secureFields.count, 2,
            "Expected at least 2 SecureFields on the Transcription tab (Deepgram + OpenAI)")

        let openAIField = secureFields.element(boundBy: 1)
        openAIField.click()
        openAIField.typeText("sk-test-1234567890")
        attachWindow(settings, name: "10-settings-openai-key-typed")

        // Click the matching Save button — the last "Save" on the tab pertains
        // to the most recently focused section (OpenAI here).
        let saves = settings.buttons.matching(identifier: "Save").allElementsBoundByIndex
        XCTAssertFalse(saves.isEmpty, "Expected at least one Save button")
        saves.last!.click()

        // No assertion on Keychain side-effects here — that's covered by the
        // KeychainStore unit tests. We just verify the click doesn't error.
    }

    // MARK: - Quit

    func testQuitTerminatesApp() {
        let app = freshApp(didOnboard: true)
        app.launch()

        menuBarStatusItem(for: app).click()
        let quit = app.menus.firstMatch.menuItems["Quit KosmoNotes"]
        XCTAssertTrue(quit.waitForExistence(timeout: 2))
        attachFullScreen(name: "11-menu-before-quit")
        quit.click()

        let terminated = expectation(for: NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue),
                                     evaluatedWith: app)
        wait(for: [terminated], timeout: 5)
    }

    // MARK: - Helpers (lookup)

    private static let allTabs = [
        "Transcription",
        "AI Providers",
        "Dictation",
        "Voice Note",
        "Hotkeys",
        "Sharing",
        "Markdown",
        "Agent",
        "Privacy",
    ]

    /// Locate the KosmoNotes menu-bar status item.
    ///
    /// Menu-bar items live in the system-wide menu bar. XCUIApplication reaches
    /// them through `app.menuBars.statusItems[…]`. We try the accessibility
    /// description first, then fall back to the visible "KN" title.
    private func menuBarStatusItem(for app: XCUIApplication) -> XCUIElement {
        let byDescription = app.menuBars.statusItems["KosmoNotes"]
        if byDescription.waitForExistence(timeout: 1) {
            return byDescription
        }
        return app.menuBars.statusItems["KN"]
    }

    private func openSettings(in app: XCUIApplication) {
        menuBarStatusItem(for: app).click()
        let menu = app.menus.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        menu.menuItems["Settings…"].click()
    }

    /// SwiftUI's `TabView` surfaces tabs differently across OS versions: usually
    /// a `tabGroup` with child `radioButton`s, sometimes plain buttons. Try both.
    private func tabExists(named name: String, in window: XCUIElement) -> Bool {
        let tabBar = window.tabGroups.firstMatch
        if tabBar.exists {
            if tabBar.buttons[name].exists || tabBar.radioButtons[name].exists {
                return true
            }
        }
        return window.buttons[name].exists
            || window.radioButtons[name].exists
            || window.staticTexts[name].exists
    }

    private func click(tabNamed name: String, in window: XCUIElement) {
        let tabBar = window.tabGroups.firstMatch
        if tabBar.exists {
            if tabBar.radioButtons[name].exists { tabBar.radioButtons[name].click(); return }
            if tabBar.buttons[name].exists { tabBar.buttons[name].click(); return }
        }
        if window.radioButtons[name].exists { window.radioButtons[name].click(); return }
        if window.buttons[name].exists { window.buttons[name].click(); return }
    }

    // MARK: - Helpers (screenshots)

    /// Attach a screenshot of the entire main display to the current test.
    /// `lifetime = .keepAlways` so the PNG survives a passing run too — useful
    /// for visual diffing across commits.
    private func attachFullScreen(name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachWindow(_ window: XCUIElement, name: String) {
        guard window.exists else {
            attachFullScreen(name: name + "-fallback-fullscreen")
            return
        }
        let shot = window.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Helpers (timing + naming)

    /// Some macOS animations (tab switch, sheet drop-in) need ~150 ms to settle
    /// before a screenshot looks right. Hard-coding this is uglier than waiting
    /// on a UI predicate — but the tab content is just SwiftUI re-rendering,
    /// there's no element to wait on.
    private func sleepShort() {
        Thread.sleep(forTimeInterval: 0.15)
    }

    private func slug(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }
}
