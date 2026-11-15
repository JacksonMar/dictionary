// I1b.3 (IOS_PLAN §7, DI8): the API key lives only in the app Keychain (`KeychainSecretStore`, shared with macOS by
// path). Needs the real Security framework — the whole file is skipped where Security is absent (Linux harness).
// Each test uses a unique `service`, so the real app item (`<prefix>.VocabMobile`) is never touched; items are
// deleted in tearDown.
#if canImport(Security)
import Foundation
import Security
import XCTest
import VocabCore
@testable import VocabMobile

final class KeychainMobileTests: XCTestCase {
    private var service: String!
    private var store: SecretStore!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        service = "com.vocabapp.mobile.tests.\(UUID().uuidString)"
        store = LivePlatform.makeSecretStore(service: service)
        suiteName = "VocabMobileTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? store?.deleteSecret(for: .anthropicAPIKey)
        defaults?.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        super.tearDown()
    }

    @MainActor
    private func makeModel(settings: SettingsStore) -> MobileAppModel {
        let container = AppContainer(
            baseDirectory: makeTemporaryDirectory(self),
            settings: settings,
            secrets: store,
            transport: MockURLProtocol.makeTransport()
        )
        return MobileAppModel(container: container)
    }

    @MainActor
    func testSaveReadDeleteKey() async throws {
        XCTAssertTrue(store is KeychainSecretStore, "LivePlatform must use the Keychain on iOS")
        XCTAssertEqual((store as? KeychainSecretStore)?.service, service)
        XCTAssertNil(try store.readSecret(for: .anthropicAPIKey))

        let model = makeModel(settings: InMemorySettingsStore())
        await model.start()
        XCTAssertFalse(model.hasAPIKey)

        let key = "sk-ant-api03-mobile-keychain-\(UUID().uuidString)"
        XCTAssertTrue(model.saveAPIKey("  \(key)\n"), model.settingsError ?? "")
        XCTAssertNil(model.settingsError)
        XCTAssertTrue(model.hasAPIKey)
        XCTAssertEqual(try store.readSecret(for: .anthropicAPIKey), key, "stored trimmed in the Keychain")
        XCTAssertTrue(model.container.keyCache.secrets().contains(key), "known to the log redactor")

        // A fresh store/model over the same service sees the key (survives relaunch).
        let reopened = KeychainSecretStore(service: service)
        XCTAssertEqual(try reopened.readSecret(for: .anthropicAPIKey), key)
        let second = makeModel(settings: InMemorySettingsStore())
        second.refreshAPIKeyState()
        XCTAssertTrue(second.hasAPIKey)

        // Overwrite.
        let replacement = key + "-2"
        XCTAssertTrue(model.saveAPIKey(replacement))
        XCTAssertEqual(try store.readSecret(for: .anthropicAPIKey), replacement)

        // Empty input is rejected and keeps the stored key.
        XCTAssertFalse(model.saveAPIKey("   "))
        XCTAssertEqual(model.settingsError, L10n.text(.settingsErrorEnterKey))
        XCTAssertEqual(try store.readSecret(for: .anthropicAPIKey), replacement)

        // Delete.
        XCTAssertTrue(model.deleteAPIKey())
        XCTAssertFalse(model.hasAPIKey)
        XCTAssertNil(try store.readSecret(for: .anthropicAPIKey))
        XCTAssertTrue(model.deleteAPIKey(), "deleting a missing key is not an error")
        model.refreshAPIKeyState()
        XCTAssertFalse(model.hasAPIKey)
    }

    @MainActor
    func testKeyNeverInUserDefaults() async throws {
        let settings = UserDefaultsSettingsStore(defaults: defaults)
        let model = makeModel(settings: settings)
        await model.start()
        let key = "sk-ant-api03-never-in-defaults-\(UUID().uuidString)"

        XCTAssertTrue(model.saveAPIKey(key), model.settingsError ?? "")
        model.setModel("claude-test-model")
        model.setInterfaceLanguage(L10n.current)
        _ = model.setDisplayLanguage("it")
        await model.settingsProcessingTask?.value
        await model.backfillTask?.value

        XCTAssertEqual(try store.readSecret(for: .anthropicAPIKey), key)
        // The settings suite holds the other settings but not the key.
        XCTAssertEqual(defaults.string(forKey: UserDefaultsSettingsStore.modelKey), "claude-test-model")
        assertNoKey(key, in: defaults.dictionaryRepresentation(), "settings suite")
        assertNoKey(key, in: UserDefaults.standard.dictionaryRepresentation(), "UserDefaults.standard")
        assertNoKey(key, in: UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:],
                    "app domain")
    }

    private func assertNoKey(_ key: String, in dictionary: [String: Any], _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        for (name, value) in dictionary {
            XCTAssertFalse(name.contains(key), "\(label): key used as a defaults name", file: file, line: line)
            let text = String(describing: value)
            XCTAssertFalse(text.contains(key), "\(label): API key found under \(name)", file: file, line: line)
            if let data = value as? Data {
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(key),
                               "\(label): API key found in data under \(name)", file: file, line: line)
            }
        }
    }
}
#endif
