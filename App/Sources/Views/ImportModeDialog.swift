import SwiftUI
import VocabCore

/// Діалоги імпорту/експорту (§10): вибір режиму («Об'єднати» — за замовчуванням, «Замінити»), підтвердження
/// заміни з попередженням про бекап і алерт з результатом (звіт або помилка). Стан — у `AppModel`.
struct ImportModeDialog: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Імпорт словника",
                isPresented: chooseModeBinding,
                titleVisibility: .visible
            ) {
                // Перша кнопка — дія за замовчуванням.
                Button("Об'єднати") {
                    model.selectImportMode(.merge)
                }
                .keyboardShortcut(.defaultAction)
                Button("Замінити…", role: .destructive) {
                    model.selectImportMode(.replace)
                }
                Button("Скасувати", role: .cancel) {
                    model.cancelImport()
                }
            } message: {
                Text("«Об'єднати»: нові записи буде додано, при конфлікті перемагає пізніша зміна.\n"
                    + "«Замінити»: поточний словник буде повністю замінено вмістом файлу.")
            }
            .alert("Замінити словник?", isPresented: confirmReplaceBinding) {
                Button("Замінити", role: .destructive) {
                    model.confirmReplaceImport()
                }
                Button("Скасувати", role: .cancel) {
                    model.cancelImport()
                }
            } message: {
                Text("Поточний буде збережено в Backups.")
            }
            .alert(
                model.transferMessage?.title ?? "",
                isPresented: transferMessageBinding,
                presenting: model.transferMessage
            ) { _ in
                Button("OK") {
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
