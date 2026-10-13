import Foundation
import VocabCore

/// Потокобезпечний кеш API-ключів — джерело `secretsProvider` для `RedactingLogger`
/// (щоб не читати Keychain на кожен рядок логу). Ключі **накопичуються** до перезапуску: після заміни
/// чи видалення ключа старий і далі вирізається з логів і текстів помилок.
final class APIKeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<String> = []

    init() {}

    /// Додає ключ до множини відомих секретів; `nil`/порожній рядок ігнорується (нічого не видаляє).
    func set(_ newValue: String?) {
        guard let newValue, !newValue.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        values.insert(newValue)
    }

    /// Усі відомі секрети для редагування логів (довші першими, щоб ключ-префікс не лишив хвіст іншого).
    func secrets() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values.sorted { lhs, rhs in
            lhs.count != rhs.count ? lhs.count > rhs.count : lhs < rhs
        }
    }
}

/// Залежності Claude для `AppModel` (M2).
struct ClaudeServices {
    let secrets: SecretStore
    let settings: SettingsStore
    let keyCache: APIKeyCache
    let logger: RedactingLogger
    let queue: PendingQueueProcessor
    let addWord: AddWordUseCase
    let serviceHandler: ServiceRequestHandler

    static func make(
        repository: DictionaryRepository,
        secrets: SecretStore,
        settings: SettingsStore,
        transport: HTTPTransport,
        logSink: LogSink,
        registry: LanguagePairRegistry = .shared,
        dateProvider: DateProvider = SystemDateProvider(),
        policy: RetryPolicy = RetryPolicy()
    ) -> ClaudeServices {
        let keyCache = APIKeyCache()
        let logger = RedactingLogger(sink: logSink, secretsProvider: { keyCache.secrets() })
        let lookup = ClaudeLookupService(transport: transport, secrets: secrets, settings: settings, logger: logger)
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
            policy: policy,
            dateProvider: dateProvider
        )
        let addWord = AddWordUseCase(repository: repository, processor: queue, settings: settings, registry: registry)
        let serviceHandler = ServiceRequestHandler(useCase: addWord)
        return ClaudeServices(
            secrets: secrets,
            settings: settings,
            keyCache: keyCache,
            logger: logger,
            queue: queue,
            addWord: addWord,
            serviceHandler: serviceHandler
        )
    }
}

/// Повідомлення про результат експорту/імпорту (алерт у UI).
struct TransferMessage: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let text: String
    let isError: Bool
}

/// Крок імпорту, що чекає рішення користувача (§10): вибір режиму, далі — підтвердження заміни.
enum ImportStage: Equatable {
    /// Файл вибрано; діалог «Об'єднати» (за замовчуванням) / «Замінити».
    case chooseMode(URL)
    /// Вибрано «Замінити»; алерт підтвердження з попередженням про бекап.
    case confirmReplace(URL)

    var url: URL {
        switch self {
        case .chooseMode(let url), .confirmReplace(let url):
            return url
        }
    }
}

/// Міст між `DictionaryRepository` та SwiftUI. Усі `@Published` змінюються лише на головному акторі.
@MainActor
final class AppModel: ObservableObject {
    /// Інтервал таймера `processDue`, поки є pending-записи (§8.3).
    static let pendingTimerInterval: TimeInterval = 60

    /// Записи для показу (найновіші зверху).
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isLoaded = false
    /// Фатальна помилка завантаження (напр. новіша версія схеми) — словник недоступний.
    @Published var loadError: String?
    /// Попередження після завантаження (напр. зіпсований файл перенесено в Backups).
    @Published var loadWarning: String?
    /// Помилка останньої операції користувача (додавання/редагування/видалення).
    @Published var operationError: String?
    /// У Keychain є API-ключ (саме значення в UI не показується).
    @Published private(set) var hasAPIKey = false
    /// Поточна модель Claude з налаштувань.
    @Published private(set) var modelName = SettingsDefaults.model
    /// Помилка у вікні налаштувань (Keychain тощо).
    @Published var settingsError: String?
    /// Записи, для яких зараз виконується «Повторити».
    @Published private(set) var retryingIDs: Set<UUID> = []
    /// Іде «Повторити всі».
    @Published private(set) var isRetryingAll = false
    /// Текст останнього результату Services — показується в меню (видно й тоді, коли сповіщення заборонені).
    @Published var lastServiceMessage: String?
    /// Звіт останнього успішного імпорту.
    @Published private(set) var lastReport: ImportReport?
    /// Результат останнього експорту/імпорту для алерту (успіх або помилка).
    @Published var transferMessage: TransferMessage?
    /// Імпорт, що чекає вибору режиму / підтвердження заміни.
    @Published var importStage: ImportStage?
    /// Іде експорт або імпорт.
    @Published private(set) var isTransferring = false

