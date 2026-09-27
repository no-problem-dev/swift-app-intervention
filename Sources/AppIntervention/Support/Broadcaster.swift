import Foundation
import Synchronization

/// Fans one value out to every live `AsyncStream`. In-process only.
package final class Broadcaster<Element: Sendable>: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])

    package init() {}

    package func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    package func yield(_ element: Element) {
        let targets = continuations.withLock { Array($0.values) }
        for continuation in targets { continuation.yield(element) }
    }
}
