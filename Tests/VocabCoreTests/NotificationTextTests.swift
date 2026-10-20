import Foundation
import XCTest
@testable import VocabCore

/// M3.3 — тексти сповіщень (§9, D17).
final class NotificationTextTests: XCTestCase {
    override func setUp() {
        super.setUp()
        pinInterfaceLanguage(.uk)
    }

    private func entry(
        _ word: String = "run",
        translations: [String] = ["бігти", "керувати"],
        status: EntryStatus = .ready
    ) -> Entry {
        var entry = TestFixtures.entry(word: word, status: status)
        entry.translations = translations
        return entry
    }

    func testAdded() {
        XCTAssertEqual(
            NotificationText.make(for: .added(entry())),
            NotificationContent(title: "Додано", body: "Додано: run — бігти, керувати")
        )
        XCTAssertEqual(
            NotificationText.make(for: .added(entry("give up", translations: ["здаватися"]))),
            NotificationContent(title: "Додано", body: "Додано: give up — здаватися")
        )
        // Без перекладів — без тире.
        XCTAssertEqual(
            NotificationText.make(for: .added(entry(translations: []))),
            NotificationContent(title: "Додано", body: "Додано: run")
        )
    }

    func testAddedLimitsToThreeTranslations() {
        XCTAssertEqual(NotificationText.maxTranslations, 3)
        let many = entry(translations: ["бігти", "керувати", "працювати", "балотуватися", "тікати"])
        XCTAssertEqual(
            NotificationText.make(for: .added(many)).body,
            "Додано: run — бігти, керувати, працювати"
        )
        let exactlyThree = entry(translations: ["a", "b", "c"])
        XCTAssertEqual(NotificationText.make(for: .added(exactlyThree)).body, "Додано: run — a, b, c")
    }

    func testDuplicate() {
        XCTAssertEqual(
            NotificationText.make(for: .duplicate(entry(translations: ["бігти"]))),
            NotificationContent(title: "Вже є в словнику", body: "run — бігти")
        )
        XCTAssertEqual(
            NotificationText.make(for: .duplicate(entry(translations: ["1", "2", "3", "4"]))).body,
            "run — 1, 2, 3",
            "duplicate also shows at most three translations"
        )
        for status in [EntryStatus.pending, .failed] {
            XCTAssertEqual(
                NotificationText.make(for: .duplicate(entry(translations: [], status: status))),
                NotificationContent(title: "Вже є в словнику", body: "run — очікує обробки"),
                "\(status)"
            )
        }
    }

    func testQueuedOffline() {
        XCTAssertEqual(
            NotificationText.make(for: .queued(entry(status: .pending), .offline)),
            NotificationContent(title: "Збережено в чергу", body: "run: немає мережі, переклад буде додано пізніше")
        )
    }

    func testQueuedMissingKey() {
        XCTAssertEqual(
            NotificationText.make(for: .queued(entry(status: .pending), .missingAPIKey)),
            NotificationContent(title: "Збережено в чергу", body: "run: додайте API-ключ у налаштуваннях")
        )
    }

    func testQueuedOtherErrors() {
        let errors: [ClaudeError] = [.timeout, .server(status: 500), .server(status: 529),
                                     .rateLimited(retryAfter: 10), .transport("x")]
        for error in errors {
            XCTAssertEqual(
                NotificationText.make(for: .queued(entry(status: .pending), error)),
                NotificationContent(title: "Збережено в чергу", body: "run: повторимо пізніше"),
                "\(error)"
            )
        }
    }

    func testQueuedInFlight() {
        XCTAssertEqual(
            NotificationText.make(for: .queued(entry(status: .pending), nil)),
            NotificationContent(title: "Обробляється", body: "Обробляється: run")
        )
        XCTAssertEqual(
            NotificationText.make(for: .queued(entry("give up", status: .pending), nil)).body,
            "Обробляється: give up"
        )
    }

    func testFailed() {
        XCTAssertEqual(
            NotificationText.make(for: .failed(entry(status: .failed), .unauthorized)),
            NotificationContent(title: "Не вдалося додати", body: "run: Невірний API-ключ (401)")
        )
        XCTAssertEqual(
            NotificationText.make(for: .failed(entry(status: .failed), .badRequest(status: 404, message: "no model"))).body,
            "run: Помилка запиту (404): no model"
        )
        XCTAssertEqual(
            NotificationText.make(for: .failed(entry(status: .failed), .refused)).body,
            "run: \(ClaudeError.refused.userMessage)"
        )
    }

    func testRejectedVariants() {
        let cases: [(SelectionRejection, String)] = [
            (.empty, "Нічого не виділено"),
            (.tooLong(max: 120), "Виділено забагато тексту (макс. 120 символів)"),
            (.tooManyWords(max: 8), "Виділено забагато тексту (макс. 8 слів)"),
            (.noLetters, "Виділений текст не містить слів"),
        ]
        for (rejection, body) in cases {
            let content = NotificationText.make(for: .rejected(rejection))
            XCTAssertEqual(content.body, body, "\(rejection)")
            XCTAssertEqual(content.title, NotificationText.rejectedTitle)
            XCTAssertFalse(content.title.isEmpty)
            XCTAssertEqual(NotificationText.rejectionText(rejection), body)
        }
    }

