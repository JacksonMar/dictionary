import AppKit
import XCTest
import VocabCore
@testable import VocabApp

/// Запис `AppleLanguages` у пам'ять (D37) — тести не чіпають реальні `UserDefaults`.
final class FakePreferredLanguagesWriter: PreferredLanguagesWriting {
    var stored: [String]?
    private(set) var writes: [[String]] = []

    init(stored: [String]? = nil) {
        self.stored = stored
    }

    var appleLanguages: [String]? {
        stored
    }

    func setAppleLanguages(_ codes: [String]) {
        writes.append(codes)
        stored = codes
    }
}

/// Фейковий перезапуск (D37): рахує виклики, за потреби кидає помилку.
@MainActor
final class FakeAppRelauncher: AppRelaunching {
    struct Failure: Error {}

    var shouldFail = false
    private(set) var calls = 0

    func relaunch() throws {
        calls += 1
        if shouldFail {
            throw Failure()
        }
    }
}

/// M9.5 — Info.plist/локалізації бандла, `ServicesMenu.strings`, вибір мови, перезапуск.
/// Під XCTest `InterfaceLanguageBootstrap` встановлює `L10n.current = .en`, тож модель тут стартує англійською.
final class InterfaceLanguageTests: XCTestCase {
    private static let servicesKey = "Додати в словник"

    override func setUp() {
        super.setUp()
        L10n.setCurrent(.en)
    }

    override func tearDown() {
        L10n.setCurrent(.en)
        super.tearDown()
    }

