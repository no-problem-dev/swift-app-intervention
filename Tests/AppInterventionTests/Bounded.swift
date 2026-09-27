import Foundation

// The only place tests may iterate an async sequence. Everything that awaits is bounded, so a
// broken build fails fast instead of hanging the run (scripts/check-bounded-awaits.sh enforces it).

/// Up to `count` values from `stream`, or fewer if `within` elapses first.
func collect<T: Sendable>(_ stream: AsyncStream<T>, count: Int, within: Duration = .seconds(2)) async -> [T] {
    await withTaskGroup(of: [T]?.self) { group in
        group.addTask {
            var values: [T] = []
            guard count > 0 else { return values }
            for await value in stream {
                values.append(value)
                if values.count == count { break }
            }
            return values
        }
        group.addTask {
            try? await Task.sleep(for: within)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? []
    }
}

/// The first value of `stream`, or `nil` if none arrives within `within`.
func firstValue<T: Sendable>(_ stream: AsyncStream<T>, within: Duration = .seconds(2)) async -> T? {
    await collect(stream, count: 1, within: within).first
}

/// Polls `condition` on the main actor until it holds or `within` elapses.
@MainActor
func waitUntil(within: Duration = .seconds(2), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + within
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(2))
    }
}