    /// Типова назва файлу експорту.
    static let defaultExportFileName = "dictionary.json"
    /// Скільки причин пропуску показувати в алерті звіту.
    static let maxReportedSkipReasons = 10

    let languagePairID: String
    private let repository: DictionaryRepository
    private let claude: ClaudeServices?
    private let transfer: DictionaryTransferService?
    private let filePanels: FilePanelPresenting
    /// Обробка імпортованих pending-записів, запущена після імпорту (для тестів — щоб дочекатися).
    private(set) var postImportProcessing: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    private var pendingTimer: Timer?

    /// `claude == nil` — без Claude (M1-режим): «Заповнити через Claude» і черга недоступні.
    /// `transfer == nil` — експорт/імпорт недоступні. `filePanels == nil` — системні `NSSavePanel`/`NSOpenPanel`.
    init(
        repository: DictionaryRepository,
        languagePairID: String = LanguagePairRegistry.defaultPairID,
        claude: ClaudeServices? = nil,
        transfer: DictionaryTransferService? = nil,
        filePanels: FilePanelPresenting? = nil
    ) {
        self.repository = repository
        self.languagePairID = languagePairID
        self.claude = claude
        self.transfer = transfer
        self.filePanels = filePanels ?? SystemFilePanels()
        if let claude {
            modelName = claude.settings.model
        }
    }

    /// Доступні функції Claude (є залежності).
    var isClaudeAvailable: Bool {
        claude != nil
    }

    /// Завантажує словник і підписується на зміни репозиторію.
    func load() async {
        refreshAPIKeyState()
        do {
            let result = try await repository.load()
            loadError = nil
            if let backupURL = result.recoveredBackupURL {
                loadWarning = "Файл словника був пошкоджений. Його перенесено в \(backupURL.path), "
                    + "розпочато порожній словник."
            }
            isLoaded = true
            apply(await repository.allEntries())
            subscribeToChanges()
        } catch let error as StorageError {
            loadError = error.userMessage
        } catch {
            loadError = "Не вдалося завантажити словник: \(error.localizedDescription)"
        }
    }

    /// Ручне додавання (D14, M1): запис зі статусом із чернетки (`ready` у формі), перевірка дубля.
    /// Повертає створений запис або `nil` (тоді `operationError` містить причину).
    @discardableResult
    func addManual(_ draft: EntryDraft) async -> Entry? {
        var cleaned = draft
        cleaned.word = TextNormalizer.clean(draft.word)
        if let message = Self.validationError(word: cleaned.word, status: cleaned.status, translations: cleaned.translations) {
            operationError = message
            return nil
        }
        do {
            let entry = try await repository.add(cleaned)
            operationError = nil
            apply(await repository.allEntries())
            return entry
        } catch {
            operationError = Self.message(for: error)
            return nil
        }
    }

    /// Редагування. Повертає оновлений запис або `nil` (тоді `operationError` містить причину).
    @discardableResult
    func update(_ entry: Entry) async -> Entry? {
        var cleaned = entry
        cleaned.word = TextNormalizer.clean(entry.word)
        if let message = Self.validationError(word: cleaned.word, status: cleaned.status, translations: cleaned.translations) {
            operationError = message
            return nil
        }
        do {
            let updated = try await repository.update(cleaned)
            operationError = nil
            apply(await repository.allEntries())
            return updated
        } catch {
            operationError = Self.message(for: error)
            return nil
        }
    }

