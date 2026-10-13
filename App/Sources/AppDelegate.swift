import AppKit
import Foundation
import VocabCore

/// Композиційний корінь застосунку.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let paths: AppPaths
    let repository: DictionaryRepository
    let model: AppModel
    private var networkMonitor: NetworkMonitor?

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

        self.paths = paths
        self.repository = repository
        self.model = AppModel(
            repository: repository,
            languagePairID: LanguagePairRegistry.defaultPairID,
            claude: claude
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Під тестами словник не завантажується автоматично: тести самі створюють AppModel у тимчасовому каталозі.
        guard !AppEnvironment.isRunningTests else { return }
        let model = self.model

        let monitor = NetworkMonitor {
            Task { @MainActor in
                await model.processPending()
            }
        }
        monitor.start()
        networkMonitor = monitor

        Task { @MainActor in
            await model.load()
            await model.processPending()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        networkMonitor?.stop()
    }
}
