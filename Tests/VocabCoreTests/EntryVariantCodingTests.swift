import Foundation
import XCTest
@testable import VocabCore

/// M7.1 — сумісність формату (D21, D22): старий файл читається, запис без варіантів пишеться байт-у-байт як у M6,
/// `schemaVersion` = 1; варіанти кодуються в camelCase; некоректний варіант відкидається без втрати запису.
final class EntryVariantCodingTests: XCTestCase {
    private func encode(_ entry: Entry) throws -> Data {
        try JSONCoding.makeEncoder().encode(entry)
    }

    private func decodeEntry(_ json: String) throws -> Entry {
        try JSONCoding.makeDecoder().decode(Entry.self, from: Data(json.utf8))
    }

    /// Сирий запис з довільним `variants` (JSON-фрагмент).
    private func rawEntryJSON(variants: String? = nil, sourceLanguage: String? = nil) -> String {
        var extra = ""
        if let variants {
            extra += ", \"variants\": \(variants)"
        }
        if let sourceLanguage {
            extra += ", \"sourceLanguage\": \(sourceLanguage)"
        }
        return """
        {"id": "\(TestFixtures.entryID)", "languagePair": "en-uk", "word": "run", "lemma": "run",
         "partOfSpeech": "verb", "transcription": "/rʌn/", "translations": ["бігти"],
         "example": {"source": "I run.", "translation": "Я біжу."}, "status": "ready",
         "createdAt": "2026-10-13T10:00:00Z", "updatedAt": "2026-10-13T11:00:00Z"\(extra)}
        """
    }

    private let validItalianVariant = """
    {"word": "correre", "lemma": "correre", "partOfSpeech": "verb", "transcription": "/korˈrere/",
     "translations": ["бігти"], "example": {"source": "Lei corre.", "translation": "Вона біжить."},
     "status": "ready", "sourceKey": "run"}
    """

    // MARK: - M6 compatibility

    func testM6FileDecodesWithoutVariants() throws {
        let file = try JSONCoding.makeDecoder().decode(DictionaryFile.self, from: Data(TestFixtures.requirementsExample.utf8))
        XCTAssertEqual(file.schemaVersion, 1)
        XCTAssertEqual(file.entries.count, 1)
        let entry = try XCTUnwrap(file.entries.first)
        XCTAssertEqual(entry.word, "run")
        XCTAssertEqual(entry.translations, ["бігти", "керувати"])
        XCTAssertNil(entry.variants)
        XCTAssertNil(entry.sourceLanguage)
        XCTAssertEqual(entry.variantState("it"), .missing)
        XCTAssertEqual(entry.dedupKeys(), ["run"])

        // Усі записи M6-набору (pending/failed, відсутні опційні поля) теж декодуються без варіантів.
        let decoded = try JSONCoding.makeDecoder().decode(DictionaryFile.self, from: M7.m6FileData(M7.m6Entries()))
        XCTAssertEqual(decoded.entries, M7.m6Entries())
        XCTAssertTrue(decoded.entries.allSatisfy { $0.variants == nil && $0.sourceLanguage == nil })
    }

    func testEntryWithoutVariantsEncodesIdenticallyToM6() throws {
        // Фікстура M6 — кодування дзеркалом M6-`Entry` (синтезований Codable) тим самим енкодером.
        for entry in M7.m6Entries() {
            let m6Bytes = try JSONCoding.makeEncoder().encode(M6EntryMirror(entry))
            XCTAssertEqual(try encode(entry), m6Bytes, "entry \(entry.word)")
        }
        let file = DictionaryFile(schemaVersion: 1, exportedAt: TestDates.reference, entries: M7.m6Entries())
        XCTAssertEqual(try JSONCoding.makeEncoder().encode(file), try M7.m6FileData(M7.m6Entries()))

        // Порожній словник варіантів — теж як M6.
        var empty = M7.m6Entries()[0]
        empty.variants = [:]
        XCTAssertEqual(try encode(empty), try JSONCoding.makeEncoder().encode(M6EntryMirror(empty)))
    }

    func testM6FileLoadsAndSavesByteIdentical() throws {
        // Старий файл M6 → завантаження → збереження без італійських даних → ті самі байти.
        let fixture = try StoreFixture()
        defer { fixture.directory.remove() }
        let m6Bytes = try M7.m6FileData(M7.m6Entries(), exportedAt: TestDates.reference)
        try FileManager.default.createDirectory(at: fixture.directory.url, withIntermediateDirectories: true)
        try m6Bytes.write(to: fixture.fileURL)

        let loaded = try fixture.store.load()
        XCTAssertNil(loaded.recoveredBackupURL)
        try fixture.store.save(loaded.file)

        XCTAssertEqual(try fixture.readRaw(), m6Bytes)
    }

