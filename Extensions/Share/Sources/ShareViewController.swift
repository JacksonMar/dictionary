// SPIKE CODE (IOS_PLAN.md stage I0) — replaced in I3 (inbox + ShareTextExtractor).
//
// Writes one probe file `share-<timestampMs>-<uuid>.txt` with the shared text (or a marker) into the App Group
// container, atomically (temporary file + move), then closes the share sheet. Never crashes when the App Group is
// unavailable: the request is completed in every path.

import UIKit
import UniformTypeIdentifiers
import os

final class ShareViewController: UIViewController {
    /// Same values as `AppGroupProbe` in the app target (no shared code in the spike).
    private static let infoPlistKey = "VocabAppGroupID"
    private static let probeDirectoryName = "SpikeProbes"
    private static let maxTextLength = 2000

    private let logger = Logger(subsystem: "VocabShare", category: "spike")
    private var didStart = false
    private var didComplete = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        loadSharedText { [weak self] text in
            guard let self else { return }
            self.writeProbe(text: text)
            self.finish()
        }
    }

    // MARK: - Input

    /// Calls `completion` exactly once on the main queue with the shared text, or `nil` if none was found.
    private func loadSharedText(completion: @escaping (String?) -> Void) {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []

        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty {
                completion(text)
                return
            }
        }

        let plainText = UTType.plainText.identifier
        let provider = items
            .flatMap { $0.attachments ?? [] }
            .first { $0.hasItemConformingToTypeIdentifier(plainText) }
        guard let provider else {
            completion(nil)
            return
        }
        provider.loadItem(forTypeIdentifier: plainText, options: nil) { item, error in
            let text: String?
            if let string = item as? String {
                text = string
            } else if let attributed = item as? NSAttributedString {
                text = attributed.string
            } else if let data = item as? Data {
                text = String(data: data, encoding: .utf8)
            } else {
                text = nil
            }
            if let error {
                Logger(subsystem: "VocabShare", category: "spike")
                    .error("loadItem failed: \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async {
                completion(text)
            }
        }
    }

    // MARK: - Output

    private func writeProbe(text: String?) {
        let rawGroupID = Bundle.main.object(forInfoDictionaryKey: Self.infoPlistKey) as? String
        guard let groupID = rawGroupID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupID.isEmpty, !groupID.contains("$(") else {
            logger.error("No App Group ID in Info.plist")
            return
        }
        let fileManager = FileManager.default
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            logger.error("App Group container unavailable for \(groupID, privacy: .public)")
            return
        }

        let directory = container.appendingPathComponent(Self.probeDirectoryName, isDirectory: true)
        let uuid = UUID().uuidString
        let timestampMs = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let temporaryURL = directory.appendingPathComponent(".\(uuid).tmp")
        let finalURL = directory.appendingPathComponent("share-\(timestampMs)-\(uuid).txt")
        let body = text.map { String($0.prefix(Self.maxTextLength)) } ?? "<marker: no text in share input>"

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: temporaryURL)
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
            logger.info("Probe written: \(finalURL.lastPathComponent, privacy: .public)")
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            logger.error("Probe write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finish() {
        guard !didComplete else { return }
        didComplete = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
