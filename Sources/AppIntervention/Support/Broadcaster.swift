import Foundation
import Synchronization

/// Fans each value out to every live `AsyncStream` made by ``stream(replaying:)``. In-process only.
///
/// Public so custom ``InterventionHandoff`` implementations can back ``InterventionHandoff/changes()``.
public final class Broadcaster<Element: Sendable>: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])

    /// Creates a broadcaster with no subscribers.
    public init() {}

    /// A new subscriber stream. `replaying` values are delivered to this subscriber first.
    public func stream(replaying initial: [Element] = []) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(64))
        for element in initial { continuation.yield(element) }
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    /// Sends `element` to every current subscriber.
    public func yield(_ element: Element) {
        let targets = continuations.withLock { Array($0.values) }
        for continuation in targets { continuation.yield(element) }
    }
}
