import XCTest
import VocabCore
@testable import VocabApp

/// Заглушка автозапуску: стан після `setEnabled` задається тестом; помилка — за потреби.
@MainActor
private final class FakeLoginItems: LoginItemManaging {
    struct Failure: LocalizedError {
        var errorDescription: String? { "Operation not permitted" }
    }

    var state: LoginItemState
    /// Стан, у який переходить система після успішного `setEnabled(true)` (напр. `.requiresApproval`).
    var stateAfterEnable: LoginItemState = .enabled
    var error: Error?
    private(set) var setEnabledCalls: [Bool] = []
    private(set) var openSettingsCalls = 0

    init(state: LoginItemState) {
        self.state = state
    }

    func setEnabled(_ enabled: Bool) throws {
        setEnabledCalls.append(enabled)
        if let error {
            throw error
        }
        state = enabled ? stateAfterEnable : .disabled
    }

    func openSystemSettings() {
        openSettingsCalls += 1
    }
}

/// Заглушка озвучення: лише запам'ятовує запити (без звуку).
@MainActor
private final class FakeSpeech: SpeechSpeaking {
    private(set) var spoken: [(text: String, languageCode: String)] = []
    private(set) var stopCalls = 0

    func speak(_ text: String, languageCode: String) {
        spoken.append((text, languageCode))
    }

    func stop() {
        stopCalls += 1
    }
}

/// M5 — `AppModel`: тумблер автозапуску (з заглушкою), озвучення (мова пари), `visibleEntries` (пошук/сортування).
final class AppModelM5Tests: XCTestCase {
    private static let reference = Date(timeIntervalSince1970: 1_791_885_600)

