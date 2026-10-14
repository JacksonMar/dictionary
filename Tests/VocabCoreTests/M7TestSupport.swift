import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import VocabCore

// MARK: - Пара без renderings (міграція тестів M2–M6)

extension LanguagePair {
    /// Той самий `id` `"en-uk"`, імена, `speechLanguageCode` і `prompt`, що й `.englishUkrainian`, але
    /// `renderings: []` — поведінка M2 (промт без додатків, без детекції мови, без варіантів).
    /// Тести, яким італійська байдужа, використовують цю пару; нові тести M7 — `.englishUkrainian`.
    static let englishUkrainianSourceOnly = LanguagePair(
        id: LanguagePair.englishUkrainian.id,
        sourceLanguageName: LanguagePair.englishUkrainian.sourceLanguageName,
        targetLanguageName: LanguagePair.englishUkrainian.targetLanguageName,
        speechLanguageCode: LanguagePair.englishUkrainian.speechLanguageCode,
        prompt: LanguagePair.englishUkrainian.prompt,
        sourceLanguageCode: LanguagePair.englishUkrainian.sourceLanguageCode,
        sourceShortTitle: LanguagePair.englishUkrainian.sourceShortTitle,
        renderings: []
    )
}

// MARK: - Фікстури M7

enum M7 {
    static let pair = "en-uk"

    /// `TestDates.reference + seconds`.
    static func date(_ seconds: TimeInterval) -> Date {
        TestDates.reference.addingTimeInterval(seconds)
    }

    /// Об'єкт відповіді (верхній рівень, варіант або елемент пакета) у форматі моделі (snake_case).
    static func object(
        word: String,
        lemma: String? = nil,
        pos: String = "noun",
        ipa: String = "/ipa/",
        translations: [String] = ["переклад"],
        example: (String, String)? = ("Example sentence.", "Приклад речення.")
    ) -> [String: Any] {
        var object: [String: Any] = [
            "word": word,
            "lemma": lemma ?? word,
            "part_of_speech": pos,
            "transcription": ipa,
            "translations": translations,
        ]
        if let example {
            object["example"] = ["source": example.0, "translation": example.1]
        }
        return object
    }

    /// Італійський варіант-об'єкт за замовчуванням для англійського слова.
    static func italianObject(for word: String, translations: [String] = ["італійський переклад"]) -> [String: Any] {
        object(word: italianWord(for: word), pos: "noun", ipa: "/it/", translations: translations,
               example: ("Frase di esempio.", "Приклад речення."))
    }

    /// Детермінований «італійський» відповідник (для ехо-відповідей пакетів).
    static func italianWord(for english: String) -> String {
        switch english {
        case "run": return "correre"
        case "house": return "casa"
        case "dog": return "cane"
        default: return english + "ino"
        }
    }

    /// Комбінована відповідь (§7.7) як JSON-рядок.
    static func combinedJSON(
        sourceLanguage: String? = "en",
        top: [String: Any],
        variants: [String: Any]? = nil
    ) -> String {
        var object = top
        if let sourceLanguage {
            object["source_language"] = sourceLanguage
        }
        if let variants {
            object["variants"] = variants
        }
        return jsonString(object)
    }

    /// `house` / `casa` (англійське виділення).
    static let houseEnglishJSON = combinedJSON(
        sourceLanguage: "en",
        top: object(word: "house", pos: "noun", ipa: "/haʊs/", translations: ["будинок", "дім"],
                    example: ("This is my house.", "Це мій будинок.")),
        variants: ["it": object(word: "casa", pos: "noun", ipa: "/ˈkaːza/", translations: ["дім", "будинок", "оселя"],
                                example: ("La casa è grande.", "Будинок великий."))]
    )

    /// Виділення «casa» (італійське): верхній рівень — англійський `house`.
    static let casaItalianJSON = combinedJSON(
        sourceLanguage: "it",
        top: object(word: "house", pos: "noun", ipa: "/haʊs/", translations: ["будинок", "дім"],
                    example: ("This is my house.", "Це мій будинок.")),
        variants: ["it": object(word: "casa", pos: "noun", ipa: "/ˈkaːza/", translations: ["дім", "будинок", "оселя"],
                                example: ("La casa è grande.", "Будинок великий."))]
    )

    /// Пакетна відповідь: масив елементів.
    static func batchJSON(_ elements: [[String: Any]]) -> String {
        jsonArrayString(elements)
    }

