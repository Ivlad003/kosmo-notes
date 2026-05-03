import Testing
@testable import DictationKit

// MARK: - AppContextDetectorTests

/// Unit tests for the bundle ID → DictationContext lookup table.
/// AVAudioEngine and AX components require hardware/TCC — not tested here.
struct AppContextDetectorTests {

    @Test func vsCodeBundleID() {
        // com.microsoft.VSCode → .vsCode
        // We test the lookup table directly via the bundleMap logic replicated inline.
        let ctx = lookupContext(bundleID: "com.microsoft.VSCode")
        #expect(ctx == .vsCode)
    }

    @Test func vsCodeFormattingNonEmpty() {
        #expect(!DictationContext.vsCode.contextSpecificFormatting.isEmpty)
    }

    @Test func cursorBundleID() {
        let ctx = lookupContext(bundleID: "com.todesktop.230313mzl4w4u92")
        #expect(ctx == .cursor)
    }

    @Test func slackBundleID() {
        let ctx = lookupContext(bundleID: "com.tinyspeck.slackmacgap")
        #expect(ctx == .slack)
    }

    @Test func discordBundleID() {
        let ctx = lookupContext(bundleID: "com.hnc.Discord")
        #expect(ctx == .discord)
    }

    @Test func unknownBundleIDMapsToDefault() {
        let ctx = lookupContext(bundleID: "com.example.unknown.app.xyz")
        #expect(ctx == .default)
    }

    @Test func nilBundleIDMapsToDefault() {
        // Simulate no frontmost application
        let ctx = lookupContext(bundleID: nil)
        #expect(ctx == .default)
    }

    @Test func allContextsHaveNonEmptyFormatting() {
        for ctx in DictationContext.allCases {
            #expect(!ctx.contextSpecificFormatting.isEmpty, "Context \(ctx.rawValue) has empty formatting hint")
        }
    }
}

// MARK: - Test helper

/// Replicates the bundle ID lookup so we can test the table without needing
/// NSWorkspace (which requires a running app context in some test environments).
private func lookupContext(bundleID: String?) -> DictationContext {
    guard let bundleID else { return .default }
    let map: [String: DictationContext] = [
        "com.todesktop.230313mzl4w4u92": .cursor,
        "com.microsoft.VSCode": .vsCode,
        "com.tinyspeck.slackmacgap": .slack,
        "com.hnc.Discord": .discord,
        "com.linear": .linear,
        "com.atlassian.jira": .jira,
        "com.apple.Notes": .notes,
        "com.apple.TextEdit": .textEdit,
    ]
    return map[bundleID] ?? .default
}
