import Foundation
import Testing
@testable import KosmoNotes

@MainActor
@Suite("AppSettings display selection")
struct AppSettingsDisplaySelectionTests {
    private let screenCaptureDisplayIDKey = "screenCaptureDisplayID"

    @Test("screen capture display selection persists across AppSettings instances")
    func screenCaptureDisplaySelectionPersists() {
        UserDefaults.standard.removeObject(forKey: screenCaptureDisplayIDKey)
        defer { UserDefaults.standard.removeObject(forKey: screenCaptureDisplayIDKey) }

        let settings = AppSettings()
        #expect(settings.screenCaptureDisplayID == 0)

        settings.screenCaptureDisplayID = 42

        let reloaded = AppSettings()
        #expect(reloaded.screenCaptureDisplayID == 42)
    }
}