    /// Елемент пакетної відповіді.
    static func batchElement(id: Any, word: String, pos: String = "noun", ipa: String = "/it/",
                             translations: [String] = ["переклад"]) -> [String: Any] {
        var element = object(word: word, pos: pos, ipa: ipa, translations: translations,
                             example: ("Frase di esempio.", "Приклад речення."))
        element["id"] = id
        return element
    }

    static func jsonString(_ object: [String: Any]) -> String {
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func jsonArrayString(_ array: [Any]) -> String {
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: array, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Записи

    /// Готовий англійський запис (як у M6, без варіантів).
    static func entry(
        id: UUID = UUID(),
        pair: String = M7.pair,
        word: String,
        translations: [String]? = nil,
        status: EntryStatus = .ready,
        created: TimeInterval = 0,
        updated: TimeInterval? = nil,
        variants: [String: EntryVariant]? = nil,
        sourceLanguage: String? = nil
    ) -> Entry {
        Entry(
            id: id,
            languagePair: pair,
            word: word,
            lemma: status == .ready ? word : nil,
            partOfSpeech: status == .ready ? "noun" : nil,
            transcription: status == .ready ? "/\(word)/" : nil,
            translations: translations ?? (status == .ready ? ["переклад-\(word)"] : []),
            example: status == .ready ? Example(source: "I see \(word).", translation: "Я бачу \(word).") : nil,
            status: status,
            lastError: nil,
            createdAt: date(created),
            updatedAt: date(updated ?? created),
            variants: variants,
            sourceLanguage: sourceLanguage
        )
    }

    /// Готовий італійський варіант для англійського `sourceWord`.
    static func readyVariant(
        _ word: String,
        sourceWord: String,
        translations: [String] = ["італ-переклад"]
    ) -> EntryVariant {
        EntryVariant(
            word: word,
            lemma: word,
            partOfSpeech: "noun",
            transcription: "/\(word)/",
            translations: translations,
            example: Example(source: "Vedo \(word).", translation: "Я бачу \(word)."),
            status: .ready,
            lastError: nil,
            sourceKey: TextNormalizer.key(sourceWord)
        )
    }

    static func unfilledVariant(_ status: EntryStatus = .pending, sourceWord: String, word: String? = nil) -> EntryVariant {
        var variant = EntryVariant.unfilled(status: status, sourceKey: TextNormalizer.key(sourceWord))
        variant.word = word
        return variant
    }

    // MARK: Запити

    /// Тіло записаного HTTP-запиту як JSON-об'єкт.
    static func body(_ request: MockURLProtocol.RecordedRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
    }

    /// Текст user-повідомлення записаного запиту.
    static func userText(_ request: MockURLProtocol.RecordedRequest) -> String {
        guard let messages = body(request)["messages"] as? [[String: Any]],
              let content = messages.first?["content"] as? String else {
            return ""
        }
        return content
    }

    static func systemText(_ request: MockURLProtocol.RecordedRequest) -> String {
        body(request)["system"] as? String ?? ""
    }

    /// Вміст між `<tag>` і `</tag>` у user-повідомленні.
    static func tagged(_ text: String, tag: String) -> String? {
        guard let start = text.range(of: "<\(tag)>"), let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// Елементи пакетного запиту (JSON-масив у `<items>…</items>`).
    static func items(_ request: MockURLProtocol.RecordedRequest) -> [[String: Any]] {
        guard let raw = tagged(userText(request), tag: "items"),
              let array = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]] else {
            return []
        }
        return array
    }

    /// Виділений текст комбінованого запиту (`<text>…</text>`).
    static func selection(_ request: MockURLProtocol.RecordedRequest) -> String? {
        tagged(userText(request), tag: "text")
    }

    /// Обробник `MockURLProtocol`, що на пакетний запит повертає валідний елемент для кожного `id`
    /// (`word` = `italianWord(for:)`; `keep` поважається).
    static func batchEchoReply(_ request: MockURLProtocol.RecordedRequest) -> MockURLProtocol.Reply {
        let elements = items(request).map { item -> [String: Any] in
            let english = item["word"] as? String ?? "x"
            let word = (item["keep"] as? String) ?? italianWord(for: english)
            return batchElement(id: item["id"] ?? 0, word: word)
        }
        return ClaudeFixtures.ok(batchJSON(elements))
    }
}

// MARK: - Стаб пакетного сервісу

/// `VariantBatchLookupService` зі сценарієм відповідей по викликах, лічильником викликів і записаними `items`.
/// Останній крок сценарію повторюється. Крок за замовчуванням — усі елементи `.ready`.
final class StubVariantBatchLookupService: VariantBatchLookupService, @unchecked Sendable {
    typealias Step = @Sendable ([VariantRequestItem]) throws -> [Int: VariantItemOutcome]

