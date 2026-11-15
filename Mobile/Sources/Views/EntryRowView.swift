import SwiftUI
import VocabCore

/// Рядок списку (IOS_PLAN §5): слово (жирне) + транскрипція, переклади, приклад (до 2 рядків), бейдж
/// «очікує»/«помилка»/«італійська версія очікує». Увесь текст уже підготовлено в `EntryRowContent`.
struct EntryRowView: View {
    let row: EntryRowContent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerLine
            if !row.translations.isEmpty {
                Text(row.translations)
                    .font(.subheadline)
                    .lineLimit(3)
            }
            if let example = row.example {
                Text(example)
                    .font(.footnote)
                    .italic()
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var headerLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.word)
                .font(.headline)
                .foregroundStyle(row.isFallback ? Color.secondary : Color.primary)
                .lineLimit(2)
            if let transcription = row.transcription {
                Text(transcription)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let badge = row.badge {
                StatusBadgeView(badge: badge)
            }
        }
    }
}

/// Бейдж статусу (очікує — помаранчевий, помилка — червоний), як на macOS.
private struct StatusBadgeView: View {
    let badge: EntryRowContent.Badge

    var body: some View {
        Text(badge.title)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.15))
            )
    }

    private var color: Color {
        switch badge.kind {
        case .failed:
            return Color.red
        case .pending:
            return Color.orange
        }
    }
}