    // MARK: - Variants coding

    func testVariantRoundTrip() throws {
        let entry = M7.entry(
            word: "house",
            variants: [
                "it": M7.readyVariant("casa", sourceWord: "house"),
                "de": EntryVariant.unfilled(status: .failed, sourceKey: "house", lastError: "помилка"),
            ],
            sourceLanguage: "it"
        )
        let data = try encode(entry)
        let decoded = try JSONCoding.makeDecoder().decode(Entry.self, from: data)
        XCTAssertEqual(decoded, entry)

        let file = DictionaryFile(entries: [entry])
        let decodedFile = try JSONCoding.makeDecoder().decode(DictionaryFile.self, from: JSONCoding.makeEncoder().encode(file))
        XCTAssertEqual(decodedFile.entries, [entry])
    }

    func testVariantKeysCamelCase() throws {
        var variant = M7.readyVariant("correre", sourceWord: "run")
        variant.lastError = "e"
        let entry = M7.entry(word: "run", variants: ["it": variant], sourceLanguage: "it")
        let object = try jsonObject(encode(entry))
        XCTAssertEqual(object["sourceLanguage"] as? String, "it")
        let variants = try XCTUnwrap(object["variants"] as? [String: Any])
        let italian = try XCTUnwrap(variants["it"] as? [String: Any])
        XCTAssertEqual(
            Set(italian.keys),
            ["word", "lemma", "partOfSpeech", "transcription", "translations", "example", "status", "lastError", "sourceKey"]
        )
        XCTAssertEqual(italian["sourceKey"] as? String, "run")
        XCTAssertEqual(italian["status"] as? String, "ready")
        XCTAssertNil(italian["part_of_speech"])
        XCTAssertNil(italian["updatedAt"], "variants have no own updatedAt (D24)")

        // Порожній pending-варіант: лише обов'язкові ключі (+ порожні translations).
        let pending = M7.entry(word: "run", variants: ["it": .unfilled(sourceKey: "run")])
        let pendingObject = try XCTUnwrap(
            (try jsonObject(encode(pending))["variants"] as? [String: Any])?["it"] as? [String: Any]
        )
        XCTAssertEqual(Set(pendingObject.keys), ["translations", "status", "sourceKey"])
    }

    func testEmptyVariantsNotEncoded() throws {
        var entry = M7.entry(word: "run")
        entry.variants = [:]
        XCTAssertNil(try jsonObject(encode(entry))["variants"])
        entry.variants = nil
        XCTAssertNil(try jsonObject(encode(entry))["variants"])
    }

    func testSourceLanguageOmittedForPrimary() throws {
        let entry = M7.entry(word: "run", variants: ["it": M7.readyVariant("correre", sourceWord: "run")])
        let object = try jsonObject(encode(entry))
        XCTAssertNil(object["sourceLanguage"])
        XCTAssertNotNil(object["variants"])
    }

    func testMalformedVariantDroppedEntryKept() throws {
        // `it` — некоректний (word не рядок), `de` — коректний: лишається лише `de`.
        let badItalian = """
        {"word": 42, "translations": ["бігти"], "status": "ready", "sourceKey": "run"}
        """
        let entry = try decodeEntry(rawEntryJSON(variants: "{\"it\": \(badItalian), \"de\": \(validItalianVariant)}"))
        XCTAssertEqual(entry.word, "run")
        XCTAssertEqual(entry.translations, ["бігти"])
        XCTAssertEqual(Array((entry.variants ?? [:]).keys), ["de"])

        // Відсутній sourceKey / варіант не-об'єкт → відкинуто; запис лишається.
        let noSourceKey = try decodeEntry(rawEntryJSON(variants: """
        {"it": {"word": "correre", "translations": ["бігти"], "status": "ready"}}
        """))
        XCTAssertNil(noSourceKey.variants)
        let notObject = try decodeEntry(rawEntryJSON(variants: "{\"it\": \"correre\"}"))
        XCTAssertNil(notObject.variants)

        // `variants` не об'єкт, `sourceLanguage` не рядок / порожній → ігноруються.
        let variantsArray = try decodeEntry(rawEntryJSON(variants: "[1, 2]", sourceLanguage: "7"))
        XCTAssertNil(variantsArray.variants)
        XCTAssertNil(variantsArray.sourceLanguage)
        XCTAssertNil(try decodeEntry(rawEntryJSON(sourceLanguage: "\"  \"")).sourceLanguage)
        XCTAssertEqual(try decodeEntry(rawEntryJSON(sourceLanguage: "\"it\"")).sourceLanguage, "it")

        // Відсутні translations у варіанті → [].
        let noTranslations = try decodeEntry(rawEntryJSON(variants: """
        {"it": {"status": "pending", "sourceKey": "run"}}
        """))
        XCTAssertEqual(noTranslations.variants?["it"]?.translations, [])
        XCTAssertEqual(noTranslations.variantState("it"), .pending)
    }

