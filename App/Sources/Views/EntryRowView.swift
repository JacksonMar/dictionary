import SwiftUI
import VocabCore

/// Рядок списку: слово, транскрипція, частина мови, переклади, приклад.
struct EntryRowView: View {
    let entry: Entry
    let onEdit: () -> Void
    let onDelete: () -> Void

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
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
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
            Button("Редагувати", action: onEdit)
            Button("Видалити", action: onDelete)
        }
    }
}