    @MainActor
    private func makeModel(
        settings: SettingsStore,
        writer: PreferredLanguagesWriting? = nil,
        relauncher: AppRelaunching? = nil
    ) throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabAppM9Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let paths = AppPaths(applicationSupportDirectory: directory)
        let dates = FixedDateProvider(Date(timeIntervalSince1970: 1_791_885_600))
        let store = FileDictionaryStore(
            fileURL: paths.dictionaryURL,
            fileSystem: LocalFileSystem(),
            dateProvider: dates,
            backups: BackupManager(directory: paths.backupsDirectory, dateProvider: dates)
        )
        let repository = DictionaryRepository(store: store, dateProvider: dates)
        return AppModel(
            repository: repository,
            settings: settings,
            preferredLanguages: writer,
            relauncher: relauncher
        )
    }

    // MARK: - Info.plist і ресурси

    func testInfoPlistDeclaresLocalizations() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDevelopmentRegion") as? String, "en")
        let localizations = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String]
        )
        XCTAssertTrue(Set(localizations).isSuperset(of: ["en", "uk"]), "\(localizations)")
        XCTAssertTrue(Set(Bundle.main.localizations).isSuperset(of: ["en", "uk"]), "\(Bundle.main.localizations)")
    }

    func testServicesMenuStringsForBothLocalizations() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let services = try XCTUnwrap(info["NSServices"] as? [[String: Any]])
        let menuItem = try XCTUnwrap(services.first?["NSMenuItem"] as? [String: Any])
        let key = try XCTUnwrap(menuItem["default"] as? String)
        XCTAssertEqual(key, Self.servicesKey, "the translation key is NSMenuItem.default (D38)")

        let expected = ["en": "Add to Dictionary", "uk": "Додати в словник"]
        for (localization, title) in expected {
            let path = try XCTUnwrap(
                Bundle.main.path(forResource: "ServicesMenu", ofType: "strings", inDirectory: nil,
                                 forLocalization: localization),
                "ServicesMenu.strings missing for \(localization)"
            )
            XCTAssertTrue(path.contains("\(localization).lproj"), path)
            let table = try XCTUnwrap(NSDictionary(contentsOf: URL(fileURLWithPath: path)), path)
            XCTAssertEqual(table[key] as? String, title, localization)
        }
    }

    // MARK: - Bootstrap (D36)

    func testBootstrapUnderTestsForcesEnglishWithoutWriting() {
        let writer = FakePreferredLanguagesWriter()
        let result = InterfaceLanguageBootstrap.apply(
            settings: InMemorySettingsStore(interfaceLanguage: .uk),
            writer: writer,
            isRunningTests: true
        )
        XCTAssertEqual(result, .en)
        XCTAssertEqual(L10n.current, .en)
        XCTAssertTrue(writer.writes.isEmpty)
    }

    func testBootstrapAppliesStoredLanguageAndSyncsAppleLanguages() {
        let writer = FakePreferredLanguagesWriter()
        let result = InterfaceLanguageBootstrap.apply(
            settings: InMemorySettingsStore(interfaceLanguage: .uk),
            writer: writer,
            isRunningTests: false
        )
        XCTAssertEqual(result, .uk)
        XCTAssertEqual(L10n.current, .uk)
        XCTAssertEqual(writer.writes, [["uk"]])

        // Уже синхронізовано → без повторного запису (ідемпотентно).
        InterfaceLanguageBootstrap.apply(
            settings: InMemorySettingsStore(interfaceLanguage: .uk),
            writer: writer,
            isRunningTests: false
        )
        XCTAssertEqual(writer.writes, [["uk"]])

        // Нова установка: англійська за замовчуванням.
        let fresh = FakePreferredLanguagesWriter()
        XCTAssertEqual(
            InterfaceLanguageBootstrap.apply(settings: InMemorySettingsStore(), writer: fresh, isRunningTests: false),
            .en
        )
        XCTAssertEqual(L10n.current, .en)
        XCTAssertEqual(fresh.writes, [["en"]])
    }

    func testUserDefaultsWriterReadsOnlyAppDomain() throws {
        let suiteName = "com.vocabapp.tests.m9.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let writer = UserDefaultsPreferredLanguagesWriter(defaults: defaults, domainName: suiteName)
        XCTAssertNil(writer.appleLanguages, "nothing in the app domain yet (global list is ignored)")
        writer.setAppleLanguages(["uk"])
        XCTAssertEqual(defaults.array(forKey: "AppleLanguages") as? [String], ["uk"])
        XCTAssertEqual(writer.appleLanguages, ["uk"])
        XCTAssertEqual(UserDefaultsPreferredLanguagesWriter.key, "AppleLanguages")
    }

    // MARK: - AppModel: вибір і перезапуск (D37)

    @MainActor
    func testSelectingLanguagePersistsAndWritesAppleLanguages() throws {
        let settings = InMemorySettingsStore()
        let writer = FakePreferredLanguagesWriter()
        let model = try makeModel(settings: settings, writer: writer)
        XCTAssertEqual(model.runningInterfaceLanguage, .en)
        XCTAssertEqual(model.interfaceLanguageSelection, .en)

        model.setInterfaceLanguage(.uk)
        XCTAssertEqual(settings.interfaceLanguage, .uk)
        XCTAssertEqual(model.interfaceLanguageSelection, .uk)
        XCTAssertEqual(writer.writes, [["uk"]])
        XCTAssertEqual(L10n.current, .en, "current UI language does not change before restart")

        model.setInterfaceLanguage(.en)
        XCTAssertEqual(settings.interfaceLanguage, .en)
        XCTAssertEqual(writer.writes, [["uk"], ["en"]])
    }

    @MainActor
    func testSelectingLanguageWithoutWriterStillPersists() throws {
        let settings = InMemorySettingsStore()
        let model = try makeModel(settings: settings, writer: nil)
        model.setInterfaceLanguage(.uk)
        XCTAssertEqual(settings.interfaceLanguage, .uk)
        XCTAssertEqual(model.interfaceLanguageSelection, .uk)
    }

    @MainActor
    func testRestartNeededOnlyWhenSelectionDiffers() throws {
        let model = try makeModel(settings: InMemorySettingsStore())
        XCTAssertFalse(model.interfaceLanguageNeedsRestart)
        model.setInterfaceLanguage(.uk)
        XCTAssertTrue(model.interfaceLanguageNeedsRestart)
        model.setInterfaceLanguage(.en)
        XCTAssertFalse(model.interfaceLanguageNeedsRestart, "back to the running language → no restart")

        // Збережено `.uk`, але запуск англійською (напр. вибір без перезапуску) → перезапуск потрібен одразу.
        let pendingRestart = try makeModel(settings: InMemorySettingsStore(interfaceLanguage: .uk))
        XCTAssertEqual(pendingRestart.interfaceLanguageSelection, .uk)
        XCTAssertTrue(pendingRestart.interfaceLanguageNeedsRestart)

        // Запуск українською з тим самим збереженим значенням → не потрібен.
        L10n.setCurrent(.uk)
        let ukrainian = try makeModel(settings: InMemorySettingsStore(interfaceLanguage: .uk))
        XCTAssertEqual(ukrainian.runningInterfaceLanguage, .uk)
        XCTAssertFalse(ukrainian.interfaceLanguageNeedsRestart)
        ukrainian.setInterfaceLanguage(.en)
        XCTAssertTrue(ukrainian.interfaceLanguageNeedsRestart)
    }

    @MainActor
    func testRestartNowInvokesRelauncher() throws {
        let relauncher = FakeAppRelauncher()
        let model = try makeModel(settings: InMemorySettingsStore(), relauncher: relauncher)
        model.setInterfaceLanguage(.uk)
        model.settingsError = "stale"
        model.restartToApplyLanguage()
        XCTAssertEqual(relauncher.calls, 1)
        XCTAssertNil(model.settingsError)
    }

    @MainActor
    func testRelaunchFailureShowsSettingsError() throws {
        let relauncher = FakeAppRelauncher()
        relauncher.shouldFail = true
        let model = try makeModel(settings: InMemorySettingsStore(), relauncher: relauncher)
        model.setInterfaceLanguage(.uk)
        model.restartToApplyLanguage()
        XCTAssertEqual(relauncher.calls, 1)
        XCTAssertEqual(model.settingsError, L10n.text(.settingsRestartFailed))
        XCTAssertEqual(
            model.settingsError,
            "Could not restart VocabApp automatically. Quit and open VocabApp manually."
        )
    }

    @MainActor
    func testMissingRelauncherShowsSettingsError() throws {
        let model = try makeModel(settings: InMemorySettingsStore(), relauncher: nil)
        model.setInterfaceLanguage(.uk)
        model.restartToApplyLanguage()
        XCTAssertEqual(model.settingsError, L10n.text(.settingsRestartFailed))
    }

    // MARK: - ProcessAppRelauncher (D37)

    func testRelauncherArgumentsWaitForPidThenOpenBundle() {
        let arguments = ProcessAppRelauncher.arguments(pid: 4242, bundlePath: "/Applications/VocabApp.app")
        XCTAssertEqual(arguments.count, 5)
        XCTAssertEqual(arguments[0], "-c")
        XCTAssertEqual(arguments[1], ProcessAppRelauncher.script)
        XCTAssertEqual(arguments[2], "sh", "$0 of the script")
        XCTAssertEqual(arguments[3], "4242", "$1 — pid to wait for")
        XCTAssertEqual(arguments[4], "/Applications/VocabApp.app", "$2 — bundle to open")
        XCTAssertEqual(ProcessAppRelauncher.shellPath, "/bin/sh")

        let script = ProcessAppRelauncher.script
        XCTAssertTrue(script.contains("kill -0 \"$1\""), script)
        XCTAssertTrue(script.contains("/usr/bin/open \"$2\""), script)
        XCTAssertFalse(script.contains("4242"), "pid is passed as an argument, not interpolated")
        XCTAssertFalse(script.contains("VocabApp.app"), "path is passed as an argument, not interpolated")
    }

    func testRelauncherScriptIsBounded() throws {
        XCTAssertEqual(ProcessAppRelauncher.maxWaitIterations, 100)
        let script = ProcessAppRelauncher.script
        XCTAssertTrue(script.contains("100"), script)
        XCTAssertTrue(script.contains("sleep 0.2"), script)
        let exitRange = try XCTUnwrap(script.range(of: "exit 1"), "loop must exit without open")
        let openRange = try XCTUnwrap(script.range(of: "/usr/bin/open"))
        XCTAssertLessThan(exitRange.lowerBound, openRange.lowerBound, "exit happens inside the loop, before open")

        // Поведінка: копія скрипта без пауз і з `echo` замість `open` (продакшн-код не змінюється).
        let testable = script
            .replacingOccurrences(of: "sleep 0.2", with: ":")
            .replacingOccurrences(of: "/usr/bin/open", with: "echo OPENED")

        // Живий процес (сам тест-хост) не завершується → вихід 1 після ліміту, без open.
        let alive = try runShell(testable, pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(alive.status, 1)
        XCTAssertFalse(alive.output.contains("OPENED"), alive.output)

        // Процес уже завершився → open одразу.
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        let dead = try runShell(testable, pid: finished.processIdentifier)
        XCTAssertEqual(dead.status, 0)
        XCTAssertTrue(dead.output.contains("OPENED /tmp/VocabApp-test.app"), dead.output)
    }

    private func runShell(_ script: String, pid: Int32) throws -> (status: Int32, output: String) {
        var arguments = ProcessAppRelauncher.arguments(pid: pid, bundlePath: "/tmp/VocabApp-test.app")
        arguments[1] = script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessAppRelauncher.shellPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - Тексти App

    func testRenderingLanguageTextsBothLanguages() throws {
        let pair = try XCTUnwrap(LanguagePairRegistry.shared.pair(id: LanguagePairRegistry.defaultPairID))
        let italian = try XCTUnwrap(pair.rendering(id: "it"))

        let english = RenderingLanguageTexts(italian, language: .en)
        XCTAssertEqual(english.pendingBadge, "Italian version pending")
        XCTAssertEqual(english.refreshTitle, "Refresh Italian Translation")
        XCTAssertEqual(english.backfillTitle, "Fill In Italian")
        XCTAssertEqual(english.backfillProgress, "Filling in Italian…")
        XCTAssertEqual(english.sectionTitle, "Italian Version")

        let ukrainian = RenderingLanguageTexts(italian, language: .uk)
        XCTAssertEqual(ukrainian.pendingBadge, "італійська версія очікує")
        XCTAssertEqual(ukrainian.refreshTitle, "Оновити італійський переклад")
        XCTAssertEqual(ukrainian.backfillTitle, "Доповнити італійською")
        XCTAssertEqual(ukrainian.backfillProgress, "Доповнення італійською…")
        XCTAssertEqual(ukrainian.sectionTitle, "Італійська версія")

        let german = RenderingLanguage(
            id: "de",
            shortTitle: "DE",
            languageName: "German",
            speechLanguageCode: "de-DE",
            prompt: italian.prompt
        )
        XCTAssertEqual(RenderingLanguageTexts(german, language: .en).sectionTitle, "DE Version")
        XCTAssertEqual(RenderingLanguageTexts(german, language: .uk).sectionTitle, "Версія DE")
        XCTAssertEqual(RenderingLanguageTexts(german, language: .uk).refreshTitle, "Оновити переклад (DE)")

        XCTAssertEqual(RenderingLanguageTexts(italian), english, "default follows L10n.current (.en)")
        L10n.setCurrent(.uk)
        XCTAssertEqual(RenderingLanguageTexts(italian), ukrainian)
    }

    func testWindowTitlesFollowCurrentLanguage() {
        XCTAssertEqual(WindowTitle.dictionary, "Dictionary")
        XCTAssertEqual(WindowTitle.settings, "Settings")
        L10n.setCurrent(.uk)
        XCTAssertEqual(WindowTitle.dictionary, "Словник")
        XCTAssertEqual(WindowTitle.settings, "Налаштування")
    }

    func testLanguagePickerLabelsAreAutonyms() {
        XCTAssertEqual(AppLanguage.allCases.map(\.nativeName), ["English", "Українська"])
        XCTAssertEqual(AppLanguage.pickerLabel, "Interface language / Мова інтерфейсу")
    }
}