    func testUnknownVariantStatusDropped() throws {
        let entry = try decodeEntry(rawEntryJSON(variants: """
        {"it": {"word": "correre", "translations": ["бігти"], "status": "cached", "sourceKey": "run"}}
        """))
        XCTAssertNil(entry.variants)
        XCTAssertEqual(entry.status, .ready)
    }

    func testM6StrictFieldsStillRequired() {
        // Стійкість стосується лише варіантів: пошкоджене основне поле, як і в M6, — помилка декодування.
        let broken = rawEntryJSON().replacingOccurrences(of: "\"status\": \"ready\"", with: "\"status\": \"weird\"")
        XCTAssertThrowsError(try decodeEntry(broken))
    }

    func testSchemaVersionStaysOne() throws {
        XCTAssertEqual(DictionaryFile.currentSchemaVersion, 1)
        let fixture = try StoreFixture()
        defer { fixture.directory.remove() }
        let entry = M7.entry(word: "run", variants: ["it": M7.readyVariant("correre", sourceWord: "run")])
        try fixture.store.save(DictionaryFile(entries: [entry]))
        let object = try jsonObject(fixture.readRaw())
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(try fixture.store.load().file.entries, [entry])
    }

    func testStoreLoadWithMalformedVariantIsNotCorrupted() throws {
        let fixture = try StoreFixture()
        defer { fixture.directory.remove() }
        let badVariant = """
        {"word": "correre", "translations": "not array", "status": "ready", "sourceKey": "run"}
        """
        try fixture.writeRaw("""
        {"schemaVersion": 1, "entries": [\(rawEntryJSON(variants: "{\"it\": \(badVariant)}"))]}
        """)

        let result = try fixture.store.load()
        XCTAssertNil(result.recoveredBackupURL, "file must not be treated as corrupted")
        XCTAssertEqual(result.file.entries.count, 1)
        XCTAssertEqual(result.file.entries.first?.word, "run")
        XCTAssertNil(result.file.entries.first?.variants)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path), "file not moved to Backups")
        let backups = fixture.directory.paths.backupsDirectory
        if FileManager.default.fileExists(atPath: backups.path) {
            XCTAssertEqual(try fixture.directory.fileNames(in: backups), [], "no backup created")
        }
    }

    // MARK: - variantState / dedupKeys / readyVariant

    func testVariantStates() {
        let ready = M7.entry(word: "run", variants: ["it": M7.readyVariant("correre", sourceWord: "run")])
        XCTAssertEqual(ready.variantState("it"), .ready)
        XCTAssertEqual(ready.readyVariant("it")?.word, "correre")
        XCTAssertEqual(ready.variantState("de"), .missing)

        let stale = M7.entry(word: "sprint", variants: ["it": M7.readyVariant("correre", sourceWord: "run")])
        XCTAssertEqual(stale.variantState("it"), .stale)
        XCTAssertNil(stale.readyVariant("it"))

        // Варіант мови виділення ніколи не stale.
        let selected = M7.entry(word: "sprint", variants: ["it": M7.readyVariant("casa", sourceWord: "house")],
                                sourceLanguage: "it")
        XCTAssertEqual(selected.variantState("it"), .ready)

        XCTAssertEqual(M7.entry(word: "run", variants: ["it": M7.unfilledVariant(.pending, sourceWord: "run")])
            .variantState("it"), .pending)
        XCTAssertEqual(M7.entry(word: "run", variants: ["it": M7.unfilledVariant(.failed, sourceWord: "run")])
            .variantState("it"), .failed)

        // Ready без слова — фактично відсутній.
        var noWord = M7.readyVariant("x", sourceWord: "run")
        noWord.word = "  "
        XCTAssertEqual(M7.entry(word: "run", variants: ["it": noWord]).variantState("it"), .missing)
    }

    func testDedupKeysIncludeOnlyReadyNonStaleVariants() {
        let entry = M7.entry(word: "House", variants: ["it": M7.readyVariant("Casa", sourceWord: "house")])
        XCTAssertEqual(entry.dedupKeys(), ["house", "casa"])
        let pending = M7.entry(word: "house", variants: ["it": M7.unfilledVariant(sourceWord: "house", word: "casa")])
        XCTAssertEqual(pending.dedupKeys(), ["house"])
        let stale = M7.entry(word: "home", variants: ["it": M7.readyVariant("casa", sourceWord: "house")])
        XCTAssertEqual(stale.dedupKeys(), ["home"])
    }
}
