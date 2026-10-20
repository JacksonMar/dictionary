import Foundation
import XCTest
@testable import VocabCore

/// M1.5 — репозиторій: додавання/редагування/видалення, дублікати в межах пари, потік змін.
final class DictionaryRepositoryTests: XCTestCase {
    private var fixture: StoreFixture!
    private var repository: DictionaryRepository!

    override func setUp() async throws {
        try await super.setUp()
        pinInterfaceLanguage(.uk)
        fixture = try StoreFixture()
        repository = DictionaryRepository(store: fixture.store, dateProvider: fixture.dateProvider)
        _ = try await repository.load()
    }

    override func tearDown() async throws {
        fixture?.directory.remove()
        fixture = nil
        repository = nil
        try await super.tearDown()
    }

    private func reloadedEntries() throws -> [Entry] {
        try fixture.store.load().file.entries
    }

    func testAddPersists() async throws {
        let draft = TestFixtures.draft(word: "run")

        let entry = try await repository.add(draft)

        XCTAssertEqual(entry.word, "run")
        XCTAssertEqual(entry.languagePair, "en-uk")
        XCTAssertEqual(entry.translations, draft.translations)
        XCTAssertEqual(entry.example, draft.example)
        XCTAssertEqual(entry.status, .ready)
        XCTAssertNil(entry.lastError)
        XCTAssertEqual(entry.createdAt, TestDates.reference)
        XCTAssertEqual(entry.updatedAt, TestDates.reference)
        let all = await repository.allEntries()
        XCTAssertEqual(all, [entry])
        let byID = await repository.entry(id: entry.id)
        XCTAssertEqual(byID, entry)
        XCTAssertEqual(try reloadedEntries(), [entry], "entry must be on disk")
    }

