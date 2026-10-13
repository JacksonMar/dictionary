import Foundation
import XCTest
@testable import VocabCore

/// Нова пара визначається поза ядром — так, як це зробив би `ItalianUkrainian.swift` у застосунку (§3.1).
extension LanguagePair {
    static let italianUkrainianForTests = LanguagePair(
        id: "it-uk",
        sourceLanguageName: "Italian",
        targetLanguageName: "Ukrainian",
        speechLanguageCode: "it-IT",
        prompt: PromptTemplate(
            system: "You are an Italian–Ukrainian dictionary. Respond with JSON only.",
            userWord: "Parola: <text>{{TEXT}}</text>",
            userPhrase: "Frase: <text>{{TEXT}}</text>"
        )
    )
}

/// M1.6 — розширюваність мовних пар.
final class LanguagePairRegistryTests: XCTestCase {
    func testEnUkRegisteredByDefault() throws {
        XCTAssertEqual(LanguagePairRegistry.defaultPairID, "en-uk")
        let pair = try XCTUnwrap(LanguagePairRegistry.shared.pair(id: "en-uk"))
        XCTAssertEqual(pair, .englishUkrainian)
        XCTAssertEqual(pair.sourceLanguageName, "English")
        XCTAssertEqual(pair.targetLanguageName, "Ukrainian")
        XCTAssertEqual(pair.speechLanguageCode, "en-US")
        XCTAssertFalse(pair.prompt.system.isEmpty)
        XCTAssertTrue(pair.prompt.userWord.contains(PromptTemplate.textPlaceholder))
        XCTAssertTrue(pair.prompt.userPhrase.contains(PromptTemplate.textPlaceholder))
        XCTAssertTrue(LanguagePairRegistry.shared.all.contains(.englishUkrainian))
    }

    func testRegisterItUkWithoutCoreChanges() async throws {
        let registry = LanguagePairRegistry(pairs: [.englishUkrainian])
        XCTAssertNil(registry.pair(id: "it-uk"))

        registry.register(.italianUkrainianForTests)

        XCTAssertEqual(registry.pair(id: "it-uk"), .italianUkrainianForTests)
        XCTAssertEqual(registry.pair(id: "en-uk"), .englishUkrainian)
        XCTAssertEqual(registry.all.map(\.id), ["en-uk", "it-uk"])

        // Записи нової пари зберігаються й дедуплікуються ядром без змін.
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let dates = FixedDateProvider(TestDates.reference)
        let store = FileDictionaryStore(
            fileURL: directory.paths.dictionaryURL,
            dateProvider: dates,
            backups: BackupManager(directory: directory.paths.backupsDirectory, dateProvider: dates)
        )
        let repository = DictionaryRepository(store: store, dateProvider: dates)
        _ = try await repository.load()
        let italian = try await repository.add(TestFixtures.draft(word: "casa", languagePair: "it-uk"))
        _ = try await repository.add(TestFixtures.draft(word: "casa", languagePair: "en-uk"))

        let reloaded = DictionaryRepository(store: store, dateProvider: dates)
        let entries = try await reloaded.load().file.entries
        XCTAssertEqual(Set(entries.map(\.languagePair)), ["en-uk", "it-uk"])
        let duplicate = await reloaded.findDuplicate(of: "Casa", languagePair: "it-uk")
        XCTAssertEqual(duplicate?.id, italian.id)
    }

    func testReRegisterReplacesDefinition() {
        let registry = LanguagePairRegistry(pairs: [.englishUkrainian])
        let replacement = LanguagePair(
            id: "en-uk",
            sourceLanguageName: "English (UK)",
            targetLanguageName: "Ukrainian",
            speechLanguageCode: "en-GB",
            prompt: LanguagePair.englishUkrainian.prompt
        )

        registry.register(replacement)

        XCTAssertEqual(registry.all.count, 1)
        XCTAssertEqual(registry.pair(id: "en-uk")?.speechLanguageCode, "en-GB")
    }

    func testInitDeduplicatesById() {
        let registry = LanguagePairRegistry(pairs: [.englishUkrainian, .italianUkrainianForTests, .englishUkrainian])
        XCTAssertEqual(registry.all.map(\.id), ["en-uk", "it-uk"])
    }

    func testUnknownPairReturnsNil() {
        let registry = LanguagePairRegistry(pairs: [.englishUkrainian])
        XCTAssertNil(registry.pair(id: "it-uk"))
        XCTAssertNil(registry.pair(id: ""))
        XCTAssertNil(registry.pair(id: "EN-UK"))
        XCTAssertNil(LanguagePairRegistry.shared.pair(id: "xx-yy"))
    }

    func testConcurrentRegistration() {
        let registry = LanguagePairRegistry(pairs: [])
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            registry.register(LanguagePair(
                id: "p\(index)",
                sourceLanguageName: "S",
                targetLanguageName: "T",
                speechLanguageCode: "en-US",
                prompt: LanguagePair.englishUkrainian.prompt
            ))
            _ = registry.pair(id: "p\(index)")
        }
        XCTAssertEqual(registry.all.count, 50)
    }
}
