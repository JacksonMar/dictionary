import SwiftUI
import VocabCore

/// Панель сторінок під таблицею (§11, M6): «‹ Previous  Page N of M  Next ›» (мовою інтерфейсу).
/// Крайні кнопки вимикаються за `hasPrevious`/`hasNext`; коли сторінка одна, панель не показується (рішення — у
/// `DictionaryWindowView`).
struct PaginationBar: View {
    let page: EntryPage
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onPrevious) {
                Text(L10n.text(.paginationPrevious))
            }
            .disabled(!page.hasPrevious)
            .help(L10n.text(.paginationPreviousHelp))

            Text(page.label)
                .monospacedDigit()
                .foregroundColor(.secondary)

            Button(action: onNext) {
                Text(L10n.text(.paginationNext))
            }
            .disabled(!page.hasNext)
            .help(L10n.text(.paginationNextHelp))
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}
