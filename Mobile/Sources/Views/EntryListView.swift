import SwiftUI
import VocabCore

/// Головний екран (IOS_PLAN §5 «Список»): `NavigationStack`, `.searchable`, сегментний перемикач EN | IT, меню
/// сортування, «+» і шестерня, рядки `EntryRowView` з переходом до `EntryDetailView`, свайпи (трейлінг — «Видалити»
/// з підтвердженням і «Редагувати»; лідинг — «Повторити» або «Оновити італійський»), `.refreshable` →
/// «Повторити всі», порожній стан, стан помилки. Аркуші (додавання, Налаштування) — через `Router`.
/// Явний `@MainActor`: допоміжні властивості (не лише `body`) читають `@MainActor`-модель.
@MainActor
struct EntryListView: View {
    @ObservedObject var model: MobileAppModel
    @EnvironmentObject private var router: Router

    /// Запис, що чекає підтвердження видалення.
    @State private var pendingDeletion: EntryRowContent?
    /// Запис, відкритий у редакторі (аркуш).
    @State private var editingEntry: Entry?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(L10n.text(.mobileListTitle))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        settingsButton
                    }
                    ToolbarItem(placement: .principal) {
                        languagePicker
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        sortMenu
                        addButton
                    }
                }
                .navigationDestination(for: UUID.self) { (id: UUID) in
                    EntryDetailView(model: model, entryID: id)
                }
        }
        .task {
            await model.start()
        }
        .sheet(item: $router.presentedSheet) { (sheet: AppSheet) in
            sheetContent(sheet)
        }
        .sheet(item: $editingEntry) { (entry: Entry) in
            EntryEditView(model: model, mode: .edit(entry))
        }
        .alert(L10n.text(.commonError), isPresented: operationErrorBinding) {
            Button(L10n.text(.commonOk), role: .cancel) {
                model.operationError = nil
            }
        } message: {
            Text(model.operationError ?? "")
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
                NavigationLink(value: row.id) {
                    EntryRowView(row: row)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    trailingActions(row)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    leadingActions(row)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            emptyOverlay
        }
        .searchable(text: $model.searchText, prompt: Text(L10n.text(.dictionarySearchPrompt)))
        .refreshable {
            await model.retryAll()
        }
        .confirmationDialog(
            Text(L10n.text(.dictionaryDeleteTitleOne)),
            isPresented: deletionBinding,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { (row: EntryRowContent) in
            Button(L10n.text(.dictionaryDeleteOne, ["word": row.word]), role: .destructive) {
                delete(row.id)
            }
            Button(L10n.text(.commonCancel), role: .cancel) {
                pendingDeletion = nil
            }
        }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if model.isDictionaryEmpty {
            ContentUnavailableView {
                Label(L10n.text(.mobileEmptyTitle), systemImage: "book.closed")
            } description: {
                Text(L10n.text(.mobileEmptyMessage))
            }
        } else if model.hasNoSearchResults {
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

    // MARK: - Swipe actions

    /// Трейлінг: «Видалити» (через підтвердження; без `role: .destructive`, щоб рядок не зникав до підтвердження)
    /// і «Редагувати».
    @ViewBuilder
    private func trailingActions(_ row: EntryRowContent) -> some View {
        Button {
            pendingDeletion = row
        } label: {
            Label(L10n.text(.mobileActionDelete), systemImage: "trash")
        }
        .tint(Color.red)
        Button {
            editingEntry = model.entry(id: row.id)
        } label: {
            Label(L10n.text(.commonEdit), systemImage: "pencil")
        }
        .tint(Color.blue)
    }

    /// Лідинг: «Повторити» (pending/failed) або «Оновити італійський» (ready, режим IT — 1 запит).
    @ViewBuilder
    private func leadingActions(_ row: EntryRowContent) -> some View {
        switch model.leadingAction(for: row) {
        case .retry?:
            Button {
                retry(row.id)
            } label: {
                Label(L10n.text(.commonRetry), systemImage: "arrow.clockwise")
            }
            .tint(Color.orange)
        case .refreshVariant(let languageID)?:
            Button {
                refreshVariant(row.id, languageID: languageID)
            } label: {
                Label(MobileAppModel.refreshVariantShortTitle(model.activeRendering), systemImage: "arrow.triangle.2.circlepath")
            }
            .tint(Color.green)
        case nil:
            EmptyView()
        }
    }

    private func delete(_ id: UUID) {
        pendingDeletion = nil
        Task<Void, Never> { @MainActor in
            _ = await model.delete(id: id)
        }
    }

    private func retry(_ id: UUID) {
        Task<Void, Never> { @MainActor in
            _ = await model.retry(id: id)
        }
    }

    private func refreshVariant(_ id: UUID, languageID: String) {
        Task<Void, Never> { @MainActor in
            _ = await model.refreshVariant(id: id, languageID: languageID)
        }
    }

    // MARK: - Bindings

    private var deletionBinding: Binding<Bool> {
        Binding<Bool>(
            get: { pendingDeletion != nil },
            set: { (isPresented: Bool) in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    /// Алерт помилки списку — лише коли не відкрито аркуш (аркуші показують помилки в себе).
    private var operationErrorBinding: Binding<Bool> {
        Binding<Bool>(
            get: { model.operationError != nil && router.presentedSheet == nil && editingEntry == nil },
            set: { (isPresented: Bool) in
                if !isPresented {
                    model.operationError = nil
                }
            }
        )
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: AppSheet) -> some View {
        switch sheet {
        case .addWord:
            AddWordSheet(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }

    // MARK: - Toolbar

    private var settingsButton: some View {
        Button {
            router.open(.settings)
        } label: {
            Label(L10n.text(.windowSettings), systemImage: "gearshape")
        }
    }

    private var addButton: some View {
        Button {
            router.open(.addSheet)
        } label: {
            Label(L10n.text(.mobileListAdd), systemImage: "plus")
        }
        .disabled(!model.isLoaded)
    }

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