    private let lock = NSLock()
    private var script: [Step]
    private var recordedItems: [[VariantRequestItem]] = []
    private let gate: Gate?

    init(_ script: [Step] = [StubVariantBatchLookupService.allReady], gate: Gate? = nil) {
        self.script = script
        self.gate = gate
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return recordedItems.count
    }

    var calls: [[VariantRequestItem]] {
        lock.lock(); defer { lock.unlock() }
        return recordedItems
    }

    func setScript(_ newScript: [Step]) {
        lock.lock(); defer { lock.unlock() }
        script = newScript
    }

    func lookupVariants(
        items: [VariantRequestItem],
        language: RenderingLanguage,
        pair: LanguagePair
    ) async throws -> [Int: VariantItemOutcome] {
        let step = record(items)
        if let gate {
            await gate.wait()
        }
        return try step(items)
    }

    /// Записує виклик і бере наступний крок сценарію (синхронно, під замком).
    private func record(_ items: [VariantRequestItem]) -> Step {
        lock.lock(); defer { lock.unlock() }
        recordedItems.append(items)
        if script.count > 1 {
            return script.removeFirst()
        }
        if let last = script.first {
            return last
        }
        return Self.emptyScript
    }

    private static let emptyScript: Step = { _ in throw ClaudeError.transport("empty script") }

    /// Усі елементи — ready (`word` = `M7.italianWord(for:)` або `keepWord`).
    static let allReady: Step = { items in
        var result: [Int: VariantItemOutcome] = [:]
        for item in items {
            result[item.ref] = .ready(LookupResult(
                word: item.keepWord ?? M7.italianWord(for: item.word),
                lemma: item.keepWord ?? M7.italianWord(for: item.word),
                partOfSpeech: "noun",
                transcription: "/it/",
                translations: ["переклад"],
                example: Example(source: "Frase.", translation: "Речення.")
            ))
        }
        return result
    }

    static func failing(_ error: ClaudeError) -> Step {
        { _ in throw error }
    }
}

// MARK: - Повний стек M7

/// Файл у тимчасовому каталозі + репозиторій + `ClaudeLookupService` поверх `MockURLProtocol` (реальний HTTP-шар)
/// + `EntryProcessor`/`PendingQueueProcessor`/`AddWordUseCase` + `VariantBackfillProcessor`. Пара — `.englishUkrainian`.
struct M7Stack {
    let fixture: StoreFixture
    let repository: DictionaryRepository
    let lookup: LookupHarness
    let registry: LanguagePairRegistry
    let processor: EntryProcessor
    let queue: PendingQueueProcessor
    let addWord: AddWordUseCase
    let backfill: VariantBackfillProcessor

    var dates: FixedDateProvider { fixture.dateProvider }

    /// - Parameter seed: записи, що вже є у `dictionary.json` до завантаження.
    static func make(
        seed: [Entry] = [],
        registry: LanguagePairRegistry = LanguagePairRegistry(pairs: [.englishUkrainian]),
        batchSize: Int = VariantBackfillProcessor.defaultBatchSize
    ) async throws -> M7Stack {
        let fixture = try StoreFixture()
        return try await make(fixture: fixture, seed: seed, registry: registry, batchSize: batchSize)
    }

    /// Новий стек над тим самим каталогом (імітація перезапуску застосунку).
    static func make(
        fixture: StoreFixture,
        seed: [Entry] = [],
        registry: LanguagePairRegistry = LanguagePairRegistry(pairs: [.englishUkrainian]),
        batchSize: Int = VariantBackfillProcessor.defaultBatchSize
    ) async throws -> M7Stack {
        if !seed.isEmpty {
            try fixture.store.save(DictionaryFile(entries: seed))
        }
        let repository = DictionaryRepository(store: fixture.store, dateProvider: fixture.dateProvider)
        _ = try await repository.load()
        let lookup = LookupHarness()
        let processor = EntryProcessor(
            repository: repository,
            lookup: lookup.service,
            registry: registry,
            dateProvider: fixture.dateProvider
        )
        let queue = PendingQueueProcessor(
            repository: repository,
            processor: processor,
            policy: RetryPolicy(),
            dateProvider: fixture.dateProvider
        )
        let addWord = AddWordUseCase(
            repository: repository,
            processor: queue,
            settings: lookup.settings,
            registry: registry
        )
        let backfill = VariantBackfillProcessor(
            repository: repository,
            lookup: lookup.service,
            registry: registry,
            policy: RetryPolicy(),
            dateProvider: fixture.dateProvider,
            batchSize: batchSize
        )
        return M7Stack(
            fixture: fixture,
            repository: repository,
            lookup: lookup,
            registry: registry,
            processor: processor,
            queue: queue,
            addWord: addWord,
            backfill: backfill
        )
    }

