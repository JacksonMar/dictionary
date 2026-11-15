import Foundation
import VocabCore
#if canImport(Combine)
import Combine
#endif

/// Дія лідинг-свайпу рядка (IOS_PLAN §5): «Повторити» для `pending`/`failed`, «Оновити італійський» для ready-запису
/// в режимі мови варіанта.
enum EntryLeadingAction: Equatable {
    case retry
    case refreshVariant(languageID: String)
}

/// Міст між ядром і SwiftUI на iOS (IOS_PLAN DI5, §4): ті самі `DictionaryRepository`, `EntryQuery`,
/// `AddWordUseCase`, `PendingQueueProcessor` і `VariantBackfillProcessor`, що й на macOS; логіка — дзеркало
/// macOS `AppModel` без AppKit (панелі, автозапуск, тема, Services). Усі `@Published` змінюються лише на головному
/// акторі.
///
/// Економія токенів (§8): нове слово через Claude — 1 запит (`AddWordUseCase`), дубль — 0 (перевірка до запиту),
/// ручне додавання й редагування — 0; варіанти старих записів — лише в режимі мови варіанта (M7, D28) або явною дією
/// «Оновити італійський» (1 запит).
@MainActor
final class MobileAppModel: ObservableObject {
    /// Тригери черги, після яких у режимі мови варіанта запускається автодоповнення (M7, D28). На iOS старт
    /// застосунку — це перша активація сцени (`.foreground`).
    static let backfillTriggers: Set<ProcessingTrigger> = [.foreground, .keySaved]

    /// Усі записи словника (останній знімок репозиторію, без фільтра).
    @Published private(set) var entries: [Entry] = []
    /// Словник успішно завантажено.
    @Published private(set) var isLoaded = false
    /// Фатальна помилка завантаження (напр. новіша схема) — словник недоступний.
    @Published private(set) var loadError: String?
    /// Попередження після завантаження (зіпсований файл перенесено в Backups, D12).
    @Published var loadWarning: String?
    /// Текст `.searchable` (D19: пошук по слову, лемі, перекладах — `EntryQuery`).
    @Published var searchText: String = ""
    /// Порядок списку.
    @Published var sort: EntrySort = .dateNewest
    /// Активна мова відображення (`"it"`); `nil` = мова джерела пари («EN»). Зберігається в налаштуваннях.
    @Published private(set) var displayLanguageID: String?
    /// Помилка останньої операції користувача (додавання/редагування/видалення/повтор).
    @Published var operationError: String?
    /// У Keychain є API-ключ (саме значення в UI не показується).
    @Published private(set) var hasAPIKey = false
    /// Поточна модель Claude з налаштувань.
    @Published private(set) var modelName: String
    /// Помилка в Налаштуваннях (Keychain тощо).
    @Published var settingsError: String?
    /// Записи, для яких зараз виконується «Повторити» / «Оновити італійський».
    @Published private(set) var retryingIDs: Set<UUID> = []
    /// Іде «Повторити всі» (`.refreshable`).
    @Published private(set) var isRetryingAll = false
    /// M7: іде прохід доповнення варіантів.
    @Published private(set) var isBackfilling = false
    /// M7: підсумок останнього проходу доповнення.
    @Published private(set) var lastBackfillReport: VariantBackfillReport?
    /// Мова інтерфейсу (DI14): застосовується миттєво — корінь UI має `.id(interfaceLanguage)`.
    @Published private(set) var interfaceLanguage: AppLanguage
    /// Кількість резервних копій (Налаштування → Дані); оновлює `refreshStorageInfo()`.
    @Published private(set) var backupCount = 0