    @MainActor
    private func makeModel(
        seed: [Entry] = [],
        loginItems: LoginItemManaging? = nil,
        speech: SpeechSpeaking? = nil
    ) async throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabAppM5Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let paths = AppPaths(applicationSupportDirectory: directory)
        let dates = FixedDateProvider(Self.reference)
        let store = FileDictionaryStore(
            fileURL: paths.dictionaryURL,
            fileSystem: LocalFileSystem(),
            dateProvider: dates,
            backups: BackupManager(directory: paths.backupsDirectory, dateProvider: dates)
        )
        if !seed.isEmpty {
            try store.save(DictionaryFile(entries: seed))
        }
        let repository = DictionaryRepository(store: store, dateProvider: dates)
        let model = AppModel(
            repository: repository,
            languagePairID: LanguagePairRegistry.defaultPairID,
            loginItems: loginItems,
            speech: speech
        )
        await model.load()
        XCTAssertNil(model.loadError)
        return model
    }

    private func entry(
        _ word: String,
        pair: String = LanguagePairRegistry.defaultPairID,
        translations: [String],
        created: TimeInterval
    ) -> Entry {
        let date = Self.reference.addingTimeInterval(created)
        return Entry(
            languagePair: pair,
            word: word,
            lemma: word,
            translations: translations,
            status: .ready,
            createdAt: date,
            updatedAt: date
        )
    }

    // MARK: - Автозапуск

    @MainActor
    func testLoginItemUnavailableWithoutService() async throws {
        let model = try await makeModel()
        XCTAssertFalse(model.isLoginItemAvailable)
        XCTAssertNil(model.loginItemState)
        XCTAssertFalse(model.launchAtLogin)
        model.setLaunchAtLogin(true)
        model.openLoginItemsSettings()
        XCTAssertNil(model.loginItemState)
        XCTAssertNil(model.loginItemError)
    }

    @MainActor
    func testInitialStateReadFromSystem() async throws {
        for (state, expected) in [(LoginItemState.enabled, true), (.requiresApproval, true),
                                  (.disabled, false), (.notFound, false)] {
            let model = try await makeModel(loginItems: FakeLoginItems(state: state))
            XCTAssertTrue(model.isLoginItemAvailable)
            XCTAssertEqual(model.loginItemState, state)
            XCTAssertEqual(model.launchAtLogin, expected, "\(state)")
        }
    }

    @MainActor
    func testEnableAutostart() async throws {
        let fake = FakeLoginItems(state: .disabled)
        let model = try await makeModel(loginItems: fake)

        model.setLaunchAtLogin(true)

        XCTAssertEqual(fake.setEnabledCalls, [true])
        XCTAssertEqual(model.loginItemState, .enabled)
        XCTAssertTrue(model.launchAtLogin)
        XCTAssertNil(model.loginItemError)
    }

    @MainActor
    func testDisableAutostart() async throws {
        let fake = FakeLoginItems(state: .enabled)
        let model = try await makeModel(loginItems: fake)

        model.setLaunchAtLogin(false)

        XCTAssertEqual(fake.setEnabledCalls, [false])
        XCTAssertEqual(model.loginItemState, .disabled)
        XCTAssertFalse(model.launchAtLogin)
        XCTAssertNil(model.loginItemError)
    }

    @MainActor
    func testEnableErrorShownAndStateReRead() async throws {
        let fake = FakeLoginItems(state: .disabled)
        fake.error = FakeLoginItems.Failure()
        let model = try await makeModel(loginItems: fake)

        model.setLaunchAtLogin(true)

        let message = try XCTUnwrap(model.loginItemError)
        XCTAssertTrue(message.hasPrefix("Не вдалося увімкнути автозапуск"), message)
        XCTAssertTrue(message.contains("Operation not permitted"), message)
        XCTAssertEqual(model.loginItemState, .disabled, "state is re-read from the system after failure")
        XCTAssertFalse(model.launchAtLogin)
    }

    @MainActor
    func testDisableErrorShown() async throws {
        let fake = FakeLoginItems(state: .enabled)
        fake.error = FakeLoginItems.Failure()
        let model = try await makeModel(loginItems: fake)

        model.setLaunchAtLogin(false)

        let message = try XCTUnwrap(model.loginItemError)
        XCTAssertTrue(message.hasPrefix("Не вдалося вимкнути автозапуск"), message)
        XCTAssertEqual(model.loginItemState, .enabled)
        XCTAssertTrue(model.launchAtLogin)
    }

    @MainActor
    func testSuccessClearsPreviousError() async throws {
        let fake = FakeLoginItems(state: .disabled)
        fake.error = FakeLoginItems.Failure()
        let model = try await makeModel(loginItems: fake)
        model.setLaunchAtLogin(true)
        XCTAssertNotNil(model.loginItemError)

        fake.error = nil
        model.setLaunchAtLogin(true)

        XCTAssertNil(model.loginItemError)
        XCTAssertEqual(model.loginItemState, .enabled)
    }

    @MainActor
    func testRequiresApprovalAfterEnable() async throws {
        let fake = FakeLoginItems(state: .disabled)
        fake.stateAfterEnable = .requiresApproval
        let model = try await makeModel(loginItems: fake)

        model.setLaunchAtLogin(true)

        XCTAssertEqual(model.loginItemState, .requiresApproval)
        XCTAssertTrue(model.launchAtLogin, "toggle stays on while waiting for approval")
        XCTAssertNil(model.loginItemError)

        model.openLoginItemsSettings()
        XCTAssertEqual(fake.openSettingsCalls, 1)

        // Користувач дозволив у System Settings → стан перечитується.
        fake.state = .enabled
        model.refreshLoginItemState()
        XCTAssertEqual(model.loginItemState, .enabled)
    }

    @MainActor
    func testRefreshPicksUpExternalChange() async throws {
        let fake = FakeLoginItems(state: .enabled)
        let model = try await makeModel(loginItems: fake)
        fake.state = .disabled
        XCTAssertEqual(model.loginItemState, .enabled, "not re-read until refresh")
        model.refreshLoginItemState()
        XCTAssertEqual(model.loginItemState, .disabled)
        XCTAssertFalse(model.launchAtLogin)
    }

    // MARK: - Озвучення

    @MainActor
    func testSpeakUsesPairSpeechLanguage() async throws {
        let speech = FakeSpeech()
        let run = entry("run", translations: ["бігти"], created: 0)
        let model = try await makeModel(seed: [run], speech: speech)
        XCTAssertTrue(model.isSpeechAvailable)
        XCTAssertEqual(model.speechLanguageCode(for: "en-uk"), "en-US")

        model.speak(run)
        model.speak("give up", languagePair: "en-uk")

        XCTAssertEqual(speech.spoken.map(\.text), ["run", "give up"])
        XCTAssertEqual(speech.spoken.map(\.languageCode), ["en-US", "en-US"])
    }

    @MainActor
    func testSpeakUnknownPairFallsBackToDefault() async throws {
        let speech = FakeSpeech()
        let model = try await makeModel(speech: speech)
        XCTAssertEqual(model.speechLanguageCode(for: "xx-yy"), "en-US")
        model.speak("hello", languagePair: "xx-yy")
        XCTAssertEqual(speech.spoken.map(\.languageCode), ["en-US"])
    }

    @MainActor
    func testSpeechUnavailableWithoutService() async throws {
        let model = try await makeModel()
        XCTAssertFalse(model.isSpeechAvailable)
        model.speak("run", languagePair: "en-uk") // no-op, не падає
    }

    // MARK: - visibleEntries

    @MainActor
    func testVisibleEntriesApplyQueryAndSort() async throws {
        let run = entry("run", translations: ["бігти"], created: 0)
        let cafe = entry("café", translations: ["кав'ярня"], created: 10)
        let apple = entry("Apple", translations: ["яблуко"], created: 20)
        let rerun = entry("rerun", translations: ["повторний запуск"], created: 30)
        let model = try await makeModel(seed: [run, cafe, apple, rerun])
        XCTAssertEqual(model.entries.count, 4)

        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.visibleEntries.map(\.word), ["rerun", "Apple", "café", "run"], "default: newest first")

        model.query.sort = .dateOldest
        XCTAssertEqual(model.visibleEntries.map(\.word), ["run", "café", "Apple", "rerun"])

        model.query.sort = .alphabetical
        XCTAssertEqual(model.visibleEntries.map(\.word), ["Apple", "café", "rerun", "run"])

        model.query.searchText = "  RUN "
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(model.visibleEntries.map(\.word), ["rerun", "run"])

        model.query.searchText = "біг"
        XCTAssertEqual(model.visibleEntries.map(\.word), ["run"])

        model.query.searchText = "cafe"
        XCTAssertEqual(model.visibleEntries.map(\.word), ["café"])

        model.query.searchText = "   "
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.visibleEntries.count, 4)
        XCTAssertEqual(model.entries.count, 4, "query never changes the underlying entries")
    }
}
