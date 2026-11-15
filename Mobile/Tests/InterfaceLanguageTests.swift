// I1b.4 (IOS_PLAN §7, DI14): the interface language applies instantly — `L10n.current` changes and the root UI
// identity (`VocabMobileApp`: `EntryListView(...).id(model.interfaceLanguage)`) changes, so the whole tree is rebuilt
// with the new texts — and it is persisted in the settings store.
import Foundation
import XCTest
import VocabCore
@testable import VocabMobile

final class InterfaceLanguageTests: XCTestCase {
    private var savedLanguage: AppLanguage = .default
    private var suiteName: String?

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.current
        L10n.setCurrent(.en)
    }

    override func tearDown() {
        L10n.setCurrent(savedLanguage)
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    @MainActor
    private func makeModel(settings: SettingsStore) -> MobileAppModel {
        MobileAppModel(container: AppContainer(baseDirectory: makeTemporaryDirectory(self), settings: settings))
    }

    @MainActor
    func testInterfaceLanguageSwitchChangesRootIdentity() async {
        let settings = InMemorySettingsStore(interfaceLanguage: .en)
        let model = makeModel(settings: settings)
        await model.start()
        let initialIdentity: AnyHashable = AnyHashable(model.interfaceLanguage)
        XCTAssertEqual(model.interfaceLanguage, .en)
        let englishTitle = L10n.text(.windowSettings)

        model.setInterfaceLanguage(.uk)

        XCTAssertNotEqual(AnyHashable(model.interfaceLanguage), initialIdentity, "root .id must change")
        XCTAssertEqual(model.interfaceLanguage, .uk)
        XCTAssertEqual(L10n.current, .uk, "texts switch without relaunch")
        XCTAssertEqual(L10n.text(.windowSettings), L10n.text(.windowSettings, language: .uk))
        XCTAssertNotEqual(L10n.text(.windowSettings), englishTitle)
        // Freshly computed row/rendering texts use the new language.
        XCTAssertEqual(MobileAppModel.refreshVariantShortTitle(model.renderings.first),
                       L10n.text(.mobileActionUpdateItalian, language: .uk))

        // Selecting the same language keeps the identity (no needless rebuild).
        let ukIdentity = AnyHashable(model.interfaceLanguage)
        model.setInterfaceLanguage(.uk)
        XCTAssertEqual(AnyHashable(model.interfaceLanguage), ukIdentity)

        // Back to English.
        model.setInterfaceLanguage(.en)
        XCTAssertEqual(AnyHashable(model.interfaceLanguage), initialIdentity)
        XCTAssertEqual(L10n.current, .en)
        XCTAssertEqual(L10n.text(.windowSettings), englishTitle)

        // The open Settings sheet lives in the Router (outside the rebuilt root), so it survives the rebuild.
        let router = Router()
        router.open(.settings)
        model.setInterfaceLanguage(.uk)
        XCTAssertEqual(router.presentedSheet, .settings)
    }

    @MainActor
    func testInterfaceLanguagePersisted() async throws {
        let suiteName = "VocabMobileTests.lang.\(UUID().uuidString)"
        self.suiteName = suiteName
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settings = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(settings.interfaceLanguage, .en, "default before any choice")
        let model = makeModel(settings: settings)
        XCTAssertEqual(model.interfaceLanguage, .en)

        model.setInterfaceLanguage(.uk)

        XCTAssertEqual(settings.interfaceLanguage, .uk)
        XCTAssertEqual(defaults.string(forKey: UserDefaultsSettingsStore.interfaceLanguageKey), "uk")
        // "Relaunch": a new store over the same defaults and a new model read the saved language.
        let reopened = UserDefaultsSettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        XCTAssertEqual(reopened.interfaceLanguage, .uk)
        let relaunched = makeModel(settings: reopened)
        XCTAssertEqual(relaunched.interfaceLanguage, .uk)

        // In-memory store (app under XCTest) behaves the same.
        let memory = InMemorySettingsStore()
        let memoryModel = makeModel(settings: memory)
        memoryModel.setInterfaceLanguage(.uk)
        XCTAssertEqual(memory.interfaceLanguage, .uk)
        XCTAssertEqual(makeModel(settings: memory).interfaceLanguage, .uk)
    }
}
