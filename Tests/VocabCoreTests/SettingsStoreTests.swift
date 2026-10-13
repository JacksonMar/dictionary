import Foundation
import XCTest
@testable import VocabCore

/// M2.8 — налаштування (UserDefaults з окремим suite) і сховище секретів у пам'яті.
final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "com.vocabapp.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultModelIsHaiku55() {
        XCTAssertEqual(SettingsDefaults.model, "claude-haiku-5-5")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).model, "claude-haiku-5-5")
        XCTAssertEqual(InMemorySettingsStore().model, "claude-haiku-5-5")
        XCTAssertEqual(ClaudeConfiguration.defaultModel, "claude-haiku-5-5")
    }

    func testDefaultLanguagePairIsEnUk() {
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).languagePairID, "en-uk")
        XCTAssertEqual(InMemorySettingsStore().languagePairID, "en-uk")
    }

    func testPersistsModel() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.model = "claude-sonnet-test"

        XCTAssertEqual(store.model, "claude-sonnet-test")
        XCTAssertEqual(defaults.string(forKey: "claudeModel"), "claude-sonnet-test")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).model, "claude-sonnet-test",
                       "new instance over same defaults sees the value")

        store.languagePairID = "it-uk"
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).languagePairID, "it-uk")
    }

    func testModelIsTrimmed() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.model = "  claude-x \n"
        XCTAssertEqual(store.model, "claude-x")
    }

    func testEmptyModelFallsBackToDefault() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.model = "claude-sonnet-test"

        store.model = ""
        XCTAssertEqual(store.model, "claude-haiku-5-5")
        XCTAssertNil(defaults.string(forKey: "claudeModel"))

        store.model = "   "
        XCTAssertEqual(store.model, "claude-haiku-5-5")

        defaults.set("", forKey: "claudeModel")
        XCTAssertEqual(store.model, "claude-haiku-5-5", "empty string written externally also falls back")

        let memory = InMemorySettingsStore(model: "x")
        memory.model = " "
        XCTAssertEqual(memory.model, "claude-haiku-5-5")
    }
}

final class InMemorySecretStoreTests: XCTestCase {
    func testWriteReadDelete() throws {
        let store = InMemorySecretStore()

        XCTAssertNil(try store.readSecret(for: .anthropicAPIKey))
        try store.writeSecret("sk-ant-one", for: .anthropicAPIKey)
        XCTAssertEqual(try store.readSecret(for: .anthropicAPIKey), "sk-ant-one")
        try store.writeSecret("sk-ant-two", for: .anthropicAPIKey)
        XCTAssertEqual(try store.readSecret(for: .anthropicAPIKey), "sk-ant-two", "overwrite")
        try store.deleteSecret(for: .anthropicAPIKey)
        XCTAssertNil(try store.readSecret(for: .anthropicAPIKey))
        XCTAssertNoThrow(try store.deleteSecret(for: .anthropicAPIKey), "deleting missing secret is not an error")
    }

    func testConcurrentAccessIsSafe() {
        let store = InMemorySecretStore()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            try? store.writeSecret("value-\(index)", for: .anthropicAPIKey)
            _ = try? store.readSecret(for: .anthropicAPIKey)
        }
        XCTAssertNotNil(try store.readSecret(for: .anthropicAPIKey))
    }

    func testSecretKeyAccountName() {
        XCTAssertEqual(SecretKey.anthropicAPIKey.rawValue, "anthropic-api-key")
    }

    func testSecretStoreErrorMessageHasNoSecret() {
        XCTAssertEqual(SecretStoreError.keychain(status: -25300).userMessage, "Помилка Keychain (код -25300)")
        XCTAssertFalse(SecretStoreError.encoding.userMessage.isEmpty)
    }
}
