// I1a.3 (IOS_PLAN §4): single-flight dictionary loading in `AppContainer`, cached load errors.
import XCTest
import VocabCore
@testable import VocabMobile

final class AppContainerTests: XCTestCase {
    @MainActor
    private func makeContainer(store: CountingDictionaryStore) -> AppContainer {
        AppContainer(
            paths: AppPaths(applicationSupportDirectory: makeTemporaryDirectory(self)),
            settings: InMemorySettingsStore(),
            store: store
        )
    }

    // MARK: - I1a.3 required

    @MainActor
    func testConcurrentEnsureLoadedLoadsOnce() async {
        let entry = makeTestEntry("house", translations: ["будинок"], createdOffset: 0)
        // The delay keeps the first load in flight while the other callers arrive.
        let store = CountingDictionaryStore(entries: [entry], loadDelay: 0.2)
        let container = makeContainer(store: store)
        XCTAssertNil(container.loadOutcome)
        XCTAssertFalse(container.isLoaded)

        let callers = 12
        let outcomes = await withTaskGroup(of: DictionaryLoadOutcome.self) { group -> [DictionaryLoadOutcome] in
            for _ in 0..<callers {
                group.addTask {
                    await container.ensureLoaded()
                }
            }
            var collected: [DictionaryLoadOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        XCTAssertEqual(store.loadCount, 1, "repository.load() must run exactly once")
        XCTAssertEqual(outcomes.count, callers)
        XCTAssertTrue(outcomes.allSatisfy { $0 == .loaded(recoveredBackupURL: nil) }, "\(outcomes)")
        XCTAssertEqual(container.loadOutcome, .loaded(recoveredBackupURL: nil))
        XCTAssertTrue(container.isLoaded)
        XCTAssertNil(container.loadError)

        // Later calls (scene re-activation, intents) reuse the cached result.
        let again = await container.ensureLoaded()
        XCTAssertEqual(again, .loaded(recoveredBackupURL: nil))
        XCTAssertEqual(store.loadCount, 1)
        let all = await container.repository.allEntries()
        XCTAssertEqual(all.map(\.id), [entry.id])
        XCTAssertEqual(store.saveCount, 0, "loading must not write the dictionary")
    }

    @MainActor
    func testLoadErrorSurfaced() async {
        let store = CountingDictionaryStore(failure: StorageError.unsupportedSchemaVersion(7))
        let container = makeContainer(store: store)

        let outcome = await container.ensureLoaded()

        let expected = StorageError.unsupportedSchemaVersion(7).userMessage
        XCTAssertEqual(outcome, .failed(message: expected))
        XCTAssertEqual(container.loadOutcome, .failed(message: expected))
        XCTAssertEqual(container.loadError, expected)
        XCTAssertFalse(container.isLoaded)

        // The error is cached: no second read until relaunch (as on macOS).
        let again = await container.ensureLoaded()
        XCTAssertEqual(again, .failed(message: expected))
        XCTAssertEqual(store.loadCount, 1)

        // The model shows the same message.
        let model = MobileAppModel(container: container)
        await model.start()
        XCTAssertEqual(model.loadError, expected)
        XCTAssertFalse(model.isLoaded)
        XCTAssertEqual(store.loadCount, 1)
    }

    // MARK: - Additional

    @MainActor
    func testConcurrentCallersAllSeeTheCachedError() async {
        let store = CountingDictionaryStore(loadDelay: 0.1, failure: StorageError.readFailed("disk"))
        let container = makeContainer(store: store)

        async let first = container.ensureLoaded()
        async let second = container.ensureLoaded()
        async let third = container.ensureLoaded()
        let outcomes = await [first, second, third]

        let expected = DictionaryLoadOutcome.failed(message: StorageError.readFailed("disk").userMessage)
        XCTAssertEqual(outcomes, [expected, expected, expected])
        XCTAssertEqual(store.loadCount, 1)
    }

    @MainActor
    func testNonStorageErrorUsesGenericLoadFailedMessage() async {
        let failure = MobileTestError(reason: "boom")
        let store = CountingDictionaryStore(failure: failure)
        let container = makeContainer(store: store)

        let outcome = await container.ensureLoaded()

        let expected = L10n.text(.modelLoadFailed, ["reason": failure.localizedDescription])
        XCTAssertEqual(outcome, .failed(message: expected))
        XCTAssertEqual(container.loadError, expected)
        XCTAssertTrue(expected.contains("boom"), expected)
    }

    @MainActor
    func testBaseDirectoryInitUsesFileStoreInThatDirectory() async throws {
        let directory = makeTemporaryDirectory(self)
        let entry = makeTestEntry("apple", translations: ["яблуко"], createdOffset: 0)
        try writeDictionary([entry], to: directory)
        let settings = InMemorySettingsStore()

        let container = AppContainer(baseDirectory: directory, settings: settings)

        XCTAssertEqual(container.paths, AppPaths(applicationSupportDirectory: directory))
        XCTAssertEqual(container.paths.backupsDirectory, directory.appendingPathComponent("Backups", isDirectory: true))
        XCTAssertTrue(container.settings === settings)
        let outcome = await container.ensureLoaded()
        XCTAssertEqual(outcome, .loaded(recoveredBackupURL: nil))
        let all = await container.repository.allEntries()
        XCTAssertEqual(all, [entry])
    }

    @MainActor
    func testMakeLiveUnderXCTestUsesTemporaryDirectoryAndInMemorySettings() async {
        let first = AppContainer.makeLive(environment: [AppContainer.xcTestEnvironmentKey: "/tmp/x.xctestconfiguration"])
        let second = AppContainer.makeLive(environment: [AppContainer.xcTestEnvironmentKey: "/tmp/x.xctestconfiguration"])

        let directory = first.paths.applicationSupportDirectory
        XCTAssertTrue(directory.lastPathComponent.hasPrefix("VocabMobileTests-"), directory.path)
        XCTAssertTrue(directory.path.hasPrefix(FileManager.default.temporaryDirectory.path), directory.path)
        XCTAssertNotEqual(directory, second.paths.applicationSupportDirectory, "each live test container is unique")
        XCTAssertTrue(first.settings is InMemorySettingsStore)
        XCTAssertNotEqual(first.paths, AppPaths.standard())
    }

    @MainActor
    func testMakeLiveOutsideXCTestUsesStandardPathsAndUserDefaults() async {
        // Construction only: nothing is loaded or written.
        let container = AppContainer.makeLive(environment: [:])
        XCTAssertEqual(container.paths, AppPaths.standard())
        XCTAssertEqual(container.paths.applicationSupportDirectory.lastPathComponent, AppPaths.folderName)
        XCTAssertTrue(container.settings is UserDefaultsSettingsStore)
        XCTAssertNil(container.loadOutcome)
    }
}
