import AppKit
import SwiftUI
import VocabCore

/// Налаштування: API-ключ (лише в Keychain, значення ніколи не показується), модель Claude (M2),
/// вигляд — тема й розмір сторінки (M6), автозапуск (M5, `SMAppService`), перенесення словника — експорт/імпорт (M4).
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var apiKeyInput = ""
    @State private var modelInput = ""

    var body: some View {
        Form {
            Section {
                SecureField("API-ключ", text: $apiKeyInput)
                HStack {
                    Button("Зберегти ключ") {
                        if model.saveAPIKey(apiKeyInput) {
                            apiKeyInput = ""
                        }
                    }
                    .disabled(trimmed(apiKeyInput).isEmpty)
                    if model.hasAPIKey {
                        Button("Видалити ключ", role: .destructive) {
                            model.deleteAPIKey()
                        }
                    }
                    Spacer()
                }
                Label(
                    model.hasAPIKey ? "Ключ збережено" : "Ключ не задано",
                    systemImage: model.hasAPIKey ? "checkmark.seal" : "exclamationmark.triangle"
                )
                .foregroundColor(model.hasAPIKey ? .secondary : .orange)
            } header: {
                Text("Claude API")
                    .font(.headline)
            }

            Section {
                TextField("Модель", text: $modelInput)
                HStack {
                    Button("Зберегти модель") {
                        model.setModel(modelInput)
                        modelInput = model.modelName
                    }
                    .disabled(trimmed(modelInput) == model.modelName)
                    Button("Типова (\(SettingsDefaults.model))") {
                        model.resetModelToDefault()
                        modelInput = model.modelName
                    }
                    .disabled(model.modelName == SettingsDefaults.model)
                    Spacer()
                }
                Text("Поточна модель: \(model.modelName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Модель")
                    .font(.headline)
            }

            Section {
                Picker("Тема", selection: appearanceBinding) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("Записів на сторінці", selection: pageSizeBinding) {
                    ForEach(Pagination.pageSizeOptions, id: \.self) { size in
                        Text(String(size)).tag(size)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            } header: {
                Text("Вигляд")
                    .font(.headline)
            }

            if model.isLoginItemAvailable {
                Section {
                    Toggle("Запускати при вході в систему", isOn: launchAtLoginBinding)
                    loginItemStatus
                    if let error = model.loginItemError {
                        Text(error)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Запуск")
                        .font(.headline)
                }
            }

            if model.isTransferAvailable {
                Section {
                    HStack {
                        Button("Експортувати…") {
                            Task { @MainActor in
                                await model.exportWithPanel()
                            }
                        }
                        Button("Імпортувати…") {
                            model.beginImport()
                        }
                        if model.isTransferring {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Spacer()
                    }
                    .disabled(!model.isLoaded || model.isTransferring)
                    Text("Експорт зберігає словник у файл JSON. Імпорт: «Об'єднати» або «Замінити» "
                        + "(поточний словник спершу зберігається в Backups).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Перенесення")
                        .font(.headline)
                }
            }

            if let error = model.settingsError {
                Text(error)
                    .foregroundColor(.red)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            modelInput = model.modelName
            model.refreshLoginItemState()
        }
        // Користувач міг дозволити/заборонити автозапуск у System Settings, поки вікно було відкрите.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLoginItemState()
        }
        .importModeDialog(model: model)
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { model.appearance },
            set: { model.setAppearance($0) }
        )
    }

    private var pageSizeBinding: Binding<Int> {
        Binding(
            get: { model.pageSize },
            set: { model.setPageSize($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    @ViewBuilder
    private var loginItemStatus: some View {
        switch model.loginItemState {
        case .requiresApproval?:
            Text("Потрібен дозвіл: System Settings → General → Login Items (Загальні → Об'єкти входу).")
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Відкрити Login Items") {
                model.openLoginItemsSettings()
            }
        case .notFound?:
            Text("Система не знайшла застосунок для автозапуску. Перемістіть VocabApp у /Applications і спробуйте ще раз.")
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .enabled?, .disabled?, nil:
            EmptyView()
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
