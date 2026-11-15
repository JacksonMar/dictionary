import Foundation
import XCTest
@testable import VocabCore

/// `FileSystem` поверх `LocalFileSystem`, що записує кожну операцію з її URL-ами і вміє ін'єктувати збої
/// (зокрема `removeItem`, якого не вміє `FailingFileSystem`). Для I3 (IOS_PLAN §3.3, DI9).
final class RecordingInboxFileSystem: FileSystem, @unchecked Sendable {
    enum Operation: Hashable {
        case readData, writeData, replaceItem, moveItem, copyItem, removeItem, createDirectory, contentsOfDirectory
    }

    struct Call: Equatable {
        let operation: Operation
        let urls: [URL]
    }

    struct InjectedError: Error, Equatable {
        let operation: Operation
    }

    private let base = LocalFileSystem()
    private let lock = NSLock()
    private var failing: Set<Operation> = []
    private var recorded: [Call] = []
    /// Колбек перед виконанням операції (поза замком) — щоб, напр., дописати файл посеред проходу.
    private var hook: (@Sendable (Operation, [URL]) -> Void)?

    func fail(_ operation: Operation) {
        lock.lock(); defer { lock.unlock() }
        failing.insert(operation)
    }

    func stopFailing() {
        lock.lock(); defer { lock.unlock() }
        failing.removeAll()
    }

    func setHook(_ newHook: (@Sendable (Operation, [URL]) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        hook = newHook
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func calls(_ operation: Operation) -> [Call] {
        calls.filter { $0.operation == operation }
    }

    func resetCalls() {
        lock.lock(); defer { lock.unlock() }
        recorded = []
    }

    private func check(_ operation: Operation, _ urls: [URL]) throws {
        lock.lock()
        recorded.append(Call(operation: operation, urls: urls))
        let shouldFail = failing.contains(operation)
        let currentHook = hook
        lock.unlock()
        currentHook?(operation, urls)
        if shouldFail {
            throw InjectedError(operation: operation)
        }
    }

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }

    func readData(at url: URL) throws -> Data {
        try check(.readData, [url])
        return try base.readData(at: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try check(.writeData, [url])
        try base.writeData(data, to: url)
    }

    func replaceItem(at target: URL, withItemAt temp: URL) throws {
        try check(.replaceItem, [target, temp])
        try base.replaceItem(at: target, withItemAt: temp)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try check(.moveItem, [source, destination])
        try base.moveItem(at: source, to: destination)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try check(.copyItem, [source, destination])
        try base.copyItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try check(.removeItem, [url])
        try base.removeItem(at: url)
    }

    func createDirectory(at url: URL) throws {
        try check(.createDirectory, [url])
        try base.createDirectory(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try check(.contentsOfDirectory, [url])
        return try base.contentsOfDirectory(at: url)
    }
}

/// Тимчасовий каталог inbox + сховище над `RecordingInboxFileSystem`.
struct InboxFixture {
    let root: TemporaryDirectory
    let fileSystem: RecordingInboxFileSystem
    let store: InboxStore

    init(maxPendingItems: Int = InboxStore.defaultMaxPendingItems) throws {
        root = try TemporaryDirectory()
        fileSystem = RecordingInboxFileSystem()
        store = InboxStore(
            directory: root.url.appendingPathComponent("Inbox", isDirectory: true),
            fileSystem: fileSystem,
            maxPendingItems: maxPendingItems
        )
    }

    var directory: URL { store.directory }

    /// Імена в каталозі inbox (включно з прихованими і `Rejected`); немає каталогу → порожньо.
    func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    func rejectedNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.rejectedDirectory.path)) ?? []).sorted()
    }

    func writeRaw(_ data: Data, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name))
    }

    func remove() {
        root.remove()
    }
}

enum InboxTestData {
    static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", suffix)) ?? UUID()
    }

    static func item(_ text: String, id suffix: Int, at seconds: TimeInterval, hint: String? = nil) -> InboxItem {
        InboxItem(id: id(suffix), text: text, languageHint: hint, source: .share,
                  createdAt: TestDates.reference.addingTimeInterval(seconds))
    }
}

