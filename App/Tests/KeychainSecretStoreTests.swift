import XCTest
import VocabCore
@testable import VocabApp

/// M2.9 — `KeychainSecretStore` у login Keychain. Кожен прогін — унікальний service
/// `com.vocabapp.tests.<UUID>`, тож реальний ключ застосунку (`com.vocabapp.VocabApp`) не зачіпається;
/// у `tearDown` запис видаляється.
final class KeychainSecretStoreTests: XCTestCase {
    private var store: KeychainSecretStore!

    override func setUp() {
        super.setUp()
        store = KeychainSecretStore(service: "com.vocabapp.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? store?.deleteSecret(for: .anthropicAPIKey)
        store = nil
        super.tearDown()
    }

    func testUsesUniqueTestService() {
        XCTAssertTrue(store.service.hasPrefix("com.vocabapp.tests."))
        XCTAssertNotEqual(store.service, KeychainSecretStore.defaultService)
        XCTAssertEqual(KeychainSecretStore.defaultService, "com.vocabapp.VocabApp")
    }

    func testWriteReadDelete() throws {
        let value = "sk-ant-api03-keychain-test-\(UUID().uuidString)"

        try store.writeSecret(value, for: .anthropicAPIKey)
        XCTAssertEqual(try store.readSecret(for: .anthropicAPIKey), value)

        try store.deleteSecret(for: .anthropicAPIKey)
        XCTAssertNil(try store.readSecret(for: .anthropicAPIKey))
    }

    func testOverwrite() throws {
        try store.writeSecret("sk-ant-first-value", for: .anthropicAPIKey)
        try store.writeSecret("sk-ant-second-value", for: .anthropicAPIKey)

        XCTAssertEqual(try store.readSecret(for: .anthropicAPIKey), "sk-ant-second-value")
        // Друга інстанція з тим самим service бачить той самий запис.
        let sameService = KeychainSecretStore(service: store.service)
        XCTAssertEqual(try sameService.readSecret(for: .anthropicAPIKey), "sk-ant-second-value")
    }

    func testReadMissingReturnsNil() throws {
        XCTAssertNil(try store.readSecret(for: .anthropicAPIKey))
    }

    func testDeleteMissingIsNotAnError() {
        XCTAssertNoThrow(try store.deleteSecret(for: .anthropicAPIKey))
    }

    func testUnicodeValueRoundTrips() throws {
        let value = "ключ-🔑-\(UUID().uuidString)"
        try store.writeSecret(value, for: .anthropicAPIKey)
        XCTAssertEqual(try store.readSecret(for: .anthropicAPIKey), value)
    }

    func testServicesAreIsolated() throws {
        let other = KeychainSecretStore(service: "com.vocabapp.tests.\(UUID().uuidString)")
        defer { try? other.deleteSecret(for: .anthropicAPIKey) }

        try store.writeSecret("sk-ant-isolated", for: .anthropicAPIKey)

        XCTAssertNil(try other.readSecret(for: .anthropicAPIKey))
    }
}
