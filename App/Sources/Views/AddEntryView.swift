import SwiftUI
import VocabCore

/// Ручне додавання запису (D14): усі поля вручну (статус `ready`) або «Заповнити через Claude» —
/// лише слово/фраза, решту заповнює Claude через `AddWordUseCase` (запис спершу зберігається як `pending`).
struct AddEntryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var form = EntryFormData()
    @State private var errorText: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text(.addTitle))
                    .font(.headline)
                Spacer()
                if model.isSpeechAvailable {
                    Button {
                        model.speak(form.word, languagePair: model.languagePairID)
                    } label: {
                        Label(L10n.text(.commonSpeak), systemImage: "speaker.wave.2")
                    }
                    .help(L10n.text(.addSpeakHelp))
                    .disabled(!form.canSave)
                }
            }
            EntryFormFields(form: $form)
            if let errorText {
                Text(errorText)
                    .foregroundColor(.red)
            }
            if model.isClaudeAvailable && !model.hasAPIKey {
                Text(L10n.text(.addNoKeyHint))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.isClaudeAvailable {
                    Button(L10n.text(.addFillViaClaude)) {
                        fillViaClaude()
                    }
                    .help(L10n.text(.addFillViaClaudeHelp))
                    .disabled(isSaving || !form.canSave)
                }
                Spacer()
                Button(L10n.text(.commonCancel)) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.text(.commonAdd)) {
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
        let draft = form.makeDraft(languagePair: model.languagePairID)
        Task { @MainActor in
            let result = await model.addManual(draft)
            isSaving = false
            if result != nil {
                dismiss()
            } else {
                errorText = model.operationError
                model.operationError = nil
            }
        }
    }

    /// Запис створюється й обробляється через `AddWordUseCase`. Аркуш закривається, якщо запис збережено
    /// (`ready`, `pending` або `failed` — статус і «Повторити» видно в списку; помилку `failed` покаже вікно).
    @MainActor
    private func fillViaClaude() {
        isSaving = true
        errorText = nil
        let word = form.word
        Task { @MainActor in
            let outcome = await model.addViaClaude(word)
            isSaving = false
            switch outcome {
            case .added?, .queued?, .failed?:
                dismiss()
            case .duplicate?, .rejected?, .storageError?, nil:
                errorText = model.operationError
                model.operationError = nil
            }
        }
    }
}
