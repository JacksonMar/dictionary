import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import VocabCore

/// Результат завантаження словника (IOS_PLAN §4): кешується в `AppContainer` разом із задачею.
enum DictionaryLoadOutcome: Equatable, Sendable {
    /// Словник завантажено; `recoveredBackupURL` — куди перенесено зіпсований файл (D12), якщо таке було.
    case loaded(recoveredBackupURL: URL?)
    /// Фатальна помилка (напр. новіша схема): текст для UI мовою інтерфейсу.
    case failed(message: String)
}

/// Композиційний корінь iOS-застосунку (IOS_PLAN §2, §4): одне сховище, один `DictionaryRepository` (actor) на
/// процес, налаштування, реєстр мовних пар, API-ключ (`SecretStore`), Claude (`ClaudeLookupService`), черга
/// (`EntryProcessor` → `PendingQueueProcessor`), `AddWordUseCase`, доповнення варіантів (`VariantBackfillProcessor`),
/// фонові задачі, озвучення, inbox «Поділитися» (`InboxStore` → `InboxIngestor`, I3), `Router` процесу (I4),
/// експорт/імпорт (`DictionaryTransferService` + `ImportFileStager`, I5). Композиція — як macOS `ClaudeServices.make` (`App/Sources/AppModel.swift`).
///
/// Завантаження — single-flight: перший `ensureLoaded()` створює й кешує `Task` з `repository.load()`; наступні
/// виклики (UI, intent-и, повторний `.active`) чекають на той самий `Task`. Помилка кешується (як на macOS):
/// повторного читання файлу немає до перезапуску.
///
/// У застосунку — `AppContainer.shared`; у тестах — `AppContainer(baseDirectory:settings:)` із тимчасовим каталогом
/// або `init(paths:settings:store:…)` з фейковим `DictionaryStoring`; за замовчуванням — `InMemorySecretStore`,
/// ефемерна `URLSession` (тести передають сесію з `MockURLProtocol` через `transport`), без фонових задач і звуку.
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
    let fileSystem: FileSystem
    /// API-ключ (Keychain застосунку в реальному запуску, DI8).
    let secrets: SecretStore
    /// Відомі ключі для редагування логів (наповнює `MobileAppModel`).
    let keyCache: APIKeyCache
    let logger: RedactingLogger
    let lookup: ClaudeLookupService
    let queue: PendingQueueProcessor
    let addWord: AddWordUseCase
    /// M7: пакетне доповнення варіантів тим самим `ClaudeLookupService` (ключ, модель, логер).
    let variantBackfill: VariantBackfillProcessor
    let backgroundTasks: BackgroundTaskRunning
    /// `nil` — озвучення недоступне (тести, Linux).
    let speech: SpeechSpeaking?
    /// I2b: розпізнавання мовлення (`SFSpeechRecognizer`); `nil` — недоступне (тести, Linux).
    let speechRecognizer: SpeechRecognizing?
    /// I2b: аудіосесія запис ↔ відтворення; `nil` — не керуємо (тести, Linux).
    let audioSession: AudioSessionControlling?
    /// I2b: остання мова голосу (`UserDefaults`, ключ `voiceLanguage`; лише iOS-застосунок, DI12).
    let voiceLanguageStore: VoiceLanguageStoring
    /// I3: inbox «Поділитися» в App Group (DI7); `nil` — App Group недоступна або тести без inbox (інжест вимкнено).
    let inbox: InboxStore?
    /// I3: інжест inbox (single-flight, §4); `nil` разом з `inbox`.
    let inboxIngestor: InboxIngestor?
    /// I4: маршрут UI процесу — один на процес, щоб `StartVoiceCaptureIntent` (виконується в процесі застосунку) і
    /// глибокі посилання відкривали той самий аркуш, що бачить `VocabMobileApp`.
    let router: Router
    /// I5: експорт/імпорт словника (`DictionaryTransferService` ядра, ARCHITECTURE §10): merge/replace, бекап перед
    /// заміною (`BackupReason.replaceImport`), D1-конфлікти.
    let transfer: DictionaryTransferService
    /// I5: копіювання вибраного у Files файлу (security-scoped) у тимчасовий каталог перед імпортом.
    let importStager: ImportFileStager

    private var loadTask: Task<DictionaryLoadOutcome, Never>?
    /// Результат завершеного завантаження; `nil` — ще не завантажено (або завантаження триває).
    private(set) var loadOutcome: DictionaryLoadOutcome?

    /// Повна ін'єкція (тести). `store == nil` → `FileDictionaryStore` у `paths` з бекапами в `paths.backupsDirectory`.
    /// `transport == nil` → `URLSessionTransport` з ефемерною сесією; `backgroundTasks == nil` → без фонових задач.
    init(
        paths: AppPaths,
        settings: SettingsStore,
        store: DictionaryStoring? = nil,
        fileSystem: FileSystem = LocalFileSystem(),
        dateProvider: DateProvider = SystemDateProvider(),
        registry: LanguagePairRegistry = .shared,
        secrets: SecretStore = InMemorySecretStore(),
        transport: HTTPTransport? = nil,
        logSink: LogSink = PrintLogSink(),
        retryPolicy: RetryPolicy = RetryPolicy(),
        backgroundTasks: BackgroundTaskRunning? = nil,
        speech: SpeechSpeaking? = nil,
        speechRecognizer: SpeechRecognizing? = nil,
        audioSession: AudioSessionControlling? = nil,
        voiceLanguageStore: VoiceLanguageStoring = InMemoryVoiceLanguageStore(),
        inboxDirectory: URL? = nil,
        securityScopedAccess: SecurityScopedAccessing = URLSecurityScopedAccess(),
        importCoordinator: FileReadCoordinating = PassthroughFileReadCoordinator(),
        importStagingDirectory: URL? = nil
    ) {
        self.paths = paths
        self.settings = settings
        self.registry = registry
        self.dateProvider = dateProvider
        self.fileSystem = fileSystem
        // Ті самі `Backups/`, що й для зіпсованого файлу (D12): бекап перед «Замінити» (I5) лягає поруч.
        let backups = BackupManager(
            directory: paths.backupsDirectory,
            fileSystem: fileSystem,
            dateProvider: dateProvider
        )
        let resolvedStore: DictionaryStoring
        if let store {
            resolvedStore = store
        } else {
            resolvedStore = FileDictionaryStore(
                fileURL: paths.dictionaryURL,
                fileSystem: fileSystem,
                dateProvider: dateProvider,
                backups: backups
            )
        }
        let repository = DictionaryRepository(store: resolvedStore, dateProvider: dateProvider)
        self.repository = repository
        self.transfer = DictionaryTransferService(
            repository: repository,
            store: resolvedStore,
            backups: backups,
            fileSystem: fileSystem,
            dateProvider: dateProvider
        )
        self.importStager = ImportFileStager(
            access: securityScopedAccess,
            coordinator: importCoordinator,
            fileSystem: fileSystem,
            directory: importStagingDirectory ?? ImportFileStager.defaultDirectory()
        )

        // Claude і черга — як macOS `ClaudeServices.make`.
        let keyCache = APIKeyCache()
        let logger = RedactingLogger(sink: logSink, secretsProvider: { keyCache.secrets() })
        let resolvedTransport: HTTPTransport = transport
            ?? URLSessionTransport(session: URLSession(configuration: .ephemeral))
        let lookup = ClaudeLookupService(
            transport: resolvedTransport,
            secrets: secrets,
            settings: settings,
            logger: logger
        )
        let processor = EntryProcessor(
            repository: repository,
            lookup: lookup,
            registry: registry,
            dateProvider: dateProvider,
            logger: logger
        )
        let queue = PendingQueueProcessor(
            repository: repository,
            processor: processor,
            policy: retryPolicy,
            dateProvider: dateProvider
        )
        self.secrets = secrets
        self.keyCache = keyCache
        self.logger = logger
        self.lookup = lookup
        self.queue = queue
        self.addWord = AddWordUseCase(repository: repository, processor: queue, settings: settings, registry: registry)
        self.variantBackfill = VariantBackfillProcessor(
            repository: repository,
            lookup: lookup,
            registry: registry,
            policy: retryPolicy,
            dateProvider: dateProvider,
            logger: logger
        )
        self.backgroundTasks = backgroundTasks ?? NoopBackgroundTaskRunner()
        self.speech = speech
        self.speechRecognizer = speechRecognizer
        self.audioSession = audioSession
        self.voiceLanguageStore = voiceLanguageStore
        self.router = Router()
        if let inboxDirectory {
            let inbox = InboxStore(directory: inboxDirectory, fileSystem: fileSystem)
            self.inbox = inbox
            self.inboxIngestor = InboxIngestor(
                store: inbox,
                repository: repository,
                processor: queue,
                registry: registry,
                settings: settings,
                logger: logger
            )
        } else {
            self.inbox = nil
            self.inboxIngestor = nil
        }
    }

    /// Контейнер над каталогом даних `baseDirectory` (`dictionary.json` і `Backups/` усередині). Тести Claude
    /// передають `transport` (напр. `URLSessionTransport` із `MockURLProtocol`) і `secrets` із ключем.
    convenience init(
        baseDirectory: URL,
        settings: SettingsStore,
        secrets: SecretStore = InMemorySecretStore(),
        transport: HTTPTransport? = nil,
        inboxDirectory: URL? = nil
    ) {
        self.init(
            paths: AppPaths(applicationSupportDirectory: baseDirectory),
            settings: settings,
            secrets: secrets,
            transport: transport,
            inboxDirectory: inboxDirectory
        )
    }

    /// Реальні шляхи (`<контейнер>/Library/Application Support/VocabApp`, DI6), `UserDefaults.standard`, Keychain
    /// (`service` = bundle id застосунку, DI8), unified logging, фонові задачі (DI18), озвучення, розпізнавання
    /// мовлення й аудіосесія (I2b), inbox «Поділитися» в App Group (I3; немає групи → без inbox), координоване читання
    /// файлу імпорту (I6, `NSFileCoordinator`). Під XCTest — унікальний тимчасовий каталог, `InMemorySettingsStore`,
    /// `InMemorySecretStore`, мова голосу в пам'яті, без inbox, фонових задач, звуку й мікрофона (hosted-тести ніколи не чіпають справжній словник, `UserDefaults` і Keychain).
    static func makeLive(environment: [String: String]) -> AppContainer {
        if environment[xcTestEnvironmentKey] != nil {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VocabMobileTests-\(UUID().uuidString)", isDirectory: true)
            return AppContainer(baseDirectory: directory, settings: InMemorySettingsStore())
        }
        return AppContainer(
            paths: AppPaths.standard(),
            settings: UserDefaultsSettingsStore(defaults: .standard),
            secrets: LivePlatform.makeSecretStore(service: LivePlatform.keychainService()),
            logSink: LivePlatform.makeLogSink(category: "claude"),
            backgroundTasks: LivePlatform.makeBackgroundTaskRunner(),
            speech: LivePlatform.makeSpeech(),
            speechRecognizer: LivePlatform.makeSpeechRecognizer(),
            audioSession: LivePlatform.makeAudioSessionController(),
            voiceLanguageStore: UserDefaultsVoiceLanguageStore(defaults: .standard),
            inboxDirectory: InboxLocation.live(),
            importCoordinator: ImportFileStager.liveCoordinator()
        )
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
        // `loadOutcome` присвоюється всередині кешованої задачі (на головному акторі), тож кожен викликач — і перший,
        // і ті, що чекали на `existing.value`, — бачить `isLoaded`/`loadError` одразу після свого `await`.
        let task = Task<DictionaryLoadOutcome, Never> { @MainActor [weak self] in
            let outcome = await Self.load(repository)
            self?.loadOutcome = outcome
            return outcome
        }
        loadTask = task
        return await task.value
    }

    // MARK: - Дані (Налаштування)

    /// Каталог даних для показу в Налаштуваннях.
    var dataDirectoryPath: String {
        paths.applicationSupportDirectory.path
    }

    /// Кількість резервних копій у `Backups/` (`dictionary-backup-*.json`, `dictionary-corrupted-*.json`);
    /// каталогу немає або його не прочитати → 0.
    func backupCount() -> Int {
        guard let urls = try? fileSystem.contentsOfDirectory(at: paths.backupsDirectory) else { return 0 }
        let prefixes = BackupReason.allCases.map(\.filePrefix)
        return urls.reduce(0) { count, url in
            let name = url.lastPathComponent
            let isBackup = name.hasSuffix(".json") && prefixes.contains { name.hasPrefix($0) }
            return count + (isBackup ? 1 : 0)
        }
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
