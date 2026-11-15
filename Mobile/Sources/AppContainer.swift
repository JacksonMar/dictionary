import Foundation
import VocabCore

/// Результат завантаження словника (IOS_PLAN §4): кешується в `AppContainer` разом із задачею.
enum DictionaryLoadOutcome: Equatable, Sendable {
    /// Словник завантажено; `recoveredBackupURL` — куди перенесено зіпсований файл (D12), якщо таке було.
    case loaded(recoveredBackupURL: URL?)
    /// Фатальна помилка (напр. новіша схема): текст для UI мовою інтерфейсу.
    case failed(message: String)
}

/// Композиційний корінь iOS-застосунку (IOS_PLAN §2, §4): одне сховище, один `DictionaryRepository` (actor) на
/// процес, налаштування, реєстр мовних пар. Claude, Keychain, черга — з I1b.
///
/// Завантаження — single-flight: перший `ensureLoaded()` створює й кешує `Task` з `repository.load()`; наступні
/// виклики (UI, intent-и, повторний `.active`) чекають на той самий `Task`. Помилка кешується (як на macOS):
/// повторного читання файлу немає до перезапуску.
///
/// У застосунку — `AppContainer.shared`; у тестах — `AppContainer(baseDirectory:settings:)` із тимчасовим каталогом
/// або `init(paths:settings:store:…)` з фейковим `DictionaryStoring`.
@MainActor
final class AppContainer {
    /// Ключ середовища, який XCTest встановлює host-застосунку.
    static let xcTestEnvironmentKey = "XCTestConfigurationFilePath"

    /// Контейнер процесу застосунку. Під XCTest — тимчасовий каталог і налаштування в пам'яті, щоб hosted-тести
    /// ніколи не чіпали справжній словник і `UserDefaults`.
    static let shared: AppContainer = AppContainer.makeLive(environment: ProcessInfo.processInfo.environment)

    let paths: AppPaths
    let settings: SettingsStore
    let registry: LanguagePairRegistry
    let dateProvider: DateProvider
    let repository: DictionaryRepository

    private var loadTask: Task<DictionaryLoadOutcome, Never>?
    /// Результат завершеного завантаження; `nil` — ще не завантажено (або завантаження триває).
    private(set) var loadOutcome: DictionaryLoadOutcome?

    /// Повна ін'єкція (тести). `store == nil` → `FileDictionaryStore` у `paths` з бекапами в `paths.backupsDirectory`.
    init(
        paths: AppPaths,
        settings: SettingsStore,
        store: DictionaryStoring? = nil,
        fileSystem: FileSystem = LocalFileSystem(),
        dateProvider: DateProvider = SystemDateProvider(),
        registry: LanguagePairRegistry = .shared
    ) {
        self.paths = paths
        self.settings = settings
        self.registry = registry
        self.dateProvider = dateProvider
        let resolvedStore: DictionaryStoring
        if let store {
            resolvedStore = store
        } else {
            let backups = BackupManager(
                directory: paths.backupsDirectory,
                fileSystem: fileSystem,
                dateProvider: dateProvider
            )
            resolvedStore = FileDictionaryStore(
                fileURL: paths.dictionaryURL,
                fileSystem: fileSystem,
                dateProvider: dateProvider,
                backups: backups
            )
        }
        self.repository = DictionaryRepository(store: resolvedStore, dateProvider: dateProvider)
    }

    /// Контейнер над каталогом даних `baseDirectory` (`dictionary.json` і `Backups/` усередині).
    convenience init(baseDirectory: URL, settings: SettingsStore) {
        self.init(paths: AppPaths(applicationSupportDirectory: baseDirectory), settings: settings)
    }

    /// Реальні шляхи (`<контейнер>/Library/Application Support/VocabApp`, DI6) і `UserDefaults.standard`;
    /// під XCTest — унікальний тимчасовий каталог і `InMemorySettingsStore`.
    static func makeLive(environment: [String: String]) -> AppContainer {
        if environment[xcTestEnvironmentKey] != nil {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VocabMobileTests-\(UUID().uuidString)", isDirectory: true)
            return AppContainer(baseDirectory: directory, settings: InMemorySettingsStore())
        }
        return AppContainer(paths: AppPaths.standard(), settings: UserDefaultsSettingsStore(defaults: .standard))
    }

    /// Помилка завантаження для UI (`nil` — немає помилки або ще не завантажено).
    var loadError: String? {
        if case .failed(let message)? = loadOutcome {
            return message
        }
        return nil
    }

    /// Словник завантажено успішно.
    var isLoaded: Bool {
        if case .loaded? = loadOutcome {
            return true
        }
        return false
    }

    /// Single-flight завантаження (§4). Повертає закешований результат; `repository.load()` виконується один раз.
    @discardableResult
    func ensureLoaded() async -> DictionaryLoadOutcome {
        if let existing = loadTask {
            return await existing.value
        }
        let repository = self.repository
        let task = Task<DictionaryLoadOutcome, Never> {
            await Self.load(repository)
        }
        loadTask = task
        let outcome = await task.value
        loadOutcome = outcome
        return outcome
    }

    /// Одна спроба завантаження; помилки перетворюються на текст мовою інтерфейсу (як macOS `AppModel.load`).
    private nonisolated static func load(_ repository: DictionaryRepository) async -> DictionaryLoadOutcome {
        do {
            let result = try await repository.load()
            return .loaded(recoveredBackupURL: result.recoveredBackupURL)
        } catch let error as StorageError {
            return .failed(message: error.userMessage)
        } catch {
            return .failed(message: L10n.text(.modelLoadFailed, ["reason": error.localizedDescription]))
        }
    }
}
