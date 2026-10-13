import SwiftUI
import VocabCore

/// Налаштування: API-ключ (лише в Keychain, значення ніколи не показується), модель Claude (M2),
/// перенесення словника — експорт/імпорт (M4). Автозапуск — M5.
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
        }
        .importModeDialog(model: model)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