    /// Видалення. Повертає `true` при успіху.
    @discardableResult
    func delete(id: UUID) async -> Bool {
        do {
            try await repository.delete(id: id)
            operationError = nil
            apply(await repository.allEntries())
            return true
        } catch {
            operationError = Self.message(for: error)
            return false
        }
    }

    // MARK: - Claude (M2)

    /// Додає слово через `AddWordUseCase` (D14: «Заповнити через Claude»). Запис зберігається як `pending`
    /// ще до запиту. Повертає `nil`, якщо Claude недоступний. Для `.failed`, `.duplicate`, `.rejected`,
    /// `.storageError` встановлює `operationError`.
    @discardableResult
    func addViaClaude(_ rawText: String) async -> AddWordOutcome? {
        guard let claude else {
            operationError = "Claude недоступний"
            return nil
        }
        let outcome = await claude.addWord.execute(rawText: rawText)
        operationError = Self.errorMessage(for: outcome)
        apply(await repository.allEntries())
        return outcome
    }

    /// Кнопка «Повторити» для `pending`/`failed` запису: ігнорує backoff і скидає лічильник спроб.
    @discardableResult
    func retry(id: UUID) async -> ProcessingResult? {
        guard let claude, !retryingIDs.contains(id) else { return nil }
        retryingIDs.insert(id)
        defer { retryingIDs.remove(id) }
        let result = await claude.queue.retry(entryID: id)
        apply(await repository.allEntries())
        return result
    }

    /// «Повторити всі»: усі pending-записи без очікування backoff, далі кожен `failed` (як кнопка «Повторити»:
    /// скидає лічильник спроб).
    func retryAll() async {
        guard let claude, !isRetryingAll else { return }
        isRetryingAll = true
        defer { isRetryingAll = false }
        await claude.queue.processAll(ignoringBackoff: true)
        let failedIDs = await repository.allEntries().filter { $0.status == .failed }.map(\.id)
        for id in failedIDs where !retryingIDs.contains(id) {
            retryingIDs.insert(id)
            _ = await claude.queue.retry(entryID: id)
            retryingIDs.remove(id)
        }
        apply(await repository.allEntries())
    }

    /// Є записи, які можна повторити (`pending` або `failed`).
    var hasRetryableEntries: Bool {
        entries.contains { $0.status != .ready }
    }

    /// Результат Services (§11): текст для меню.
    func recordServiceResponse(_ response: ServiceResponse) {
        lastServiceMessage = response.notification.singleLine
    }

    /// Обробка всіх pending-записів (старт, відновлення мережі, новий ключ/модель).
    func processPending() async {
        guard let claude else { return }
        await claude.queue.processAll(ignoringBackoff: true)
    }

    /// Таймер: лише записи, для яких настав час наступної спроби.
    func processDue() async {
        guard let claude else { return }
        await claude.queue.processDue()
    }

    // MARK: - Експорт / імпорт (M4)

    /// Доступні експорт та імпорт (є залежності).
    var isTransferAvailable: Bool {
        transfer != nil
    }

    /// «Експортувати»: `NSSavePanel` (`dictionary.json`) → `export(to:)`. Скасування панелі — нічого не робить.
    func exportWithPanel() async {
        guard transfer != nil, !isTransferring else { return }
        guard let url = filePanels.chooseExportDestination(defaultFileName: Self.defaultExportFileName) else {
            return
        }
        await export(to: url)
    }

    /// Експорт поточного словника в `url` (атомарний запис). Результат — у `transferMessage`.
    @discardableResult
    func export(to url: URL) async -> Bool {
        guard let transfer else {
            transferMessage = Self.unavailableTransferMessage
            return false
        }
        guard !isTransferring else { return false }
        isTransferring = true
        defer { isTransferring = false }
        do {
            try await transfer.exportDictionary(to: url)
            let count = await repository.allEntries().count
            transferMessage = TransferMessage(
                title: "Словник експортовано",
                text: "Записів: \(count). Файл: \(url.path)",
                isError: false
            )
            return true
        } catch {
            transferMessage = TransferMessage(
                title: "Не вдалося експортувати",
                text: Self.exportErrorMessage(error),
                isError: true
            )
            return false
        }
    }

