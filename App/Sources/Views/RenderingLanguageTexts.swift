import VocabCore

/// Підписи UI для мови відображення (M7, §11) мовою інтерфейсу (M9). Відомі мови — з окремими текстами
/// (в українській — з правильними відмінками), інші — нейтральні формулювання з `shortTitle`.
struct RenderingLanguageTexts: Equatable {
    /// Бейдж рядка без ready-варіанта: «Italian version pending» / «італійська версія очікує».
    let pendingBadge: String
    /// Пункт меню / кнопка редактора: «Refresh Italian Translation» / «Оновити італійський переклад».
    let refreshTitle: String
    /// Кнопка в toolbar без лічильника: «Fill In Italian» / «Доповнити італійською».
    let backfillTitle: String
    /// Текст під час автопроходу: «Filling in Italian…» / «Доповнення італійською…».
    let backfillProgress: String
    /// Заголовок блоку в редакторі: «Italian Version» / «Італійська версія».
    let sectionTitle: String

    init(_ rendering: RenderingLanguage, language: AppLanguage = L10n.current) {
        switch rendering.id {
        case "it":
            pendingBadge = L10n.text(.renderingItalianPendingBadge, language: language)
            refreshTitle = L10n.text(.renderingItalianRefresh, language: language)
            backfillTitle = L10n.text(.renderingItalianBackfill, language: language)
            backfillProgress = L10n.text(.renderingItalianBackfillProgress, language: language)
            sectionTitle = L10n.text(.renderingItalianSection, language: language)
        default:
            let args = ["language": rendering.shortTitle]
            pendingBadge = L10n.text(.renderingOtherPendingBadge, args, language: language)
            refreshTitle = L10n.text(.renderingOtherRefresh, args, language: language)
            backfillTitle = L10n.text(.renderingOtherBackfill, args, language: language)
            backfillProgress = L10n.text(.renderingOtherBackfillProgress, args, language: language)
            sectionTitle = L10n.text(.renderingOtherSection, args, language: language)
        }
    }
}
