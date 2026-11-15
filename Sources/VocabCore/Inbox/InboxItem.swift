import Foundation

/// Звідки прийшов елемент inbox (IOS_PLAN §3.3). Поки що лише Share Extension.
public enum InboxSource: String, Codable, Sendable {
    case share
}

/// Один елемент inbox — слово, яке розширення («Поділитися») поклало для застосунку (IOS_PLAN DI7, DI9, §3.3).
/// Зберігається окремим файлом `<createdAtMs>-<uuid>.json` (`InboxStore`); єдиний споживач — застосунок
/// (`InboxIngestor`). Розширення Claude не викликає й у словник не пише.
public struct InboxItem: Codable, Equatable, Sendable {
    /// Версія формату файлу; інший номер → файл відхиляється (`Rejected/`).
    public static let currentVersion = 1

    public var version: Int
    public var id: UUID
    /// Текст як його віддав лист «Поділитися» (обрізаний до 2000 символів у розширенні); валідація
    /// (`SelectionValidator`) — при інжесті.
    public var text: String
    /// Код мови-підказки (`Entry.languageHint`), якщо джерело його знає; для «Поділитися» — `nil`.
    public var languageHint: String?
    public var source: InboxSource
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        languageHint: String? = nil,
        source: InboxSource = .share,
        createdAt: Date,
        version: Int = InboxItem.currentVersion
    ) {
        self.version = version
        self.id = id
        self.text = text
        self.languageHint = languageHint
        self.source = source
        self.createdAt = createdAt
    }

    /// Мілісекунди від 1970 для імені файлу (сортування за іменем ≈ за часом створення).
    public var createdAtMilliseconds: Int64 {
        Int64((createdAt.timeIntervalSince1970 * 1000).rounded())
    }

    /// Ім'я файлу `<createdAtMs>-<uuid>.json`; унікальне, бо містить `id`.
    public var fileName: String {
        "\(createdAtMilliseconds)-\(id.uuidString).json"
    }
}

/// Елемент inbox, прочитаний з диска, разом із його файлом (для `InboxStore.remove`).
public struct InboxStoredItem: Equatable, Sendable {
    public var item: InboxItem
    public var fileURL: URL

    public init(item: InboxItem, fileURL: URL) {
        self.item = item
        self.fileURL = fileURL
    }
}

/// Помилки inbox.
public enum InboxError: Error, Equatable, Sendable {
    /// Уже `maxPendingItems` необроблених елементів — новий не приймається.
    case full
    /// Помилка файлової системи або кодування; текст — для логів/UI (без вмісту елемента).
    case storage(String)
}
