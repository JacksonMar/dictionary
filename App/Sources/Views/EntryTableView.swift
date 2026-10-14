import SwiftUI
import VocabCore

/// Таблиця записів поточної сторінки (§11, M6; замінює `EntryRowView`).
///
/// Колонки: Слово | Транскрипція | Переклад | Приклад + вузька колонка статусу й дій (бейдж pending/failed,
/// «Повторити», озвучення). Багаторядкове виділення; контекстне меню над виділенням
/// (`contextMenu(forSelectionType:menu:primaryAction:)`, macOS 13), подвійний клік → редактор.
/// Заголовки не сортують (D19): порядок задає `Picker` сортування (`EntrySort`).
///
/// M7: рядки — `EntryDisplay` активної мови. У режимі мови варіанта рядок без ready-варіанта показує англійське
/// слово приглушеним і бейдж «італійська версія очікує» / «помилка» (+ «Повторити» = `onRefreshVariant`).
///
/// Клітинки — окремі маленькі `View`, щоб компілятор швидко перевіряв типи `TableColumnBuilder`.
struct EntryTableView: View {
    let rows: [EntryDisplay]
    @Binding var selection: Set<Entry.ID>
    let retryingIDs: Set<UUID>
    let canRetry: Bool
    let canSpeak: Bool
    /// Підписи активної мови варіанта; `nil` — режим мови джерела.
    let variantTexts: RenderingLanguageTexts?
    /// Доступне «Оновити … переклад» (є доповнення варіантів).
    let canRefreshVariant: Bool
    let onEdit: (Entry) -> Void
    let onDelete: ([Entry]) -> Void
    let onRetry: ([Entry]) -> Void
    let onRefreshVariant: (Entry) -> Void
    let onSpeak: (String, EntryDisplay) -> Void

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Слово") { (row: EntryDisplay) in
                WordCell(row: row)
            }
            .width(min: 80, ideal: 140)
            TableColumn("Транскрипція") { (row: EntryDisplay) in
                TruncatedTextCell(text: row.transcription ?? "", isSecondary: true)
            }
            .width(min: 70, ideal: 120)
            TableColumn("Переклад") { (row: EntryDisplay) in
                TruncatedTextCell(text: row.translations.joined(separator: ", "), isSecondary: false)
            }
            .width(min: 100, ideal: 220)
            TableColumn("Приклад") { (row: EntryDisplay) in
                ExampleCell(example: row.example)
            }
            .width(min: 100, ideal: 260)
            TableColumn("") { (row: EntryDisplay) in
                statusCell(for: row)
            }
            .width(min: 70, ideal: 100, max: 200)
        }
        .contextMenu(forSelectionType: Entry.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            openEditor(for: ids)
        }
    }

    private func statusCell(for row: EntryDisplay) -> StatusActionsCell {
        StatusActionsCell(
            row: row,
            isRetrying: retryingIDs.contains(row.id),
            canRetry: canRetry,
            canSpeak: canSpeak,
            canRefreshVariant: canRefreshVariant,
            variantPendingText: variantTexts?.pendingBadge ?? "",
            onRetry: { onRetry([row.entry]) },
            onRefreshVariant: { onRefreshVariant(row.entry) },
            onSpeak: { onSpeak(row.word, row) }
        )
    }

    private func menu(for ids: Set<Entry.ID>) -> EntryContextMenu {
        let selected = rows.filter { ids.contains($0.id) }
        return EntryContextMenu(
            rows: selected,
            retryingIDs: retryingIDs,
            canRetry: canRetry,
            canSpeak: canSpeak,
            refreshTitle: canRefreshVariant ? variantTexts?.refreshTitle : nil,
            onEdit: onEdit,
            onDelete: onDelete,
            onRetry: onRetry,
            onRefreshVariant: onRefreshVariant,
            onSpeak: onSpeak
        )
    }

    /// Подвійний клік (primaryAction) по одному рядку → редактор.
    private func openEditor(for ids: Set<Entry.ID>) {
        guard ids.count == 1, let row = rows.first(where: { ids.contains($0.id) }) else { return }
        onEdit(row.entry)
    }
}

// MARK: - Клітинки

/// Слово жирним, один рядок, повний текст — у підказці. Fallback-рядок (варіант не ready) — приглушений.
private struct WordCell: View {
    let row: EntryDisplay

    var body: some View {
        Text(row.word)
            .fontWeight(.semibold)
            .foregroundColor(row.isFallback ? Color.secondary : Color.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(row.word)
    }
}

/// Текст в один рядок з підказкою (повний текст).
private struct TruncatedTextCell: View {
    let text: String
    let isSecondary: Bool

