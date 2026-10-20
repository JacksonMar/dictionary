import SwiftUI
import VocabCore

/// Діалоги імпорту/експорту (§10): вибір режиму («Об'єднати» — за замовчуванням, «Замінити»), підтвердження
/// заміни з попередженням про бекап і алерт з результатом (звіт або помилка). Стан — у `AppModel`.
struct ImportModeDialog: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                L10n.text(.importDialogTitle),
                isPresented: chooseModeBinding,
                titleVisibility: .visible
            ) {
                // Перша кнопка — дія за замовчуванням.
                Button(L10n.text(.importDialogMerge)) {
                    model.selectImportMode(.merge)
                }
                .keyboardShortcut(.defaultAction)
                Button(L10n.text(.importDialogReplaceEllipsis), role: .destructive) {
                    model.selectImportMode(.replace)
                }
                Button(L10n.text(.commonCancel), role: .cancel) {
                    model.cancelImport()
                }
            } message: {
                Text(L10n.text(.importDialogMessage))
            }
            .alert(L10n.text(.importDialogConfirmTitle), isPresented: confirmReplaceBinding) {
                Button(L10n.text(.importDialogReplace), role: .destructive) {
                    model.confirmReplaceImport()
                }
                Button(L10n.text(.commonCancel), role: .cancel) {
                    model.cancelImport()
                }
            } message: {
                Text(L10n.text(.importDialogConfirmMessage))
            }
            .alert(
                model.transferMessage?.title ?? "",
                isPresented: transferMessageBinding,
                presenting: model.transferMessage
            ) { _ in
                Button(L10n.text(.commonOk)) {
                    model.transferMessage = nil
                }
            } message: { message in
                Text(message.text)
            }
    }

    // Сеттери скидають стан лише якщо він не змінився в дії кнопки (напр. «Замінити…» переводить у
    // `.confirmReplace` до того, як SwiftUI закриє діалог вибору).

    private var chooseModeBinding: Binding<Bool> {
        Binding(
            get: {
                if case .chooseMode? = model.importStage { return true }
                return false
            },
            set: { isPresented in
                if !isPresented, case .chooseMode? = model.importStage {
                    model.cancelImport()
                }
            }
        )
    }

    private var confirmReplaceBinding: Binding<Bool> {
        Binding(
            get: {
                if case .confirmReplace? = model.importStage { return true }
                return false
            },
            set: { isPresented in
                if !isPresented, case .confirmReplace? = model.importStage {
                    model.cancelImport()
                }
            }
        )
    }

    private var transferMessageBinding: Binding<Bool> {
        Binding(
            get: { model.transferMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.transferMessage = nil
                }
            }
        )
    }
}

extension View {
    /// Діалоги імпорту/експорту для `AppModel`.
    func importModeDialog(model: AppModel) -> some View {
        modifier(ImportModeDialog(model: model))
    }
}
