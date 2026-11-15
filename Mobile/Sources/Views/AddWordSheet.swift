import SwiftUI
import VocabCore

/// Аркуш додавання (IOS_PLAN §5): мікрофон з перемикачем EN | IT (`VoiceCaptureView`, I2b), поле + «Додати через
/// Claude» (`AddWordUseCase`: запис спершу `pending`, далі 1 запит; дубль — 0 запитів і повідомлення в аркуші) і
/// «Заповнити вручну» → `EntryEditView` (D14, статус ready, 0 запитів). Введене слово закриває аркуш, коли запис
/// збережено (`ready`, `pending` або `failed` — статус і «Повторити» видно в списку); голос показує результат-картку.
///
/// Поки голосове введення активне (не `idle`), поле введення приховане: у голосу власне редаговане поле.
/// Глибоке посилання `vocabapp://voice[?lang=…]` (`Router.takeVoiceCapture()`) одразу запускає слухання, якщо
/// дозволи вже є (DI10, §4). Закриття аркуша зупиняє мікрофон.
@MainActor
struct AddWordSheet: View {
    @ObservedObject var model: MobileAppModel
    @ObservedObject var router: Router
    @StateObject private var voice: VoiceCaptureModel
    @Environment(\.dismiss) private var dismiss

    /// Аркуш відкрито глибоким посиланням голосу — поле введення не фокусуємо (клавіатура не закриває мікрофон).
    private let openedForVoice: Bool

    @State private var text: String = ""
    @State private var errorText: String?
    @State private var isSaving: Bool = false
    @FocusState private var isFieldFocused: Bool

    init(model: MobileAppModel, router: Router) {
        self.model = model
        self.router = router
        _voice = StateObject(wrappedValue: model.makeVoiceCaptureModel())
        if case .voiceCapture = router.route {
            openedForVoice = true
        } else {
            openedForVoice = false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VoiceCaptureView(voice: voice) {
                        close()
                    }
                    // Поки додається введене слово, мікрофон недоступний (інакше поле зникло б посеред запиту).
                    .disabled(isSaving)
                } header: {
                    Text(L10n.text(.voiceAddWithVoice))
                }
                if voice.phase == .idle {
                    textSections
                }
            }
            .navigationTitle(L10n.text(.addTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text(.commonCancel)) {
                        close()
                    }
                }
            }
            .onAppear {
                if !openedForVoice {
                    isFieldFocused = true
                }
            }
            .onDisappear {
                voice.cancel()
            }
            .onChange(of: voice.phase) { (_: VoiceCaptureModel.Phase, newPhase: VoiceCaptureModel.Phase) in
                if newPhase != .idle {
                    isFieldFocused = false
                }
            }
            .onChange(of: router.route, initial: true) { (_: AppRoute, _: AppRoute) in
                guard let launch = router.takeVoiceCapture() else { return }
                isFieldFocused = false
                let voice = self.voice
                Task<Void, Never> { @MainActor in
                    await voice.launch(languageID: launch.languageID)
                }
            }
        }
        .interactiveDismissDisabled(isSaving || voice.phase == .submitting)
    }

    @ViewBuilder
    private var textSections: some View {
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
                            .accessibilityLabel(Text(L10n.text(.mobileAddWorking)))
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

    /// «Скасувати» / «Готово»: мікрофон зупиняється до закриття аркуша.
    private func close() {
        voice.cancel()
        dismiss()
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
