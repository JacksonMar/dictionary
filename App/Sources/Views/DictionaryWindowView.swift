import SwiftUI
import VocabCore

/// Записи, що чекають підтвердження видалення (один або кілька виділених рядків).
private struct PendingDeletion {
    let entries: [Entry]
}

/// Головне вікно: таблиця записів поточної сторінки (M6), пошук (слово/лема/переклад) і сортування по всьому
/// словнику (M5), пагінація (M6), ручне додавання, редагування, видалення, озвучення, «Повторити» для
/// pending/failed, «Повторити всі» (якщо є pending/failed записи).
struct DictionaryWindowView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isAdding = false
    @State private var editingEntry: Entry?
    @State private var pendingDeletion: PendingDeletion?
    @State private var selection = Set<Entry.ID>()

    var body: some View {
        content
            .frame(minWidth: 720, minHeight: 420)
            .searchable(text: $model.query.searchText, placement: .toolbar, prompt: "Слово або переклад")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Picker(selection: $model.query.sort) {
                        ForEach(EntrySort.allCases, id: \.self) { sort in
                            Text(sort.title).tag(sort)
                        }
                    } label: {
                        Label("Сортування", systemImage: "arrow.up.arrow.down")
                    }
                    .pickerStyle(.menu)
                    .help("Сортування списку")
                    .disabled(!model.isLoaded)
                }
                ToolbarItem(placement: .primaryAction) {
                    if model.isClaudeAvailable && model.hasRetryableEntries {
                        if model.isRetryingAll {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button {
                                Task { @MainActor in
                                    await model.retryAll()
                                }
                            } label: {
                                Label("Повторити всі", systemImage: "arrow.clockwise")
                            }
                            .help("Повторити запит до Claude для всіх записів, що очікують обробки або з помилкою")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAdding = true
                    } label: {
                        Label("Додати", systemImage: "plus")
                    }
                    .help("Додати слово вручну")
                    .disabled(!model.isLoaded)
                }
            }
            .sheet(isPresented: $isAdding) {
                AddEntryView()
                    .environmentObject(model)
            }
            .sheet(item: $editingEntry) { entry in
                EntryEditorView(entry: entry)
                    .environmentObject(model)
            }
            .confirmationDialog(
                deletionTitle,
                isPresented: deletionDialogBinding,
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { deletion in
                Button(Self.deleteButtonTitle(for: deletion.entries), role: .destructive) {
                    delete(deletion.entries)
                }
                Button("Скасувати", role: .cancel) {}
            }
            // Зміна сторінки (у т.ч. скидання на 1 після пошуку/сортування/розміру) скидає виділення.
            .onChange(of: model.pageNumber) { _ in
                selection.removeAll()
            }
            .alert("Помилка", isPresented: operationErrorBinding) {
                Button("OK") {
                    model.operationError = nil
                }
            } message: {
                Text(model.operationError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError = model.loadError {
            messageView(systemImage: "exclamationmark.triangle", text: loadError)
        } else if !model.isLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if let warning = model.loadWarning {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(warning)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Закрити") {
                            model.loadWarning = nil
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(10)
                    .background(Color.yellow.opacity(0.2))
                }
                if model.entries.isEmpty {
                    messageView(systemImage: "character.book.closed", text: "Словник порожній. Додайте слово кнопкою «+».")
                } else {
                    let page = model.currentPage
                    if page.totalCount == 0 {
                        messageView(
                            systemImage: "magnifyingglass",
                            text: "Нічого не знайдено за запитом «\(model.query.normalizedSearchText)»."
                        )
                    } else {
                        pageView(page)
                    }
                }
            }
        }
    }

    private func pageView(_ page: EntryPage) -> some View {
        VStack(spacing: 0) {
            EntryTableView(
                entries: page.entries,
                selection: $selection,
                retryingIDs: model.retryingIDs,
                canRetry: model.isClaudeAvailable,
                canSpeak: model.isSpeechAvailable,
                onEdit: { entry in editingEntry = entry },
                onDelete: { entries in pendingDeletion = PendingDeletion(entries: entries) },
                onRetry: { entries in retry(entries) },
                onSpeak: { text, entry in model.speak(text, languagePair: entry.languagePair) }
            )
            if page.pageCount > 1 {
                Divider()
                PaginationBar(
                    page: page,
                    onPrevious: { model.previousPage() },
                    onNext: { model.nextPage() }
                )
            }
        }
    }

    /// «Повторити» для одного чи кількох записів — послідовно (черга й так обробляє записи по одному).
    private func retry(_ entries: [Entry]) {
        let ids = entries.map(\.id)
        Task { @MainActor in
            for id in ids {
                await model.retry(id: id)
            }
        }
    }

    /// Видалення після підтвердження; виділення скидається.
    private func delete(_ entries: [Entry]) {
        let ids = entries.map(\.id)
        selection.subtract(ids)
        Task { @MainActor in
            for id in ids {
                guard await model.delete(id: id) else { break }
            }
        }
    }

    private var deletionTitle: String {
        let count = pendingDeletion?.entries.count ?? 0
        return count > 1 ? "Видалити записи (\(count))?" : "Видалити запис?"
    }

    private static func deleteButtonTitle(for entries: [Entry]) -> String {
        if entries.count == 1, let entry = entries.first {
            return "Видалити «\(entry.word)»"
        }
        return "Видалити вибрані (\(entries.count))"
    }

    private func messageView(systemImage: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deletionDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    /// Аркуші додавання/редагування показують свої помилки самі; тут — лише помилки з вікна (напр. видалення).
    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { model.operationError != nil && !isAdding && editingEntry == nil },
            set: { isPresented in
                if !isPresented {
                    model.operationError = nil
                }
            }
        )
    }
}

extension EntrySort {
    /// Назва в меню сортування.
    var title: String {
        switch self {
        case .dateNewest:
            return "Спершу нові"
        case .dateOldest:
            return "Спершу старі"
        case .alphabetical:
            return "За алфавітом"
        }
    }
}
