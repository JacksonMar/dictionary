import Foundation
import VocabCore

/// Потокобезпечний кеш поточного API-ключа — джерело `secretsProvider` для `RedactingLogger`
/// (щоб не читати Keychain на кожен рядок логу).
final class APIKeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init() {}

    func set(_ newValue: String?) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    /// Поточні секрети для редагування логів.
    func secrets() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return value.map { [$0] } ?? []
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
            dateProvider: dateProvider
        )
        let queue = PendingQueueProcessor(
            repository: repository,
            processor: processor,
            policy: policy,
            dateProvider: dateProvider
        )
        let addWord = AddWordUseCase(repository: repository, processor: queue, settings: settings, registry: registry)
        return ClaudeServices(
            secrets: secrets,
            settings: settings,
            keyCache: keyCache,
            logger: logger,
            queue: queue,
            addWord: addWord
        )
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

    let languagePairID: String
    private let repository: DictionaryRepository
    private let claude: ClaudeServices?
    private var changesTask: Task<Void, Never>?
    private var pendingTimer: Timer?

    /// `claude == nil` — без Claude (M1-режим): «Заповнити через Claude» і черга недоступні.
    init(
        repository: DictionaryRepository,
        languagePairID: String = LanguagePairRegistry.defaultPairID,
        claude: ClaudeServices? = nil
    ) {
        self.repository = repository
        self.languagePairID = languagePairID
        self.claude = claude
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

    /// «Повторити всі»: усі pending-записи без очікування backoff.
    func retryAll() async {
        await processPending()
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
        // Кеш для редагування логів не очищаємо: старий ключ і далі вирізається з логів до перезапуску.
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