    func testDuplicateSamePairRejected() async throws {
        let original = try await repository.add(TestFixtures.draft(word: "run"))

        for variant in ["Run ", "RUN", "  run.", "\nrun\t"] {
            do {
                _ = try await repository.add(TestFixtures.draft(word: variant))
                XCTFail("\"\(variant)\" must be rejected as duplicate")
            } catch {
                XCTAssertEqual(error as? RepositoryError, .duplicate(original))
            }
        }
        let count = await repository.allEntries().count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try reloadedEntries().count, 1)
    }

    func testDuplicatePhraseAndApostropheVariantsRejected() async throws {
        _ = try await repository.add(TestFixtures.draft(word: "don't give up"))

        do {
            _ = try await repository.add(TestFixtures.draft(word: "Don\u{2019}t  give\nUP"))
            XCTFail("phrase variant must be rejected")
        } catch {
            guard case RepositoryError.duplicate = error else {
                return XCTFail("expected duplicate, got \(error)")
            }
        }
    }

    func testDuplicateErrorMessage() async throws {
        let original = try await repository.add(TestFixtures.draft(word: "run"))
        XCTAssertEqual(RepositoryError.duplicate(original).userMessage, "«run» вже є в словнику")
    }

    func testLemmaIsNotDedupKey() async throws {
        _ = try await repository.add(TestFixtures.draft(word: "run"))
        // D8: `runs` ≠ `run`, навіть якщо лема однакова.
        var draft = TestFixtures.draft(word: "runs")
        draft.lemma = "run"
        let runs = try await repository.add(draft)
        XCTAssertEqual(runs.word, "runs")
    }

    func testSameWordOtherPairAllowed() async throws {
        let english = try await repository.add(TestFixtures.draft(word: "casa", languagePair: "en-uk"))
        let italian = try await repository.add(TestFixtures.draft(word: "Casa", languagePair: "it-uk"))

        XCTAssertNotEqual(english.id, italian.id)
        XCTAssertEqual(try reloadedEntries().count, 2)
        let dupEN = await repository.findDuplicate(of: "CASA", languagePair: "en-uk")
        let dupIT = await repository.findDuplicate(of: "casa ", languagePair: "it-uk")
        let dupOther = await repository.findDuplicate(of: "casa", languagePair: "fr-uk")
        XCTAssertEqual(dupEN?.id, english.id)
        XCTAssertEqual(dupIT?.id, italian.id)
        XCTAssertNil(dupOther)
    }

    func testFindDuplicateExcluding() async throws {
        let entry = try await repository.add(TestFixtures.draft(word: "run"))
        let excluded = await repository.findDuplicate(of: "run", languagePair: "en-uk", excluding: entry.id)
        XCTAssertNil(excluded)
    }

    func testUpdateSetsUpdatedAt() async throws {
        let entry = try await repository.add(TestFixtures.draft(word: "run"))
        fixture.dateProvider.advance(by: 120)

        var edited = entry
        edited.translations = ["бігати"]
        edited.createdAt = TestDates.reference.addingTimeInterval(-999)   // клієнт не може змінити createdAt
        edited.updatedAt = TestDates.reference.addingTimeInterval(-999)
        let updated = try await repository.update(edited)

        XCTAssertEqual(updated.id, entry.id)
        XCTAssertEqual(updated.translations, ["бігати"])
        XCTAssertEqual(updated.createdAt, TestDates.reference)
        XCTAssertEqual(updated.updatedAt, TestDates.reference.addingTimeInterval(120))
        XCTAssertEqual(try reloadedEntries(), [updated])
    }

    func testUpdateSameWordDifferentCaseAllowed() async throws {
        let entry = try await repository.add(TestFixtures.draft(word: "run"))
        var edited = entry
        edited.word = "Run"
        let updated = try await repository.update(edited)
        XCTAssertEqual(updated.word, "Run")
    }

    func testUpdateToDuplicateRejected() async throws {
        let run = try await repository.add(TestFixtures.draft(word: "run"))
        let walk = try await repository.add(TestFixtures.draft(word: "walk"))
        let before = try fixture.readRaw()

        var edited = walk
        edited.word = " RUN"
        do {
            _ = try await repository.update(edited)
            XCTFail("update to duplicate must fail")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .duplicate(run))
        }
        let stored = await repository.entry(id: walk.id)
        XCTAssertEqual(stored, walk)
        XCTAssertEqual(try fixture.readRaw(), before)
    }

    func testUpdateMissingThrowsNotFound() async throws {
        let ghost = TestFixtures.entry()
        do {
            _ = try await repository.update(ghost)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .notFound(ghost.id))
        }
    }

    func testDeleteRemoves() async throws {
        let run = try await repository.add(TestFixtures.draft(word: "run"))
        let walk = try await repository.add(TestFixtures.draft(word: "walk"))

        try await repository.delete(id: run.id)

        let all = await repository.allEntries()
        XCTAssertEqual(all, [walk])
        let gone = await repository.entry(id: run.id)
        XCTAssertNil(gone)
        XCTAssertEqual(try reloadedEntries(), [walk])
        // Після видалення те саме слово можна додати знову.
        _ = try await repository.add(TestFixtures.draft(word: "run"))
    }

    func testDeleteMissingThrowsNotFound() async throws {
        let id = UUID()
        do {
            try await repository.delete(id: id)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .notFound(id))
        }
    }

    func testMutationBeforeLoadThrowsNotLoaded() async throws {
        let fresh = DictionaryRepository(store: fixture.store, dateProvider: fixture.dateProvider)
        do {
            _ = try await fresh.add(TestFixtures.draft(word: "run"))
            XCTFail("expected notLoaded")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .notLoaded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    func testLoadReadsExistingEntries() async throws {
        let entry = try await repository.add(TestFixtures.draft(word: "run"))
        let second = DictionaryRepository(store: fixture.store, dateProvider: fixture.dateProvider)

        let result = try await second.load()

        XCTAssertEqual(result.file.entries, [entry])
        let all = await second.allEntries()
        XCTAssertEqual(all, [entry])
    }

    func testLoadPropagatesUnsupportedSchemaVersion() async throws {
        try fixture.writeRaw("{\"schemaVersion\": 2, \"entries\": []}")
        let fresh = DictionaryRepository(store: fixture.store, dateProvider: fixture.dateProvider)

        do {
            _ = try await fresh.load()
            XCTFail("expected unsupportedSchemaVersion")
        } catch {
            XCTAssertEqual(error as? StorageError, .unsupportedSchemaVersion(2))
        }
        do {
            _ = try await fresh.add(TestFixtures.draft(word: "run"))
            XCTFail("repository must not start after unsupported schema")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .notLoaded)
        }
    }

    func testChangesStreamEmits() async throws {
        let stream = await repository.changes()
        var iterator = stream.makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial, [])

        let run = try await repository.add(TestFixtures.draft(word: "run"))
        let afterAdd = await iterator.next()
        XCTAssertEqual(afterAdd, [run])

        try await repository.delete(id: run.id)
        let afterDelete = await iterator.next()
        XCTAssertEqual(afterDelete, [])
    }

    func testChangesStreamNotEmittedOnFailedMutation() async throws {
        let run = try await repository.add(TestFixtures.draft(word: "run"))
        let stream = await repository.changes()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, [run])

        // Невдала мутація (дубль) — без знімка; наступний знімок — від успішної.
        _ = try? await repository.add(TestFixtures.draft(word: "RUN"))
        let walk = try await repository.add(TestFixtures.draft(word: "walk"))
        let next = await iterator.next()
        XCTAssertEqual(next, [run, walk])
    }

    func testFailedSaveDoesNotChangeState() async throws {
        let run = try await repository.add(TestFixtures.draft(word: "run"))
        let bytesBefore = try fixture.readRaw()
        let stream = await repository.changes()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        fixture.fileSystem.fail(.replaceItem)

        do {
            _ = try await repository.add(TestFixtures.draft(word: "walk"))
            XCTFail("add must fail")
        } catch {
            guard case RepositoryError.storage = error else {
                return XCTFail("expected RepositoryError.storage, got \(error)")
            }
        }
        var edited = run
        edited.translations = ["змінено"]
        do {
            _ = try await repository.update(edited)
            XCTFail("update must fail")
        } catch {
            guard case RepositoryError.storage = error else {
                return XCTFail("expected RepositoryError.storage, got \(error)")
            }
        }
        do {
            try await repository.delete(id: run.id)
            XCTFail("delete must fail")
        } catch {
            guard case RepositoryError.storage = error else {
                return XCTFail("expected RepositoryError.storage, got \(error)")
            }
        }

        let all = await repository.allEntries()
        XCTAssertEqual(all, [run], "in-memory state unchanged")
        XCTAssertEqual(try fixture.readRaw(), bytesBefore, "file unchanged")
        XCTAssertEqual(try fixture.temporaryFiles(), [])

        // Після відновлення диска наступна мутація проходить, і потік отримує саме її знімок.
        fixture.fileSystem.stopFailing()
        let walk = try await repository.add(TestFixtures.draft(word: "walk"))
        let next = await iterator.next()
        XCTAssertEqual(next, [run, walk])
    }

    func testReplaceAllPersists() async throws {
        _ = try await repository.add(TestFixtures.draft(word: "run"))
        let replacement = [TestFixtures.entry(word: "alpha"), TestFixtures.entry(word: "beta")]

        try await repository.replaceAll(replacement)

        let all = await repository.allEntries()
        XCTAssertEqual(all, replacement)
        XCTAssertEqual(try reloadedEntries(), replacement)
    }

    func testConcurrentAddsOfSameWordCreateOneEntry() async throws {
        let repository = self.repository!
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for index in 0..<20 {
                group.addTask {
                    let word = index.isMultiple(of: 2) ? "Run" : " run "
                    return (try? await repository.add(TestFixtures.draft(word: word))) != nil
                }
            }
            var collected: [Bool] = []
            for await value in group { collected.append(value) }
            return collected
        }

        XCTAssertEqual(results.filter { $0 }.count, 1)
        let count = await repository.allEntries().count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try reloadedEntries().count, 1)
    }

    func testConcurrentAddsOfDifferentWordsAllPersisted() async throws {
        let repository = self.repository!
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<25 {
                group.addTask {
                    _ = try? await repository.add(TestFixtures.draft(word: "word\(index)"))
                }
            }
        }

        let count = await repository.allEntries().count
        XCTAssertEqual(count, 25)
        XCTAssertEqual(try reloadedEntries().count, 25)
        XCTAssertEqual(try fixture.temporaryFiles(), [])
    }
}
