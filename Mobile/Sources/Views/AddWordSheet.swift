import SwiftUI
import VocabCore

/// Аркуш додавання (IOS_PLAN §5, I1b — без мікрофона): поле + «Додати через Claude» (`AddWordUseCase`: запис
/// спершу `pending`, далі 1 запит; дубль — 0 запитів і повідомлення в аркуші) і «Заповнити вручну» → `EntryEditView`
/// (D14, статус ready, 0 запитів). Аркуш закривається, коли запис збережено (`ready`, `pending` або `failed` — статус
/// і «Повторити» видно в списку).
@MainActor
struct AddWordSheet: View {
    @ObservedObject var model: MobileAppModel
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var errorText: String?
    @State private var isSaving: Bool = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.text(.editorWord), text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.done)
                        .focused($isFieldFocused)
                        .onSubmit {
                            addViaClaude()
                        }
                } footer: {
                    Text(footerText)
                }
                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(Color.red)
                    }
                }
                Section {
                    Button {
                        addViaClaude()
                    } label: {
                        HStack(spacing: 8) {
                            Text(L10n.text(.mobileAddViaClaude))
                            if isSaving {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!canSubmit)
                    NavigationLink {
                        EntryEditView(model: model, mode: .create(initialWord: text)) {
                            dismiss()
                        }
                    } label: {
                        Text(L10n.text(.mobileAddManual))
                    }
                    .disabled(isSaving)
                }
            }
            .navigationTitle(L10n.text(.addTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text(.commonCancel)) {
                        dismiss()
                    }
                }
            }
            .onAppear {
                isFieldFocused = true
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var canSubmit: Bool {
        !isSaving && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var footerText: String {
        model.hasAPIKey ? L10n.text(.mobileAddHint) : L10n.text(.addNoKeyHint)
    }

    private func addViaClaude() {
        guard canSubmit else { return }
        isSaving = true
        errorText = nil
        let word = text
        Task<Void, Never> { @MainActor in
            let outcome = await model.addViaClaude(word)
            isSaving = false
            switch outcome {
            case .added, .queued:
                dismiss()
            case .failed:
                // Запис збережено як `failed`: аркуш закривається, причину показує алерт списку.
                dismiss()
            case .duplicate, .rejected, .storageError:
                errorText = model.consumeOperationError()
            }
        }
    }
}
