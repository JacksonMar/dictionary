import Foundation
import VocabCore
#if canImport(Combine)
import Combine
#endif

/// Міст між ядром і SwiftUI на iOS (IOS_PLAN DI5, §4): той самий `DictionaryRepository` і `EntryQuery`, що й на
/// macOS, без AppKit-логіки `AppModel`. I1a — лише читання: завантаження, пошук, сортування, мова відображення
/// EN | IT. Додавання/редагування/Claude — I1b. Усі `@Published` змінюються лише на головному акторі.
@MainActor
final class MobileAppModel: ObservableObject {
    /// Усі записи словника (останній знімок репозиторію, без фільтра).
    @Published private(set) var entries: [Entry] = []
    /// Словник успішно завантажено.
    @Published private(set) var isLoaded = false
    /// Фатальна помилка завантаження (напр. новіша схема) — словник недоступний.
    @Published private(set) var loadError: String?
    /// Попередження після завантаження (зіпсований файл перенесено в Backups, D12).
    @Published var loadWarning: String?
    /// Текст `.searchable` (D19: пошук по слову, лемі, перекладах — `EntryQuery`).
    @Published var searchText: String = ""
    /// Порядок списку.
    @Published var sort: EntrySort = .dateNewest
    /// Активна мова відображення (`"it"`); `nil` = мова джерела пари («EN»). Зберігається в налаштуваннях.
    @Published private(set) var displayLanguageID: String?

    let container: AppContainer
    /// Підписка на знімки репозиторію (для тестів — щоб перевірити, що вона одна).
    private(set) var changesTask: Task<Void, Never>?

    init(container: AppContainer) {
        self.container = container
        // Збережений режим перевіряється для поточної пари; невідомий → мова джерела (як macOS M7).
        let pair = container.registry.pair(id: container.settings.languagePairID)
        let stored = container.settings.displayLanguageID
        self.displayLanguageID = Self.validatedLanguageID(stored, pair: pair)
    }

    // MARK: - Завантаження

    /// Завантажує словник через single-flight `AppContainer.ensureLoaded()` і підписується на зміни репозиторію.
    /// Повторні виклики (повторний `.task`, повернення на передній план) нічого не дублюють.
    func start() async {
        let outcome = await container.ensureLoaded()
        guard !isLoaded else { return }
        switch outcome {
        case .failed(let message):
            loadError = message
        case .loaded(let recoveredBackupURL):
            loadError = nil
            isLoaded = true
            if let recoveredBackupURL {
                loadWarning = L10n.text(.modelLoadRecovered, ["path": recoveredBackupURL.path])
            }
            entries = await container.repository.allEntries()
            subscribeToChanges()
        }
    }

    private func subscribeToChanges() {
        guard changesTask == nil else { return }
        let repository = container.repository
        changesTask = Task<Void, Never> { @MainActor [weak self] in
            let stream = await repository.changes()
            for await snapshot in stream {
                guard let self else { return }
                self.entries = snapshot
            }
        }
    }

    // MARK: - Пошук і сортування (`EntryQuery`)

    /// Поточний запит списку.
    var query: EntryQuery {
        EntryQuery(searchText: searchText, sort: sort, languageID: displayLanguageID)
    }

    /// Відфільтровані й відсортовані записи в активній мові відображення (DI16: весь результат, без сторінок).
    var visibleEntries: [EntryDisplay] {
        let languageID = displayLanguageID
        return query.apply(to: entries).map { entry in
            EntryDisplay.make(entry, languageID: languageID)
        }
    }

    /// Рядки списку (текст і бейджі вже обчислені мовою інтерфейсу).
    var visibleRows: [EntryRowContent] {
        let rendering = activeRendering
        return visibleEntries.map { display in
            EntryRowContent.make(display, rendering: rendering)
        }
    }

    /// Порожній стан: словник завантажено, записів немає.
    var isDictionaryEmpty: Bool {
        isLoaded && entries.isEmpty
    }

    /// Пошук нічого не знайшов (записи є).
    var hasNoSearchResults: Bool {
        isLoaded && !entries.isEmpty && !entries.contains { query.matches($0) }
    }

    // MARK: - Мова відображення (EN | IT)

