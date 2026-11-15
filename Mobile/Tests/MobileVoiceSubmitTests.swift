// I2b token check (IOS_PLAN DI13, §8): «Add» after voice = `MobileAppModel.submitVoiceWord` → exactly 1 request for a
// new word with the language-hint sentence in the same system prompt; a duplicate = 0 requests. Real stack:
// `AppContainer` → `URLSessionTransport` with `MockURLProtocol` → `ClaudeLookupService` → queue → `AddWordUseCase`.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import VocabCore
@testable import VocabMobile

final class MobileVoiceSubmitTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private static func hintSentence(name: String, code: String) -> String {
        "The user stated the text is \(name); set source_language to \"\(code)\" unless the text is clearly not \(name)."
    }

    /// Italian «come» → top level `how`, Italian variant `come`.
    private static let comeItalianJSON: String = {
        var top = MobileClaudeFixtures.object(word: "how", translations: ["як"])
        top["source_language"] = "it"
        top["variants"] = ["it": MobileClaudeFixtures.object(word: "come", translations: ["як"])]
        return MobileClaudeFixtures.jsonString(top)
    }()

    private static func systemText(_ request: MockURLProtocol.RecordedRequest) -> String {
        let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        return object?["system"] as? String ?? ""
    }

    private static func userText(_ request: MockURLProtocol.RecordedRequest) -> String {
        let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        let messages = object?["messages"] as? [[String: Any]]
        if let content = messages?.first?["content"] as? String {
            return content
        }
        let blocks = messages?.first?["content"] as? [[String: Any]]
        return blocks?.compactMap { $0["text"] as? String }.joined() ?? ""
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    @MainActor
    private func makeModel(
        entries: [Entry] = [],
        directory: URL,
        recognizer: FakeSpeechRecognizer? = nil,
        voiceStore: VoiceLanguageStoring = InMemoryVoiceLanguageStore()
    ) async throws -> MobileAppModel {
        if !entries.isEmpty {
            try writeDictionary(entries, to: directory)
        }
        let container = AppContainer(
            paths: AppPaths(applicationSupportDirectory: directory),
            settings: InMemorySettingsStore(),
            secrets: InMemorySecretStore(values: [.anthropicAPIKey: MobileClaudeFixtures.apiKey]),
            transport: URLSessionTransport(session: MockURLProtocol.makeSession()),
            speechRecognizer: recognizer,
            voiceLanguageStore: voiceStore
        )
        let model = MobileAppModel(container: container)
        await model.start()
        XCTAssertTrue(model.isLoaded)
        return model
    }

    @MainActor
    func testSubmitVoiceWordNewWordMakesOneRequestWithHint() async throws {
        let directory = makeTemporaryDirectory(self)
        let model = try await makeModel(directory: directory)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(Self.comeItalianJSON)])

        let outcome = await model.submitVoiceWord("come", languageHint: "it")

        guard case .added(let entry) = outcome else { return XCTFail("expected .added, got \(outcome)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "new word → exactly one request")
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        let system = Self.systemText(request)
        let italianHint = Self.hintSentence(name: "Italian", code: "it")
        XCTAssertEqual(Self.occurrences(of: italianHint, in: system), 1, "hint sentence once, in the system prompt")
        XCTAssertTrue(system.hasSuffix(italianHint))
        XCTAssertFalse(Self.userText(request).contains("The user stated"), "the user message is unchanged")
        XCTAssertEqual(entry.sourceLanguage, "it")
        XCTAssertEqual(entry.variants?["it"]?.word, "come")
        XCTAssertNil(entry.languageHint, "hint cleared once ready")
        XCTAssertEqual(model.entry(id: entry.id)?.status, .ready, "list refreshed after the await")
        XCTAssertNil(model.operationError, "the voice card shows the result, not the list alert")

        let runner = try XCTUnwrap(model.container.backgroundTasks as? NoopBackgroundTaskRunner)
        XCTAssertTrue(runner.startedNames.contains("VocabAddVoiceWord"))
        XCTAssertTrue(runner.activeTokens.isEmpty)

        // Same word spoken again → duplicate, 0 requests.
        let again = await model.submitVoiceWord("come", languageHint: "it")
        guard case .duplicate(let existing) = again else { return XCTFail("expected .duplicate, got \(again)") }
        XCTAssertEqual(existing.id, entry.id)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)

        // English hint for an English word: the English sentence, one more request.
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])
        let house = await model.submitVoiceWord("house", languageHint: "en")
        guard case .added = house else { return XCTFail("expected .added, got \(house)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
        let englishSystem = Self.systemText(MockURLProtocol.requests[1])
        XCTAssertEqual(Self.occurrences(of: Self.hintSentence(name: "English", code: "en"), in: englishSystem), 1)
        XCTAssertFalse(englishSystem.contains(italianHint))
    }

    @MainActor
    func testSubmitVoiceWordDuplicateMakesNoRequest() async throws {
        let directory = makeTemporaryDirectory(self)
        let house = makeTestEntry(
            "house",
            translations: ["будинок"],
            createdOffset: 0,
            variants: ["it": EntryVariant(word: "casa", translations: ["дім"], status: .ready,
                                          sourceKey: TextNormalizer.key("house"))]
        )
        let model = try await makeModel(entries: [house], directory: directory)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])

        for (text, hint) in [("casa", "it"), ("House", "en"), (" house ", "it"), ("Casa", "en")] {
            let outcome = await model.submitVoiceWord(text, languageHint: hint)
            guard case .duplicate(let existing) = outcome else {
                XCTFail("\(text)/\(hint): expected .duplicate, got \(outcome)")
                continue
            }
            XCTAssertEqual(existing.id, house.id)
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "duplicates never reach Claude")
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertNil(model.entries.first?.languageHint, "a duplicate does not write the hint anywhere")

        // Rejected text (empty after trim) — 0 requests.
        let rejected = await model.submitVoiceWord("   ", languageHint: "it")
        if case .rejected(.empty) = rejected {} else { XCTFail("expected .rejected(.empty), got \(rejected)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    @MainActor
    func testVoiceFlowEndToEndOneRequestThenDuplicate() async throws {
        let directory = makeTemporaryDirectory(self)
        let recognizer = FakeSpeechRecognizer()
        let store = InMemoryVoiceLanguageStore(voiceLanguage: .italian)
        let model = try await makeModel(directory: directory, recognizer: recognizer, voiceStore: store)
        XCTAssertEqual(model.voiceLanguage, .italian)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(Self.comeItalianJSON)])

        let voice = model.makeVoiceCaptureModel(scheduler: ManualVoiceScheduler())
        XCTAssertEqual(voice.language, .italian)
        await voice.toggleListening()
        XCTAssertEqual(recognizer.startCalls.last, .init(locale: "it-IT", onDevice: true))
        recognizer.emit(.final(RecognitionTranscript(text: "come", confidence: 0.99)))
        await waitUntil { voice.phase == .recognized }
        await settleMainActor()
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "no request before «Add» (iU15)")

        await voice.submit()
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        guard case .result(let result) = voice.phase else { return XCTFail("expected .result, got \(voice.phase)") }
        XCTAssertFalse(result.isFailure)
        if case .added = result.outcome {} else { XCTFail("expected .added, got \(result.outcome)") }
        XCTAssertEqual(model.entries.count, 1)

        // «Again» → the same word → duplicate card, still 1 request.
        await voice.again()
        recognizer.emit(.final(RecognitionTranscript(text: "come")))
        await waitUntil { voice.phase == .recognized }
        await voice.submit()
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        guard case .result(let duplicate) = voice.phase else { return XCTFail("expected .result, got \(voice.phase)") }
        if case .duplicate = duplicate.outcome {} else { XCTFail("expected .duplicate, got \(duplicate.outcome)") }

        // Settings and the mic toggle share one value.
        voice.selectLanguage(.english)
        model.refreshVoiceLanguage()
        XCTAssertEqual(model.voiceLanguage, .english)
        model.setVoiceLanguage(.italian)
        XCTAssertEqual(store.voiceLanguage, .italian)
        XCTAssertEqual(model.makeVoiceCaptureModel(scheduler: ManualVoiceScheduler()).language, .italian)
    }
}