    var body: some View {
        Text(text)
            .foregroundColor(isSecondary ? Color.secondary : Color.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
    }
}

/// Приклад мовою відображення; підказка — «source — translation».
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
/// озвучення (лише ready). M7: для ready-запису без ready-варіанта — бейдж варіанта; для `failed`-варіанта —
/// «Повторити» (оновлення варіанта).
private struct StatusActionsCell: View {
    let row: EntryDisplay
    let isRetrying: Bool
    let canRetry: Bool
    let canSpeak: Bool
    let canRefreshVariant: Bool
    let variantPendingText: String
    let onRetry: () -> Void
    let onRefreshVariant: () -> Void
    let onSpeak: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if row.entry.status != .ready {
                StatusBadge(title: entryBadgeTitle, isError: row.entry.status == .failed, helpText: entryHelpText)
                if canRetry {
                    RetryButton(isRetrying: isRetrying, word: row.word, action: onRetry)
                }
            } else if let state = row.state, state != .ready {
                StatusBadge(title: variantBadgeTitle(state), isError: state == .failed, helpText: variantHelpText(state))
                if state == .failed && canRefreshVariant {
                    RetryButton(isRetrying: isRetrying, word: row.word, action: onRefreshVariant)
                }
            } else if canSpeak {
                Button(action: onSpeak) {
                    Image(systemName: "speaker.wave.2")
                }
                .buttonStyle(.borderless)
                .help("Озвучити")
                .accessibilityLabel("Озвучити «\(row.word)»")
            }
        }
    }

    private var entryBadgeTitle: String {
        row.entry.status == .failed ? "помилка" : "очікує"
    }

    private var entryHelpText: String {
        if let lastError = row.entry.lastError, !lastError.isEmpty {
            return lastError
        }
        return row.entry.status == .failed ? "Помилка обробки" : "Очікує обробки"
    }

    private func variantBadgeTitle(_ state: VariantState) -> String {
        state == .failed ? "помилка" : variantPendingText
    }

    private func variantHelpText(_ state: VariantState) -> String {
        let lastError = row.languageID.flatMap { row.entry.variants?[$0]?.lastError } ?? ""
        if state == .failed {
            return lastError.isEmpty ? "Помилка доповнення" : lastError
        }
        if state == .stale || lastError.isEmpty {
            return "Буде доповнено при наступному запуску доповнення"
        }
        return lastError
    }
}

/// «Повторити» або індикатор виконання.
private struct RetryButton: View {
    let isRetrying: Bool
    let word: String
    let action: () -> Void

    var body: some View {
        if isRetrying {
            ProgressView()
                .controlSize(.small)
        } else {
            Button(action: action) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Повторити запит до Claude")
            .accessibilityLabel("Повторити «\(word)»")
        }
    }
}

/// Бейдж статусу (очікує — помаранчевий, помилка — червоний).
private struct StatusBadge: View {
    let title: String
    let isError: Bool
    let helpText: String

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

    private var color: Color {
        isError ? Color.red : Color.orange
    }
}

// MARK: - Контекстне меню

/// Дії над виділеними рядками: «Редагувати» (один запис), «Повторити» (pending/failed), «Оновити італійський
/// переклад» (M7, один ready-запис у режимі мови варіанта), «Озвучити» (один ready-рядок), «Видалити»
/// (з підтвердженням у вікні). Порожнє виділення → порожнє меню.
private struct EntryContextMenu: View {
    let rows: [EntryDisplay]
    let retryingIDs: Set<UUID>
    let canRetry: Bool
    let canSpeak: Bool
    /// `nil` — оновлення варіанта недоступне (режим мови джерела або немає доповнення).
    let refreshTitle: String?
    let onEdit: (Entry) -> Void
    let onDelete: ([Entry]) -> Void
    let onRetry: ([Entry]) -> Void
    let onRefreshVariant: (Entry) -> Void
    let onSpeak: (String, EntryDisplay) -> Void

    var body: some View {
        if let single = singleRow {
            Button("Редагувати") {
                onEdit(single.entry)
            }
        }
        if canRetry && !retryable.isEmpty {
            Button(retryTitle) {
                onRetry(retryable)
            }
        }
        if let refreshTitle, let single = singleRow, single.entry.status == .ready, !retryingIDs.contains(single.id) {
            Button(refreshTitle) {
                onRefreshVariant(single.entry)
            }
        }
        if canSpeak, let single = singleRow, isSpeakable(single) {
            Button("Озвучити") {
                onSpeak(single.word, single)
            }
            if let source = single.example?.source, !source.isEmpty {
                Button("Озвучити приклад") {
                    onSpeak(source, single)
                }
            }
        }
        if !rows.isEmpty {
            Divider()
            Button(deleteTitle) {
                onDelete(rows.map(\.entry))
            }
        }
    }

    private var retryTitle: String {
        retryable.count > 1 ? "Повторити (\(retryable.count))" : "Повторити"
    }

    private var deleteTitle: String {
        rows.count > 1 ? "Видалити (\(rows.count))…" : "Видалити…"
    }

    private var singleRow: EntryDisplay? {
        rows.count == 1 ? rows.first : nil
    }

    /// Озвучення — лише для ready-запису і (у режимі варіанта) ready-варіанта.
    private func isSpeakable(_ row: EntryDisplay) -> Bool {
        row.entry.status == .ready && !row.isFallback
    }

    /// pending/failed записи, що зараз не повторюються.
    private var retryable: [Entry] {
        rows.map(\.entry).filter { $0.status != .ready && !retryingIDs.contains($0.id) }
    }
}
