import Foundation
import XCTest
@testable import VocabCore

/// M4.2 — merge з конфліктами за `updatedAt` (§10, D1). Чисті функції `ImportMerger`.
final class ImportMergerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        pinInterfaceLanguage(.uk)
    }

    func testNewEntriesAdded() {
        let local = [M4.entry(word: "run")]
        let imported = [M4.entry(word: "walk"), M4.entry(word: "give up")]

        let result = ImportMerger.merge(local: local, imported: imported)

        XCTAssertEqual(result.entries, local + imported, "local first, new entries appended in file order")
        XCTAssertEqual(result.report, ImportReport(added: 2, updated: 0, skipped: 0, skippedReasons: []))
    }

    func testMergeIntoEmptyAddsAll() {
        let imported = [M4.entry(word: "run"), M4.entry(word: "walk")]
        let result = ImportMerger.merge(local: [], imported: imported)
        XCTAssertEqual(result.entries, imported)
        XCTAssertEqual(result.report.summary, "Додано 2, оновлено 0, пропущено 0")
    }

    func testEmptyImportChangesNothing() {
        let local = [M4.entry(word: "run")]
        let result = ImportMerger.merge(local: local, imported: [])
        XCTAssertEqual(result.entries, local)
        XCTAssertEqual(result.report, ImportReport())
    }

    func testSameIdNewerWins() {
        let id = UUID()
        let local = M4.entry(id: id, word: "run", translations: ["бігти"], updated: 10)
        let imported = M4.entry(id: id, word: "run", translations: ["бігти", "керувати"], created: 5, updated: 20)

        let result = ImportMerger.merge(local: [local], imported: [imported])

        XCTAssertEqual(result.entries, [imported], "content (including createdAt/updatedAt) taken from the import")
        XCTAssertEqual(result.report, ImportReport(added: 0, updated: 1, skipped: 0))
    }

    func testSameIdNewerWinsEvenWithChangedWord() {
        // Збіг за id має пріоритет над ключем слова (D1).
        let id = UUID()
        let local = M4.entry(id: id, word: "runn", updated: 10)
        let imported = M4.entry(id: id, word: "run", updated: 20)

        let result = ImportMerger.merge(local: [local], imported: [imported])

        XCTAssertEqual(result.entries, [imported])
        XCTAssertEqual(result.report.updated, 1)
        XCTAssertEqual(result.report.added, 0)
    }

    func testSameIdOlderSkipped() {
        let id = UUID()
        let local = M4.entry(id: id, word: "run", translations: ["бігти"], updated: 20)
        let imported = M4.entry(id: id, word: "run", translations: ["старе"], updated: 10)

        let result = ImportMerger.merge(local: [local], imported: [imported])

        XCTAssertEqual(result.entries, [local])
        XCTAssertEqual(result.report.added, 0)
        XCTAssertEqual(result.report.updated, 0)
        XCTAssertEqual(result.report.skipped, 1)
        XCTAssertEqual(result.report.skippedReasons, ["«run»: у словнику та сама або новіша версія"])
    }

    func testSameIdEqualKeepsLocal() {
        let id = UUID()
        let local = M4.entry(id: id, word: "run", translations: ["локальний"], updated: 10)
        let imported = M4.entry(id: id, word: "run", translations: ["імпортований"], updated: 10)

        let result = ImportMerger.merge(local: [local], imported: [imported])

        XCTAssertEqual(result.entries, [local])
        XCTAssertEqual(result.report, ImportReport(
            added: 0, updated: 0, skipped: 1,
            skippedReasons: ["«run»: у словнику та сама або новіша версія"]
        ))
    }

    func testSameNormalizedWordNewerWinsKeepsLocalId() {
        let localID = UUID()
        let importedID = UUID()
        let local = M4.entry(id: localID, word: "give up", translations: ["здаватися"], updated: 10)
        // Інший регістр, зайві пробіли, інший id — той самий ключ дедуплікації (D8).
        let imported = M4.entry(id: importedID, word: "Give   Up", translations: ["кидати"], updated: 20)

        let result = ImportMerger.merge(local: [local], imported: [imported])

        XCTAssertEqual(result.report, ImportReport(added: 0, updated: 1, skipped: 0))
        XCTAssertEqual(result.entries.count, 1)
        var expected = imported
        expected.id = localID
        XCTAssertEqual(result.entries, [expected], "local id kept, rest of the content from the import")
        XCTAssertFalse(result.entries.contains { $0.id == importedID })
    }

    func testSameNormalizedWordOlderSkipped() {
        let local = M4.entry(word: "run", updated: 20)
        let imported = M4.entry(word: "RUN", updated: 10)

        let result = ImportMerger.merge(local: [local], imported: [imported])

        XCTAssertEqual(result.entries, [local])
        XCTAssertEqual(result.report, ImportReport(
            added: 0, updated: 0, skipped: 1,
            skippedReasons: ["«RUN»: у словнику та сама або новіша версія"]
        ))
    }

    func testCurlyApostropheMatchesStraight() {
        let local = M4.entry(word: "don't", updated: 10)
        let imported = M4.entry(word: "don\u{2019}t", updated: 20)
        let result = ImportMerger.merge(local: [local], imported: [imported])
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.id, local.id)
        XCTAssertEqual(result.report.updated, 1)
    }

    func testOtherPairIsNotConflict() {
        let local = M4.entry(pair: "en-uk", word: "run", updated: 20)
        let imported = M4.entry(pair: "de-uk", word: "run", updated: 10)

        let result = ImportMerger.merge(local: [local], imported: [imported])

        XCTAssertEqual(result.entries, [local, imported])
        XCTAssertEqual(result.report, ImportReport(added: 1, updated: 0, skipped: 0))
    }

    func testImportedPendingDoesNotOverwriteReady() {
        let id = UUID()
        let local = M4.entry(id: id, word: "run", status: .ready, updated: 10)
        let pending = M4.entry(id: id, word: "run", status: .pending, updated: 20)
        let failedByWord = M4.entry(word: "walk", status: .failed, lastError: "HTTP 400", updated: 20)
        let localWalk = M4.entry(word: "walk", status: .ready, updated: 10)

        let result = ImportMerger.merge(local: [local, localWalk], imported: [pending, failedByWord])

        XCTAssertEqual(result.entries, [local, localWalk])
        XCTAssertEqual(result.report.added, 0)
        XCTAssertEqual(result.report.updated, 0)
        XCTAssertEqual(result.report.skipped, 2)
        XCTAssertEqual(result.report.skippedReasons, [
            "«run»: імпортований запис ще не оброблено, у словнику — готовий",
            "«walk»: імпортований запис ще не оброблено, у словнику — готовий",
        ])
    }

    func testImportedReadyOverwritesLocalPending() {
        let id = UUID()
        let local = M4.entry(id: id, word: "run", status: .pending, updated: 10)
        let imported = M4.entry(id: id, word: "run", status: .ready, updated: 20)

        let result = ImportMerger.merge(local: [local], imported: [imported])

        XCTAssertEqual(result.entries, [imported])
        XCTAssertEqual(result.report.updated, 1)
    }

    func testImportedFailedOverwritesLocalPendingWhenNewer() {
        let id = UUID()
        let local = M4.entry(id: id, word: "run", status: .pending, updated: 10)
        let imported = M4.entry(id: id, word: "run", status: .failed, lastError: "HTTP 400", updated: 20)

        let result = ImportMerger.merge(local: [local], imported: [imported])

        XCTAssertEqual(result.entries, [imported])
        XCTAssertEqual(result.report.updated, 1)
    }

    func testIdMatchWhoseWordCollidesWithAnotherLocalIsSkipped() {
        let id = UUID()
        let localRun = M4.entry(id: id, word: "run", updated: 10)
        let localWalk = M4.entry(word: "walk", updated: 10)
        // Той самий id, що й у localRun, але слово — як у localWalk: заміна дала б дубль.
        let imported = M4.entry(id: id, word: "walk", updated: 20)

        let result = ImportMerger.merge(local: [localRun, localWalk], imported: [imported])

        XCTAssertEqual(result.entries, [localRun, localWalk])
        XCTAssertEqual(result.report, ImportReport(
            added: 0, updated: 0, skipped: 1,
            skippedReasons: ["«walk»: у словнику вже є інший запис з цим словом"]
        ))
    }

    func testDuplicatesInsideFileCollapsed() {
        let sharedID = UUID()
        let olderByID = M4.entry(id: sharedID, word: "run", translations: ["старе"], updated: 10)
        let newerByID = M4.entry(id: sharedID, word: "run", translations: ["нове"], updated: 30)
        let firstByWord = M4.entry(word: "walk", translations: ["перше"], updated: 50)
        let olderByWord = M4.entry(word: "Walk", translations: ["друге"], updated: 40)
        let equalByWord = M4.entry(word: "WALK", translations: ["третє"], updated: 50)

        let result = ImportMerger.merge(
            local: [],
            imported: [olderByID, firstByWord, newerByID, olderByWord, equalByWord]
        )

        XCTAssertEqual(result.entries, [newerByID, firstByWord],
                       "newer updatedAt wins; equal → first in file; order by first appearance")
        XCTAssertEqual(result.report.added, 2)
        XCTAssertEqual(result.report.updated, 0)
        XCTAssertEqual(result.report.skipped, 3)
        XCTAssertEqual(result.report.skippedReasons.count, 3)
        XCTAssertTrue(result.report.skippedReasons.allSatisfy { $0.hasSuffix(": дублікат у файлі імпорту") },
                      "\(result.report.skippedReasons)")
    }

    func testCollapseDuplicatesDirect() {
        let a = M4.entry(word: "run", updated: 10)
        let b = M4.entry(word: "run", updated: 20)
        let c = M4.entry(word: "walk", updated: 0)

        let collapsed = ImportMerger.collapseDuplicates([a, c, b])

        XCTAssertEqual(collapsed.entries, [b, c])
        XCTAssertEqual(collapsed.skippedReasons, ["«run»: дублікат у файлі імпорту"])
    }

    func testDuplicateInsideFileThenConflictWithLocal() {
        // Згортання відбувається до порівняння з локальним: перемагає новіший запис файлу, і вже він
        // порівнюється з локальним.
        let local = M4.entry(word: "run", translations: ["локальний"], updated: 15)
        let older = M4.entry(word: "run", translations: ["файл-старий"], updated: 10)
        let newer = M4.entry(word: "run", translations: ["файл-новий"], updated: 20)

        let result = ImportMerger.merge(local: [local], imported: [older, newer])

        var expected = newer
        expected.id = local.id
        XCTAssertEqual(result.entries, [expected])
        XCTAssertEqual(result.report.added, 0)
        XCTAssertEqual(result.report.updated, 1)
        XCTAssertEqual(result.report.skipped, 1)
    }

    func testReportCounts() {
        let idNewer = UUID()
        let idOlder = UUID()
        let idEqual = UUID()
        let local = [
            M4.entry(id: idNewer, word: "run", updated: 10),
            M4.entry(id: idOlder, word: "walk", updated: 30),
            M4.entry(id: idEqual, word: "jump", updated: 20),
            M4.entry(word: "swim", status: .ready, updated: 10),
            M4.entry(word: "look up", updated: 10),
        ]
        let imported = [
            M4.entry(word: "fly", updated: 1),                                // added
            M4.entry(id: idNewer, word: "run", translations: ["x"], updated: 20), // updated by id
            M4.entry(word: "Look Up", translations: ["y"], updated: 40),     // updated by word
            M4.entry(id: idOlder, word: "walk", updated: 10),                // skipped: older
            M4.entry(id: idEqual, word: "jump", updated: 20),                // skipped: equal
            M4.entry(word: "swim", status: .pending, updated: 99),           // skipped: pending vs ready
            M4.entry(word: "dive", updated: 5),                              // added
            M4.entry(word: "DIVE", updated: 4),                              // skipped: duplicate in file
            M4.entry(pair: "de-uk", word: "run", updated: 1),                // added: other pair
        ]

        let result = ImportMerger.merge(local: local, imported: imported)

        XCTAssertEqual(result.report.added, 3)
        XCTAssertEqual(result.report.updated, 2)
        XCTAssertEqual(result.report.skipped, 4)
        XCTAssertEqual(result.report.skippedReasons.count, 4)
        XCTAssertEqual(result.report.summary, "Додано 3, оновлено 2, пропущено 4")
        XCTAssertEqual(result.entries.count, local.count + 3)
        XCTAssertEqual(Set(result.entries.map(\.id)).count, result.entries.count, "ids unique")
        XCTAssertEqual(result.entries.prefix(local.count).map(\.id), local.map(\.id), "local ids preserved in place")
    }
}
