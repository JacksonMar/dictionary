// Replaces the I0 SpikeTests (the App Group probe left the app in I1a). The I1a tests proper
// (`MobileAppModelTests`, `AppContainerTests`) are written by the Tester.
import XCTest
@testable import VocabMobile

final class AppLaunchTests: XCTestCase {
    /// Hosted test: the host app launched, and under XCTest the shared container never points at the real data
    /// directory (temporary `VocabMobileTests-*` directory instead).
    @MainActor
    func testAppLaunchesWithTemporaryDataDirectory() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        XCTAssertTrue(bundleID.hasSuffix(".VocabMobile"), "unexpected host bundle id: \(bundleID)")

        let directory = AppContainer.shared.paths.applicationSupportDirectory
        XCTAssertTrue(directory.lastPathComponent.hasPrefix("VocabMobileTests-"), directory.path)
    }
}
