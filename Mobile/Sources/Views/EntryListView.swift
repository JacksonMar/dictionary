import SwiftUI
import VocabCore

/// Головний екран (IOS_PLAN §5 «Список», I1a — лише читання): `NavigationStack`, `.searchable`, сегментний
/// перемикач EN | IT, меню сортування, рядки `EntryRowView`, порожній стан, стан помилки.
/// «+», шестерня, свайпи, `.refreshable` — I1b.
/// Явний `@MainActor`: допоміжні властивості (не лише `body`) читають `@MainActor`-модель.
@MainActor
struct EntryListView: View {
    @ObservedObject var model: MobileAppModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(L10n.text(.mobileListTitle))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        languagePicker
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        sortMenu
                    }
                }
        }
        .task {
            await model.start()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let loadError = model.loadError {
            ContentUnavailableView {
                Label(L10n.text(.mobileLoadErrorTitle), systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            }
        } else if !model.isLoaded {
            ProgressView(L10n.text(.mobileLoading))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            loadedContent
        }
    }

    /// Список із пошуком. `.searchable` — лише коли словник завантажено (інакше нема чого шукати).
    private var loadedContent: some View {
        let rows: [EntryRowContent] = model.visibleRows
        return List {
            if let warning = model.loadWarning {
                Section {
                    warningBanner(warning)
                }
            }
            ForEach(rows) { (row: EntryRowContent) in
                EntryRowView(row: row)
            }
        }
        .listStyle(.plain)
        .overlay {
            emptyOverlay(rowsAreEmpty: rows.isEmpty)
        }
        .searchable(text: $model.searchText, prompt: Text(L10n.text(.dictionarySearchPrompt)))
    }

    @ViewBuilder
    private func emptyOverlay(rowsAreEmpty: Bool) -> some View {
        if model.isDictionaryEmpty {
            ContentUnavailableView {
                Label(L10n.text(.mobileEmptyTitle), systemImage: "book.closed")
            } description: {
                Text(L10n.text(.mobileEmptyMessage))
            }
        } else if rowsAreEmpty {
            ContentUnavailableView {
                Label(L10n.text(.mobileNoResultsTitle), systemImage: "magnifyingglass")
            } description: {
                Text(L10n.text(.dictionaryNoResults, ["query": model.query.normalizedSearchText]))
            }
        }
    }

    private func warningBanner(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.orange)
            Text(warning)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L10n.text(.commonClose)) {
                model.loadWarning = nil
            }
            .font(.footnote)
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Toolbar

    /// Сегменти «EN | IT» (`pair.sourceShortTitle` + `renderings`); прихований, якщо в пари немає мов відображення.
    @ViewBuilder
    private var languagePicker: some View {
        if !model.renderings.isEmpty {
            Picker(L10n.text(.dictionaryLanguagePicker), selection: $model.displayLanguageSelection) {
                Text(verbatim: model.sourceShortTitle)
                    .tag(String?.none)
                ForEach(model.renderings, id: \.id) { (rendering: RenderingLanguage) in
                    Text(verbatim: rendering.shortTitle)
                        .tag(String?.some(rendering.id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!model.isLoaded)
            .accessibilityHint(Text(L10n.text(.dictionaryLanguageHelp)))
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker(L10n.text(.dictionarySort), selection: $model.sort) {
                ForEach(EntrySort.allCases, id: \.self) { (sort: EntrySort) in
                    Text(sort.title)
                        .tag(sort)
                }
            }
        } label: {
            Label(L10n.text(.dictionarySort), systemImage: "arrow.up.arrow.down")
        }
        .disabled(!model.isLoaded)
        .accessibilityHint(Text(L10n.text(.dictionarySortHelp)))
    }
}
