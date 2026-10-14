import AppKit
import XCTest
import VocabCore
@testable import VocabApp

/// M6.4 — `AppearanceController`: `.system` → `nil`, `.light` → `.aqua`, `.dark` → `.darkAqua` (D20).
/// Тести hosted (TEST_HOST = VocabApp.app), тож `NSApp` існує; `tearDown` повертає системну тему (`nil`).
final class AppearanceControllerTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run {
            NSApp.appearance = nil
        }
        try await super.tearDown()
    }

    @MainActor
    func testNSAppearanceMapping() {
        XCTAssertNil(AppearanceController.nsAppearance(for: .system))
        XCTAssertEqual(AppearanceController.nsAppearance(for: .light)?.name, NSAppearance.Name.aqua)
        XCTAssertEqual(AppearanceController.nsAppearance(for: .dark)?.name, NSAppearance.Name.darkAqua)
    }

    @MainActor
    func testApplySetsNSAppAppearance() throws {
        let app = try XCTUnwrap(NSApp, "hosted tests: NSApplication must exist")
        let controller = AppearanceController()

        controller.apply(.light)
        XCTAssertEqual(app.appearance?.name, NSAppearance.Name.aqua)

        controller.apply(.dark)
        XCTAssertEqual(app.appearance?.name, NSAppearance.Name.darkAqua)

        controller.apply(.system)
        XCTAssertNil(app.appearance, "system → nil (follow macOS appearance)")
    }

    @MainActor
    func testControllerConformsToAppearanceApplying() {
        let applier: AppearanceApplying = AppearanceController()
        applier.apply(.dark)
        XCTAssertEqual(NSApp.appearance?.name, NSAppearance.Name.darkAqua)
        applier.apply(.system)
        XCTAssertNil(NSApp.appearance)
    }
}
