import Foundation

/// Оновлення одного варіанта запису (`DictionaryRepository.setVariants`, M7).
public struct VariantUpdate: Equatable, Sendable {
    public var entryID: UUID
    public var languageID: String
    public var variant: EntryVariant

    public init(entryID: UUID, languageID: String, variant: EntryVariant) {
        self.entryID = entryID
        self.languageID = languageID
        self.variant = variant
    }
}

/// Єдине джерело істини для записів словника. Кожна мутація: змінити копію → `store.save` →
/// лише після успіху замінити стан і розіслати знімок підписникам.
public actor DictionaryRepository {
    private let store: DictionaryStoring
    private let dateProvider: DateProvider
    private var entries: [Entry] = []
    private var isLoaded = false
    private var continuations: [UUID: AsyncStream<[Entry]>.Continuation] = [:]

    public init(store: DictionaryStoring, dateProvider: DateProvider) {
        self.store = store
        self.dateProvider = dateProvider
    }

    /// Читає словник зі сховища (на старті). Помилки сховища (`StorageError`) передаються нагору.
    public func load() throws -> LoadResult {
        let result = try store.load()
        entries = result.file.entries
        isLoaded = true
        broadcast()
        return result
    }

    public func allEntries() -> [Entry] {
        entries
    }

    public func entry(id: UUID) -> Entry? {
        entries.first { $0.id == id }
    }

    /// Запис тієї ж мовної пари, серед ключів якого (`Entry.dedupKeys()`: англійський `key(word)` і ключі
    /// ready-варіантів, D26) є `key(word)`. Для додавання нового слова (`add`, `AddWordUseCase`, ручне додавання).
    public func findDuplicate(of word: String, languagePair: String, excluding: UUID? = nil) -> Entry? {
        findDuplicate(keys: [TextNormalizer.key(word)], languagePair: languagePair, excluding: excluding)
    }

    /// M7 (D27): запис тієї ж пари, `dedupKeys()` якого перетинаються з `keys` — перевірка після відповіді Claude.
    public func findDuplicate(keys: Set<String>, languagePair: String, excluding: UUID?) -> Entry? {
        guard !keys.isEmpty else { return nil }
        return entries.first { entry in
            entry.id != excluding
                && entry.languagePair == languagePair
                && !entry.dedupKeys().isDisjoint(with: keys)
        }
    }

    /// Додає запис. Перевірка дубля (за всіма відображеннями, D26) і вставка — в одному виклику актора.
    @discardableResult
    public func add(_ draft: EntryDraft) throws -> Entry {
        try ensureLoaded()
        if let existing = findDuplicate(of: draft.word, languagePair: draft.languagePair) {
            throw RepositoryError.duplicate(existing)
        }
        let now = dateProvider.now()
        let entry = Entry(
            id: UUID(),
            languagePair: draft.languagePair,
            word: draft.word,
            lemma: draft.lemma,
            partOfSpeech: draft.partOfSpeech,
            transcription: draft.transcription,
            translations: draft.translations,
            example: draft.example,
            status: draft.status,
            lastError: nil,
            createdAt: now,
            updatedAt: now
        )
        try commit(entries + [entry])
        return entry
    }

    /// Оновлює запис за `id`; `updatedAt` = зараз, `createdAt` зберігається з поточного стану.
    /// M7: збережені `variants` і `sourceLanguage` **зберігаються** (аргумент може бути застарілою копією
    /// редактора/`AppModel`), див. `update(_:replacingVariants:)`.
    @discardableResult
    public func update(_ entry: Entry) throws -> Entry {
        try update(entry, replacingVariants: false)
    }

    /// `replacingVariants: true` — `variants` і `sourceLanguage` беруться з аргументу (лише `EntryProcessor`).
    /// Дубль перевіряється **лише** за англійським `key(word)` проти англійських ключів інших записів пари і
    /// лише якщо ключ (або пара) змінився відносно збереженого запису (§6, M7). Варіанти дублів не перевіряються.
    @discardableResult
    public func update(_ entry: Entry, replacingVariants: Bool) throws -> Entry {
        try ensureLoaded()
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            throw RepositoryError.notFound(entry.id)
        }
        let stored = entries[index]
        let newKey = TextNormalizer.key(entry.word)
        if newKey != TextNormalizer.key(stored.word) || entry.languagePair != stored.languagePair {
            let duplicate = entries.first { other in
                other.id != entry.id
                    && other.languagePair == entry.languagePair
                    && TextNormalizer.key(other.word) == newKey
            }
            if let duplicate {
                throw RepositoryError.duplicate(duplicate)
            }
        }
        var updated = entry
        if !replacingVariants {
            updated.variants = stored.variants
            updated.sourceLanguage = stored.sourceLanguage
        }
        if updated.variants?.isEmpty == true {
            updated.variants = nil
        }
        updated.createdAt = stored.createdAt
        updated.updatedAt = dateProvider.now()
        var newEntries = entries
        newEntries[index] = updated
        try commit(newEntries)
        return updated
    }

    /// M7: записує варіанти пакетом — **один** атомарний save. `Entry.updatedAt` не змінюється (D24).
    /// Оновлення пропускається (не помилка), якщо запису вже нема або `variant.sourceKey` не збігається з
    /// `key(поточного word)` (запис відредаговано під час запиту); виняток — варіант мови `sourceLanguage`
    /// запису (слово користувача, ніколи не застаріває). Дублі ніколи не перевіряються.
    /// - Returns: фактично оновлені записи (у порядку першої появи); нічого не застосовано → без save.
    @discardableResult
    public func setVariants(_ updates: [VariantUpdate]) throws -> [Entry] {
        try ensureLoaded()
        var newEntries = entries
        var changedOrder: [UUID] = []
        for update in updates {
            guard let index = newEntries.firstIndex(where: { $0.id == update.entryID }) else {
                continue
            }
            var entry = newEntries[index]
            let isSourceLanguageVariant = entry.sourceLanguage == update.languageID
            guard isSourceLanguageVariant || update.variant.sourceKey == TextNormalizer.key(entry.word) else {
                continue
            }
            var variants = entry.variants ?? [:]
            variants[update.languageID] = update.variant
            entry.variants = variants
            newEntries[index] = entry
            if !changedOrder.contains(entry.id) {
                changedOrder.append(entry.id)
            }
        }
        guard !changedOrder.isEmpty else { return [] }
        try commit(newEntries)
        return changedOrder.compactMap { id in newEntries.first { $0.id == id } }
    }

    public func delete(id: UUID) throws {
        try ensureLoaded()
        guard entries.contains(where: { $0.id == id }) else {
            throw RepositoryError.notFound(id)
        }
        try commit(entries.filter { $0.id != id })
    }

    /// Повна заміна вмісту (імпорт). Один атомарний запис.
    public func replaceAll(_ newEntries: [Entry]) throws {
        try ensureLoaded()
        try commit(newEntries)
    }

    /// Знімок записів для експорту; до успішного `load()` → `RepositoryError.notLoaded`
    /// (щоб не експортувати порожній словник замість незавантаженого).
    public func loadedEntries() throws -> [Entry] {
        try ensureLoaded()
        return entries
    }

    /// Імпорт у режимі «Об'єднати» (§10, D1): `ImportMerger.merge` з поточним станом і **один** атомарний запис —
    /// в одному виклику актора, тож паралельні зміни (черга, Services) не губляться між читанням і записом.
    /// Якщо нічого не додано й не оновлено — запису на диск нема.
    public func mergeImported(_ imported: [Entry]) throws -> ImportReport {
        try ensureLoaded()
        let merged = ImportMerger.merge(local: entries, imported: imported)
        if merged.report.added > 0 || merged.report.updated > 0 {
            try commit(merged.entries)
        }
        return merged.report
    }

    /// Повна заміна вмісту з підготовчим кроком (імпорт «Замінити»): `beforeSave` (бекап поточного файлу)
    /// виконується в тому ж виклику актора безпосередньо перед записом. Помилка `beforeSave` передається
    /// нагору без змін, і нічого не записується.
    public func replaceAll(_ newEntries: [Entry], beforeSave: @Sendable () throws -> Void) throws {
        try ensureLoaded()
        try beforeSave()
        try commit(newEntries)
    }

    /// Потік знімків: одразу поточний стан, далі — після кожної успішної зміни.
    /// Буферизується лише найновіший знімок.
    public func changes() -> AsyncStream<[Entry]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(entries)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    // MARK: - Private

    private func ensureLoaded() throws {
        guard isLoaded else { throw RepositoryError.notLoaded }
    }

    private func commit(_ newEntries: [Entry]) throws {
        let file = DictionaryFile(
            schemaVersion: DictionaryFile.currentSchemaVersion,
            exportedAt: nil,
            entries: newEntries
        )
        do {
            try store.save(file)
        } catch let error as StorageError {
            throw RepositoryError.storage(error.userMessage)
        } catch {
            throw RepositoryError.storage(error.localizedDescription)
        }
        entries = newEntries
        broadcast()
    }

    private func broadcast() {
        for continuation in continuations.values {
            continuation.yield(entries)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations[id] = nil
    }
}
