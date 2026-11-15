import SwiftUI
import VocabCore

/// Режим форми запису.
enum EntryEditMode {
    /// Ручне додавання (D14): статус ready, перевірка дубля, 0 запитів.
    case create(initialWord: String)
    /// Редагування наявного запису: основні поля; варіанти (італійська) зберігаються.
    case edit(Entry)
}

/// Форма запису (IOS_PLAN §5): ручне додавання з `AddWordSheet` (усередині його `NavigationStack`) або редагування
/// (власний аркуш з `NavigationStack`). Помилки (порожнє слово, ready без перекладу, дубль) — під формою.
@MainActor
struct EntryEditView: View {
    @ObservedObject var model: MobileAppModel
    let mode: EntryEditMode
    /// Викликається після успішного збереження (напр. закрити весь аркуш додавання); `nil` → `dismiss()`.
    let onFinish: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var form: EntryForm
    @State private var errorText: String?
    @State private var isSaving: Bool = false

    init(model: MobileAppModel, mode: EntryEditMode, onFinish: (() -> Void)? = nil) {
        self.model = model
        self.mode = mode
        self.onFinish = onFinish
        switch mode {
        case .create(let initialWord):
            _form = State(initialValue: EntryForm(word: initialWord.trimmingCharacters(in: .whitespacesAndNewlines)))
        case .edit(let entry):
            _form = State(initialValue: EntryForm(entry: entry))
        }
    }

    var body: some View {
        switch mode {
        case .create:
            formContent
        case .edit:
            NavigationStack {
                formContent
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.text(.commonCancel)) {
                                dismiss()
                            }
                        }
                    }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private var formContent: some View {
        Form {
            Section {
                TextField(L10n.text(.editorWord), text: $form.word)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField(L10n.text(.editorTranscription), text: $form.transcription)
                    .autocorrectionDisabled(true)
                TextField(L10n.text(.editorPartOfSpeech), text: $form.partOfSpeech)
                    .textInputAutocapitalization(.never)
                TextField(L10n.text(.editorLemma), text: $form.lemma)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
            Section {
                TextField(L10n.text(.editorTranslationsInput), text: $form.translations, axis: .vertical)
                    .lineLimit(1...4)
            } header: {
                Text(L10n.text(.editorTranslations))
            }
            Section {
                TextField(L10n.text(.editorExample), text: $form.exampleSource, axis: .vertical)
                    .lineLimit(1...4)
                TextField(L10n.text(.editorExampleTranslation), text: $form.exampleTranslation, axis: .vertical)
                    .lineLimit(1...4)
            } header: {
                Text(L10n.text(.editorExample))
            } footer: {
                if hasVariants {
                    Text(L10n.text(.mobileEditVariantsKept))
                }
            }
            if let errorText {
                Section {
                    Text(errorText)
                        .foregroundStyle(Color.red)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text(saveKey)) {
                    save()
                }
                .disabled(isSaving || !form.canSave)
            }
        }
    }

    private var title: String {
        switch mode {
        case .create:
            return L10n.text(.addTitle)
        case .edit:
            return L10n.text(.editorTitle)
        }
    }

    private var saveKey: L10nKey {
        switch mode {
        case .create:
            return .commonAdd
        case .edit:
            return .commonSave
        }
    }

    /// У запису є варіанти (італійська) — підказка, що редагування їх не зітре.
    private var hasVariants: Bool {
        guard case .edit(let entry) = mode else { return false }
        return !(entry.variants?.isEmpty ?? true)
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorText = nil
        let form = self.form
        let mode = self.mode
        Task<Void, Never> { @MainActor in
            let succeeded: Bool
            switch mode {
            case .create:
                let draft = form.makeDraft(languagePair: model.languagePairID)
                succeeded = await model.addManual(draft) != nil
            case .edit(let original):
                // Свіжий стан запису (міг змінитися, напр. оновився варіант), поверх нього — поля форми.
                let base = model.entry(id: original.id) ?? original
                succeeded = await model.update(form.applied(to: base)) != nil
            }
            isSaving = false
            if succeeded {
                finish()
            } else {
                errorText = model.consumeOperationError()
            }
        }
    }

    private func finish() {
        if let onFinish {
            onFinish()
        } else {
            dismiss()
        }
    }
}
