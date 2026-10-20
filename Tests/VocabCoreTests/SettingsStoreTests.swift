import Foundation
import XCTest
@testable import VocabCore

/// M2.8 — налаштування (UserDefaults з окремим suite) і сховище секретів у пам'яті.
final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pinInterfaceLanguage(.uk)
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

    // MARK: - M6.4: тема і розмір сторінки

    func testAppearanceDefaultsToSystem() {
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).appearance, .system)
        XCTAssertNil(defaults.object(forKey: "appearance"))
        XCTAssertEqual(InMemorySettingsStore().appearance, .system)
        XCTAssertEqual(AppAppearance.allCases, [.system, .light, .dark])
        XCTAssertEqual(AppAppearance.system.title, "Як у системі")
        XCTAssertEqual(AppAppearance.light.title, "Світла")
        XCTAssertEqual(AppAppearance.dark.title, "Темна")
    }

    func testAppearancePersistsInUserDefaults() {
        XCTAssertEqual(UserDefaultsSettingsStore.appearanceKey, "appearance")
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.appearance = .dark

        XCTAssertEqual(store.appearance, .dark)
        XCTAssertEqual(defaults.string(forKey: "appearance"), "dark")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).appearance, .dark,
                       "new instance over same defaults sees the value")

        store.appearance = .light
        XCTAssertEqual(defaults.string(forKey: "appearance"), "light")
        store.appearance = .system
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).appearance, .system)
    }

    func testUnknownAppearanceFallsBackToSystem() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        for raw in ["purple", "", "Dark", " dark"] {
            defaults.set(raw, forKey: "appearance")
            XCTAssertEqual(store.appearance, .system, "'\(raw)'")
        }
        defaults.set(42, forKey: "appearance")
        XCTAssertEqual(store.appearance, .system, "non-string value")
    }

    func testPageSizeDefaultAndPersist() {
        XCTAssertEqual(UserDefaultsSettingsStore.pageSizeKey, "entriesPageSize")
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(store.pageSize, 25)

        for size in [20, 30, 25] {
            store.pageSize = size
            XCTAssertEqual(store.pageSize, size)
            XCTAssertEqual(defaults.integer(forKey: "entriesPageSize"), size)
            XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).pageSize, size)
        }
    }

    func testInvalidPageSizeFallsBackToDefault() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.pageSize = 30

        store.pageSize = 50
        XCTAssertEqual(store.pageSize, 25, "setter normalizes unsupported value")

        for raw in [0, -3, 7, 50, 1000] {
            defaults.set(raw, forKey: "entriesPageSize")
            XCTAssertEqual(store.pageSize, 25, "externally written \(raw)")
        }
        defaults.set("abc", forKey: "entriesPageSize")
        XCTAssertEqual(store.pageSize, 25, "non-numeric value")

        let memory = InMemorySettingsStore(pageSize: 99)
        XCTAssertEqual(memory.pageSize, 25)
        memory.pageSize = 20
        memory.pageSize = 31
        XCTAssertEqual(memory.pageSize, 25)
    }

    func testInMemoryStoreAppearanceAndPageSize() {
        let memory = InMemorySettingsStore(appearance: .dark, pageSize: 30)
        XCTAssertEqual(memory.appearance, .dark)
        XCTAssertEqual(memory.pageSize, 30)

        memory.appearance = .light
        memory.pageSize = 20
        XCTAssertEqual(memory.appearance, .light)
        XCTAssertEqual(memory.pageSize, 20)

        let defaultsOnly = InMemorySettingsStore()
        XCTAssertEqual(defaultsOnly.appearance, .system)
        XCTAssertEqual(defaultsOnly.pageSize, 25)
    }

    // MARK: - M7: display language

    func testDisplayLanguageDefaultsToNil() {
        XCTAssertNil(UserDefaultsSettingsStore(defaults: defaults).displayLanguageID)
        XCTAssertNil(InMemorySettingsStore().displayLanguageID)
        XCTAssertEqual(UserDefaultsSettingsStore.displayLanguageKey, "displayLanguage")
    }

    func testDisplayLanguagePersists() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.displayLanguageID = "it"
        XCTAssertEqual(store.displayLanguageID, "it")
        XCTAssertEqual(defaults.string(forKey: "displayLanguage"), "it")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).displayLanguageID, "it", "new instance reads it")

        // Невідомий рядок зберігається як є (перевірка — в AppModel).
        store.displayLanguageID = "xx"
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).displayLanguageID, "xx")

        store.displayLanguageID = nil
        XCTAssertNil(store.displayLanguageID)
        XCTAssertNil(defaults.object(forKey: "displayLanguage"))

        store.displayLanguageID = "   "
        XCTAssertNil(store.displayLanguageID, "blank → nil")
        defaults.set("", forKey: "displayLanguage")
        XCTAssertNil(UserDefaultsSettingsStore(defaults: defaults).displayLanguageID)
    }

    func testInMemoryDisplayLanguage() {
        let store = InMemorySettingsStore(displayLanguageID: "it")
        XCTAssertEqual(store.displayLanguageID, "it")
        store.displayLanguageID = nil
        XCTAssertNil(store.displayLanguageID)
        store.displayLanguageID = " "
        XCTAssertNil(store.displayLanguageID)
        store.displayLanguageID = "it"
        XCTAssertEqual(store.displayLanguageID, "it")
    }

    // MARK: - M9.4 Мова інтерфейсу

    func testInterfaceLanguageDefaultsToEnglish() {
        XCTAssertNil(defaults.object(forKey: "interfaceLanguage"))
        XCTAssertEqual(UserDefaultsSettingsStore.interfaceLanguageKey, "interfaceLanguage")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).interfaceLanguage, .en)
        XCTAssertEqual(InMemorySettingsStore().interfaceLanguage, .en)
    }

    func testInterfaceLanguagePersistsInUserDefaults() {
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.interfaceLanguage = .uk

        XCTAssertEqual(store.interfaceLanguage, .uk)
        XCTAssertEqual(defaults.string(forKey: "interfaceLanguage"), "uk")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).interfaceLanguage, .uk,
                       "new instance over same suite sees the value")

        store.interfaceLanguage = .en
        XCTAssertEqual(defaults.string(forKey: "interfaceLanguage"), "en")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).interfaceLanguage, .en)
    }

    func testUnknownInterfaceLanguageFallsBackToEnglish() {
        for raw in ["xx", "", "   ", "de", "ukrainian"] {
            defaults.set(raw, forKey: "interfaceLanguage")
            XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).interfaceLanguage, .en, "stored \(raw)")
        }
        defaults.set(" UK ", forKey: "interfaceLanguage")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).interfaceLanguage, .uk,
                       "stored value is trimmed and case-insensitive")
        defaults.set(42, forKey: "interfaceLanguage")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).interfaceLanguage, .en, "non-string value")
    }

    func testInMemoryInterfaceLanguage() {
        let store = InMemorySettingsStore()
        XCTAssertEqual(store.interfaceLanguage, .en)
        store.interfaceLanguage = .uk
        XCTAssertEqual(store.interfaceLanguage, .uk)
        XCTAssertEqual(InMemorySettingsStore(interfaceLanguage: .uk).interfaceLanguage, .uk)
    }

    func testSettingsStoreProtocolDefaultInterfaceLanguageIsEnglishAndIgnoresWrites() {
        final class MinimalStore: SettingsStore, @unchecked Sendable {
            var model = ""
            var languagePairID = ""
            var appearance = AppAppearance.system
            var pageSize = 50
        }
        let store = MinimalStore()
        XCTAssertEqual(store.interfaceLanguage, .en)
        store.interfaceLanguage = .uk
        XCTAssertEqual(store.interfaceLanguage, .en)
    }
}

final class InMemorySecretStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        pinInterfaceLanguage(.uk)
    }

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