/// I3.1 (IOS_PLAN §3.3, DI9): атомарний inbox — tmp-файл → `moveItem` в унікальне ім'я, читач бачить лише `*.json`,
/// биті файли → `Rejected/`, переповнення → `InboxError.full`.
final class InboxStoreTests: XCTestCase {
    private var fixture: InboxFixture?

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        super.tearDown()
    }

    private func makeFixture(maxPendingItems: Int = InboxStore.defaultMaxPendingItems) throws -> InboxFixture {
        let made = try InboxFixture(maxPendingItems: maxPendingItems)
        fixture = made
        return made
    }

    // MARK: - I3.1 required

    func testEnqueueWritesTempThenMovesToUniqueName() throws {
        let fixture = try makeFixture()
        // Ціла секунда: формат дат JSON (ISO 8601) зберігає секунди, тож елемент декодується рівно таким самим.
        let item = InboxTestData.item("serendipity", id: 1, at: 2)

        try fixture.store.enqueue(item)

        // Порядок: запис лише у прихований tmp, далі одна `moveItem` у фінальне ім'я.
        let writes = fixture.fileSystem.calls(.writeData)
        XCTAssertEqual(writes.count, 1)
        let tempURL = try XCTUnwrap(writes.first?.urls.first)
        XCTAssertEqual(tempURL.deletingLastPathComponent().standardizedFileURL.path,
                       fixture.directory.standardizedFileURL.path, "tmp in the same directory → atomic rename")
        XCTAssertTrue(tempURL.lastPathComponent.hasPrefix("."), "tmp is a dot-file: \(tempURL.lastPathComponent)")
        XCTAssertTrue(tempURL.lastPathComponent.hasSuffix(".tmp"))
        XCTAssertFalse(InboxStore.isItemFileName(tempURL.lastPathComponent))

        let moves = fixture.fileSystem.calls(.moveItem)
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves.first?.urls.first, tempURL)
        let finalURL = try XCTUnwrap(moves.first?.urls.last)
        let expectedMs = Int64((TestDates.reference.timeIntervalSince1970 + 2) * 1000)
        XCTAssertEqual(finalURL.lastPathComponent, item.fileName)
        XCTAssertEqual(item.fileName, "\(expectedMs)-\(InboxTestData.id(1).uuidString).json")
        XCTAssertEqual(finalURL.deletingLastPathComponent().standardizedFileURL.path,
                       fixture.directory.standardizedFileURL.path)
        let operations = fixture.fileSystem.calls.map(\.operation)
        let writeIndex = try XCTUnwrap(operations.firstIndex(of: .writeData))
        let moveIndex = try XCTUnwrap(operations.firstIndex(of: .moveItem))
        XCTAssertLessThan(writeIndex, moveIndex)
        XCTAssertTrue(fixture.fileSystem.calls(.replaceItem).isEmpty, "rename into a new unique name, not replace")

        // На диску — лише фінальний файл, tmp прибрано; вміст декодується назад у той самий елемент.
        XCTAssertEqual(fixture.names(), [item.fileName])
        let data = try Data(contentsOf: finalURL)
        XCTAssertEqual(try JSONCoding.makeDecoder().decode(InboxItem.self, from: data), item)
        XCTAssertEqual(try fixture.store.pendingItems().map(\.item), [item])

        // Два елементи з тим самим часом — різні імена (uuid), жоден не перезаписує інший.
        let twin = InboxTestData.item("serendipity", id: 2, at: 2)
        try fixture.store.enqueue(twin)
        XCTAssertNotEqual(twin.fileName, item.fileName)
        XCTAssertEqual(Set(fixture.names()), [item.fileName, twin.fileName])
        XCTAssertEqual(try fixture.store.pendingItems().count, 2)
    }

    func testTempAndDotFilesIgnored() throws {
        let fixture = try makeFixture()
        let item = InboxTestData.item("run", id: 1, at: 0)
        try fixture.store.enqueue(item)
        let valid = try JSONCoding.makeEncoder().encode(InboxTestData.item("walk", id: 2, at: 1))

        // tmp від незавершеного запису розширення, прихований .json, інші розширення — невидимі для читача.
        try fixture.writeRaw(valid, name: ".\(InboxTestData.id(2).uuidString).tmp")
        try fixture.writeRaw(valid, name: ".hidden.json")
        try fixture.writeRaw(valid, name: "1000-\(InboxTestData.id(3).uuidString).json.tmp")
        try fixture.writeRaw(valid, name: "notes.txt")
        try fixture.writeRaw(Data("garbage".utf8), name: ".DS_Store")

        let scan = try fixture.store.scan()

        XCTAssertEqual(scan.items.map(\.item), [item])
        XCTAssertEqual(scan.rejectedFiles, 0, "ignored files are not 'corrupt'")
        XCTAssertEqual(scan.unreadableFiles, 0)
        XCTAssertTrue(fixture.rejectedNames().isEmpty, "ignored files are left alone")
        XCTAssertTrue(fixture.names().contains(".\(InboxTestData.id(2).uuidString).tmp"))
        XCTAssertTrue(fixture.names().contains(".DS_Store"))

        // Ліміт `maxPendingItems` теж рахує лише елементи, а не tmp/приховані файли.
        let small = InboxStore(directory: fixture.directory, fileSystem: fixture.fileSystem, maxPendingItems: 2)
        XCTAssertNoThrow(try small.enqueue(InboxTestData.item("swim", id: 4, at: 2)))

        // Немає каталогу → порожньо, без помилки.
        let missing = InboxStore(directory: fixture.root.url.appendingPathComponent("Nope"), fileSystem: fixture.fileSystem)
        XCTAssertEqual(try missing.scan(), InboxScanResult(items: []))
    }

    func testFailedMoveRemovesTemp() throws {
        let fixture = try makeFixture()
        fixture.fileSystem.fail(.moveItem)

        XCTAssertThrowsError(try fixture.store.enqueue(InboxTestData.item("run", id: 1, at: 0))) { error in
            guard case InboxError.storage = error else { return XCTFail("expected .storage, got \(error)") }
        }

        let tempURL = try XCTUnwrap(fixture.fileSystem.calls(.writeData).first?.urls.first)
        XCTAssertEqual(fixture.fileSystem.calls(.removeItem).map(\.urls), [[tempURL]], "tmp removed after failed move")
        XCTAssertTrue(fixture.names().isEmpty, "no tmp and no final file left: \(fixture.names())")
        XCTAssertTrue(try fixture.store.pendingItems().isEmpty)

        // Збій запису tmp → теж `.storage`, нічого не лишилось.
        fixture.fileSystem.stopFailing()
        fixture.fileSystem.fail(.writeData)
        XCTAssertThrowsError(try fixture.store.enqueue(InboxTestData.item("run", id: 2, at: 0))) { error in
            guard case InboxError.storage = error else { return XCTFail("expected .storage, got \(error)") }
        }
        XCTAssertTrue(fixture.names().isEmpty)

        // Після відновлення — звичайний запис.
        fixture.fileSystem.stopFailing()
        try fixture.store.enqueue(InboxTestData.item("run", id: 3, at: 0))
        XCTAssertEqual(try fixture.store.pendingItems().count, 1)
    }

    func testItemsSortedByCreatedAt() throws {
        let fixture = try makeFixture()
        // Порядок запису не збігається з часом; один елемент — до 2001 р. (ім'я коротше, лексикографічно «більше»)
        // — сортування саме за `createdAt`, а не за іменем файлу.
        let late = InboxTestData.item("late", id: 1, at: 300)
        let early = InboxTestData.item("early", id: 2, at: -100)
        let middle = InboxTestData.item("middle", id: 3, at: 5)
        let ancient = InboxItem(id: InboxTestData.id(4), text: "ancient", createdAt: Date(timeIntervalSince1970: 999))
        let tieB = InboxTestData.item("tie-b", id: 9, at: 50)
        let tieA = InboxTestData.item("tie-a", id: 8, at: 50)
        // Кілька «Поділитися» в межах однієї секунди: у JSON лишаються секунди, порядок дає ім'я `<ms>-…`.
        let quick2 = InboxTestData.item("quick-2", id: 11, at: 100.9)
        let quick1 = InboxTestData.item("quick-1", id: 10, at: 100.1)
        for item in [late, early, middle, ancient, tieB, tieA, quick2, quick1] {
            try fixture.store.enqueue(item)
        }
        XCTAssertGreaterThan(ancient.fileName, early.fileName, "precondition: name order differs from time order")

        let items = try fixture.store.pendingItems().map(\.item)

        XCTAssertEqual(items.map(\.text), ["ancient", "early", "middle", "tie-a", "tie-b", "quick-1", "quick-2", "late"])
        // Кожен `InboxStoredItem` вказує на свій файл (ім'я містить id; мілісекунди в імені точніші за секунди JSON).
        for stored in try fixture.store.pendingItems() {
            XCTAssertTrue(stored.fileURL.lastPathComponent.hasSuffix("-\(stored.item.id.uuidString).json"))
        }
    }

    func testCorruptFileMovedToRejected() throws {
        let fixture = try makeFixture()
        let good = InboxTestData.item("run", id: 1, at: 0)
        try fixture.store.enqueue(good)
        var future = InboxTestData.item("walk", id: 2, at: 1)
        future.version = 2
        try fixture.writeRaw(Data("not json {".utf8), name: "1-garbage.json")
        try fixture.writeRaw(Data(#"{"text":"run"}"#.utf8), name: "2-missing-fields.json")
        try fixture.writeRaw(try JSONCoding.makeEncoder().encode(future), name: future.fileName)
        // Конфлікт імені в `Rejected/` — не перезаписується, а отримує унікальне ім'я.
        try FileManager.default.createDirectory(at: fixture.store.rejectedDirectory, withIntermediateDirectories: true)
        try Data("older".utf8).write(to: fixture.store.rejectedDirectory.appendingPathComponent("1-garbage.json"))

        let scan = try fixture.store.scan()

        XCTAssertEqual(scan.items.map(\.item), [good])
        XCTAssertEqual(scan.rejectedFiles, 3)
        XCTAssertEqual(scan.unreadableFiles, 0)
        XCTAssertEqual(fixture.names().filter { $0.hasSuffix(".json") }, [good.fileName], "corrupt files left the inbox")
        let rejected = fixture.rejectedNames()
        XCTAssertEqual(rejected.count, 4, "\(rejected)")
        XCTAssertTrue(rejected.contains("2-missing-fields.json"))
        XCTAssertTrue(rejected.contains(future.fileName))
        XCTAssertEqual(rejected.filter { $0.hasSuffix("1-garbage.json") }.count, 2)
        XCTAssertEqual(
            try Data(contentsOf: fixture.store.rejectedDirectory.appendingPathComponent("1-garbage.json")),
            Data("older".utf8), "existing rejected file not overwritten"
        )

        // Повторне читання: `Rejected/` (підкаталог) не сканується, лічильник не росте.
        let again = try fixture.store.scan()
        XCTAssertEqual(again.items.map(\.item), [good])
        XCTAssertEqual(again.rejectedFiles, 0)

        // Нечитабельний файл (збій readData) лишається на місці й рахується як unreadable.
        fixture.fileSystem.fail(.readData)
        let failing = try fixture.store.scan()
        XCTAssertEqual(failing.items, [])
        XCTAssertEqual(failing.unreadableFiles, 1)
        XCTAssertEqual(failing.rejectedFiles, 0)
        XCTAssertTrue(fixture.names().contains(good.fileName))
    }

    func testFullInboxThrows() throws {
        let fixture = try makeFixture(maxPendingItems: 3)
        for index in 1...3 {
            try fixture.store.enqueue(InboxTestData.item("word\(index)", id: index, at: TimeInterval(index)))
        }
        fixture.fileSystem.resetCalls()

        XCTAssertThrowsError(try fixture.store.enqueue(InboxTestData.item("word4", id: 4, at: 4))) { error in
            XCTAssertEqual(error as? InboxError, .full)
        }
        XCTAssertTrue(fixture.fileSystem.calls(.writeData).isEmpty, "nothing written when full")
        XCTAssertEqual(fixture.names().count, 3)
        XCTAssertEqual(try fixture.store.pendingItems().count, 3)

        // Після того, як застосунок забрав елемент, місце звільняється.
        let first = try XCTUnwrap(try fixture.store.pendingItems().first)
        try fixture.store.remove(first)
        XCTAssertNoThrow(try fixture.store.enqueue(InboxTestData.item("word4", id: 4, at: 4)))
        XCTAssertEqual(try fixture.store.pendingItems().map(\.item.text), ["word2", "word3", "word4"])

        // Видалення вже відсутнього файлу — не помилка.
        XCTAssertNoThrow(try fixture.store.remove(first))
        XCTAssertEqual(InboxStore.defaultMaxPendingItems, 200)
    }
}
