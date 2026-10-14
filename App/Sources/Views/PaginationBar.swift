import SwiftUI
import VocabCore

/// Панель сторінок під таблицею (§11, M6): «‹ Попередня  Сторінка N з M  Наступна ›».
/// Крайні кнопки вимикаються за `hasPrevious`/`hasNext`; коли сторінка одна, панель не показується (рішення — у
/// `DictionaryWindowView`).
struct PaginationBar: View {
    let page: EntryPage
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onPrevious) {
                Text("‹ Попередня")
            }
            .disabled(!page.hasPrevious)
            .help("Попередня сторінка")

            Text(page.label)
                .monospacedDigit()
                .foregroundColor(.secondary)

            Button(action: onNext) {
                Text("Наступна ›")
            }
            .disabled(!page.hasNext)
            .help("Наступна сторінка")
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}
