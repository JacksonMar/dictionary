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
            if let rendering = model.activeRendering {
                VariantReadOnlySection(entryID: entry.id, rendering: rendering)
            }
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

/// M7: італійські поля запису — лише для читання (редагування відкладено) + «Оновити італійський переклад».
/// Дані беруться з актуального стану `AppModel` (після оновлення блок перемальовується).
private struct VariantReadOnlySection: View {
    let entryID: UUID
    let rendering: RenderingLanguage

    @EnvironmentObject private var model: AppModel

    var body: some View {
        let texts = RenderingLanguageTexts(rendering)
        GroupBox(texts.sectionTitle) {
            VStack(alignment: .leading, spacing: 6) {
                if let entry = currentEntry, let variant = entry.readyVariant(rendering.id) {
                    VariantFieldRow(title: "Слово", value: variant.word ?? "")
                    VariantFieldRow(title: "Лема", value: variant.lemma ?? "")
                    VariantFieldRow(title: "Частина мови", value: variant.partOfSpeech ?? "")
                    VariantFieldRow(title: "Транскрипція", value: variant.transcription ?? "")
                    VariantFieldRow(title: "Переклади", value: variant.translations.joined(separator: ", "))
                    VariantFieldRow(title: "Приклад", value: variant.example?.source ?? "")
                    VariantFieldRow(title: "Переклад прикладу", value: variant.example?.translation ?? "")
                } else {
                    Text(statusText)
                        .foregroundColor(Color.secondary)
                }
                HStack {
                    Spacer()
                    if model.retryingIDs.contains(entryID) {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button(texts.refreshTitle) {
                        refresh()
                    }
                    .disabled(!canRefresh)
                    .help("Один запит до Claude лише для цього запису")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var currentEntry: Entry? {
        model.entries.first { $0.id == entryID }
    }

    private var canRefresh: Bool {
        guard model.isBackfillAvailable, let entry = currentEntry else { return false }
        return entry.status == .ready && !model.retryingIDs.contains(entryID)
    }

    private var statusText: String {
        guard let entry = currentEntry else { return "Запис не знайдено" }
        guard entry.status == .ready else {
            return "Буде заповнено разом з основним перекладом"
        }
        switch entry.variantState(rendering.id) {
        case .failed:
            let lastError = entry.variants?[rendering.id]?.lastError ?? ""
            return lastError.isEmpty ? "Помилка доповнення" : "Помилка: \(lastError)"
        case .missing, .stale, .pending, .ready:
            return "Ще не доповнено"
        }
    }

    private func refresh() {
        let id = entryID
        let languageID = rendering.id
        Task { @MainActor in
            await model.refreshVariant(id: id, languageID: languageID)
        }
    }
}

/// Рядок «назва: значення» (виділюваний текст, без редагування).
private struct VariantFieldRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundColor(Color.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
