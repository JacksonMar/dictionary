import SwiftUI
import VocabCore

/// Рядок списку: слово, транскрипція, частина мови, переклади, приклад; для `pending`/`failed` —
/// позначка статусу, остання помилка і кнопка «Повторити».
struct EntryRowView: View {
    let entry: Entry
    let isRetrying: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onRetry: (() -> Void)?

    init(
        entry: Entry,
        isRetrying: Bool = false,
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRetry: (() -> Void)? = nil
    ) {
        self.entry = entry
        self.isRetrying = isRetrying
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onRetry = onRetry
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.word)
                        .font(.headline)
                    if let transcription = entry.transcription, !transcription.isEmpty {
                        Text(transcription)
                            .foregroundColor(.secondary)
                    }
                    if let partOfSpeech = entry.partOfSpeech, !partOfSpeech.isEmpty {
                        Text(partOfSpeech)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    statusBadge
                }
                if !entry.translations.isEmpty {
                    Text(entry.translations.joined(separator: ", "))
                }
                if let example = entry.example, !example.source.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(example.source)
                            .italic()
                        if !example.translation.isEmpty {
                            Text(example.translation)
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.callout)
                }
                if entry.status != .ready, let lastError = entry.lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.caption)
                        .foregroundColor(entry.status == .failed ? .red : .secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if entry.status != .ready, let onRetry {
                    if isRetrying {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Повторити", action: onRetry)
                            .help("Повторити запит до Claude")
                    }
                }
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .help("Редагувати")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .help("Видалити")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .contextMenu {
            if entry.status != .ready, let onRetry {
                Button("Повторити", action: onRetry)
                    .disabled(isRetrying)
            }
            Button("Редагувати", action: onEdit)
            Button("Видалити", action: onDelete)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch entry.status {
        case .ready:
            EmptyView()
        case .pending:
            badge("очікує обробки", color: .orange)
        case .failed:
            badge("помилка", color: .red)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundColor(color)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.15))
            )
    }
}
