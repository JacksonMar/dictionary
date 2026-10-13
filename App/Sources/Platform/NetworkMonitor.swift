import Foundation
import Network

/// Стежить за мережею (`NWPathMonitor` на власній черзі) і викликає `onBecameSatisfied`
/// при переході в `.satisfied` (не при першому оновленні — на старті черга запускається окремо).
final class NetworkMonitor: @unchecked Sendable {
    // `@unchecked`: змінюваний стан (`lastStatus`) читається й пишеться лише на `queue`.
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.vocabapp.VocabApp.network-monitor")
    private let onBecameSatisfied: @Sendable () -> Void
    private var lastStatus: NWPath.Status?

    init(onBecameSatisfied: @escaping @Sendable () -> Void) {
        self.onBecameSatisfied = onBecameSatisfied
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(status: path.status)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    private func handle(status: NWPath.Status) {
        let previous = lastStatus
        lastStatus = status
        if status == .satisfied, let previous, previous != .satisfied {
            onBecameSatisfied()
        }
    }
}
