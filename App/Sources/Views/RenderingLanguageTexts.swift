import VocabCore

/// Україномовні підписи UI для мови відображення (M7, §11). Відомі мови — з правильними відмінками,
/// інші — нейтральні формулювання з `shortTitle`.
struct RenderingLanguageTexts: Equatable {
    /// Бейдж рядка без ready-варіанта: «італійська версія очікує».
    let pendingBadge: String
    /// Пункт меню / кнопка редактора: «Оновити італійський переклад».
    let refreshTitle: String
    /// Кнопка в toolbar без лічильника: «Доповнити італійською».
    let backfillTitle: String
    /// Текст під час автопроходу: «Доповнення італійською…».
    let backfillProgress: String
    /// Заголовок блоку в редакторі: «Італійська версія».
    let sectionTitle: String

    init(_ rendering: RenderingLanguage) {
        switch rendering.id {
        case "it":
            pendingBadge = "італійська версія очікує"
            refreshTitle = "Оновити італійський переклад"
            backfillTitle = "Доповнити італійською"
            backfillProgress = "Доповнення італійською…"
            sectionTitle = "Італійська версія"
        default:
            pendingBadge = "версія \(rendering.shortTitle) очікує"
            refreshTitle = "Оновити переклад (\(rendering.shortTitle))"
            backfillTitle = "Доповнити (\(rendering.shortTitle))"
            backfillProgress = "Доповнення (\(rendering.shortTitle))…"
            sectionTitle = "Версія \(rendering.shortTitle)"
        }
    }
}
