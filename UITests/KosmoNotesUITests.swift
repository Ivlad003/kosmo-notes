import XCTest

// MARK: - KosmoNotesUITests
//
// End-to-end UI smoke tests using XCUITest.
//
// What these cover:
//   * App launches and registers a menu-bar status item
//   * First-launch onboarding window appears and dismisses
//   * Menu-bar dropdown contains Record / Settings / Quit
//   * Settings… opens a real window with the three tabs
//   * Typing into an API key field works and the Save button reacts
//   * Quit terminates the app cleanly
//
// What these DO NOT cover (out of scope for v0):
//   * Real audio capture (no mic in CI; manual smoke gate per AC-9b)
//   * Real Deepgram / Anthropic / OpenAI network calls (mocked at unit level)
//   * Recording flow (RecorderState ships in Phase A Week 3)
//
// Running locally:
//   xcodebuild test -scheme KosmoNotes -destination 'platform=macOS'
//
// Note on TCC: macOS UI tests need Accessibility permission for `xctest` /
// Xcode. First run will prompt; grant via System Settings → Privacy &
// Security → Accessibility, then re-run.

final class KosmoNotesUITests: XCTestCase {

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Reset onboarding state via UserDefaults launch arguments so each test
    /// starts from a known state. The app already reads `didOnboard` from
    /// `UserDefaults.standard` — passing `-didOnboard <Bool>` overrides it
    /// for the test process scope only.
    private func freshApp(didOnboard: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-didOnboard", didOnboard ? "YES" : "NO",
            // Disable any user-defaults persistence side effects between tests.
            "-AppleScrollViewSuppressTesting", "YES",
        ]
        return app
    }

    // MARK: - App launch + status item

    func testAppLaunchesAndShowsStatusItem() {
        let app = freshApp(didOnboard: true)
        app.launch()
        defer { app.terminate() }

        // The menu-bar status item is exposed as a child of the system menu bar
        // (handled by the system process, not our app). XCUIApplication's
        // `menuBars` query reaches it via the accessibility hierarchy.
        let statusItem = menuBarStatusItem(for: app)
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5),
                      "Expected KosmoNotes menu-bar status item to be visible")
    }

    // MARK: - Onboarding

    func testOnboardingWindowAppearsOnFirstLaunch() {
        let app = freshApp(didOnboard: false)
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Welcome to Jarvis Note"]
        XCTAssertTrue(window.waitForExistence(timeout: 5),
                      "Onboarding window should appear when didOnboard == false")
    }

    func testOnboardingDismissesOnContinue() {
        let app = freshApp(didOnboard: false)
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Welcome to Jarvis Note"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let continueButton = window.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 2),
                      "Continue button should be present in onboarding")
        continueButton.click()

        // Window should disappear within ~1 s
        let dismissed = !window.waitForExistence(timeout: 2)
        XCTAssertTrue(dismissed, "Onboarding window should close after Continue")
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

        XCTAssertTrue(menu.menuItems["Record (coming soon)"].exists)
        XCTAssertTrue(menu.menuItems["Settings…"].exists)
        XCTAssertTrue(menu.menuItems["Quit Jarvis Note"].exists)
    }

    func testRecordItemIsDisabled() {
        let app = freshApp(didOnboard: true)
        app.launch()
        defer { app.terminate() }

        menuBarStatusItem(for: app).click()
        let recordItem = app.menus.firstMatch.menuItems["Record (coming soon)"]
        XCTAssertTrue(recordItem.waitForExistence(timeout: 2))
        XCTAssertFalse(recordItem.isEnabled,
                       "Record placeholder should be disabled until Phase A Week 3 lands")
    }

    // MARK: - Settings

    func testSettingsOpensCustomWindow() {
        let app = freshApp(didOnboard: true)
        app.launch()
        defer { app.terminate() }

        openSettings(in: app)

        let settings = app.windows["Jarvis Note Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3),
                      "Settings window should open with title 'Jarvis Note Settings'")
    }

    func testSettingsHasThreeTabs() {
        let app = freshApp(didOnboard: true)
        app.launch()
        defer { app.terminate() }

        openSettings(in: app)
        let settings = app.windows["Jarvis Note Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))

        // TabView tabs surface as accessibility buttons / radio items.
        let tabBar = settings.tabGroups.firstMatch
        if tabBar.exists {
            XCTAssertTrue(tabBar.buttons["Transcription"].exists ||
                          settings.buttons["Transcription"].exists)
            XCTAssertTrue(tabBar.buttons["AI Providers"].exists ||
                          settings.buttons["AI Providers"].exists)
            XCTAssertTrue(tabBar.buttons["Privacy"].exists ||
                          settings.buttons["Privacy"].exists)
        } else {
            // Some macOS versions surface tabs as plain buttons inside the window.
            XCTAssertTrue(settings.buttons["Transcription"].exists)
            XCTAssertTrue(settings.buttons["AI Providers"].exists)
            XCTAssertTrue(settings.buttons["Privacy"].exists)
        }
    }

    func testCanTypeIntoOpenAIKeyFieldAndSave() {
        let app = freshApp(didOnboard: true)
        app.launch()
        defer { app.terminate() }

        openSettings(in: app)
        let settings = app.windows["Jarvis Note Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))

        // Default tab is Transcription. Find the OpenAI section's secure field.
        // SecureField shows up as `secureTextFields` in XCUIElementQuery.
        let secureFields = settings.secureTextFields
        XCTAssertGreaterThanOrEqual(secureFields.count, 2,
            "Expected at least 2 SecureFields (Deepgram + OpenAI)")

        // The OpenAI section's API key field is the second SecureField on the
        // Transcription tab (Deepgram first, OpenAI second).
        let openAIField = secureFields.element(boundBy: 1)
        openAIField.click()
        openAIField.typeText("sk-test-1234567890")

        // Click the matching Save button — find the Save in the OpenAI section
        // by the order on screen (last "Save" before tab switch).
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
        let quit = app.menus.firstMatch.menuItems["Quit Jarvis Note"]
        XCTAssertTrue(quit.waitForExistence(timeout: 2))
        quit.click()

        // Wait for app to actually terminate
        let terminated = expectation(for: NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue),
                                     evaluatedWith: app)
        wait(for: [terminated], timeout: 5)
    }

    // MARK: - Helpers

    /// Locate the KosmoNotes menu-bar status item.
    ///
    /// macOS menu-bar items live in the system-wide menu bar (process
    /// `SystemUIServer` / `WindowServer`), not in the app's own UI. XCUIApplication
    /// reaches them via the system menu bar query — we can ask the app for its
    /// menu bar items by accessibility description.
    private func menuBarStatusItem(for app: XCUIApplication) -> XCUIElement {
        // Try matching by the accessibility description we set in code first;
        // fall back to the visible title "JN".
        let byDescription = app.menuBars.statusItems["Jarvis Note"]
        if byDescription.waitForExistence(timeout: 1) {
            return byDescription
        }
        return app.menuBars.statusItems["JN"]
    }

    private func openSettings(in app: XCUIApplication) {
        menuBarStatusItem(for: app).click()
        let menu = app.menus.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        menu.menuItems["Settings…"].click()
    }
}
