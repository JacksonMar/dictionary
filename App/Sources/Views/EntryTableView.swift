import SwiftUI
import VocabCore

/// Таблиця записів поточної сторінки (§11, M6; замінює `EntryRowView`).
///
/// Колонки: Слово | Транскрипція | Переклад | Приклад + вузька колонка статусу й дій (бейдж pending/failed,
/// «Повторити», озвучення). Багаторядкове виділення; контекстне меню над виділенням
/// (`contextMenu(forSelectionType:menu:primaryAction:)`, macOS 13), подвійний клік → редактор.
/// Заголовки не сортують (D19): порядок задає `Picker` сортування (`EntrySort`).
///
/// Клітинки — окремі маленькі `View`, щоб компілятор швидко перевіряв типи `TableColumnBuilder`.
struct EntryTableView: View {
    let entries: [Entry]
    @Binding var selection: Set<Entry.ID>
    let retryingIDs: Set<UUID>
    let canRetry: Bool
    let canSpeak: Bool
    let onEdit: (Entry) -> Void
    let onDelete: ([Entry]) -> Void
    let onRetry: ([Entry]) -> Void
    let onSpeak: (String, Entry) -> Void

    var body: some View {
        Table(entries, selection: $selection) {
            TableColumn("Слово") { (entry: Entry) in
                WordCell(entry: entry)
            }
            .width(min: 80, ideal: 140)
            TableColumn("Транскрипція") { (entry: Entry) in
                TruncatedTextCell(text: entry.transcription ?? "", isSecondary: true)
            }
            .width(min: 70, ideal: 120)
            TableColumn("Переклад") { (entry: Entry) in
                TruncatedTextCell(text: entry.translations.joined(separator: ", "), isSecondary: false)
            }
            .width(min: 100, ideal: 220)
            TableColumn("Приклад") { (entry: Entry) in
                ExampleCell(example: entry.example)
            }
            .width(min: 100, ideal: 260)
            TableColumn("") { (entry: Entry) in
                statusCell(for: entry)
            }
            .width(min: 70, ideal: 90, max: 120)
        }
        .contextMenu(forSelectionType: Entry.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            openEditor(for: ids)
        }
    }

    private func statusCell(for entry: Entry) -> StatusActionsCell {
        StatusActionsCell(
            entry: entry,
            isRetrying: retryingIDs.contains(entry.id),
            canRetry: canRetry,
            canSpeak: canSpeak,
            onRetry: { onRetry([entry]) },
            onSpeak: { onSpeak(entry.word, entry) }
        )
    }

    private func menu(for ids: Set<Entry.ID>) -> EntryContextMenu {
        let selected = entries.filter { ids.contains($0.id) }
        return EntryContextMenu(
            entries: selected,
            retryingIDs: retryingIDs,
            canRetry: canRetry,
            canSpeak: canSpeak,
            onEdit: onEdit,
            onDelete: onDelete,
            onRetry: onRetry,
            onSpeak: onSpeak
        )
    }

    /// Подвійний клік (primaryAction) по одному рядку → редактор.
    private func openEditor(for ids: Set<Entry.ID>) {
        guard ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) else { return }
        onEdit(entry)
    }
}

// MARK: - Клітинки

/// Слово жирним, один рядок, повний текст — у підказці.
private struct WordCell: View {
    let entry: Entry

    var body: some View {
        Text(entry.word)
            .fontWeight(.semibold)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(entry.word)
    }
}

/// Текст в один рядок з підказкою (повний текст).
private struct TruncatedTextCell: View {
    let text: String
    let isSecondary: Bool

    var body: some View {
        Text(text)
            .foregroundColor(isSecondary ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
    }
}

/// Приклад англійською; підказка — «source — translation».
private struct ExampleCell: View {
    let example: Example?

    var body: some View {
        Text(example?.source ?? "")
            .italic()
            .lineLimit(1)
            .truncationMode(.tail)
            .help(helpText)
    }

    private var helpText: String {
        guard let example else { return "" }
        if example.translation.isEmpty {
            return example.source
        }
        return "\(example.source) — \(example.translation)"
    }
}

/// Вузька колонка: бейдж «очікує»/«помилка» (підказка — `lastError`), «Повторити» (лише pending/failed),
/// озвучення (лише ready).
private struct StatusActionsCell: View {
    let entry: Entry
    let isRetrying: Bool
    let canRetry: Bool
    let canSpeak: Bool
    let onRetry: () -> Void
    let onSpeak: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if entry.status == .ready {
                if canSpeak {
                    Button(action: onSpeak) {
                        Image(systemName: "speaker.wave.2")
                    }
                    .buttonStyle(.borderless)
                    .help("Озвучити")
                    .accessibilityLabel("Озвучити «\(entry.word)»")
                }
            } else {
                StatusBadge(status: entry.status, lastError: entry.lastError)
                if canRetry {
                    retryControl
                }
            }
        }
    }

    @ViewBuilder
    private var retryControl: some View {
        if isRetrying {
            ProgressView()
                .controlSize(.small)
        } else {
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Повторити запит до Claude")
            .accessibilityLabel("Повторити «\(entry.word)»")
        }
    }
}

/// Бейдж статусу pending/failed.
private struct StatusBadge: View {
    let status: EntryStatus
    let lastError: String?

    var body: some View {
        Text(title)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundColor(color)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.15))
            )
            .help(helpText)
    }

    private var title: String {
        status == .failed ? "помилка" : "очікує"
    }

    private var color: Color {
        status == .failed ? .red : .orange
    }

    private var helpText: String {
        if let lastError, !lastError.isEmpty {
            return lastError
        }
        return status == .failed ? "Помилка обробки" : "Очікує обробки"
    }
}

// MARK: - Контекстне меню

/// Дії над виділеними рядками: «Редагувати» (один запис), «Повторити» (pending/failed), «Озвучити»
/// (один ready-запис), «Видалити» (з підтвердженням у вікні). Порожнє виділення → порожнє меню.
private struct EntryContextMenu: View {
    let entries: [Entry]
    let retryingIDs: Set<UUID>
    let canRetry: Bool
    let canSpeak: Bool
    let onEdit: (Entry) -> Void
    let onDelete: ([Entry]) -> Void
    let onRetry: ([Entry]) -> Void
    let onSpeak: (String, Entry) -> Void

    var body: some View {
        if let single = singleEntry {
            Button("Редагувати") {
                onEdit(single)
            }
        }
        if canRetry && !retryable.isEmpty {
            Button(retryTitle) {
                onRetry(retryable)
            }
        }
        if canSpeak, let single = singleEntry, single.status == .ready {
            Button("Озвучити") {
                onSpeak(single.word, single)
            }
            if let source = single.example?.source, !source.isEmpty {
                Button("Озвучити приклад") {
                    onSpeak(source, single)
                }
            }
        }
        if !entries.isEmpty {
            Divider()
            Button(deleteTitle) {
                onDelete(entries)
            }
        }
    }

    private var retryTitle: String {
        retryable.count > 1 ? "Повторити (\(retryable.count))" : "Повторити"
    }

    private var deleteTitle: String {
        entries.count > 1 ? "Видалити (\(entries.count))…" : "Видалити…"
    }

    private var singleEntry: Entry? {
        entries.count == 1 ? entries.first : nil
    }

    /// pending/failed записи, що зараз не повторюються.
    private var retryable: [Entry] {
        entries.filter { $0.status != .ready && !retryingIDs.contains($0.id) }
    }
}
