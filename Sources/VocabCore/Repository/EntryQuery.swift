import Foundation

/// Порядок записів у головному вікні (§6, M5).
public enum EntrySort: String, CaseIterable, Sendable {
    /// Спершу найновіші (`createdAt` за спаданням).
    case dateNewest
    /// Спершу найстаріші (`createdAt` за зростанням).
    case dateOldest
    /// За алфавітом: `TextNormalizer.key(word)`, тай-брейк — `createdAt` (старіші першими).
    case alphabetical

    /// Назва в меню сортування поточною мовою інтерфейсу.
    public var title: String {
        title(in: L10n.current)
    }

    public func title(in language: AppLanguage) -> String {
        switch self {
        case .dateNewest:
            return L10n.text(.sortDateNewest, language: language)
        case .dateOldest:
            return L10n.text(.sortDateOldest, language: language)
        case .alphabetical:
            return L10n.text(.sortAlphabetical, language: language)
        }
    }
}

/// Пошук і сортування записів (чиста логіка, §6, M5).
///
/// Пошук: підрядок `searchText` (після trim) без урахування регістру й діакритики
/// (`.caseInsensitive, .diacriticInsensitive`) у `word`, `lemma` або будь-якому з `translations`.
/// Порожній запит → усі записи.
///
/// M7: `languageID` — активна мова відображення (`nil` = мова джерела). Пошук і алфавіт працюють по
/// `EntryDisplay.make(entry, languageID:)`; для fallback-рядків (варіант не ready) пошук — по англійських
/// `word`/`lemma`/`translations`, щоб запис не «зникав».
public struct EntryQuery: Equatable, Sendable {
    public var searchText: String
    public var sort: EntrySort
    public var languageID: String?

    public init(searchText: String = "", sort: EntrySort = .dateNewest, languageID: String? = nil) {
        self.searchText = searchText
        self.sort = sort
        self.languageID = languageID
    }

    /// Відфільтровані й відсортовані записи.
    public func apply(to entries: [Entry]) -> [Entry] {
        sorted(filtered(entries))
    }

    /// Чи відповідає запис пошуковому запиту.
    public func matches(_ entry: Entry) -> Bool {
        let needle = normalizedSearchText
        guard !needle.isEmpty else { return true }
        let display = EntryDisplay.make(entry, languageID: languageID)
        let word = display.isFallback ? entry.word : display.word
        let lemma = display.isFallback ? entry.lemma : display.lemma
        let translations = display.isFallback ? entry.translations : display.translations
        if Self.contains(word, needle) {
            return true
        }
        if let lemma, Self.contains(lemma, needle) {
            return true
        }
        return translations.contains { Self.contains($0, needle) }
    }

    /// Слово, за яким сортується запис в активній мові.
    private func sortWord(_ entry: Entry) -> String {
        EntryDisplay.make(entry, languageID: languageID).word
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
                return alphabeticalOrder(lhs, rhs)
            }
        case .dateOldest:
            return entries.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return alphabeticalOrder(lhs, rhs)
            }
        case .alphabetical:
            // Ключі обчислюються один раз (`clean` не безкоштовний).
            let keyed = entries.map { (key: TextNormalizer.key(sortWord($0)), entry: $0) }
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
    private func alphabeticalOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let lhsKey = TextNormalizer.key(sortWord(lhs))
        let rhsKey = TextNormalizer.key(sortWord(rhs))
        if lhsKey != rhsKey {
            return lhsKey < rhsKey
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
