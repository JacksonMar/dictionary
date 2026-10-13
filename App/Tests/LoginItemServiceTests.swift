import ServiceManagement
import XCTest
@testable import VocabApp

/// M5.4 — мапінг `SMAppService.Status` → `LoginItemState` (чиста функція, без реєстрації в системі).
final class LoginItemServiceTests: XCTestCase {
    func testStatusMapping() {
        XCTAssertEqual(LoginItemService.state(for: .enabled), .enabled)
        XCTAssertEqual(LoginItemService.state(for: .notRegistered), .disabled)
        XCTAssertEqual(LoginItemService.state(for: .requiresApproval), .requiresApproval)
        XCTAssertEqual(LoginItemService.state(for: .notFound), .notFound)
    }
}
