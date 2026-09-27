import Foundation
import Synchronization

/// The source of "now". Injected everywhere so decisions are reproducible in tests.
public protocol InterventionClock: Sendable {
    var now: Date { get }
}

/// The wall clock.
public struct SystemClock: InterventionClock {
    public init() {}
    public var now: Date { Date() }
}

/// A clock that only moves when told to. For tests and previews.
public final class ManualClock: InterventionClock {
    private let current: Mutex<Date>

    public init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = Mutex(start)
    }

    public var now: Date { current.withLock { $0 } }

    public func set(_ date: Date) { current.withLock { $0 = date } }

    public func advance(by duration: Duration) {
        current.withLock { $0 = $0.addingTimeInterval(duration.timeInterval) }
    }
}

extension Duration {
    /// The duration in seconds as a `TimeInterval`.
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    /// The duration in whole milliseconds, rounded down.
    public var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}

extension Date {
    func adding(_ duration: Duration) -> Date { addingTimeInterval(duration.timeInterval) }
}
