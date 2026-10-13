import SwiftUI
import VocabCore

/// Головне вікно: список записів, ручне додавання, редагування, видалення, «Повторити» для pending/failed,
/// «Повторити всі» (якщо є pending/failed записи).
struct DictionaryWindowView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isAdding = false
    @State private var editingEntry: Entry?
    @State private var entryPendingDeletion: Entry?

    var body: some View {
        content
            .frame(minWidth: 560, minHeight: 420)
            .toolbar {
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
                "Видалити запис?",
                isPresented: deletionDialogBinding,
                titleVisibility: .visible,
                presenting: entryPendingDeletion
            ) { entry in
                Button("Видалити «\(entry.word)»", role: .destructive) {
                    Task { @MainActor in
                        await model.delete(id: entry.id)
                    }
                }
                Button("Скасувати", role: .cancel) {}
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
                    List(model.entries) { entry in
                        EntryRowView(
                            entry: entry,
                            isRetrying: model.retryingIDs.contains(entry.id),
                            onEdit: { editingEntry = entry },
                            onDelete: { entryPendingDeletion = entry },
                            onRetry: model.isClaudeAvailable ? { retry(entry) } : nil
                        )
                    }
                }
            }
        }
    }

    private func retry(_ entry: Entry) {
        Task { @MainActor in
            await model.retry(id: entry.id)
        }
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
            get: { entryPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    entryPendingDeletion = nil
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