    /// «Імпортувати»: `NSOpenPanel` → `importStage = .chooseMode(url)` (UI показує вибір режиму).
    func beginImport() {
        guard transfer != nil, !isTransferring else { return }
        guard let url = filePanels.chooseImportSource() else { return }
        importStage = .chooseMode(url)
    }

    /// Вибір режиму: «Об'єднати» — одразу імпорт; «Замінити» — спершу підтвердження (`.confirmReplace`).
    /// Стан змінюється синхронно (до закриття діалогу SwiftUI); повертає задачу імпорту для «Об'єднати».
    @discardableResult
    func selectImportMode(_ mode: ImportMode) -> Task<Void, Never>? {
        guard case .chooseMode(let url)? = importStage else { return nil }
        switch mode {
        case .merge:
            importStage = nil
            return Task { @MainActor [weak self] in
                await self?.import(from: url, mode: .merge)
            }
        case .replace:
            importStage = .confirmReplace(url)
            return nil
        }
    }

    /// Підтверджено «Замінити» (поточний словник буде збережено в Backups). Повертає задачу імпорту.
    @discardableResult
    func confirmReplaceImport() -> Task<Void, Never>? {
        guard case .confirmReplace(let url)? = importStage else { return nil }
        importStage = nil
        return Task { @MainActor [weak self] in
            await self?.import(from: url, mode: .replace)
        }
    }

    func cancelImport() {
        importStage = nil
    }

    /// Імпорт з `url`. Успіх → `lastReport` і `transferMessage` зі звітом; помилка → `transferMessage` з
    /// україномовним текстом (словник не змінено). Імпортовані pending-записи передаються черзі.
    @discardableResult
    func `import`(from url: URL, mode: ImportMode) async -> ImportReport? {
        guard let transfer else {
            transferMessage = Self.unavailableTransferMessage
            return nil
        }
        guard !isTransferring else { return nil }
        isTransferring = true
        defer { isTransferring = false }
        do {
            let report = try await transfer.importDictionary(from: url, mode: mode)
            lastReport = report
            transferMessage = TransferMessage(
                title: "Імпорт завершено",
                text: Self.reportText(report),
                isError: false
            )
            apply(await repository.allEntries())
            if claude != nil, entries.contains(where: { $0.status == .pending }) {
                postImportProcessing = Task { @MainActor [weak self] in
                    await self?.processPending()
                }
            }
            return report
        } catch {
            let message = (error as? ImportError)?.userMessage
                ?? "Не вдалося імпортувати: \(error.localizedDescription). Словник не змінено."
            transferMessage = TransferMessage(title: "Не вдалося імпортувати", text: message, isError: true)
            return nil
        }
    }

    /// Текст звіту: «Додано X, оновлено Y, пропущено Z» і перші причини пропуску.
    static func reportText(_ report: ImportReport) -> String {
        guard !report.skippedReasons.isEmpty else { return report.summary }
        var lines = report.skippedReasons.prefix(maxReportedSkipReasons).map { "• \($0)" }
        let rest = report.skippedReasons.count - maxReportedSkipReasons
        if rest > 0 {
            lines.append("…та ще \(rest)")
        }
        return report.summary + "\n\nПропущено:\n" + lines.joined(separator: "\n")
    }

    private static let unavailableTransferMessage = TransferMessage(
        title: "Перенесення недоступне",
        text: "Експорт та імпорт недоступні",
        isError: true
    )

    private static func exportErrorMessage(_ error: Error) -> String {
        if case .writeFailed(let reason)? = error as? StorageError {
            return "Не вдалося записати файл: \(reason)"
        }
        return message(for: error)
    }

