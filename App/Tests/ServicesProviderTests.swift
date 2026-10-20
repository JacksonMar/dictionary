import AppKit
import XCTest
import VocabCore
@testable import VocabApp

/// Заглушка `UserNotifier`: запам'ятовує показані сповіщення, нічого не показує.
final class SpyUserNotifier: UserNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [NotificationContent] = []
    private var authorizationRequests = 0

    var posted: [NotificationContent] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    var authorizationRequestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return authorizationRequests
    }

    func requestAuthorization() async -> Bool {
        recordAuthorizationRequest()
        return true
    }

    func post(_ content: NotificationContent) async {
        record(content)
    }

    // Лок — лише в синхронних методах (NSLock недоступний в async-контексті в нових SDK).
    private func recordAuthorizationRequest() {
        lock.lock(); defer { lock.unlock() }
        authorizationRequests += 1
    }

    private func record(_ content: NotificationContent) {
        lock.lock(); defer { lock.unlock() }
        stored.append(content)
    }
}

/// Заглушка `ServiceRequestHandling`: запам'ятовує отриманий текст і повертає заданий outcome.
final class StubServiceRequestHandler: ServiceRequestHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String?] = []
    private let outcome: AddWordOutcome

    init(outcome: AddWordOutcome) {
        self.outcome = outcome
    }

    var receivedTexts: [String?] {
        lock.lock(); defer { lock.unlock() }
        return texts
    }

    func handle(text: String?) async -> ServiceResponse {
        record(text)
        return ServiceResponse(outcome: outcome)
    }

    private func record(_ text: String?) {
        lock.lock(); defer { lock.unlock() }
        texts.append(text)
    }
}

/// M3.4 — обробник Services з тестовим (унікальним) pasteboard; без реальних сповіщень і мережі.
final class ServicesProviderTests: XCTestCase {
    private var pasteboard: NSPasteboard?

    private static let readyEntry: Entry = {
        let date = Date(timeIntervalSince1970: 1_791_885_600)
        return Entry(
            id: UUID(),
            languagePair: "en-uk",
            word: "run",
            lemma: "run",
            partOfSpeech: "verb",
            transcription: "/rʌn/",
            translations: ["бігти", "керувати"],
            example: Example(source: "She runs every morning.", translation: "Вона бігає щоранку."),
            status: .ready,
            lastError: nil,
            createdAt: date,
            updatedAt: date
        )
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        pinInterfaceLanguage(.uk)
        let board = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
        board.clearContents()
        pasteboard = board
    }

