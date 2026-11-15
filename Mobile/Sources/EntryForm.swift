import Foundation
import VocabCore

/// Значення полів форми запису (ручне додавання D14 і редагування). Копія логіки macOS `EntryFormData`
/// (`App/Sources/Views/EntryEditorView.swift`, DI5 — macOS-файл не змінюємо), без SwiftUI — тестується й
/// тайпчекається на Linux.
struct EntryForm: Equatable {
    var word = ""
    var lemma = ""
    var partOfSpeech = ""
    var transcription = ""
    /// Переклади через кому (крапку з комою або новий рядок).
    var translations = ""
    var exampleSource = ""
    var exampleTranslation = ""

    init() {}

    /// Порожня форма з уже введеним словом (перехід «Заповнити вручну» з аркуша додавання).
    init(word: String) {
        self.word = word
    }

    init(entry: Entry) {
        word = entry.word
        lemma = entry.lemma ?? ""
        partOfSpeech = entry.partOfSpeech ?? ""
        transcription = entry.transcription ?? ""
        translations = entry.translations.joined(separator: ", ")
        exampleSource = entry.example?.source ?? ""
        exampleTranslation = entry.example?.translation ?? ""
    }

    /// Кнопку «Зберегти» можна натиснути (повна валідація — `MobileAppModel.validationError`).
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

    /// Чернетка ручного запису: статус `ready` (D14), без запиту до Claude.
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

    /// Застосовує поля до наявного запису. `id`, пара, статус, дати, `variants` і `sourceLanguage` формою не
    /// змінюються (`DictionaryRepository.update(_:)` теж не чіпає варіанти, §6).
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
