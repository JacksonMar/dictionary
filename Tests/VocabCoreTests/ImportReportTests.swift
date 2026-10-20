import Foundation
import XCTest
@testable import VocabCore

/// M4.5 — текст звіту імпорту.
final class ImportReportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        pinInterfaceLanguage(.uk)
    }

    func testSummaryText() {
        let report = ImportReport(added: 2, updated: 1, skipped: 3)
        XCTAssertEqual(report.summary, "Додано 2, оновлено 1, пропущено 3")
    }

    func testEmptyReportSummary() {
        XCTAssertEqual(ImportReport().summary, "Додано 0, оновлено 0, пропущено 0")
        XCTAssertEqual(ImportReport(), ImportReport(added: 0, updated: 0, skipped: 0, skippedReasons: []))
    }

    func testAddSkippedCountsReasons() {
        var report = ImportReport(added: 1)
        report.addSkipped(["a", "b"])
        report.addSkipped([])
        report.addSkipped(["c"])
        XCTAssertEqual(report.skipped, 3)
        XCTAssertEqual(report.skippedReasons, ["a", "b", "c"])
        XCTAssertEqual(report.summary, "Додано 1, оновлено 0, пропущено 3")
    }

    func testServiceReportListsInvalidEntriesFirst() async throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        let local = M4.entry(word: "run", updated: 50)
        try await fixture.seed([local])
        var broken = try M4.rawEntry(M4.entry(word: "bad"))
        broken["id"] = nil
        let older = try M4.rawEntry(M4.entry(word: "run", updated: 10))
        let url = try fixture.writeImportFile(M4.rawFileData([older, broken]))

        let report = try await fixture.service.importDictionary(from: url, mode: .merge)

        XCTAssertEqual(report.skipped, 2)
        XCTAssertEqual(report.skippedReasons, [
            "Запис #2: відсутнє поле id",
            "«run»: у словнику та сама або новіша версія",
        ])
        XCTAssertEqual(report.skipped, report.skippedReasons.count)
    }
}
