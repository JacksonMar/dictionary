import Foundation
import XCTest
@testable import VocabCore

/// M6.2 — пагінація (чиста логіка, сторінки з 1).
final class PaginationTests: XCTestCase {
    /// `count` записів зі словами `w1…wN` у заданому порядку.
    private func entries(_ count: Int) -> [Entry] {
        (1...max(count, 1)).prefix(count).map { index in
            TestFixtures.entry(word: "w\(index)", date: TestDates.reference.addingTimeInterval(Double(index)))
        }
    }

    func testDefaultPageSizeIs25() {
        XCTAssertEqual(Pagination.defaultPageSize, 25)
        XCTAssertEqual(Pagination.pageSizeOptions, [20, 25, 30])
        XCTAssertEqual(Pagination().pageSize, 25)
        XCTAssertEqual(Pagination(pageSize: 20).pageSize, 20)
        XCTAssertEqual(Pagination(pageSize: 30).pageSize, 30)
    }

    func testInvalidPageSizeFallsBackToDefault() {
        for invalid in [0, -1, 1, 10, 24, 26, 50, 100, Int.max, Int.min] {
            XCTAssertEqual(Pagination(pageSize: invalid).pageSize, 25, "\(invalid)")
            XCTAssertEqual(Pagination.normalizedPageSize(invalid), 25, "\(invalid)")
        }
        for valid in Pagination.pageSizeOptions {
            XCTAssertEqual(Pagination.normalizedPageSize(valid), valid)
        }
    }

    func testPageCountRoundsUp() {
        let pagination = Pagination(pageSize: 25)
        XCTAssertEqual(pagination.pageCount(totalCount: 1), 1)
        XCTAssertEqual(pagination.pageCount(totalCount: 25), 1)
        XCTAssertEqual(pagination.pageCount(totalCount: 26), 2)
        XCTAssertEqual(pagination.pageCount(totalCount: 50), 2)
        XCTAssertEqual(pagination.pageCount(totalCount: 51), 3)
        XCTAssertEqual(Pagination(pageSize: 20).pageCount(totalCount: 41), 3)
        XCTAssertEqual(Pagination(pageSize: 30).pageCount(totalCount: 90), 3)
    }

    func testEmptyListHasOnePage() {
        let pagination = Pagination()
        XCTAssertEqual(pagination.pageCount(totalCount: 0), 1)
        let page = pagination.page(1, of: [])
        XCTAssertEqual(page.entries, [])
        XCTAssertEqual(page.number, 1)
        XCTAssertEqual(page.pageCount, 1)
        XCTAssertEqual(page.totalCount, 0)
        XCTAssertFalse(page.hasPrevious)
        XCTAssertFalse(page.hasNext)
        XCTAssertEqual(pagination.page(5, of: []).number, 1)
    }

    func testFirstPageSlice() {
        let all = entries(60)
        let page = Pagination(pageSize: 25).page(1, of: all)
        XCTAssertEqual(page.entries, Array(all[0..<25]))
        XCTAssertEqual(page.number, 1)
        XCTAssertEqual(page.pageCount, 3)
        XCTAssertEqual(page.totalCount, 60)

        let second = Pagination(pageSize: 25).page(2, of: all)
        XCTAssertEqual(second.entries, Array(all[25..<50]))
    }

    func testLastPartialPage() {
        let all = entries(60)
        let page = Pagination(pageSize: 25).page(3, of: all)
        XCTAssertEqual(page.entries.count, 10)
        XCTAssertEqual(page.entries, Array(all[50..<60]))
        XCTAssertEqual(page.number, 3)

        let twenty = Pagination(pageSize: 20).page(3, of: entries(41))
        XCTAssertEqual(twenty.entries.map(\.word), ["w41"])
    }

    func testClampBelowOneAndAboveLast() {
        let pagination = Pagination(pageSize: 25)
        XCTAssertEqual(pagination.clamp(0, totalCount: 60), 1)
        XCTAssertEqual(pagination.clamp(-5, totalCount: 60), 1)
        XCTAssertEqual(pagination.clamp(2, totalCount: 60), 2)
        XCTAssertEqual(pagination.clamp(4, totalCount: 60), 3)
        XCTAssertEqual(pagination.clamp(Int.max, totalCount: 60), 3)
        XCTAssertEqual(pagination.clamp(3, totalCount: 0), 1)
    }

    func testPageClampsRequestedNumber() {
        let all = entries(30)
        let pagination = Pagination(pageSize: 25)

        let tooFar = pagination.page(9, of: all)
        XCTAssertEqual(tooFar.number, 2)
        XCTAssertEqual(tooFar.entries, Array(all[25..<30]))

        let tooLow = pagination.page(0, of: all)
        XCTAssertEqual(tooLow.number, 1)
        XCTAssertEqual(tooLow.entries, Array(all[0..<25]))
    }

    func testHasPreviousAndHasNext() {
        let all = entries(60)
        let pagination = Pagination(pageSize: 25)

        let first = pagination.page(1, of: all)
        XCTAssertFalse(first.hasPrevious)
        XCTAssertTrue(first.hasNext)

        let middle = pagination.page(2, of: all)
        XCTAssertTrue(middle.hasPrevious)
        XCTAssertTrue(middle.hasNext)

        let last = pagination.page(3, of: all)
        XCTAssertTrue(last.hasPrevious)
        XCTAssertFalse(last.hasNext)

        let single = pagination.page(1, of: entries(25))
        XCTAssertFalse(single.hasPrevious)
        XCTAssertFalse(single.hasNext)
    }

    func testLabelText() {
        XCTAssertEqual(EntryPage(entries: [], number: 2, pageCount: 5, totalCount: 120).label, "Сторінка 2 з 5")
        XCTAssertEqual(Pagination().page(1, of: []).label, "Сторінка 1 з 1")
        XCTAssertEqual(Pagination(pageSize: 20).page(3, of: entries(41)).label, "Сторінка 3 з 3")
    }
}
