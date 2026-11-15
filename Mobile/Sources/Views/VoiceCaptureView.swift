import SwiftUI
import UIKit
import VocabCore

/// Голосове введення (IOS_PLAN §5, DI10–DI12): кнопка мікрофона з індикатором рівня і перемикач EN | IT поруч,
/// живий частковий текст, після зупинки — редаговане поле з «Додати» / «Ще раз» (підтвердження завжди, iU15 = (а)),
/// результат-картка з «Озвучити»; відмова в дозволі — посилання «Відкрити Налаштування»; позначка серверного
/// розпізнавання; офлайн та інші помилки — поле для ручного введення.
///
/// Вбудовується в рядок `Form` аркуша додавання: кожна кнопка має явний `buttonStyle` (інакше дотик до рядка
/// спрацьовує на всі кнопки рядка).
@MainActor
struct VoiceCaptureView: View {
    @ObservedObject var voice: VoiceCaptureModel
    /// «Готово» на картці результату (закрити аркуш).
    let onDone: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            micRow
            statusArea
            if voice.showsEditableField {
                editableArea
            }
            if let result = voice.result {
                resultCard(result)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Мікрофон і мова

    private var micRow: some View {
        HStack(spacing: 16) {
            Button {
                Task<Void, Never> { @MainActor in
                    await voice.toggleListening()
                }
            } label: {
                micIcon
            }
            .buttonStyle(.plain)
            .disabled(voice.phase == .requestingPermission || voice.phase == .submitting)
            .accessibilityLabel(Text(voice.isListening ? L10n.text(.voiceMicStop) : L10n.text(.voiceMicStart)))

            Picker(L10n.text(.voiceLanguagePicker), selection: languageBinding) {
                ForEach(VoiceLanguage.allCases) { (language: VoiceLanguage) in
                    Text(verbatim: language.shortTitle)
                        .tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(voice.isBusy)
            .accessibilityHint(Text(L10n.text(.voiceLanguageHint)))

            Spacer(minLength: 0)
        }
    }

    private var micIcon: some View {
        let isListening = voice.isListening
        let levelScale = 1 + CGFloat(voice.level) * 0.35
        return ZStack {
            if isListening {
                Circle()
                    .fill(Color.red.opacity(0.25))
                    .frame(width: 60, height: 60)
                    .scaleEffect(levelScale)
                    .animation(.easeOut(duration: 0.1), value: voice.level)
            }
            Circle()
                .fill(isListening ? Color.red : Color.accentColor)
                .frame(width: 56, height: 56)
            Image(systemName: isListening ? "stop.fill" : "mic.fill")
                .font(.title2)
                .foregroundStyle(Color.white)
        }
        .frame(width: 76, height: 76)
        .contentShape(Circle())
    }

    private var languageBinding: Binding<VoiceLanguage> {
        Binding<VoiceLanguage>(
            get: { voice.language },
            set: { (language: VoiceLanguage) in
                voice.selectLanguage(language)
            }
        )
    }

    // MARK: - Стан

    @ViewBuilder
    private var statusArea: some View {
        switch voice.phase {
        case .idle:
            Text(L10n.text(.voiceIdleHint))
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        case .requestingPermission:
            progressRow(L10n.text(.voiceRequestingPermission))
        case .listening:
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text(.voiceListening))
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                if !voice.partialText.isEmpty {
                    Text(verbatim: voice.partialText)
                        .font(.title3)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                serverNote
            }
        case .recognized:
            VStack(alignment: .leading, spacing: 6) {
                if voice.isFinalizing {
                    progressRow(L10n.text(.voiceFinalizing))
                } else if voice.isRecognitionEmpty {
                    Text(L10n.text(.voiceRecognizedEmpty))
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }
                serverNote
            }
        case .submitting:
            progressRow(L10n.text(.mobileAddWorking))
        case .error(let error):
            VStack(alignment: .leading, spacing: 6) {
                Text(error.message())
                    .foregroundStyle(Color.red)
                if error.showsSettingsLink {
                    Button(L10n.text(.voiceOpenSettings)) {
                        openSettings()
                    }
                    .buttonStyle(.bordered)
                }
                Text(L10n.text(.voiceManualHint))
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
        case .result:
            EmptyView()
        }
    }

    @ViewBuilder
    private var serverNote: some View {
        if voice.usesServerRecognition {
            Label {
                Text(L10n.text(.voiceServerNote))
            } icon: {
                Image(systemName: "icloud")
            }
            .font(.footnote)
            .foregroundStyle(Color.secondary)
        }
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        }
    }

    // MARK: - Підтвердження

    private var editableArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L10n.text(.voiceRecognizedLabel), text: $voice.editableText)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.done)
                .disabled(voice.phase == .submitting)
                .onSubmit {
                    submit()
                }
            if let submitError = voice.submitError {
                Text(submitError)
                    .font(.footnote)
                    .foregroundStyle(Color.red)
            }
            if voice.phase == .recognized && !voice.alternatives.isEmpty {
                alternativesRow
            }
            HStack(spacing: 12) {
                Button {
                    submit()
                } label: {
                    Text(L10n.text(.voiceAdd))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!voice.canSubmit)

                Button {
                    again()
                } label: {
                    Text(L10n.text(.voiceAgain))
                }
                .buttonStyle(.bordered)
                .disabled(voice.isBusy)
            }
        }
    }

    /// Опційні чипи альтернатив (DI12): дотик підставляє варіант у поле.
    private var alternativesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(voice.alternatives, id: \.self) { (alternative: String) in
                    Button {
                        voice.editableText = alternative
                    } label: {
                        Text(verbatim: alternative)
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Результат

    private func resultCard(_ result: VoiceCaptureResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.title)
                .font(.headline)
                .foregroundStyle(result.isFailure ? Color.red : Color.primary)
            Text(result.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if result.speakText != nil && voice.isSpeechAvailable {
                    Button {
                        voice.speakResult()
                    } label: {
                        Label {
                            Text(L10n.text(.commonSpeak))
                        } icon: {
                            Image(systemName: "speaker.wave.2")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    again()
                } label: {
                    Text(L10n.text(.voiceAgain))
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button {
                    onDone()
                } label: {
                    Text(L10n.text(.mobileCommonDone))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    // MARK: - Дії

    private func submit() {
        Task<Void, Never> { @MainActor in
            await voice.submit()
        }
    }

    private func again() {
        Task<Void, Never> { @MainActor in
            await voice.again()
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
