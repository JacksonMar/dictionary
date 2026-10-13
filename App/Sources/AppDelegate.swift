import AppKit
import Foundation
import VocabCore

/// Композиційний корінь застосунку.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let paths: AppPaths
    let repository: DictionaryRepository
    let model: AppModel
    /// Обробник Services (§11); реєструється в `applicationDidFinishLaunching` (не під XCTest).
    let servicesProvider: ServicesProvider
    let notifier: UserNotifier
    private var networkMonitor: NetworkMonitor?
    /// Завантаження словника на старті; запити Services чекають на нього (U5: запуск застосунку сервісом).
    private var loadTask: Task<Void, Never>?

    override init() {
        let paths = AppEnvironment.makePaths()
        let dateProvider = SystemDateProvider()
        let fileSystem = LocalFileSystem()
        let backups = BackupManager(
            directory: paths.backupsDirectory,
            fileSystem: fileSystem,
            dateProvider: dateProvider
        )
        let store = FileDictionaryStore(
            fileURL: paths.dictionaryURL,
            fileSystem: fileSystem,
            dateProvider: dateProvider,
            backups: backups
        )
        let repository = DictionaryRepository(store: store, dateProvider: dateProvider)
        let transfer = DictionaryTransferService(
            repository: repository,
            store: store,
            backups: backups,
            fileSystem: fileSystem,
            dateProvider: dateProvider
        )

        // Під тестами — ні Keychain, ні реальних UserDefaults (§11).
        let isRunningTests = AppEnvironment.isRunningTests
        let secrets: SecretStore = isRunningTests ? InMemorySecretStore() : KeychainSecretStore()
        let settings: SettingsStore = isRunningTests
            ? InMemorySettingsStore()
            : UserDefaultsSettingsStore(defaults: .standard)
        let claude = ClaudeServices.make(
            repository: repository,
            secrets: secrets,
            settings: settings,
            transport: URLSessionTransport(session: URLSession(configuration: .ephemeral)),
            logSink: OSLogSink(category: "claude"),
            registry: .shared,
            dateProvider: dateProvider
        )

        // Під тестами — заглушка без звернень до `UNUserNotificationCenter`.
        let notifier: UserNotifier = isRunningTests
            ? SilentUserNotifier()
            : NotificationService(logger: claude.logger)
        // Під тестами — без реєстрації login item і без аудіо.
        let loginItems: LoginItemManaging? = isRunningTests ? nil : LoginItemService()
        let speech: SpeechSpeaking? = isRunningTests ? nil : SpeechService()
        let model = AppModel(
            repository: repository,
            languagePairID: LanguagePairRegistry.defaultPairID,
            claude: claude,
            transfer: transfer,
            filePanels: SystemFilePanels(),
            loginItems: loginItems,
            speech: speech
        )

        self.paths = paths
        self.repository = repository
        self.model = model
        self.notifier = notifier
        self.servicesProvider = ServicesProvider(
            handler: claude.serviceHandler,
            notifier: notifier,
            onResponse: { [weak model] response in
                model?.recordServiceResponse(response)
            }
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Під тестами словник не завантажується автоматично: тести самі створюють AppModel у тимчасовому каталозі.
        guard !AppEnvironment.isRunningTests else { return }
        let model = self.model

        // U12: при запуску жодне вікно не відкривається — лише іконка в menu bar.
        closeScenesOpenedAtLaunch()

        // Спершу — завантаження словника, щоб запит Services, що запустив застосунок, його дочекався.
        let loadTask = Task { @MainActor in
            await model.load()
        }
        self.loadTask = loadTask
        servicesProvider.setPreparation {
            await loadTask.value
        }
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()

        // Дозвіл на сповіщення запитується ЛИШЕ тут (один раз на старті, §11); `NotificationService.post`
        // сам не запитує, а чекає на цей запит, якщо користувач ще не відповів.
        if let notificationService = notifier as? NotificationService {
            notificationService.install()
        }
        let notifier = self.notifier
        Task {
            _ = await notifier.requestAuthorization()
        }

        let monitor = NetworkMonitor {
            Task { @MainActor in
                await model.processPending()
            }
        }
        monitor.start()
        networkMonitor = monitor

        Task { @MainActor in
            await loadTask.value
            await model.processPending()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        networkMonitor?.stop()
    }

    // MARK: - U12: вікна, відкриті системою при запуску

    /// macOS 13 (без `defaultLaunchBehavior(.suppressed)`, що є лише з macOS 15) може автоматично відкрити першу
    /// `Window`-сцену при запуску. Закриваємо вікна сцен «Словник»/«Налаштування» одразу, на наступному проході
    /// головної черги і ще раз через 0,3 с (SwiftUI може створити вікно трохи пізніше). Викликається лише зі
    /// старту, тож вікна, які користувач відкриє через меню пізніше, не зачіпаються.
    private func closeScenesOpenedAtLaunch() {
        Self.closeSceneWindows()
        Task { @MainActor in
            Self.closeSceneWindows()
            try? await Task.sleep(nanoseconds: 300_000_000)
            Self.closeSceneWindows()
        }
    }

    private static func closeSceneWindows() {
        for window in NSApp.windows where isSceneWindow(window) {
            window.close()
        }
    }

    /// Вікно `Window`-сцени словника чи налаштувань. Формат `NSWindow.identifier` для SwiftUI-сцен на macOS 13
    /// не задокументований (U12), тому збіг — за ідентифікатором (містить id сцени) **або** заголовком.
    /// Ніколи не чіпаємо вікно `MenuBarExtra` (status bar, без рамки заголовка) і панелі.
    static func isSceneWindow(_ window: NSWindow) -> Bool {
        let className = String(describing: type(of: window))
        if className.contains("StatusBar") || className.contains("MenuBarExtra") || window is NSPanel {
            return false
        }
        guard window.styleMask.contains(.titled) else { return false }
        let identifier = window.identifier?.rawValue ?? ""
        if identifier.contains(WindowID.dictionary) || identifier.contains(WindowID.settings) {
            return true
        }
        return window.title == WindowTitle.dictionary || window.title == WindowTitle.settings
    }
}
