import SwiftUI
import VocabCore

/// Діалоги імпорту/експорту на iOS (ARCHITECTURE §10, як macOS `ImportModeDialog`): вибір режиму («Об'єднати» —
/// за замовчуванням, «Замінити…»), підтвердження заміни з попередженням про бекап і алерт з результатом (звіт
/// імпорту, кількість експортованих записів або помилка). Стан — у `MobileAppModel`.
struct ImportModeDialog: ViewModifier {
    @ObservedObject var model: MobileAppModel

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
            ) { (_: TransferMessage) in
                Button(L10n.text(.commonOk)) {
                    model.transferMessage = nil
                }
            } message: { (message: TransferMessage) in
                Text(message.text)
            }
    }

    // Сеттери скидають стан лише якщо він не змінився в дії кнопки (напр. «Замінити…» переводить у
    // `.confirmReplace` до того, як SwiftUI закриє діалог вибору).

    private var chooseModeBinding: Binding<Bool> {
        Binding<Bool>(
            get: {
                if case .chooseMode? = model.importStage { return true }
                return false
            },
            set: { (isPresented: Bool) in
                if !isPresented, case .chooseMode? = model.importStage {
                    model.cancelImport()
                }
            }
        )
    }

    private var confirmReplaceBinding: Binding<Bool> {
        Binding<Bool>(
            get: {
                if case .confirmReplace? = model.importStage { return true }
                return false
            },
            set: { (isPresented: Bool) in
                if !isPresented, case .confirmReplace? = model.importStage {
                    model.cancelImport()
                }
            }
        )
    }

    private var transferMessageBinding: Binding<Bool> {
        Binding<Bool>(
            get: { model.transferMessage != nil },
            set: { (isPresented: Bool) in
                if !isPresented {
                    model.transferMessage = nil
                }
            }
        )
    }
}

extension View {
    /// Діалоги імпорту/експорту для `MobileAppModel`.
    func importModeDialog(model: MobileAppModel) -> some View {
        modifier(ImportModeDialog(model: model))
    }
}
