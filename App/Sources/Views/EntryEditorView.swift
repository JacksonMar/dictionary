import SwiftUI
import VocabCore

/// Значення полів форми запису (спільне для додавання й редагування).
struct EntryFormData: Equatable {
    var word = ""
    var lemma = ""
    var partOfSpeech = ""
    var transcription = ""
    /// Переклади через кому.
    var translations = ""
    var exampleSource = ""
    var exampleTranslation = ""

    init() {}

    init(entry: Entry) {
        word = entry.word
        lemma = entry.lemma ?? ""
        partOfSpeech = entry.partOfSpeech ?? ""
        transcription = entry.transcription ?? ""
        translations = entry.translations.joined(separator: ", ")
        exampleSource = entry.example?.source ?? ""
        exampleTranslation = entry.example?.translation ?? ""
    }

    var canSave: Bool {
        !Self.trimmed(word).isEmpty
    }

    /// Переклади, розділені комою, крапкою з комою або переносом рядка; порожні відкидаються.
    var translationList: [String] {
        translations
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { Self.trimmed(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Приклад зберігається, лише якщо є речення-джерело.
    var example: Example? {
        let source = Self.trimmed(exampleSource)
        guard !source.isEmpty else { return nil }
        return Example(source: source, translation: Self.trimmed(exampleTranslation))
    }

    func makeDraft(languagePair: String) -> EntryDraft {
        EntryDraft(
            word: word,
            languagePair: languagePair,
            lemma: Self.optional(lemma),
            partOfSpeech: Self.optional(partOfSpeech),
            transcription: Self.optional(transcription),
            translations: translationList,
            example: example,
            status: .ready
        )
    }

    /// Застосовує поля до наявного запису (id, пара, статус, дати не змінюються формою).
    func applied(to entry: Entry) -> Entry {
        var result = entry
        result.word = word
        result.lemma = Self.optional(lemma)
        result.partOfSpeech = Self.optional(partOfSpeech)
        result.transcription = Self.optional(transcription)
        result.translations = translationList
        result.example = example
        return result
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func optional(_ value: String) -> String? {
        let result = trimmed(value)
        return result.isEmpty ? nil : result
    }
}

/// Поля форми запису.
struct EntryFormFields: View {
    @Binding var form: EntryFormData

    var body: some View {
        Form {
            TextField("Слово або фраза", text: $form.word)
            TextField("Лема", text: $form.lemma)
            TextField("Частина мови", text: $form.partOfSpeech)
            TextField("Транскрипція", text: $form.transcription)
            TextField("Переклади (через кому)", text: $form.translations)
            TextField("Приклад", text: $form.exampleSource)
            TextField("Переклад прикладу", text: $form.exampleTranslation)
        }
    }
}

/// Редагування наявного запису (аркуш).
struct EntryEditorView: View {
    let entry: Entry

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var form: EntryFormData
    @State private var errorText: String?
    @State private var isSaving = false

    init(entry: Entry) {
        self.entry = entry
        _form = State(initialValue: EntryFormData(entry: entry))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Редагувати запис")
                    .font(.headline)
                Spacer()
                if model.isSpeechAvailable {
                    Button {
                        model.speak(form.word, languagePair: entry.languagePair)
                    } label: {
                        Label("Озвучити", systemImage: "speaker.wave.2")
                    }
                    .help("Озвучити слово")
                    .disabled(!form.canSave)
                }
            }
            EntryFormFields(form: $form)
            if let errorText {
                Text(errorText)
                    .foregroundColor(.red)
            }
            HStack {
                Spacer()
                Button("Скасувати") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Зберегти") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !form.canSave)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }

    @MainActor
    private func save() {
        isSaving = true
        let updated = form.applied(to: entry)
        Task { @MainActor in
            let result = await model.update(updated)
            isSaving = false
            if result != nil {
                dismiss()
            } else {
                errorText = model.operationError
                model.operationError = nil
            }
        }
    }
}
