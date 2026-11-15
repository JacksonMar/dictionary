// I3.3 (IOS_PLAN §3.3, DI7): the Share extension's UIKit-free logic. `ShareTextExtractor.swift` and
// `ShareInboxWriter.swift` are compiled into this test target by path (project.yml), so their internal types are
// visible here without importing the extension module.
import Foundation
import XCTest
import VocabCore

final class ShareTextExtractorTests: XCTestCase {
    private let pageURL = URL(string: "https://example.com/article?id=1")!

    // MARK: - I3.3 required

    func testPrefersSelectedText() {
        // Safari/Notes/Telegram/Chrome deliver the selection as a `public.plain-text` attachment; the item's
        // `attributedContentText` is often the page title. The plain text wins regardless of order.
        XCTAssertEqual(
            ShareTextExtractor.extract(from: [
                .attributedContentText("A Page Title — Example"),
                .url(pageURL),
                .plainText("  serendipity \n"),
            ]),
            .accepted(text: "serendipity", truncated: false)
        )
        // Several plain-text attachments → the first non-empty one in arrival order.
        XCTAssertEqual(
            ShareTextExtractor.extract(from: [.plainText("   "), .plainText("wane"), .plainText("thrive")]),
            .accepted(text: "wane", truncated: false)
        )
        // A plain-text candidate that is only the page URL (Chrome/Safari) is skipped → falls back to the content text.
        XCTAssertEqual(
            ShareTextExtractor.extract(from: [.plainText(pageURL.absoluteString), .attributedContentText("brisk")]),
            .accepted(text: "brisk", truncated: false)
        )
        // No plain text at all → `attributedContentText` is used.
        XCTAssertEqual(
            ShareTextExtractor.extract(from: [.url(pageURL), .attributedContentText(" ephemeral ")]),
            .accepted(text: "ephemeral", truncated: false)
        )
    }

    func testTruncatesTo2000() {
        XCTAssertEqual(ShareTextExtractor.maxLength, 2000)

        let long = String(repeating: "abcde ", count: 500)   // 3000 characters
        guard case .accepted(let text, let truncated) = ShareTextExtractor.extract(from: [.plainText(long)]) else {
            return XCTFail("expected .accepted")
        }
        XCTAssertTrue(truncated)
        XCTAssertLessThanOrEqual(text.count, 2000)
        XCTAssertGreaterThanOrEqual(text.count, 1999, "only the trailing space at the cut may be trimmed")
        XCTAssertTrue(long.hasPrefix(text))
        XCTAssertEqual(text, text.trimmingCharacters(in: .whitespacesAndNewlines))

        // Exactly 2000 characters (after trimming) → kept whole, not flagged.
        let exact = String(repeating: "x", count: 2000)
        XCTAssertEqual(ShareTextExtractor.extract(from: [.plainText("  \(exact)\n")]),
                       .accepted(text: exact, truncated: false))

        // The cut never splits a grapheme cluster (counted in `Character`s).
        let family = "👨‍👩‍👧‍👦"
        let emoji = String(repeating: "y", count: 1999) + family + String(repeating: "z", count: 10)
        guard case .accepted(let cut, true) = ShareTextExtractor.extract(from: [.plainText(emoji)]) else {
            return XCTFail("expected truncated .accepted")
        }
        XCTAssertEqual(cut.count, 2000)
        XCTAssertTrue(cut.hasSuffix(family))
    }

    func testEmptyShareRejected() {
        XCTAssertEqual(ShareTextExtractor.extract(from: []), .rejected)
        XCTAssertEqual(ShareTextExtractor.extract(from: [.url(pageURL)]), .rejected, "URL only (whole-page share)")
        XCTAssertEqual(ShareTextExtractor.extract(from: [.plainText(" \n\t "), .attributedContentText("")]), .rejected)
        XCTAssertEqual(
            ShareTextExtractor.extract(from: [.url(pageURL), .plainText(pageURL.absoluteString),
                                              .attributedContentText("  HTTP://EXAMPLE.COM/x  ")]),
            .rejected, "text that is only a web link is not a word"
        )
    }

    // MARK: - URL handling

    func testURLIgnored() {
        XCTAssertEqual(ShareTextExtractor.extract(from: [.url(pageURL), .plainText("quaint")]),
                       .accepted(text: "quaint", truncated: false))
        // Text that merely contains a link (with spaces) is still text; non-http schemes are text too.
        XCTAssertEqual(ShareTextExtractor.extract(from: [.plainText("see https://example.com")]),
                       .accepted(text: "see https://example.com", truncated: false))
        XCTAssertFalse(ShareTextExtractor.isWebLink("mailto:someone"))
        XCTAssertTrue(ShareTextExtractor.isWebLink("https://example.com/path?q=1"))
        XCTAssertTrue(ShareTextExtractor.isWebLink("http://example.com"))
        XCTAssertFalse(ShareTextExtractor.isWebLink("run"))
    }

    // MARK: - ShareInboxWriter

    private func readItems(_ directory: URL) throws -> [InboxItem] {
        try InboxStore(directory: directory, fileSystem: LocalFileSystem()).pendingItems().map(\.item)
    }

