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
            Text("Нове слово")
                .font(.headline)
            EntryFormFields(form: $form)
            if let errorText {
                Text(errorText)
                    .foregroundColor(.red)
            }
            if model.isClaudeAvailable && !model.hasAPIKey {
                Text("API-ключ не задано: слово буде збережено в чергу і перекладено після додавання ключа в налаштуваннях.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.isClaudeAvailable {
                    Button("Заповнити через Claude") {
                        fillViaClaude()
                    }
                    .help("Перекласти слово через Claude і додати в словник")
                    .disabled(isSaving || !form.canSave)
                }
                Spacer()
                Button("Скасувати") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Додати") {
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
