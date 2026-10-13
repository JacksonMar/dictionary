import Foundation
import XCTest
@testable import VocabCore

/// M5.1 / M5.2 — `EntryQuery`: пошук (слово, лема, переклад; без регістру й діакритики) і сортування.
final class EntryQueryTests: XCTestCase {
    private func entry(
        _ word: String,
        lemma: String? = nil,
        translations: [String] = [],
        created: TimeInterval = 0,
        id: UUID = UUID()
    ) -> Entry {
        Entry(
            id: id,
            languagePair: "en-uk",
            word: word,
            lemma: lemma,
            translations: translations,
            status: translations.isEmpty ? .pending : .ready,
            createdAt: TestDates.reference.addingTimeInterval(created),
            updatedAt: TestDates.reference.addingTimeInterval(created)
        )
    }

    private lazy var run = entry("run", lemma: "run", translations: ["бігти", "керувати"], created: 0)
    private lazy var went = entry("went", lemma: "go", translations: ["пішов"], created: 10)
    private lazy var cafe = entry("café", lemma: "café", translations: ["кав'ярня"], created: 20)
    private lazy var giveUp = entry("give up", translations: ["здаватися"], created: 30)
    private lazy var pending = entry("naïve", created: 40)

    private var all: [Entry] { [run, went, cafe, giveUp, pending] }

    private func words(_ query: EntryQuery) -> Set<String> {
        Set(query.apply(to: all).map(\.word))
    }

    // MARK: - Search (M5.1)

    func testSearchByWord() {
        XCTAssertEqual(words(EntryQuery(searchText: "run")), ["run"])
        XCTAssertEqual(words(EntryQuery(searchText: "giv")), ["give up"], "substring match")
        XCTAssertEqual(words(EntryQuery(searchText: "e u")), ["give up"], "substring across space")
        XCTAssertTrue(EntryQuery(searchText: "run").matches(run))
        XCTAssertFalse(EntryQuery(searchText: "run").matches(went))
    }

    func testSearchByLemma() {
        XCTAssertEqual(words(EntryQuery(searchText: "go")), ["went"])
    }

    func testSearchByTranslation() {
        XCTAssertEqual(words(EntryQuery(searchText: "біг")), ["run"], "«біг» знаходить run")
        XCTAssertEqual(words(EntryQuery(searchText: "керув")), ["run"], "any translation, not only the first")
        XCTAssertEqual(words(EntryQuery(searchText: "кав'ярня")), ["café"])
    }

    func testSearchCaseAndDiacriticInsensitive() {
        XCTAssertEqual(words(EntryQuery(searchText: "RUN")), ["run"])
        XCTAssertEqual(words(EntryQuery(searchText: "Run")), ["run"])
        XCTAssertEqual(words(EntryQuery(searchText: "cafe")), ["café"], "cafe finds café")
        XCTAssertEqual(words(EntryQuery(searchText: "CAFÉ")), ["café"])
        XCTAssertEqual(words(EntryQuery(searchText: "naive")), ["naïve"])
        XCTAssertEqual(words(EntryQuery(searchText: "БІГТИ")), ["run"], "Cyrillic case-insensitive")
    }

    func testSearchTrimsWhitespace() {
        XCTAssertEqual(words(EntryQuery(searchText: "  run \n")), ["run"])
        XCTAssertEqual(EntryQuery(searchText: "  run \n").normalizedSearchText, "run")
    }

    func testSearchNoMatchReturnsEmpty() {
        XCTAssertTrue(EntryQuery(searchText: "qwertyzz").apply(to: all).isEmpty)
    }

    func testEmptySearchReturnsAll() {
        for text in ["", " ", "   \t\n "] {
            let query = EntryQuery(searchText: text)
            XCTAssertEqual(query.apply(to: all).count, all.count, "«\(text)»")
            XCTAssertTrue(all.allSatisfy(query.matches), "«\(text)»")
        }
        XCTAssertEqual(EntryQuery().apply(to: []), [])
    }

    func testDefaultQuery() {
        let query = EntryQuery()
        XCTAssertEqual(query.searchText, "")
        XCTAssertEqual(query.sort, .dateNewest)
    }

    // MARK: - Sort (M5.2)

