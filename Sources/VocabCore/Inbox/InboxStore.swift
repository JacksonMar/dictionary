import Foundation

/// Результат читання каталогу inbox (`InboxStore.scan()`).
public struct InboxScanResult: Equatable, Sendable {
    /// Придатні елементи, відсортовані за `createdAt` (за рівності — за іменем файлу).
    public var items: [InboxStoredItem]
    /// Биті файли (не JSON / не той формат / інша `version`), перенесені в `Rejected/` під час цього читання.
    public var rejectedFiles: Int
    /// Файли, які не вдалося прочитати або перенести в `Rejected/` (лишилися на місці; спроба — наступного разу).
    public var unreadableFiles: Int

    public init(items: [InboxStoredItem], rejectedFiles: Int = 0, unreadableFiles: Int = 0) {
        self.items = items
        self.rejectedFiles = rejectedFiles
        self.unreadableFiles = unreadableFiles
    }
}

/// Inbox — каталог в App Group, куди Share Extension кладе слова, а застосунок їх забирає (IOS_PLAN DI7, DI9, §3.3).
///
/// Кожен елемент — окремий файл з унікальним ім'ям `<createdAtMs>-<uuid>.json`, тож спільного файлу з кількома
/// писачами немає і `NSFileCoordinator` не потрібен. Запис: `writeData` у `.<uuid>.tmp` (dot-файл — споживач
/// його не бачить) → `moveItem` у фінальне ім'я (ціль не існує, той самий каталог → атомарне перейменування).
/// Збій на будь-якому кроці → tmp видаляється, помилка прокидається. Читач бере лише `*.json` без крапки на початку.
/// Усі операції — через `FileSystem` (ін'єкція збоїв у тестах).
public struct InboxStore: Sendable {
    public static let defaultMaxPendingItems = 200
    /// Підкаталог для битих файлів (не видаляються — для діагностики).
    public static let rejectedDirectoryName = "Rejected"
    static let fileExtension = "json"
    static let temporaryExtension = "tmp"

    public let directory: URL
    public let maxPendingItems: Int
    private let fileSystem: FileSystem

    public init(directory: URL, fileSystem: FileSystem, maxPendingItems: Int = InboxStore.defaultMaxPendingItems) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.maxPendingItems = maxPendingItems
    }

    public var rejectedDirectory: URL {
        directory.appendingPathComponent(Self.rejectedDirectoryName, isDirectory: true)
    }

    /// Кладе елемент у inbox: tmp → `moveItem`. Якщо вже `maxPendingItems` необроблених файлів —
    /// `InboxError.full` (нічого не записано). Інші збої — `InboxError.storage`, tmp-файл прибрано.
    public func enqueue(_ item: InboxItem) throws {
        let data: Data
        do {
            data = try JSONCoding.makeEncoder().encode(item)
        } catch {
            throw InboxError.storage(error.localizedDescription)
        }
        do {
            try fileSystem.createDirectory(at: directory)
        } catch {
            throw InboxError.storage(error.localizedDescription)
        }
        if try pendingFileURLs().count >= maxPendingItems {
            throw InboxError.full
        }

        let temporaryURL = directory.appendingPathComponent(".\(item.id.uuidString).\(Self.temporaryExtension)")
        let finalURL = directory.appendingPathComponent(item.fileName)
        do {
            try fileSystem.writeData(data, to: temporaryURL)
            try fileSystem.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            if fileSystem.fileExists(at: temporaryURL) {
                // Прибирання tmp — найкраща спроба: основна помилка важливіша.
                try? fileSystem.removeItem(at: temporaryURL)
            }
            throw InboxError.storage(error.localizedDescription)
        }
    }

    /// Придатні елементи (`scan().items`). Биті файли переносяться в `Rejected/`.
    public func pendingItems() throws -> [InboxStoredItem] {
        try scan().items
    }

    /// Читає всі `*.json` (не dot-файли, не tmp) каталогу. Немає каталогу → порожньо. Биті файли (не JSON,
    /// інша `version`) → `Rejected/<ім'я>`; файл, який не вдалося прочитати, лишається на місці.
    /// Помилка лише тоді, коли не вдалося прочитати сам каталог.
    public func scan() throws -> InboxScanResult {
        guard fileSystem.fileExists(at: directory) else {
            return InboxScanResult(items: [])
        }
        let urls = try pendingFileURLs()
        let decoder = JSONCoding.makeDecoder()
        var items: [InboxStoredItem] = []
        var rejected = 0
        var unreadable = 0
        for url in urls {
            let data: Data
            do {
                data = try fileSystem.readData(at: url)
            } catch {
                unreadable += 1
                continue
            }
            if let item = try? decoder.decode(InboxItem.self, from: data), item.version == InboxItem.currentVersion {
                items.append(InboxStoredItem(item: item, fileURL: url))
            } else if moveToRejected(url) {
                rejected += 1
            } else {
                unreadable += 1
            }
        }
        items.sort { lhs, rhs in
            if lhs.item.createdAt != rhs.item.createdAt {
                return lhs.item.createdAt < rhs.item.createdAt
            }
            return lhs.fileURL.lastPathComponent < rhs.fileURL.lastPathComponent
        }
        return InboxScanResult(items: items, rejectedFiles: rejected, unreadableFiles: unreadable)
    }

    /// Видаляє файл обробленого елемента; уже відсутній файл — не помилка.
    public func remove(_ item: InboxStoredItem) throws {
        guard fileSystem.fileExists(at: item.fileURL) else { return }
        do {
            try fileSystem.removeItem(at: item.fileURL)
        } catch {
            throw InboxError.storage(error.localizedDescription)
        }
    }

    // MARK: - Private

    /// Файли елементів: `*.json`, ім'я не починається з крапки (tmp і приховані файли ігноруються).
    private func pendingFileURLs() throws -> [URL] {
        let urls: [URL]
        do {
            urls = try fileSystem.contentsOfDirectory(at: directory)
        } catch {
            throw InboxError.storage(error.localizedDescription)
        }
        return urls
            .filter { Self.isItemFileName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func isItemFileName(_ name: String) -> Bool {
        !name.hasPrefix(".") && name.hasSuffix(".\(fileExtension)")
    }

    /// Переносить битий файл у `Rejected/` (за конфлікту імені — з унікальним суфіксом). `false` — не вдалося.
    private func moveToRejected(_ url: URL) -> Bool {
        do {
            try fileSystem.createDirectory(at: rejectedDirectory)
            var destination = rejectedDirectory.appendingPathComponent(url.lastPathComponent)
            if fileSystem.fileExists(at: destination) {
                destination = rejectedDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            }
            try fileSystem.moveItem(at: url, to: destination)
            return true
        } catch {
            return false
        }
    }
}
