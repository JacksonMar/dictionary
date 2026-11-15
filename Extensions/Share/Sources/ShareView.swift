import SwiftUI
import VocabCore

/// Стан листа «Поділитися»: «Збереження…» → результат (`ShareSaveOutcome`). Усе на головному акторі.
@MainActor
final class ShareViewModel: ObservableObject {
    enum State: Equatable {
        case saving
        case finished(ShareSaveOutcome)
    }

    @Published private(set) var state: State = .saving
    let language: AppLanguage
    private let onDone: () -> Void

    init(language: AppLanguage, onDone: @escaping () -> Void) {
        self.language = language
        self.onDone = onDone
    }

    func show(_ outcome: ShareSaveOutcome) {
        state = .finished(outcome)
    }

    /// «Готово» або автозакриття після успіху.
    func done() {
        onDone()
    }
}

/// Маленьке підтвердження в листі «Поділитися» (IOS_PLAN I3): «Збережено — переклад з'явиться, коли ви відкриєте
/// VocabApp» або причина, чому не збережено, і кнопка «Готово». Тексти — `L10n` мовою системи (`language`).
@MainActor
struct ShareView: View {
    @ObservedObject var model: ShareViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                icon
                    .font(.system(size: 40))
                Text(text(.shareTitle))
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if case .finished = model.state {
                    Button {
                        model.done()
                    } label: {
                        Text(text(.shareDone))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(24)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch model.state {
        case .saving:
            ProgressView()
                .controlSize(.large)
        case .finished(let outcome):
            if outcome.isSuccess {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                    .accessibilityHidden(true)
            }
        }
    }

    private var message: String {
        switch model.state {
        case .saving:
            return text(.shareSaving)
        case .finished(let outcome):
            return outcome.message(language: model.language)
        }
    }

    private func text(_ key: L10nKey) -> String {
        L10n.text(key, language: model.language)
    }
}