    func testSortNewestFirst() {
        let result = EntryQuery(sort: .dateNewest).apply(to: [went, pending, run, giveUp, cafe])
        XCTAssertEqual(result.map(\.word), ["naïve", "give up", "café", "went", "run"])
    }

    func testSortOldestFirst() {
        let result = EntryQuery(sort: .dateOldest).apply(to: [went, pending, run, giveUp, cafe])
        XCTAssertEqual(result.map(\.word), ["run", "went", "café", "give up", "naïve"])
    }

    func testSortAlphabeticalByKey() {
        let entries = [
            entry("walk", created: 0),
            entry("Apple", created: 1),
            entry("«banana»", created: 2),
            entry("apricot", created: 3),
            entry("Zebra", created: 4),
        ]
        let result = EntryQuery(sort: .alphabetical).apply(to: entries)
        XCTAssertEqual(result.map(\.word), ["Apple", "apricot", "«banana»", "walk", "Zebra"],
                       "case-insensitive, edge punctuation ignored (TextNormalizer.key)")
    }

    func testSortAlphabeticalTieBreaksByCreatedAt() {
        let newer = entry("Run", created: 50)
        let older = entry("run", created: 5)
        let middle = entry("RUN.", created: 20)
        for input in [[newer, older, middle], [middle, newer, older], [older, middle, newer]] {
            XCTAssertEqual(EntryQuery(sort: .alphabetical).apply(to: input).map(\.id),
                           [older.id, middle.id, newer.id])
        }
    }

    func testSortAlphabeticalFullTieIsDeterministic() {
        let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let highID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        let a = entry("run", created: 0, id: highID)
        let b = entry("Run", created: 0, id: lowID)
        XCTAssertEqual(EntryQuery(sort: .alphabetical).apply(to: [a, b]).map(\.id), [lowID, highID])
        XCTAssertEqual(EntryQuery(sort: .alphabetical).apply(to: [b, a]).map(\.id), [lowID, highID])
    }

    func testSortByDateTieBreaksAlphabeticallyThenByID() {
        let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let highID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        let walk = entry("walk", created: 0)
        let apple = entry("Apple", created: 0)
        let run1 = entry("run", created: 0, id: highID)
        let run2 = entry("RUN", created: 0, id: lowID)
        let expected = [apple.id, run2.id, run1.id, walk.id]
        for sort in [EntrySort.dateNewest, .dateOldest] {
            for input in [[walk, run1, apple, run2], [run2, walk, run1, apple]] {
                XCTAssertEqual(EntryQuery(sort: sort).apply(to: input).map(\.id), expected, "\(sort)")
            }
        }
    }

    func testAllSortCases() {
        XCTAssertEqual(EntrySort.allCases, [.dateNewest, .dateOldest, .alphabetical])
        XCTAssertEqual(EntrySort.allCases.map(\.rawValue), ["dateNewest", "dateOldest", "alphabetical"])
    }

    // MARK: - Combined

    func testSearchAndSortCombined() {
        let runFast = entry("run fast", translations: ["швидко бігти"], created: 100)
        let rerun = entry("rerun", translations: ["повтор"], created: -100)
        let input = all + [runFast, rerun]

        let newest = EntryQuery(searchText: "RUN", sort: .dateNewest).apply(to: input)
        XCTAssertEqual(newest.map(\.word), ["run fast", "run", "rerun"])

        let oldest = EntryQuery(searchText: "run", sort: .dateOldest).apply(to: input)
        XCTAssertEqual(oldest.map(\.word), ["rerun", "run", "run fast"])

        let alphabetical = EntryQuery(searchText: " run ", sort: .alphabetical).apply(to: input)
        XCTAssertEqual(alphabetical.map(\.word), ["rerun", "run", "run fast"])

        let byTranslation = EntryQuery(searchText: "бігти", sort: .dateNewest).apply(to: input)
        XCTAssertEqual(byTranslation.map(\.word), ["run fast", "run"])
    }

    func testApplyDoesNotMutateInput() {
        let input = [run, went, cafe]
        _ = EntryQuery(searchText: "x", sort: .alphabetical).apply(to: input)
        XCTAssertEqual(input.map(\.word), ["run", "went", "café"])
    }
}
