// SPIKE CODE (IOS_PLAN.md stage I0) — replaced in I1a.
//
// Purpose: verify on a real iPhone with a free Personal Team that the app installs, the App Group container is
// reachable, the Share extension can drop files into it and the widget deep link (`vocabapp://voice`) opens the app.
// UI strings are plain English literals on purpose: the hardcoded-strings scan (no Cyrillic literals) is extended to
// `Mobile/` in I1a, when this file is rewritten on top of `L10n`.

import SwiftUI

// MARK: - App Group probe (testable: group ID and container lookup are injected)

/// Probes the App Group container: resolves it, writes a probe file, reads it back and lists the files written by
/// the Share extension. Never throws and never crashes — every failure becomes a `Status`.
struct AppGroupProbe {
    /// Info.plist key with the App Group identifier (`$(VOCAB_APP_GROUP)` expanded at build time).
    static let infoPlistKey = "VocabAppGroupID"
    /// Subdirectory of the container shared with the Share extension (the extension uses the same literal).
    static let probeDirectoryName = "SpikeProbes"
    static let appProbeFileName = "app-probe.txt"
    static let shareProbePrefix = "share-"

    enum Status: Equatable {
        case ok(containerPath: String)
        case missingGroupID
        case containerUnavailable(groupID: String)
        case ioError(String)

        var isOK: Bool {
            if case .ok = self { return true }
            return false
        }
    }

    struct ProbeFile: Equatable, Identifiable {
        let name: String
        let content: String
        var id: String { name }
    }

    let groupID: String?
    private let fileManager: FileManager
    private let containerURL: (String) -> URL?

    init(groupID: String?, fileManager: FileManager = .default, containerURL: @escaping (String) -> URL?) {
        self.groupID = Self.normalizedGroupID(groupID)
        self.fileManager = fileManager
        self.containerURL = containerURL
    }

    /// Production wiring: group ID from the bundle's Info.plist, container from `FileManager`.
    static func live(bundle: Bundle = .main, fileManager: FileManager = .default) -> AppGroupProbe {
        let raw = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String
        return AppGroupProbe(groupID: raw, fileManager: fileManager) { identifier in
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        }
    }

    /// Empty values and unexpanded build-setting references (`$(...)`) count as "no group".
    static func normalizedGroupID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains("$(") else {
            return nil
        }
        return trimmed
    }

    private func probeDirectory() -> Result<URL, Status> {
        guard let groupID else { return .failure(.missingGroupID) }
        guard let container = containerURL(groupID) else {
            return .failure(.containerUnavailable(groupID: groupID))
        }
        return .success(container.appendingPathComponent(Self.probeDirectoryName, isDirectory: true))
    }

    /// Writes `app-probe.txt` with a timestamp and reads it back.
    func run(now: Date = Date()) -> Status {
        let directory: URL
        switch probeDirectory() {
        case .success(let url): directory = url
        case .failure(let status): return status
        }
        let fileURL = directory.appendingPathComponent(Self.appProbeFileName)
        let payload = "app probe \(now.timeIntervalSince1970)"
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(payload.utf8).write(to: fileURL, options: .atomic)
            let readBack = try String(contentsOf: fileURL, encoding: .utf8)
            guard readBack == payload else {
                return .ioError("read-back mismatch")
            }
            return .ok(containerPath: directory.deletingLastPathComponent().path)
        } catch {
            return .ioError(error.localizedDescription)
        }
    }

    /// Files `share-*.txt` written by the Share extension, newest first (names start with a millisecond timestamp).
    func shareProbeFiles() -> [ProbeFile] {
        guard case .success(let directory) = probeDirectory() else { return [] }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            return [] // directory does not exist yet: nothing shared so far
        }
        return urls
            .filter { $0.lastPathComponent.hasPrefix(Self.shareProbePrefix) && $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { url in
                let content = (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>"
                return ProbeFile(name: url.lastPathComponent, content: String(content.prefix(200)))
            }
    }
}

// MARK: - Model

@MainActor
final class SpikeModel: ObservableObject {
    @Published private(set) var status: AppGroupProbe.Status = .missingGroupID
    @Published private(set) var shareFiles: [AppGroupProbe.ProbeFile] = []
    @Published private(set) var lastRefresh: Date?
    @Published var lastOpenedURL: String?

    private let probe: AppGroupProbe

    init(probe: AppGroupProbe = .live()) {
        self.probe = probe
    }

    var groupID: String { probe.groupID ?? "<missing>" }

    func refresh() {
        status = probe.run()
        shareFiles = probe.shareProbeFiles()
        lastRefresh = Date()
    }
}

// MARK: - App

@main
struct VocabMobileApp: App {
    @StateObject private var model = SpikeModel()

    var body: some Scene {
        WindowGroup {
            SpikeView(model: model)
                .onOpenURL { url in
                    model.lastOpenedURL = url.absoluteString
                    model.refresh()
                }
        }
    }
}

struct SpikeView: View {
    @ObservedObject var model: SpikeModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section("App Group") {
                    Text(statusText)
                        .font(.headline)
                        .foregroundStyle(model.status.isOK ? Color.green : Color.red)
                    LabeledContent("Group ID", value: model.groupID)
                    if case .ok(let path) = model.status {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Section("Last opened URL") {
                    Text(model.lastOpenedURL ?? "none")
                        .textSelection(.enabled)
                }
                Section("Share extension probe files (\(model.shareFiles.count))") {
                    if model.shareFiles.isEmpty {
                        Text("No files yet. Select text in Safari or Notes, tap Share, choose VocabApp.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.shareFiles) { file in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name).font(.caption.monospaced())
                            Text(file.content).font(.body)
                        }
                    }
                }
                if let lastRefresh = model.lastRefresh {
                    Section {
                        Text("Refreshed \(lastRefresh.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("VocabApp I0 spike")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") { model.refresh() }
                }
            }
        }
        .onAppear { model.refresh() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                model.refresh()
            }
        }
    }

    private var statusText: String {
        switch model.status {
        case .ok:
            return "App Group: OK"
        case .missingGroupID:
            return "App Group: unavailable (no VocabAppGroupID in Info.plist)"
        case .containerUnavailable(let groupID):
            return "App Group: unavailable (no container for \(groupID))"
        case .ioError(let message):
            return "App Group: unavailable (I/O error: \(message))"
        }
    }
}