    let container: AppContainer
    /// Підписка на знімки репозиторію (для тестів — щоб перевірити, що вона одна).
    private(set) var changesTask: Task<Void, Never>?
    /// Останній запущений прохід доповнення (перемикання на мову варіанта) — для тестів, щоб дочекатися.
    private(set) var backfillTask: Task<Void, Never>?
    /// Остання обробка черги, запущена з Налаштувань (ключ збережено / модель змінено) — для тестів.
    private(set) var settingsProcessingTask: Task<Void, Never>?
    /// Single-flight `start()`.
    private var startTask: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
        // Збережений режим перевіряється для поточної пари; невідомий → мова джерела (як macOS M7).
        let settings = container.settings
        let pair = container.registry.pair(id: settings.languagePairID)
        self.displayLanguageID = Self.validatedLanguageID(settings.displayLanguageID, pair: pair)
        self.modelName = settings.model
        self.interfaceLanguage = settings.interfaceLanguage
    }

    // MARK: - Завантаження й активація

    /// Завантажує словник через single-flight `AppContainer.ensureLoaded()` і підписується на зміни репозиторію.
    /// Повторні виклики (повторний `.task`, повернення на передній план) нічого не дублюють. Single-flight: перший
    /// виклик кешує `Task`, решта чекають на нього, тож кожен викликач повертається лише тоді, коли `entries`, `isLoaded`
    /// і підписка вже встановлені (без «порожнього словника» на мить при одночасних `.task` і `becameActive()`).
    func start() async {
        if let existing = startTask {
            await existing.value
            return
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performStart()
        }
        startTask = task
        await task.value
    }

    private func performStart() async {
        refreshAPIKeyState()
        let outcome = await container.ensureLoaded()
        switch outcome {
        case .failed(let message):
            loadError = message
        case .loaded(let recoveredBackupURL):
            // `entries` — до `isLoaded`, щоб UI ніколи не бачив завантажений, але порожній словник.
            entries = await container.repository.allEntries()
            loadError = nil
            if let recoveredBackupURL {
                loadWarning = L10n.text(.modelLoadRecovered, ["path": recoveredBackupURL.path])
            }
            isLoaded = true
            subscribeToChanges()
        }
    }

    /// `scenePhase == .active` (IOS_PLAN §4): `ensureLoaded()` → `processAll(.foreground)` → автодоповнення, якщо
    /// режим мови варіанта. Повторні активації не дублюють запити: черга й доповнення самі відкидають паралельний
    /// прохід (`isRunning`), записи в обробці не беруться вдруге.
    func becameActive() async {
        await start()
        guard isLoaded else { return }
        await processPending(trigger: .foreground)
    }

    private func subscribeToChanges() {
        guard changesTask == nil else { return }
        let repository = container.repository
        changesTask = Task<Void, Never> { @MainActor [weak self] in
            let stream = await repository.changes()
            for await snapshot in stream {
                guard let self else { return }
                self.entries = snapshot
            }
        }
    }

    /// Свіжий знімок після операції (підписка теж оновить `entries`, але тести й UI бачать результат одразу).
    private func refreshEntries() async {
        entries = await container.repository.allEntries()
    }

    // MARK: - Пошук і сортування (`EntryQuery`)

    /// Поточний запит списку.
    var query: EntryQuery {
        EntryQuery(searchText: searchText, sort: sort, languageID: displayLanguageID)
    }

    /// Відфільтровані й відсортовані записи в активній мові відображення (DI16: весь результат, без сторінок).
    var visibleEntries: [EntryDisplay] {
        let languageID = displayLanguageID
        return query.apply(to: entries).map { entry in
            EntryDisplay.make(entry, languageID: languageID)
        }
    }

    /// Рядки списку (текст і бейджі вже обчислені мовою інтерфейсу).
    var visibleRows: [EntryRowContent] {
        let rendering = activeRendering
        return visibleEntries.map { display in
            EntryRowContent.make(display, rendering: rendering)
        }
    }

    /// Порожній стан: словник завантажено, записів немає.
    var isDictionaryEmpty: Bool {
        isLoaded && entries.isEmpty
    }

    /// Пошук нічого не знайшов (записи є) — оверлей «Нічого не знайдено» у списку.
    var hasNoSearchResults: Bool {
        isLoaded && !entries.isEmpty && !entries.contains { query.matches($0) }
    }

    /// Актуальний запис за id (екран деталей; `nil` — запис видалено).
    func entry(id: UUID) -> Entry? {
        entries.first { $0.id == id }
    }

    // MARK: - Мова відображення (EN | IT)

    /// Пара нових записів (з налаштувань).
    var currentPair: LanguagePair? {
        container.registry.pair(id: container.settings.languagePairID)
    }

    /// Id пари нових записів; невідома пара в налаштуваннях → пара за замовчуванням (як `AddWordUseCase`).
    var languagePairID: String {
        currentPair?.id ?? LanguagePairRegistry.defaultPairID
    }

    /// Мови відображення пари; порожньо → перемикач прихований.
    var renderings: [RenderingLanguage] {
        currentPair?.renderings ?? []
    }

    /// Підпис сегмента мови джерела («EN»).
    var sourceShortTitle: String {
        currentPair?.sourceShortTitle ?? LanguagePair.englishUkrainian.sourceShortTitle
    }

    /// Активна мова відображення (`nil` у режимі мови джерела).
    var activeRendering: RenderingLanguage? {
        guard let displayLanguageID else { return nil }
        return currentPair?.rendering(id: displayLanguageID)
    }

    /// Прив'язка сегментного `Picker` (tag `nil` = мова джерела).
    var displayLanguageSelection: String? {
        get { displayLanguageID }
        set { setDisplayLanguage(newValue) }
    }

    /// Перемикач EN | IT: невідома для пари мова → мова джерела; значення зберігається в налаштуваннях. Перехід у
    /// режим мови варіанта запускає автодоповнення (`.displaySwitch`; 0 придатних → 0 запитів, M7). Повертає задачу
    /// доповнення (для тестів), якщо її запущено.
    @discardableResult
    func setDisplayLanguage(_ id: String?) -> Task<Void, Never>? {
        let validated = Self.validatedLanguageID(id, pair: currentPair)
        container.settings.displayLanguageID = validated
        displayLanguageID = validated
        guard validated != nil, isLoaded else { return nil }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.runBackfill(trigger: .displaySwitch)
        }
        backfillTask = task
        return task
    }

    private static func validatedLanguageID(_ id: String?, pair: LanguagePair?) -> String? {
        guard let id, let pair, pair.rendering(id: id) != nil else { return nil }
        return id
    }

    // MARK: - Додавання, редагування, видалення

    /// «Додати через Claude» (D14): запис зберігається як `pending` ще до запиту, далі — 1 комбінований запит через
    /// чергу; дубль (будь-яке відображення, D26) — 0 запитів. Робота — у фоновій задачі (DI18). Для `.failed`,
    /// `.duplicate`, `.rejected`, `.storageError` встановлює `operationError`.
    @discardableResult
    func addViaClaude(_ rawText: String) async -> AddWordOutcome {
        let addWord = container.addWord
        let outcome = await container.backgroundTasks.run(named: "VocabAddWord") {
            await addWord.execute(rawText: rawText)
        }
        operationError = Self.errorMessage(for: outcome)
        await refreshEntries()
        return outcome
    }

    /// Ручне додавання (D14): статус із чернетки (`ready` у формі), перевірка дубля, 0 запитів.
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
            let entry = try await container.repository.add(cleaned)
            operationError = nil
            await refreshEntries()
            return entry
        } catch {
            operationError = Self.message(for: error)
            return nil
        }
    }

    /// Редагування основних полів. Варіанти (`variants`) і `sourceLanguage` зберігаються: `update(_:)` їх не
    /// перезаписує (§6). Повертає оновлений запис або `nil` (тоді `operationError` містить причину).
    @discardableResult
    func update(_ entry: Entry) async -> Entry? {
        var cleaned = entry
        cleaned.word = TextNormalizer.clean(entry.word)
        if let message = Self.validationError(word: cleaned.word, status: cleaned.status, translations: cleaned.translations) {
            operationError = message
            return nil
        }
        do {
            let updated = try await container.repository.update(cleaned)
            operationError = nil
            await refreshEntries()
            return updated
        } catch {
            operationError = Self.message(for: error)
            return nil
        }
    }

    /// Видалення (після підтвердження в UI). Повертає `true` при успіху.
    @discardableResult
    func delete(id: UUID) async -> Bool {
        do {
            try await container.repository.delete(id: id)
            operationError = nil
            await refreshEntries()
            return true
        } catch {
            operationError = Self.message(for: error)
            return false
        }
    }

    /// Повертає й очищає `operationError` (аркуші показують помилку в себе, а не алертом списку).
    func consumeOperationError() -> String? {
        let message = operationError
        operationError = nil
        return message
    }

    // MARK: - Повтор (черга)

    /// «Повторити» для `pending`/`failed`: рівно один виклик черги (ігнорує backoff, скидає лічильник спроб).
    /// Запис, для якого «Повторити» вже йде, — `nil` без другого запиту.
    @discardableResult
    func retry(id: UUID) async -> ProcessingResult? {
        guard !retryingIDs.contains(id) else { return nil }
        retryingIDs.insert(id)
        defer { retryingIDs.remove(id) }
        logQueueStarted(.manual, entryID: id)
        let queue = container.queue
        let result = await container.backgroundTasks.run(named: "VocabRetry") {
            await queue.retry(entryID: id)
        }
        logQueueFinished(.manual, entryID: id, results: [result])
        if case .duplicate(let existing, _) = result {
            // M7 (D27): запис виявився дублем іншого — «Вже є в словнику».
            operationError = RepositoryError.duplicate(existing).userMessage
        }
        await refreshEntries()
        return result
    }

    /// «Повторити всі» (`.refreshable`): усі pending-записи без очікування backoff, далі кожен `failed` (як кнопка
    /// «Повторити»: скидає лічильник спроб). Як macOS `AppModel.retryAll`.
    func retryAll() async {
        guard !isRetryingAll else { return }
        isRetryingAll = true
        defer { isRetryingAll = false }
        logQueueStarted(.retryAll)
        let token = container.backgroundTasks.beginTask(named: "VocabRetryAll")
        var results = await container.queue.processAll(ignoringBackoff: true)
        let failedIDs = await container.repository.allEntries().filter { $0.status == .failed }.map(\.id)
        for id in failedIDs where !retryingIDs.contains(id) {
            retryingIDs.insert(id)
            results.append(await container.queue.retry(entryID: id))
            retryingIDs.remove(id)
        }
        container.backgroundTasks.endTask(token)
        logQueueFinished(.retryAll, results: results)
        await refreshEntries()
    }

    /// Є записи, які можна повторити (`pending` або `failed`).
    var hasRetryableEntries: Bool {
        entries.contains { $0.status != .ready }
    }

    /// Обробка всіх pending-записів (`.foreground`, `.keySaved`, `.modelChanged`). Тригер пишеться в лог (M6).
    /// Після черги — автодоповнення, лише в режимі мови варіанта і для `backfillTriggers` (M7, D28).
    func processPending(trigger: ProcessingTrigger) async {
        logQueueStarted(trigger)
        let queue = container.queue
        let results = await container.backgroundTasks.run(named: "VocabProcessPending") {
            await queue.processAll(ignoringBackoff: true)
        }
        logQueueFinished(trigger, results: results)
        if !results.isEmpty {
            await refreshEntries()
        }
        if displayLanguageID != nil, Self.backfillTriggers.contains(trigger) {
            await runBackfill(trigger: trigger)
        }
    }

    // MARK: - Доповнення варіантів (M7)

    /// Дія лідинг-свайпу: «Повторити» (pending/failed) або «Оновити італійський» (ready, режим мови варіанта).
    func leadingAction(for row: EntryRowContent) -> EntryLeadingAction? {
        switch row.status {
        case .pending, .failed:
            return .retry
        case .ready:
            guard let rendering = activeRendering else { return nil }
            return .refreshVariant(languageID: rendering.id)
        }
    }

    /// Автодоповнення активної мови (без backoff). Нічого не робить у режимі мови джерела або під час проходу.
    func runBackfill(trigger: ProcessingTrigger) async {
        guard let languageID = displayLanguageID, !isBackfilling else { return }
        isBackfilling = true
        defer { isBackfilling = false }
        let backfill = container.variantBackfill
        let pairID = languagePairID
        let eligible = await backfill.eligibleEntryIDs(pairID: pairID, languageID: languageID, includeFailed: false).count
        container.logger.info(QueueLog.variantStarted(trigger, languageID: languageID, eligible: eligible))
        // 0 придатних → 0 запитів (ready-варіант не запитується ніколи, D28).
        let report: VariantBackfillReport
        if eligible == 0 {
            report = VariantBackfillReport()
        } else {
            report = await container.backgroundTasks.run(named: "VocabVariantBackfill") {
                await backfill.backfill(pairID: pairID, languageID: languageID, ignoringBackoff: true)
            }
        }
        await finishBackfill(trigger, languageID: languageID, report: report)
    }

    /// «Оновити італійський переклад»: рівно 1 запит для одного ready-запису (навіть з ready-варіантом).
    /// `languageID == nil` → активна мова, а в режимі мови джерела — перша мова відображення пари.
    @discardableResult
    func refreshVariant(id: UUID, languageID: String? = nil) async -> VariantBackfillReport? {
        guard let target = languageID ?? displayLanguageID ?? renderings.first?.id else { return nil }
        guard !retryingIDs.contains(id) else { return nil }
        retryingIDs.insert(id)
        defer { retryingIDs.remove(id) }
        container.logger.info(QueueLog.variantStarted(.variantRefresh, languageID: target, eligible: 1))
        let backfill = container.variantBackfill
        let report = await container.backgroundTasks.run(named: "VocabVariantRefresh") {
            await backfill.refresh(entryID: id, languageID: target)
        }
        await finishBackfill(.variantRefresh, languageID: target, report: report)
        if report.alreadyRunning {
            operationError = L10n.text(.modelBackfillRunning)
        } else if let error = report.stoppedBy {
            operationError = error.userMessage
        }
        return report
    }

    private func finishBackfill(_ trigger: ProcessingTrigger, languageID: String, report: VariantBackfillReport) async {
        container.logger.info(QueueLog.variantFinished(trigger, languageID: languageID, report: report))
        lastBackfillReport = report
        await refreshEntries()
    }

    /// Текст стану варіанта на екрані деталей, коли ready-варіанта немає (як macOS `VariantReadOnlySection`);
    /// `nil` — варіант ready (показуються його поля).
    static func variantStatusText(for entry: Entry, rendering: RenderingLanguage) -> String? {
        if entry.readyVariant(rendering.id) != nil {
            return nil
        }
        guard entry.status == .ready else {
            return L10n.text(.editorVariantWaitsForMain)
        }
        switch entry.variantState(rendering.id) {
        case .failed:
            let lastError = entry.variants?[rendering.id]?.lastError ?? ""
            return lastError.isEmpty
                ? L10n.text(.tableHelpVariantFailed)
                : L10n.text(.editorVariantFailedWithError, ["error": lastError])
        case .missing, .stale, .pending, .ready:
            return L10n.text(.editorVariantNotFilled)
        }
    }

    /// Короткий підпис свайпу «Оновити італійський» / «Update {language}».
    static func refreshVariantShortTitle(_ rendering: RenderingLanguage?, language: AppLanguage = L10n.current) -> String {
        guard let rendering, rendering.id != "it" else {
            return L10n.text(.mobileActionUpdateItalian, language: language)
        }
        return L10n.text(.mobileActionUpdateOther, ["language": rendering.shortTitle], language: language)
    }

    // MARK: - API-ключ і модель (Налаштування)

    /// Зберігає ключ лише в `SecretStore` (Keychain, DI8). Записи, що чекали на ключ, обробляються одразу.
    /// Повертає `true` при успіху.
    @discardableResult
    func saveAPIKey(_ rawKey: String) -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            settingsError = L10n.text(.settingsErrorEnterKey)
            return false
        }
        do {
            try container.secrets.writeSecret(key, for: .anthropicAPIKey)
        } catch {
            settingsError = L10n.text(.settingsErrorSaveKey, ["reason": Self.secretErrorMessage(error)])
            return false
        }
        container.keyCache.set(key)
        hasAPIKey = true
        settingsError = nil
        container.logger.info("API key saved")
        startSettingsProcessing(.keySaved)
        return true
    }

    @discardableResult
    func deleteAPIKey() -> Bool {
        do {
            try container.secrets.deleteSecret(for: .anthropicAPIKey)
        } catch {
            settingsError = L10n.text(.settingsErrorDeleteKey, ["reason": Self.secretErrorMessage(error)])
            return false
        }
        // Кеш редагування логів не очищаємо: видалений ключ і далі вирізається з логів до перезапуску.
        hasAPIKey = false
        settingsError = nil
        container.logger.info("API key deleted")
        return true
    }

    /// Читає наявність ключа і оновлює кеш редагування логів.
    func refreshAPIKeyState() {
        do {
            let key = try container.secrets.readSecret(for: .anthropicAPIKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let key, !key.isEmpty {
                container.keyCache.set(key)
                hasAPIKey = true
            } else {
                hasAPIKey = false
            }
        } catch {
            hasAPIKey = false
            settingsError = L10n.text(.settingsErrorReadKey, ["reason": Self.secretErrorMessage(error)])
        }
        modelName = container.settings.model
    }

    /// Зберігає модель; порожній рядок → модель за замовчуванням. Pending-записи обробляються з новою моделлю.
    func setModel(_ name: String) {
        container.settings.model = name
        modelName = container.settings.model
        startSettingsProcessing(.modelChanged)
    }

    func resetModelToDefault() {
        setModel("")
    }

    /// Модель за замовчуванням (підпис кнопки скидання).
    var defaultModelName: String {
        SettingsDefaults.model
    }

    private func startSettingsProcessing(_ trigger: ProcessingTrigger) {
        guard isLoaded else { return }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.processPending(trigger: trigger)
        }
        settingsProcessingTask = task
    }

    // MARK: - Мова інтерфейсу (DI14)

    /// Зберігає мову й застосовує її миттєво: `L10n.setCurrent` + нове значення `interfaceLanguage`, яке змінює
    /// `.id` кореня UI (усе дерево перебудовується з новими текстами).
    func setInterfaceLanguage(_ language: AppLanguage) {
        container.settings.interfaceLanguage = language
        L10n.setCurrent(language)
        interfaceLanguage = language
    }

    // MARK: - Дані

    /// Каталог даних (`dictionary.json` і `Backups/`).
    var dataDirectoryPath: String {
        container.dataDirectoryPath
    }

    /// Перечитує кількість резервних копій (при відкритті Налаштувань).
    func refreshStorageInfo() {
        backupCount = container.backupCount()
    }

    // MARK: - Озвучення

    var isSpeechAvailable: Bool {
        container.speech != nil
    }

    /// Озвучує `text` голосом мови `languageID` (ready-варіант) або мови джерела пари запису.
    func speak(_ text: String, entry: Entry, languageID: String? = nil) {
        guard let speech = container.speech else { return }
        speech.speak(text, languageCode: speechLanguageCode(for: entry.languagePair, languageID: languageID))
    }

    /// Код голосу: мова варіанта (`it-IT`), якщо вона є в пари, інакше мова джерела пари (`en-US`).
    func speechLanguageCode(for languagePair: String, languageID: String?) -> String {
        let pair = container.registry.pair(id: languagePair)
            ?? container.registry.pair(id: LanguagePairRegistry.defaultPairID)
            ?? .englishUkrainian
        guard let languageID, let rendering = pair.rendering(id: languageID) else {
            return pair.speechLanguageCode
        }
        return rendering.speechLanguageCode
    }

    // MARK: - Логи

    /// Лог черги: лише тригер, UUID і лічильники (`QueueLog`), без слів, помилок і ключа.
    private func logQueueStarted(_ trigger: ProcessingTrigger, entryID: UUID? = nil) {
        container.logger.info(QueueLog.started(trigger, entryID: entryID))
    }

    private func logQueueFinished(_ trigger: ProcessingTrigger, entryID: UUID? = nil, results: [ProcessingResult]) {
        container.logger.info(QueueLog.finished(trigger, entryID: entryID, results: results))
    }

    // MARK: - Тексти помилок (як macOS `AppModel`)

    static func validationError(word: String, status: EntryStatus, translations: [String]) -> String? {
        if word.isEmpty {
            return L10n.text(.inputEnterWord)
        }
        // `ready` без перекладів не пройде валідацію імпорту (§10), тому не дозволяємо створити такий запис.
        if status == .ready && translations.isEmpty {
            return L10n.text(.inputAddTranslation)
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

    static func errorMessage(for outcome: AddWordOutcome) -> String? {
        switch outcome {
        case .added, .queued:
            return nil
        case .duplicate(let entry):
            return RepositoryError.duplicate(entry).userMessage
        case .failed(let entry, let error):
            return L10n.text(.modelAddFailed, ["word": entry.word, "reason": error.userMessage])
        case .rejected(let rejection):
            switch rejection {
            case .empty:
                return L10n.text(.inputEnterWord)
            case .tooLong(let max):
                return L10n.text(.inputTooLong, ["max": String(max)])
            case .tooManyWords(let max):
                return L10n.text(.inputTooManyWords, ["max": String(max)])
            case .noLetters:
                return L10n.text(.inputNoLetters)
            }
        case .storageError(let message):
            return message
        }
    }

    private static func secretErrorMessage(_ error: Error) -> String {
        (error as? SecretStoreError)?.userMessage ?? L10n.text(.settingsErrorUnknown)
    }
}
