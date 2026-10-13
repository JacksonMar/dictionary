import SwiftUI
import VocabCore

/// Ручне додавання запису (D14, M1: усі поля вручну, статус `ready`).
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
            HStack {
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
}