    func testStorageError() {
        XCTAssertEqual(
            NotificationText.make(for: .storageError("Не вдалося зберегти словник: disk full")),
            NotificationContent(title: "Не вдалося додати", body: "Не вдалося зберегти словник: disk full")
        )
    }

    func testSingleLine() {
        XCTAssertEqual(NotificationContent(title: "Додано", body: "Додано: run — бігти").singleLine, "Додано: run — бігти")
        XCTAssertEqual(NotificationContent(title: "Вже є в словнику", body: "run — бігти").singleLine,
                       "Вже є в словнику: run — бігти")
        XCTAssertEqual(NotificationContent(title: "Нічого", body: "").singleLine, "Нічого")
    }

    func testServiceResponseUsesNotificationText() {
        let outcome = AddWordOutcome.queued(entry(status: .pending), .offline)
        XCTAssertEqual(ServiceResponse(outcome: outcome).notification, NotificationText.make(for: outcome))
        XCTAssertEqual(ServiceResponse(outcome: outcome).outcome, outcome)
    }


    // MARK: - M7: selection language

    private func italianSelection(variantStatus: EntryStatus = .ready) -> Entry {
        var house = entry("house", translations: ["будинок", "дім"])
        house.sourceLanguage = "it"
        house.variants = ["it": EntryVariant(
            word: variantStatus == .ready ? "casa" : nil,
            translations: variantStatus == .ready ? ["дім", "будинок", "оселя", "житло"] : [],
            status: variantStatus,
            sourceKey: "house"
        )]
        return house
    }

    func testAddedItalianUsesItalianRendering() {
        XCTAssertEqual(
            NotificationText.make(for: .added(italianSelection())),
            NotificationContent(title: "Додано", body: "Додано: casa — дім, будинок, оселя")
        )
        // Англійське виділення з італійським варіантом — як раніше (англійською).
        var english = entry("house", translations: ["будинок"])
        english.variants = italianSelection().variants
        XCTAssertEqual(NotificationText.make(for: .added(english)).body, "Додано: house — будинок")
        // Варіант мови виділення не ready → англійське відображення.
        XCTAssertEqual(NotificationText.make(for: .added(italianSelection(variantStatus: .pending))).body,
                       "Додано: house — будинок, дім")
    }

    func testDuplicateItalian() {
        XCTAssertEqual(
            NotificationText.make(for: .duplicate(italianSelection())),
            NotificationContent(title: "Вже є в словнику", body: "casa — дім, будинок, оселя")
        )
        var pending = italianSelection()
        pending.status = .pending
        XCTAssertEqual(NotificationText.make(for: .duplicate(pending)).body, "house — очікує обробки")
    }

    // MARK: - M7: duplicate language by selection (D26)

    /// Англійський запис «house» (`sourceLanguage == nil`) з ready-варіантом it «casa».
    private func englishHouseWithCasa() -> Entry {
        M7.entry(word: "house", translations: ["будинок", "дім"],
                 variants: ["it": M7.readyVariant("casa", sourceWord: "house", translations: ["дім", "оселя"])])
    }

    func testDuplicateBodyFollowsSelectionLanguage() {
        let house = englishHouseWithCasa()
        XCTAssertNil(house.sourceLanguage)

        let italian = NotificationText.make(for: .duplicate(house), selection: "casa")
        XCTAssertEqual(italian.title, "Вже є в словнику")
        XCTAssertTrue(italian.body.hasPrefix("casa —"), italian.body)
        XCTAssertEqual(italian.body, "casa — дім, оселя")
        // Сире виділення (регістр, пунктуація, пробіли) нормалізується так само.
        XCTAssertEqual(NotificationText.make(for: .duplicate(house), selection: "  Casa.\n").body, "casa — дім, оселя")

        let english = NotificationText.make(for: .duplicate(house), selection: "house")
        XCTAssertEqual(english.body, "house — будинок, дім")
        // Без selection — як раніше (мова sourceLanguage == nil → англійська).
        XCTAssertEqual(NotificationText.make(for: .duplicate(house)).body, "house — будинок, дім")
    }

    func testDuplicateLanguageDetection() {
        let house = englishHouseWithCasa()
        XCTAssertEqual(NotificationText.duplicateLanguage(selection: "casa", entry: house), "it")
        XCTAssertNil(NotificationText.duplicateLanguage(selection: "house", entry: house))
        XCTAssertNil(NotificationText.duplicateLanguage(selection: "dog", entry: house))
        XCTAssertNil(NotificationText.duplicateLanguage(selection: "   ", entry: house))

        // Варіант не ready → nil.
        var pending = house
        pending.variants = ["it": M7.unfilledVariant(.pending, sourceWord: "house", word: "casa")]
        XCTAssertNil(NotificationText.duplicateLanguage(selection: "casa", entry: pending))
    }

    func testDuplicateLanguageNilWhenSelectionMatchesEnglishWordToo() {
        // Англійське слово й італійський варіант мають той самий ключ (D25) → англійська.
        let piano = M7.entry(word: "piano", translations: ["фортепіано"],
                             variants: ["it": M7.readyVariant("piano", sourceWord: "piano", translations: ["тихо"])])
        XCTAssertNil(NotificationText.duplicateLanguage(selection: "piano", entry: piano))
        XCTAssertNil(NotificationText.duplicateLanguage(selection: " PIANO! ", entry: piano))
        XCTAssertEqual(NotificationText.make(for: .duplicate(piano), selection: "piano").body, "piano — фортепіано")
    }
}