    override func tearDown() {
        pasteboard?.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private func currentPasteboard() throws -> NSPasteboard {
        try XCTUnwrap(pasteboard)
    }

    // MARK: - M3.4

    @MainActor
    func testReadsPublicUTF8PlainText() async throws {
        let board = try currentPasteboard()
        XCTAssertTrue(board.setString("run", forType: .string))
        XCTAssertEqual(NSPasteboard.PasteboardType.string.rawValue, "public.utf8-plain-text")
        let handler = StubServiceRequestHandler(outcome: .added(Self.readyEntry))
        let notifier = SpyUserNotifier()
        let provider = ServicesProvider(handler: handler, notifier: notifier)

        var errorMessage: NSString?
        provider.addToDictionary(board, userData: nil, error: &errorMessage)
        let response = await provider.lastTask?.value

        XCTAssertNil(errorMessage, "no error for a valid selection")
        XCTAssertEqual(handler.receivedTexts, ["run"])
        XCTAssertEqual(response?.outcome, .added(Self.readyEntry))
        XCTAssertEqual(notifier.posted, [NotificationContent(title: "Додано", body: "Додано: run — бігти, керувати")])
    }

    @MainActor
    func testSelectionPassedToHandlerUnchangedForCoreCleaning() async throws {
        // Провайдер не чистить текст сам: очищення/trim — у `SelectionValidator` всередині `ServiceRequestHandler`
        // (покрито `ServiceRequestHandlerTests.testNewWordAddedReady`). Сюди передається сирий текст.
        let board = try currentPasteboard()
        XCTAssertTrue(board.setString("  don’t\n", forType: .string))
        let handler = StubServiceRequestHandler(outcome: .added(Self.readyEntry))
        let provider = ServicesProvider(handler: handler, notifier: SpyUserNotifier())

        var errorMessage: NSString?
        provider.addToDictionary(board, userData: nil, error: &errorMessage)
        _ = await provider.lastTask?.value

        XCTAssertNil(errorMessage)
        XCTAssertEqual(handler.receivedTexts, ["  don’t\n"])
        XCTAssertEqual(SelectionValidator.validate(handler.receivedTexts.first ?? nil),
                       .valid(CleanedSelection(text: "don't", key: "don't", kind: .word)),
                       "core cleaning yields the trimmed word")
    }

    @MainActor
    func testReadsLegacyStringType() async throws {
        let board = try currentPasteboard()
        let legacy = NSPasteboard.PasteboardType("NSStringPboardType")
        XCTAssertEqual(ServicesProvider.legacyStringType, legacy)
        board.declareTypes([legacy], owner: nil)
        XCTAssertTrue(board.setString("give up", forType: legacy))
        let handler = StubServiceRequestHandler(outcome: .added(Self.readyEntry))
        let notifier = SpyUserNotifier()
        let provider = ServicesProvider(handler: handler, notifier: notifier)

        var errorMessage: NSString?
        provider.addToDictionary(board, userData: nil, error: &errorMessage)
        _ = await provider.lastTask?.value

        XCTAssertNil(errorMessage)
        XCTAssertEqual(handler.receivedTexts, ["give up"])
        XCTAssertEqual(ServicesProvider.text(from: board), "give up")
        XCTAssertEqual(notifier.posted.count, 1)
    }

    @MainActor
    func testEmptyPasteboardSetsError() async throws {
        let board = try currentPasteboard()
        let handler = StubServiceRequestHandler(outcome: .added(Self.readyEntry))
        let notifier = SpyUserNotifier()
        var responses: [ServiceResponse] = []
        let provider = ServicesProvider(handler: handler, notifier: notifier, onResponse: { responses.append($0) })

        var errorMessage: NSString?
        provider.addToDictionary(board, userData: nil, error: &errorMessage)
        let response = await provider.lastTask?.value

        XCTAssertEqual(errorMessage.map { $0 as String }, "Не вдалося отримати текст")
        XCTAssertEqual(errorMessage.map { $0 as String }, ServicesProvider.noTextErrorMessage)
        XCTAssertEqual(handler.receivedTexts.count, 0, "handler is not called for an empty pasteboard")
        XCTAssertEqual(response?.outcome, .rejected(.empty))
        XCTAssertEqual(notifier.posted.map(\.body), ["Нічого не виділено"])
        XCTAssertEqual(notifier.posted.first, NotificationText.make(for: .rejected(.empty)))
        XCTAssertEqual(responses.map(\.outcome), [.rejected(.empty)])
    }

    @MainActor
    func testWhitespaceOnlyPasteboardSetsError() async throws {
        let board = try currentPasteboard()
        XCTAssertTrue(board.setString(" \n\t ", forType: .string))
        let handler = StubServiceRequestHandler(outcome: .added(Self.readyEntry))
        let notifier = SpyUserNotifier()
        let provider = ServicesProvider(handler: handler, notifier: notifier)

        var errorMessage: NSString?
        provider.addToDictionary(board, userData: nil, error: &errorMessage)
        _ = await provider.lastTask?.value

        XCTAssertEqual(errorMessage.map { $0 as String }, ServicesProvider.noTextErrorMessage)
        XCTAssertEqual(handler.receivedTexts.count, 0)
        XCTAssertEqual(notifier.posted.map(\.body), ["Нічого не виділено"])
    }

    @MainActor
    func testPostsNotificationFromOutcome() async throws {
        let queuedEntry: Entry = {
            var entry = Self.readyEntry
            entry.status = .pending
            entry.translations = []
            return entry
        }()
        let cases: [AddWordOutcome] = [
            .added(Self.readyEntry),
            .duplicate(Self.readyEntry),
            .queued(queuedEntry, .offline),
            .queued(queuedEntry, .missingAPIKey),
            .queued(queuedEntry, nil),
            .failed(queuedEntry, .unauthorized),
            .rejected(.tooLong(max: 120)),
            .storageError("disk full"),
        ]
        for outcome in cases {
            let board = try currentPasteboard()
            board.clearContents()
            XCTAssertTrue(board.setString("run", forType: .string))
            let notifier = SpyUserNotifier()
            var responses: [ServiceResponse] = []
            let provider = ServicesProvider(
                handler: StubServiceRequestHandler(outcome: outcome),
                notifier: notifier,
                onResponse: { responses.append($0) }
            )

            var errorMessage: NSString?
            provider.addToDictionary(board, userData: nil, error: &errorMessage)
            _ = await provider.lastTask?.value

            XCTAssertNil(errorMessage, "\(outcome)")
            XCTAssertEqual(notifier.posted, [NotificationText.make(for: outcome)], "\(outcome)")
            XCTAssertEqual(responses, [ServiceResponse(outcome: outcome)], "\(outcome)")
        }
    }

    @MainActor
    func testPreparationAwaitedBeforeHandling() async throws {
        let board = try currentPasteboard()
        XCTAssertTrue(board.setString("run", forType: .string))
        let handler = StubServiceRequestHandler(outcome: .added(Self.readyEntry))
        var events: [String] = []
        let provider = ServicesProvider(handler: handler, notifier: SpyUserNotifier())
        provider.setPreparation {
            events.append("prepare(handled=\(handler.receivedTexts.count))")
        }

        var errorMessage: NSString?
        provider.addToDictionary(board, userData: nil, error: &errorMessage)
        _ = await provider.lastTask?.value

        XCTAssertEqual(events, ["prepare(handled=0)"], "dictionary load is awaited before the request (U5)")
        XCTAssertEqual(handler.receivedTexts, ["run"])
    }

    @MainActor
    func testRecordServiceResponseUpdatesMenuMessage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabServicesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(applicationSupportDirectory: directory)
        let dates = FixedDateProvider(Date(timeIntervalSince1970: 1_791_885_600))
        let store = FileDictionaryStore(
            fileURL: paths.dictionaryURL,
            fileSystem: LocalFileSystem(),
            dateProvider: dates,
            backups: BackupManager(directory: paths.backupsDirectory, dateProvider: dates)
        )
        let model = AppModel(repository: DictionaryRepository(store: store, dateProvider: dates))
        let board = try currentPasteboard()
        XCTAssertTrue(board.setString("run", forType: .string))
        let provider = ServicesProvider(
            handler: StubServiceRequestHandler(outcome: .added(Self.readyEntry)),
            notifier: SpyUserNotifier(),
            onResponse: { model.recordServiceResponse($0) }
        )

        var errorMessage: NSString?
        provider.addToDictionary(board, userData: nil, error: &errorMessage)
        _ = await provider.lastTask?.value

        XCTAssertEqual(model.lastServiceMessage, "Додано: run — бігти, керувати")
    }

    @MainActor
    func testProviderRespondsToServiceSelector() {
        let provider = ServicesProvider(handler: StubServiceRequestHandler(outcome: .rejected(.empty)),
                                        notifier: SpyUserNotifier())
        XCTAssertTrue(provider.responds(to: NSSelectorFromString("addToDictionary:userData:error:")))
    }
}
