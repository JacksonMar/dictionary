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
        let model = AppModel(
            repository: repository,
            languagePairID: LanguagePairRegistry.defaultPairID,
            claude: claude,
            transfer: transfer,
            filePanels: SystemFilePanels()
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
}
