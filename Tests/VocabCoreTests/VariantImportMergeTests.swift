import Foundation
import XCTest
@testable import VocabCore

/// M7.8 — варіанти при імпорті й merge (§10 M7, D30): невалідні варіанти відкидаються без втрати запису,
/// merge за англійським ключем, `VariantMerge.combine` вирішує варіанти.
final class VariantImportMergeTests: XCTestCase {
    private var fixtures: [TransferFixture] = []

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
        super.tearDown()
    }

    private func makeFixture() throws -> TransferFixture {
        let fixture = try TransferFixture()
        fixtures.append(fixture)
        return fixture
    }

    private func importData(_ entries: [Any]) throws -> Data {
        try M4.rawFileData(entries)
    }

    // MARK: - Importer

    func testImporterDropsInvalidVariantKeepsEntry() throws {
        var raw = try M4.rawEntry(M7.entry(word: "run"))
        raw["variants"] = [
            "it": ["word": "correre", "translations": ["бігти"], "status": "bogus", "sourceKey": "run"],
            "de": ["word": "rennen", "translations": ["бігти"], "status": "ready"],
        ]
        let parsed = try DictionaryImporter.parse(importData([raw]))
        XCTAssertEqual(parsed.entries.count, 1)
        XCTAssertEqual(parsed.skippedReasons, [], "dropped variants are not reported")
        XCTAssertEqual(parsed.entries.first?.word, "run")
        XCTAssertNil(parsed.entries.first?.variants)
    }

    func testImporterDropsReadyVariantWithoutTranslations() throws {
        var raw = try M4.rawEntry(M7.entry(word: "run"))
        raw["variants"] = [
            "it": ["word": "correre", "translations": ["  ", ""], "status": "ready", "sourceKey": "run"],
            "es": ["word": "  ", "translations": ["бігти"], "status": "ready", "sourceKey": "run"],
            "fr": ["word": "  courir! ", "translations": ["  бігти   швидко "], "status": "ready", "sourceKey": "run"],
            "pt": ["translations": [], "status": "pending", "sourceKey": "run"],
        ]
        let parsed = try DictionaryImporter.parse(importData([raw]))
        let variants = try XCTUnwrap(parsed.entries.first?.variants)
        XCTAssertEqual(Set(variants.keys), ["fr", "pt"])
        XCTAssertEqual(variants["fr"]?.word, "courir")
        XCTAssertEqual(variants["fr"]?.translations, ["бігти швидко"])
        XCTAssertEqual(variants["pt"]?.status, .pending)
    }

    func testImporterParseDefaultRegistry() throws {
        let entry = M7.entry(word: "house", variants: ["it": M7.readyVariant("casa", sourceWord: "house")],
                             sourceLanguage: "it")
        let data = try M4.fileData([entry])
        let viaDefault = try DictionaryImporter.parse(data)
        XCTAssertEqual(viaDefault, try DictionaryImporter.parse(data, registry: .shared))
        XCTAssertEqual(viaDefault.entries, [entry])
        XCTAssertEqual(viaDefault.entries.first?.sourceLanguage, "it")

        // Реєстр з парою без італійської — sourceLanguage недопустимий → nil (варіант лишається).
        let sourceOnly = try DictionaryImporter.parse(data, registry: LanguagePairRegistry(pairs: [.englishUkrainianSourceOnly]))
        XCTAssertNil(sourceOnly.entries.first?.sourceLanguage)
        XCTAssertEqual(sourceOnly.entries.first?.variants?["it"]?.word, "casa")
    }

    func testImporterUnknownSourceLanguageCleared() throws {
        let french = M7.entry(word: "house", sourceLanguage: "fr")
        let english = M7.entry(word: "dog", created: 10, sourceLanguage: "en")
        let foreignPair = M7.entry(pair: "xx-yy", word: "cat", created: 20, sourceLanguage: "zz")
        let parsed = try DictionaryImporter.parse(M4.fileData([french, english, foreignPair]))
        XCTAssertEqual(parsed.entries.count, 3)
        XCTAssertNil(parsed.entries[0].sourceLanguage)
        XCTAssertNil(parsed.entries[1].sourceLanguage, "pair source language is stored as nil")
        XCTAssertEqual(parsed.entries[2].sourceLanguage, "zz", "unknown pair: kept as is")
    }

    // MARK: - VariantMerge / ImportMerger

    func testMergeAdoptsImportedVariantCountsUpdated() {
        let local = M7.entry(word: "run", updated: 100)
        var imported = local
        imported.updatedAt = M7.date(50)   // старіший — основні поля лишаються локальними
        imported.translations = ["інше"]
        imported.variants = ["it": M7.readyVariant("correre", sourceWord: "run")]

        let merged = ImportMerger.merge(local: [local], imported: [imported])

        XCTAssertEqual(merged.report.updated, 1)
        XCTAssertEqual(merged.report.added, 0)
        XCTAssertEqual(merged.report.skipped, 0)
        XCTAssertEqual(merged.entries.count, 1)
        let result = merged.entries[0]
        XCTAssertEqual(result.translations, local.translations, "main fields stay local")
        XCTAssertEqual(result.updatedAt, local.updatedAt)
        XCTAssertEqual(result.variants?["it"]?.word, "correre")

        // Та сама версія без нових варіантів — skipped, не updated.
        let again = ImportMerger.merge(local: merged.entries, imported: [imported])
        XCTAssertEqual(again.report.updated, 0)
        XCTAssertEqual(again.report.skipped, 1)
    }

    func testMergeKeepsLocalReadyOverImportedPending() {
        let local = M7.entry(word: "run", updated: 0, variants: ["it": M7.readyVariant("correre", sourceWord: "run")])
        var imported = local
        imported.updatedAt = M7.date(100)   // новіший — переможець D1
        imported.translations = ["мчати"]
        imported.variants = ["it": M7.unfilledVariant(.pending, sourceWord: "run")]

        let merged = ImportMerger.merge(local: [local], imported: [imported])

        XCTAssertEqual(merged.report.updated, 1)
        let result = merged.entries[0]
        XCTAssertEqual(result.translations, ["мчати"])
        XCTAssertEqual(result.variants?["it"]?.status, .ready)
        XCTAssertEqual(result.variants?["it"]?.word, "correre")
        XCTAssertEqual(result.id, local.id)
    }

    func testMergeBothReadyKeepsD1WinnerVariant() {
        let local = M7.entry(word: "run", updated: 0, variants: ["it": M7.readyVariant("correre", sourceWord: "run")])
        var newer = local
        newer.updatedAt = M7.date(100)
        newer.variants = ["it": M7.readyVariant("scappare", sourceWord: "run")]

        let importedWins = ImportMerger.merge(local: [local], imported: [newer])
        XCTAssertEqual(importedWins.entries[0].variants?["it"]?.word, "scappare")

        var older = local
        older.updatedAt = M7.date(-100)
        older.variants = ["it": M7.readyVariant("scappare", sourceWord: "run")]
        let localWins = ImportMerger.merge(local: [local], imported: [older])
        XCTAssertEqual(localWins.entries[0].variants?["it"]?.word, "correre")
        XCTAssertEqual(localWins.report.updated, 0)
        XCTAssertEqual(localWins.report.skipped, 1)

        // VariantMerge напряму: обидва не-ready → варіант переможця; лише в other → other.
        let winner = M7.entry(word: "run", variants: ["it": M7.unfilledVariant(.failed, sourceWord: "run")])
        let other = M7.entry(word: "run", variants: [
            "it": M7.unfilledVariant(.pending, sourceWord: "run"),
            "de": M7.readyVariant("rennen", sourceWord: "run"),
        ])
        let combined = VariantMerge.combine(winner: winner, other: other)
        XCTAssertEqual(combined?["it"]?.status, .failed)
        XCTAssertEqual(combined?["de"]?.word, "rennen")
        XCTAssertNil(VariantMerge.combine(winner: M7.entry(word: "run"), other: M7.entry(word: "run")))
    }

    func testMergeSelectedLanguageVariantStaysFromWinner() {
        // Варіант мови виділення переможця (слово користувача) не замінюється навіть ready-варіантом other.
        let winner = M7.entry(word: "house", variants: ["it": M7.readyVariant("casa", sourceWord: "home")],
                              sourceLanguage: "it")
        let other = M7.entry(word: "house", variants: ["it": M7.readyVariant("abitazione", sourceWord: "house")])
        XCTAssertEqual(VariantMerge.combine(winner: winner, other: other)?["it"]?.word, "casa")
    }

    func testMergeDropsVariantsWithForeignSourceKey() {
        let local = M7.entry(word: "run", updated: 100)
        var imported = local
        imported.updatedAt = M7.date(0)
        imported.variants = ["it": M7.readyVariant("camminare", sourceWord: "walk")]

        let merged = ImportMerger.merge(local: [local], imported: [imported])

        XCTAssertEqual(merged.report.updated, 0)
        XCTAssertNil(merged.entries[0].variants)

        // Переможець з чужим варіантом: його власний stale варіант теж не переноситься.
        var newer = local
        newer.updatedAt = M7.date(200)
        newer.variants = ["it": M7.readyVariant("camminare", sourceWord: "walk")]
        let replaced = ImportMerger.merge(local: [local], imported: [newer])
        XCTAssertNil(replaced.entries[0].variants)
    }

    func testCollapseDuplicatesInFileCombinesVariants() {
        // Два записи одного слова у файлі імпорту: переможець (новіший) без варіанта, старіший — з ready.
        let older = M7.entry(word: "run", updated: 0, variants: ["it": M7.readyVariant("correre", sourceWord: "run")])
        let newer = M7.entry(word: "Run", updated: 100)
        let merged = ImportMerger.merge(local: [], imported: [older, newer])
        XCTAssertEqual(merged.entries.count, 1)
        XCTAssertEqual(merged.entries[0].updatedAt, newer.updatedAt)
        XCTAssertEqual(merged.entries[0].variants?["it"]?.word, "correre")
    }

    // MARK: - Round trips

    func testExportImportRoundTripWithVariants() async throws {
        let source = try makeFixture()
        let entries = [
            M7.entry(word: "run", created: 0, variants: ["it": M7.readyVariant("correre", sourceWord: "run")]),
            M7.entry(word: "house", created: 10, variants: ["it": M7.readyVariant("casa", sourceWord: "house")],
                     sourceLanguage: "it"),
            M7.entry(word: "dog", created: 20, variants: ["it": M7.unfilledVariant(.failed, sourceWord: "dog")]),
            M7.entry(word: "plain", created: 30),
        ]
        try await source.seed(entries)
        let exportURL = source.transferDirectory.appendingPathComponent("export.json")
        try FileManager.default.createDirectory(at: source.transferDirectory, withIntermediateDirectories: true)
        let count = try await source.service.exportDictionary(to: exportURL)
        XCTAssertEqual(count, 4)
        let exported = try jsonObject(Data(contentsOf: exportURL))
        XCTAssertEqual(exported["schemaVersion"] as? Int, 1)

        // Інший «профіль»: порожній словник, імпорт «Замінити» і «Об'єднати».
        let target = try makeFixture()
        try await target.seed([])
        let importURL = try target.writeImportFile(Data(contentsOf: exportURL))
        let report = try await target.service.importDictionary(from: importURL, mode: .merge)
        XCTAssertEqual(report.added, 4)
        let imported = try await target.repository.loadedEntries()
        XCTAssertEqual(imported.sorted { $0.createdAt < $1.createdAt }, entries)

        let replaceTarget = try makeFixture()
        try await replaceTarget.seed([M7.entry(word: "old")])
        let replaceURL = try replaceTarget.writeImportFile(Data(contentsOf: exportURL))
        _ = try await replaceTarget.service.importDictionary(from: replaceURL, mode: .replace)
        let replaced = try await replaceTarget.repository.loadedEntries()
        XCTAssertEqual(replaced.sorted { $0.createdAt < $1.createdAt }, entries)
    }

    func testM6ExportImportsUnchanged() async throws {
        let m6Entries = M7.m6Entries()
        let data = try M7.m6FileData(m6Entries)
        let parsed = try DictionaryImporter.parse(data)
        XCTAssertEqual(parsed.entries, m6Entries)
        XCTAssertEqual(parsed.skippedReasons, [])

        let fixture = try makeFixture()
        try await fixture.seed([])
        let url = try fixture.writeImportFile(data)
        let report = try await fixture.service.importDictionary(from: url, mode: .merge)
        XCTAssertEqual(report.added, m6Entries.count)
        let stored = try await fixture.repository.loadedEntries()
        XCTAssertTrue(stored.allSatisfy { $0.variants == nil && $0.sourceLanguage == nil })
        // Файл словника після імпорту M6-даних — без M7-ключів.
        let text = String(decoding: try fixture.dictionaryBytes(), as: UTF8.self)
        XCTAssertFalse(text.contains("variants"))
        XCTAssertFalse(text.contains("sourceLanguage"))
    }
}
