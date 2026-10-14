import Foundation

/// Посторінковий показ записів (§6, M6). Чиста логіка; сторінки нумеруються з 1.
///
/// Порядок застосування: `EntryQuery.apply(to:)` (пошук і сортування по всьому словнику) → `page(_:of:)`.
public struct Pagination: Equatable, Sendable {
    /// Допустимі розміри сторінки (Settings → «Вигляд»).
    public static let pageSizeOptions = [20, 25, 30]
    /// Розмір сторінки за замовчуванням (D18).
    public static let defaultPageSize = 25

    /// Розмір сторінки; завжди одне з `pageSizeOptions`.
    public let pageSize: Int

    /// Значення поза `pageSizeOptions` → `defaultPageSize`.
    public init(pageSize: Int = Pagination.defaultPageSize) {
        self.pageSize = Self.normalizedPageSize(pageSize)
    }

    /// `pageSize`, якщо воно серед `pageSizeOptions`, інакше `defaultPageSize`.
    public static func normalizedPageSize(_ pageSize: Int) -> Int {
        pageSizeOptions.contains(pageSize) ? pageSize : defaultPageSize
    }

    /// Кількість сторінок: `max(1, ceil(total / pageSize))`; 0 записів → 1 сторінка.
    public func pageCount(totalCount: Int) -> Int {
        guard totalCount > 0 else { return 1 }
        return (totalCount + pageSize - 1) / pageSize
    }

    /// Номер сторінки в межах `1...pageCount` (≤ 0 → 1, більше за останню → остання).
    public func clamp(_ page: Int, totalCount: Int) -> Int {
        min(max(page, 1), pageCount(totalCount: totalCount))
    }

    /// Сторінка `number` (спершу обмежується `clamp`) з уже відфільтрованих і відсортованих записів.
    public func page(_ number: Int, of entries: [Entry]) -> EntryPage {
        let total = entries.count
        let count = pageCount(totalCount: total)
        let current = clamp(number, totalCount: total)
        let start = (current - 1) * pageSize
        let end = min(start + pageSize, total)
        let slice = start < end ? Array(entries[start..<end]) : []
        return EntryPage(entries: slice, number: current, pageCount: count, totalCount: total)
    }
}

/// Одна сторінка записів (§6, M6).
public struct EntryPage: Equatable, Sendable {
    public let entries: [Entry]
    /// Номер сторінки (з 1).
    public let number: Int
    /// Загальна кількість сторінок (≥ 1).
    public let pageCount: Int
    /// Загальна кількість записів (після пошуку).
    public let totalCount: Int

    public init(entries: [Entry], number: Int, pageCount: Int, totalCount: Int) {
        self.entries = entries
        self.number = number
        self.pageCount = pageCount
        self.totalCount = totalCount
    }

    public var hasPrevious: Bool {
        number > 1
    }

    public var hasNext: Bool {
        number < pageCount
    }

    /// «Сторінка 2 з 5».
    public var label: String {
        "Сторінка \(number) з \(pageCount)"
    }
}
