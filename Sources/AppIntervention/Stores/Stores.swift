import Foundation
import Synchronization

// MARK: - PassStore

/// Passes, one per app.
///
/// Synchronous by design: callers are an intent's `perform()` and main-actor UI, and each call
/// is one small file operation. Implementations must be safe from any thread; file-backed ones
/// also across processes.
public protocol PassStore: Sendable {
    func allPasses() throws(InterventionError) -> [Pass]
    /// Atomic read-modify-write for one app. Returning `nil` from `transform` removes the pass.
    @discardableResult
    func update(appID: GuardedApp.ID, _ transform: (Pass?) -> Pass?) throws(InterventionError) -> Pass?
}

extension PassStore {
    public func pass(for appID: GuardedApp.ID) throws(InterventionError) -> Pass? {
        try allPasses().first { $0.appID == appID }
    }

    public func save(_ pass: Pass) throws(InterventionError) {
        try update(appID: pass.appID) { _ in pass }
    }

    public func removePass(for appID: GuardedApp.ID) throws(InterventionError) {
        try update(appID: appID) { _ in nil }
    }

    /// Removes passes that have expired and whose return window (if any) has ended too.
    public func removeExpired(asOf date: Date) throws(InterventionError) {
        for pass in try allPasses() where pass.isExpired(at: date) {
            try update(appID: pass.appID) { current in
                guard let current, current.isExpired(at: date) else { return current }
                return nil
            }
        }
    }
}

/// A ``PassStore`` in memory. For tests and previews.
public final class InMemoryPassStore: PassStore {
    private let passes = Mutex<[GuardedApp.ID: Pass]>([:])

    public init(_ initial: [Pass] = []) {
        passes.withLock { store in for pass in initial { store[pass.appID] = pass } }
    }

    public func allPasses() throws(InterventionError) -> [Pass] {
        passes.withLock { $0.values.sorted { $0.appID < $1.appID } }
    }

    @discardableResult
    public func update(appID: GuardedApp.ID, _ transform: (Pass?) -> Pass?) throws(InterventionError) -> Pass? {
        passes.withLock { store in
            let next = transform(store[appID])
            store[appID] = next
            return next
        }
    }
}

// MARK: - OpenLogStore

/// The append-only open log. Retention is the implementation's business.
public protocol OpenLogStore: Sendable {
    func append(_ event: OpenEvent) throws(InterventionError)
    /// Events in ascending date order, limited to `[interval.start, interval.end)` when given.
    func events(in interval: DateInterval?) throws(InterventionError) -> [OpenEvent]
}

/// An ``OpenLogStore`` in memory. For tests and previews.
public final class InMemoryOpenLogStore: OpenLogStore {
    private let storage = Mutex<[OpenEvent]>([])

    public init(_ initial: [OpenEvent] = []) {
        storage.withLock { $0 = initial }
    }

    public func append(_ event: OpenEvent) throws(InterventionError) {
        storage.withLock { $0.append(event) }
    }

    public func events(in interval: DateInterval?) throws(InterventionError) -> [OpenEvent] {
        storage.withLock { events in
            events
                .filter { event in interval.map { $0.start <= event.date && event.date < $0.end } ?? true }
                .sorted { $0.date < $1.date }
        }
    }
}

// MARK: - InterventionHandoff

/// What happened to the pending intervention.
public enum HandoffChange: Sendable, Hashable {
    /// A context was posted.
    case posted(UUID)
    /// A context was taken by a reader (usually the inbox).
    case taken(UUID)
    /// The context is void: the app could not come forward, or it was resolved elsewhere.
    /// Readers that already hold it must drop it.
    case withdrawn(UUID)
}

/// One slot carrying the pending intervention from the intent to the host UI.
public protocol InterventionHandoff: Sendable {
    func post(_ context: InterventionContext) throws(InterventionError)
    /// Removes and returns the pending context. Returns `nil` when there is none or it is older
    /// than `maxAge` (a pause screen for an open from ten minutes ago would be wrong).
    func take(now: Date, maxAge: Duration) throws(InterventionError) -> InterventionContext?
    /// Removes the pending context if it is `contextID`, and announces
    /// ``HandoffChange/withdrawn(_:)`` either way so a reader that already took it drops it.
    func withdraw(contextID: UUID) throws(InterventionError)
    /// Changes in this process. The default implementation returns a finished stream; readers
    /// then rely on ``InterventionInbox/refresh()``.
    func changes() -> AsyncStream<HandoffChange>
}

extension InterventionHandoff {
    /// Removes any pending context.
    public func clear() throws(InterventionError) {
        _ = try take(now: .distantPast, maxAge: .zero)
    }

    public func changes() -> AsyncStream<HandoffChange> {
        AsyncStream { $0.finish() }
    }
}

package func isFresh(_ context: InterventionContext, now: Date, maxAge: Duration) -> Bool {
    let age = now.timeIntervalSince(context.requestedAt)
    return age <= maxAge.timeInterval && age >= -60
}

/// An ``InterventionHandoff`` in memory. For tests, previews, and hosts that never need the
/// context to survive the process.
public final class InMemoryInterventionHandoff: InterventionHandoff {
    private let slot = Mutex<InterventionContext?>(nil)
    private let broadcaster = Broadcaster<HandoffChange>()

    public init() {}

    public func post(_ context: InterventionContext) throws(InterventionError) {
        slot.withLock { $0 = context }
        broadcaster.yield(.posted(context.id))
    }

    public func take(now: Date, maxAge: Duration) throws(InterventionError) -> InterventionContext? {
        let taken = slot.withLock { value -> InterventionContext? in
            defer { value = nil }
            return value
        }
        guard let taken else { return nil }
        broadcaster.yield(.taken(taken.id))
        return isFresh(taken, now: now, maxAge: maxAge) ? taken : nil
    }

    public func withdraw(contextID: UUID) throws(InterventionError) {
        slot.withLock { value in
            if value?.id == contextID { value = nil }
        }
        broadcaster.yield(.withdrawn(contextID))
    }

    public func changes() -> AsyncStream<HandoffChange> { broadcaster.stream() }
}