    /// Зберігає ключ лише в `SecretStore` (Keychain). Повертає `true` при успіху.
    @discardableResult
    func saveAPIKey(_ rawKey: String) -> Bool {
        guard let claude else { return false }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            settingsError = "Введіть API-ключ"
            return false
        }
        do {
            try claude.secrets.writeSecret(key, for: .anthropicAPIKey)
        } catch {
            settingsError = "Не вдалося зберегти ключ: \(Self.secretErrorMessage(error))"
            return false
        }
        claude.keyCache.set(key)
        hasAPIKey = true
        settingsError = nil
        claude.logger.info("API key saved")
        // Записи, що чекали на ключ, обробляються одразу.
        Task { @MainActor [weak self] in
            await self?.processPending()
        }
        return true
    }

    @discardableResult
    func deleteAPIKey() -> Bool {
        guard let claude else { return false }
        do {
            try claude.secrets.deleteSecret(for: .anthropicAPIKey)
        } catch {
            settingsError = "Не вдалося видалити ключ: \(Self.secretErrorMessage(error))"
            return false
        }
        // Кеш для редагування логів не очищаємо: ключі в ньому накопичуються, тож видалений ключ і далі
        // вирізається з логів до перезапуску.
        hasAPIKey = false
        settingsError = nil
        claude.logger.info("API key deleted")
        return true
    }

    /// Зберігає модель; порожній рядок → модель за замовчуванням.
    func setModel(_ name: String) {
        guard let claude else { return }
        claude.settings.model = name
        modelName = claude.settings.model
        Task { @MainActor [weak self] in
            await self?.processPending()
        }
    }

    func resetModelToDefault() {
        setModel("")
    }

    /// Читає наявність ключа (на старті) і оновлює кеш редагування логів.
    func refreshAPIKeyState() {
        guard let claude else { return }
        do {
            let key = try claude.secrets.readSecret(for: .anthropicAPIKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let key, !key.isEmpty {
                claude.keyCache.set(key)
                hasAPIKey = true
            } else {
                hasAPIKey = false
            }
        } catch {
            hasAPIKey = false
            settingsError = "Не вдалося прочитати ключ: \(Self.secretErrorMessage(error))"
        }
        modelName = claude.settings.model
    }

    static func errorMessage(for outcome: AddWordOutcome) -> String? {
        switch outcome {
        case .added, .queued:
            return nil
        case .duplicate(let entry):
            return RepositoryError.duplicate(entry).userMessage
        case .failed(let entry, let error):
            return "Не вдалося додати «\(entry.word)»: \(error.userMessage)"
        case .rejected(let rejection):
            switch rejection {
            case .empty:
                return "Введіть слово або фразу"
            case .tooLong(let max):
                return "Забагато тексту (макс. \(max) символів)"
            case .tooManyWords(let max):
                return "Забагато слів (макс. \(max))"
            case .noLetters:
                return "Текст не містить слів"
            }
        case .storageError(let message):
            return message
        }
    }

    private static func secretErrorMessage(_ error: Error) -> String {
        (error as? SecretStoreError)?.userMessage ?? "невідома помилка"
    }

    /// Таймер `processDue` кожні 60 с — лише поки є pending-записи.
    private func updatePendingTimer() {
        guard claude != nil else { return }
        let hasPending = entries.contains { $0.status == .pending }
        if hasPending, pendingTimer == nil {
            pendingTimer = Timer.scheduledTimer(withTimeInterval: Self.pendingTimerInterval, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                Task { @MainActor in
                    await self.processDue()
                }
            }
        } else if !hasPending, let timer = pendingTimer {
            timer.invalidate()
            pendingTimer = nil
        }
    }

    // MARK: - Private

    private func subscribeToChanges() {
        changesTask?.cancel()
        let repository = self.repository
        changesTask = Task { @MainActor [weak self] in
            let stream = await repository.changes()
            for await snapshot in stream {
                guard let self else { return }
                self.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: [Entry]) {
        entries = snapshot.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.word.localizedCaseInsensitiveCompare(rhs.word) == .orderedAscending
        }
        updatePendingTimer()
    }

    static func validationError(word: String, status: EntryStatus, translations: [String]) -> String? {
        if word.isEmpty {
            return "Введіть слово або фразу"
        }
        // `ready` без перекладів не пройде валідацію імпорту (§10), тому не дозволяємо створити такий запис.
        if status == .ready && translations.isEmpty {
            return "Додайте хоча б один переклад"
        }
        return nil
    }

    static func message(for error: Error) -> String {
        if let repositoryError = error as? RepositoryError {
            return repositoryError.userMessage
        }
        if let storageError = error as? StorageError {
            return storageError.userMessage
        }
        return error.localizedDescription
    }
}
