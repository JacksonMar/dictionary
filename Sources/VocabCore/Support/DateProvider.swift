import Foundation

/// Джерело поточного часу. Усі дати в записах створюються через нього.
public protocol DateProvider: Sendable {
    func now() -> Date
}

/// Системний час, обрізаний до цілих секунд (щоб round-trip через ISO8601 без дробових секунд був точним).
public struct SystemDateProvider: DateProvider {
    public init() {}

    public func now() -> Date {
        Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    }
}

/// Керований час для тестів.
public final class FixedDateProvider: DateProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDate: Date

    public init(_ date: Date) {
        self.storedDate = date
    }

    public var current: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedDate
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedDate = newValue
        }
    }

    public func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        storedDate = storedDate.addingTimeInterval(interval)
    }

    public func now() -> Date {
        current
    }
}
