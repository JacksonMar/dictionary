import Foundation

/// Порядок записів у головному вікні (§6, M5).
public enum EntrySort: String, CaseIterable, Sendable {
    /// Спершу найновіші (`createdAt` за спаданням).
    case dateNewest
    /// Спершу найстаріші (`createdAt` за зростанням).
    case dateOldest
    /// За алфавітом: `TextNormalizer.key(word)`, тай-брейк — `createdAt` (старіші першими).
    case alphabetical
}

/// Пошук і сортування записів (чиста логіка, §6, M5).
///
/// Пошук: підрядок `searchText` (після trim) без урахування регістру й діакритики
/// (`.caseInsensitive, .diacriticInsensitive`) у `word`, `lemma` або будь-якому з `translations`.
/// Порожній запит → усі записи.
public struct EntryQuery: Equatable, Sendable {
    public var searchText: String
    public var sort: EntrySort

    public init(searchText: String = "", sort: EntrySort = .dateNewest) {
        self.searchText = searchText
        self.sort = sort
    }

    /// Відфільтровані й відсортовані записи.
    public func apply(to entries: [Entry]) -> [Entry] {
        sorted(filtered(entries))
    }

    /// Чи відповідає запис пошуковому запиту.
    public func matches(_ entry: Entry) -> Bool {
        let needle = normalizedSearchText
        guard !needle.isEmpty else { return true }
        if Self.contains(entry.word, needle) {
            return true
        }
        if let lemma = entry.lemma, Self.contains(lemma, needle) {
            return true
        }
        return entry.translations.contains { Self.contains($0, needle) }
    }

    /// `searchText` без крайніх пробілів.
    public var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    private func filtered(_ entries: [Entry]) -> [Entry] {
        guard !normalizedSearchText.isEmpty else { return entries }
        return entries.filter(matches)
    }

    private func sorted(_ entries: [Entry]) -> [Entry] {
        switch sort {
        case .dateNewest:
            return entries.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return Self.alphabeticalOrder(lhs, rhs)
            }
        case .dateOldest:
            return entries.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return Self.alphabeticalOrder(lhs, rhs)
            }
        case .alphabetical:
            // Ключі обчислюються один раз (`clean` не безкоштовний).
            let keyed = entries.map { (key: TextNormalizer.key($0.word), entry: $0) }
            return keyed.sorted { lhs, rhs in
                if lhs.key != rhs.key {
                    return lhs.key < rhs.key
                }
                if lhs.entry.createdAt != rhs.entry.createdAt {
                    return lhs.entry.createdAt < rhs.entry.createdAt
                }
                return lhs.entry.id.uuidString < rhs.entry.id.uuidString
            }
            .map(\.entry)
        }
    }

    /// Тай-брейк для однакових дат: ключ слова, далі `id` (стабільний, детермінований порядок).
    private static func alphabeticalOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let lhsKey = TextNormalizer.key(lhs.word)
        let rhsKey = TextNormalizer.key(rhs.word)
        if lhsKey != rhsKey {
            return lhsKey < rhsKey
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
