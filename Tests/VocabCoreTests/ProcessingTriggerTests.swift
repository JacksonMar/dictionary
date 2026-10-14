import Foundation
import XCTest
@testable import VocabCore

/// M6.5 — рядки логу черги: лише тригер, UUID і лічильники (P5), без слова, тексту помилки, ключа.
final class ProcessingTriggerTests: XCTestCase {
    private static let entryID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testTriggerRawValues() {
        XCTAssertEqual(ProcessingTrigger.allCases.map(\.rawValue),
                       ["manual", "retryAll", "startup", "network", "keySaved", "modelChanged", "imported", "due"])
    }

    func testStartedMessageContainsTrigger() {
        XCTAssertEqual(QueueLog.started(.network), "Queue run started: trigger=network")
        XCTAssertEqual(QueueLog.started(.retryAll, entryID: nil), "Queue run started: trigger=retryAll")
        XCTAssertEqual(QueueLog.started(.manual, entryID: Self.entryID),
                       "Queue run started: trigger=manual id=11111111-2222-3333-4444-555555555555")
        for trigger in ProcessingTrigger.allCases {
            XCTAssertTrue(QueueLog.started(trigger).hasSuffix("trigger=\(trigger.rawValue)"), "\(trigger)")
        }
    }

    func testFinishedMessageCountsResults() {
        let ready = TestFixtures.entry(word: "a")
        let pending = TestFixtures.entry(word: "b", status: .pending)
        let failed = TestFixtures.entry(word: "c", status: .failed)
        let results: [ProcessingResult] = [
            .ready(ready),
            .ready(ready),
            .pending(pending, .offline),
            .failed(failed, .unauthorized),
            .skipped(pending),
            .notFound(UUID()),
            .notFound(UUID()),
            .notFound(UUID()),
        ]

        XCTAssertEqual(QueueLog.finished(.network, results: results),
                       "Queue run finished: trigger=network ready=2 pending=1 failed=1 skipped=1 notFound=3")
        XCTAssertEqual(QueueLog.finished(.manual, entryID: Self.entryID, results: [.ready(ready)]),
                       "Queue run finished: trigger=manual id=11111111-2222-3333-4444-555555555555 "
                           + "ready=1 pending=0 failed=0 skipped=0 notFound=0")
        XCTAssertEqual(QueueLog.finished(.startup, results: []),
                       "Queue run finished: trigger=startup ready=0 pending=0 failed=0 skipped=0 notFound=0")
    }

    func testMessagesContainNoWordOrErrorText() {
        let secretKey = "sk-ant-api03-SECRETKEYVALUE"
        let word = "serendipityword"
        let errorText = "server says invalid key \(secretKey)"
        let entry = Entry(
            id: Self.entryID,
            languagePair: "en-uk",
            word: word,
            lemma: "serendipitylemma",
            translations: ["перекладслово"],
            status: .failed,
            lastError: errorText,
            createdAt: TestDates.reference,
            updatedAt: TestDates.reference
        )
        let results: [ProcessingResult] = [
            .failed(entry, .badRequest(status: 400, message: errorText)),
            .pending(entry, .transport(errorText)),
            .ready(entry),
            .skipped(entry),
        ]

        let messages = [
            QueueLog.started(.manual, entryID: entry.id),
            QueueLog.finished(.manual, entryID: entry.id, results: results),
            QueueLog.finished(.retryAll, results: results),
        ]
        for message in messages {
            for forbidden in [word, "serendipitylemma", "перекладслово", errorText, "invalid key", secretKey, "sk-ant"] {
                XCTAssertFalse(message.contains(forbidden), "'\(message)' contains '\(forbidden)'")
            }
        }
        XCTAssertEqual(messages[1], "Queue run finished: trigger=manual id=\(Self.entryID.uuidString) "
                           + "ready=1 pending=1 failed=1 skipped=1 notFound=0")
    }
}