    /// Пара нових записів (з налаштувань).
    var currentPair: LanguagePair? {
        container.registry.pair(id: container.settings.languagePairID)
    }

    /// Мови відображення пари; порожньо → перемикач прихований.
    var renderings: [RenderingLanguage] {
        currentPair?.renderings ?? []
    }

    /// Підпис сегмента мови джерела («EN»).
    var sourceShortTitle: String {
        currentPair?.sourceShortTitle ?? LanguagePair.englishUkrainian.sourceShortTitle
    }

    /// Активна мова відображення (`nil` у режимі мови джерела).
    var activeRendering: RenderingLanguage? {
        guard let displayLanguageID else { return nil }
        return currentPair?.rendering(id: displayLanguageID)
    }

    /// Прив'язка сегментного `Picker` (tag `nil` = мова джерела).
    var displayLanguageSelection: String? {
        get { displayLanguageID }
        set { setDisplayLanguage(newValue) }
    }

    /// Перемикач EN | IT: невідома для пари мова → мова джерела; значення зберігається в налаштуваннях.
    /// Автодоповнення варіантів (Claude) — з I1b.
    func setDisplayLanguage(_ id: String?) {
        let validated = Self.validatedLanguageID(id, pair: currentPair)
        container.settings.displayLanguageID = validated
        displayLanguageID = validated
    }

    private static func validatedLanguageID(_ id: String?, pair: LanguagePair?) -> String? {
        guard let id, let pair, pair.rendering(id: id) != nil else { return nil }
        return id
    }
}

/// Вміст рядка списку (чиста логіка поза SwiftUI, щоб тайпчекатися й тестуватися без UI).
/// Бейджі — як macOS `StatusActionsCell` (M7): статус запису важливіший за стан варіанта.
struct EntryRowContent: Equatable, Identifiable {
    enum BadgeKind: Equatable {
        case pending
        case failed
    }

    struct Badge: Equatable {
        let title: String
        let kind: BadgeKind
    }

    let id: UUID
    let word: String
    let transcription: String?
    /// Переклади через кому (порожньо для fallback-рядка без ready-варіанта).
    let translations: String
    /// «приклад — переклад прикладу» або `nil`.
    let example: String?
    /// Варіант не ready: показується англійське слово (приглушено) з бейджем.
    let isFallback: Bool
    let badge: Badge?

    static func make(
        _ display: EntryDisplay,
        rendering: RenderingLanguage?,
        language: AppLanguage = L10n.current
    ) -> EntryRowContent {
        EntryRowContent(
            id: display.id,
            word: display.word,
            transcription: nonEmpty(display.transcription),
            translations: display.translations.joined(separator: ", "),
            example: exampleText(display.example),
            isFallback: display.isFallback,
            badge: badge(for: display, rendering: rendering, language: language)
        )
    }

    static func badge(for display: EntryDisplay, rendering: RenderingLanguage?, language: AppLanguage) -> Badge? {
        switch display.entry.status {
        case .pending:
            return Badge(title: L10n.text(.tableBadgePending, language: language), kind: .pending)
        case .failed:
            return Badge(title: L10n.text(.tableBadgeFailed, language: language), kind: .failed)
        case .ready:
            break
        }
        guard let state = display.state, state != .ready else { return nil }
        if state == .failed {
            return Badge(title: L10n.text(.tableBadgeFailed, language: language), kind: .failed)
        }
        return Badge(title: variantPendingTitle(rendering: rendering, language: language), kind: .pending)
    }

    /// «Italian version pending» / «італійська версія очікує»; інші мови — нейтральне формулювання.
    static func variantPendingTitle(rendering: RenderingLanguage?, language: AppLanguage) -> String {
        guard let rendering else {
            return L10n.text(.tableBadgePending, language: language)
        }
        if rendering.id == "it" {
            return L10n.text(.renderingItalianPendingBadge, language: language)
        }
        return L10n.text(.renderingOtherPendingBadge, ["language": rendering.shortTitle], language: language)
    }

    private static func exampleText(_ example: Example?) -> String? {
        guard let example, let source = nonEmpty(example.source) else { return nil }
        guard let translation = nonEmpty(example.translation) else { return source }
        return "\(source) — \(translation)"
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