    func testWriterSavesItemWithoutHint() throws {
        let directory = makeTemporaryDirectory(self).appendingPathComponent("Inbox", isDirectory: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let outcome = ShareInboxWriter.save(.accepted(text: "serendipity", truncated: false), directory: directory, now: now)

        XCTAssertEqual(outcome, .saved(truncated: false))
        XCTAssertTrue(outcome.isSuccess)
        let items = try readItems(directory)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.text, "serendipity")
        XCTAssertEqual(items.first?.source, .share)
        XCTAssertNil(items.first?.languageHint, "Share has no language hint (D25)")
        XCTAssertEqual(items.first?.createdAt, now)
        XCTAssertEqual(items.first?.version, InboxItem.currentVersion)
        // No temporary files left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".tmp") }, [])

        // Truncation flag is passed through.
        XCTAssertEqual(ShareInboxWriter.save(.accepted(text: "wane", truncated: true), directory: directory),
                       .saved(truncated: true))
        XCTAssertEqual(try readItems(directory).count, 2)
    }

    func testWriterOutcomes() throws {
        let root = makeTemporaryDirectory(self)
        let directory = root.appendingPathComponent("Inbox", isDirectory: true)

        // Nothing to save → `.empty`, nothing created (even without an App Group).
        XCTAssertEqual(ShareInboxWriter.save(.rejected, directory: directory), .empty)
        XCTAssertEqual(ShareInboxWriter.save(.rejected, directory: nil), .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        // No App Group → `.unavailable`.
        let unavailable = ShareInboxWriter.save(.accepted(text: "run", truncated: false), directory: nil)
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertFalse(unavailable.isSuccess)

        // Full inbox (200 waiting items) → `.full`, the new word is not written.
        let store = InboxStore(directory: directory, fileSystem: LocalFileSystem())
        for index in 0..<InboxStore.defaultMaxPendingItems {
            try store.enqueue(InboxItem(text: "w\(index)", createdAt: Date(timeIntervalSince1970: TimeInterval(index))))
        }
        XCTAssertEqual(ShareInboxWriter.save(.accepted(text: "run", truncated: false), directory: directory), .full)
        XCTAssertEqual(try store.pendingItems().count, InboxStore.defaultMaxPendingItems)

        // Storage failure (the inbox path is a regular file) → `.failed(reason:)`.
        let blocker = root.appendingPathComponent("NotADirectory")
        try Data("x".utf8).write(to: blocker)
        let failed = ShareInboxWriter.save(.accepted(text: "run", truncated: false), directory: blocker)
        guard case .failed(let reason) = failed else { return XCTFail("expected .failed, got \(failed)") }
        XCTAssertFalse(reason.contains("run"), "reason never carries the shared text")
        XCTAssertFalse(failed.isSuccess)
    }

    func testOutcomeMessages() {
        for language in AppLanguage.allCases {
            let saved = ShareSaveOutcome.saved(truncated: false).message(language: language)
            XCTAssertEqual(saved, L10n.text(.shareSaved, language: language))
            let truncated = ShareSaveOutcome.saved(truncated: true).message(language: language)
            XCTAssertTrue(truncated.hasPrefix(saved))
            XCTAssertTrue(truncated.contains("2000"), truncated)
            XCTAssertFalse(truncated.contains("{max}"))
            XCTAssertEqual(ShareSaveOutcome.empty.message(language: language), L10n.text(.shareEmpty, language: language))
            XCTAssertEqual(ShareSaveOutcome.full.message(language: language), L10n.text(.shareFull, language: language))
            XCTAssertEqual(ShareSaveOutcome.unavailable.message(language: language),
                           L10n.text(.shareUnavailable, language: language))
            let failed = ShareSaveOutcome.failed(reason: "disk is full").message(language: language)
            XCTAssertTrue(failed.contains("disk is full"))
            XCTAssertFalse(failed.contains("{reason}"))
        }
        XCTAssertEqual(ShareSaveOutcome.saved(truncated: false).message(language: .en),
                       "Saved — will be translated when you open VocabApp.")
        XCTAssertNotEqual(ShareSaveOutcome.saved(truncated: false).message(language: .uk),
                          ShareSaveOutcome.saved(truncated: false).message(language: .en))
    }

    func testExtensionLanguageFromPreferredLanguages() {
        XCTAssertEqual(ShareInboxWriter.interfaceLanguage(preferredLanguages: ["uk-UA", "en-US"]), .uk)
        XCTAssertEqual(ShareInboxWriter.interfaceLanguage(preferredLanguages: ["en-GB", "uk-UA"]), .en)
        XCTAssertEqual(ShareInboxWriter.interfaceLanguage(preferredLanguages: ["de-DE", "it-IT", "uk"]), .uk,
                       "first supported language in preference order")
        XCTAssertEqual(ShareInboxWriter.interfaceLanguage(preferredLanguages: ["de-DE", "fr"]), .en, "fallback")
        XCTAssertEqual(ShareInboxWriter.interfaceLanguage(preferredLanguages: []), .en)
        XCTAssertEqual(ShareInboxWriter.interfaceLanguage(preferredLanguages: ["UK_ua"]), .uk)
        XCTAssertEqual(ShareInboxWriter.interfaceLanguage(preferredLanguages: ["zh-Hans-CN", "en"]), .en)
    }
}
