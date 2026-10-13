import AppKit
import VocabCore

/// Композиційний корінь застосунку.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let paths: AppPaths
    let repository: DictionaryRepository
    let model: AppModel

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
        self.paths = paths
        self.repository = repository
        self.model = AppModel(repository: repository, languagePairID: LanguagePairRegistry.defaultPairID)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Під тестами словник не завантажується автоматично: тести самі створюють AppModel у тимчасовому каталозі.
        guard !AppEnvironment.isRunningTests else { return }
        let model = self.model
        Task { @MainActor in
            await model.load()
        }
    }
}