    /// Записи, прочитані з диска новим сховищем (а не з пам'яті репозиторію).
    func entriesOnDisk() throws -> [Entry] {
        try fixture.store.load().file.entries
    }

    func entryOnDisk(_ id: UUID) throws -> Entry? {
        try entriesOnDisk().first { $0.id == id }
    }

    func remove() {
        fixture.directory.remove()
    }
}

/// Репозиторій + `VariantBackfillProcessor` зі стабом пакетного сервісу.
struct BackfillStubHarness {
    let fixture: StoreFixture
    let repository: DictionaryRepository
    let lookup: StubVariantBatchLookupService
    let backfill: VariantBackfillProcessor

    var dates: FixedDateProvider { fixture.dateProvider }

    static func make(
        seed: [Entry],
        lookup: StubVariantBatchLookupService = StubVariantBatchLookupService(),
        registry: LanguagePairRegistry = LanguagePairRegistry(pairs: [.englishUkrainian]),
        batchSize: Int = VariantBackfillProcessor.defaultBatchSize
    ) async throws -> BackfillStubHarness {
        let fixture = try StoreFixture()
        if !seed.isEmpty {
            try fixture.store.save(DictionaryFile(entries: seed))
        }
        let repository = DictionaryRepository(store: fixture.store, dateProvider: fixture.dateProvider)
        _ = try await repository.load()
        let backfill = VariantBackfillProcessor(
            repository: repository,
            lookup: lookup,
            registry: registry,
            policy: RetryPolicy(),
            dateProvider: fixture.dateProvider,
            batchSize: batchSize
        )
        return BackfillStubHarness(fixture: fixture, repository: repository, lookup: lookup, backfill: backfill)
    }

    func remove() {
        fixture.directory.remove()
    }
}

// MARK: - M6-формат (для байтового порівняння, D21)

/// Дзеркало `Entry` з M6 (синтезований `Codable`: опційні поля — `encodeIfPresent`). Кодування цим типом тим самим
/// енкодером = файл, який писав M6.
struct M6EntryMirror: Codable, Equatable {
    var id: UUID
    var languagePair: String
    var word: String
    var lemma: String?
    var partOfSpeech: String?
    var transcription: String?
    var translations: [String]
    var example: Example?
    var status: EntryStatus
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date

    init(_ entry: Entry) {
        id = entry.id
        languagePair = entry.languagePair
        word = entry.word
        lemma = entry.lemma
        partOfSpeech = entry.partOfSpeech
        transcription = entry.transcription
        translations = entry.translations
        example = entry.example
        status = entry.status
        lastError = entry.lastError
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
    }
}

struct M6FileMirror: Codable, Equatable {
    var schemaVersion: Int
    var exportedAt: Date?
    var entries: [M6EntryMirror]
}

extension M7 {
    /// Байти `dictionary.json`, які записав би M6 для цих записів.
    static func m6FileData(_ entries: [Entry], exportedAt: Date? = TestDates.reference) throws -> Data {
        try JSONCoding.makeEncoder().encode(
            M6FileMirror(schemaVersion: 1, exportedAt: exportedAt, entries: entries.map(M6EntryMirror.init))
        )
    }

    /// Набір записів M6 з усіма варіантами полів (опційні nil/не nil, pending/failed з lastError).
    /// Детерміновані `id`, тож повторні виклики дають рівні записи.
    static func m6Entries() -> [Entry] {
        func id(_ suffix: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", suffix)) ?? UUID()
        }
        var failed = entry(id: id(3), word: "zzyzx", status: .failed, created: 20)
        failed.lastError = "Невалідна відповідь Claude: x"
        var bare = entry(id: id(4), word: "give up", created: 30)
        bare.transcription = nil
        bare.example = nil
        return [
            entry(id: id(1), word: "run", translations: ["бігти", "керувати"], created: 0, updated: 5),
            entry(id: id(2), word: "pending one", status: .pending, created: 10),
            failed,
            bare,
        ]
    }
}

// MARK: - Асерти

extension ProcessingResult {
    var isDuplicate: Bool {
        if case .duplicate = self { return true }
        return false
    }
}
