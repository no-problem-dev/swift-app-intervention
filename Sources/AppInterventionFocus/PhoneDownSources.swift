import AppIntervention
import Foundation
import Synchronization

// MARK: - Session store

/// Persists the current session so it survives suspension and termination.
public protocol PhoneDownSessionStore: Sendable {
    func load() throws(InterventionError) -> PhoneDownSession?
    func save(_ session: PhoneDownSession) throws(InterventionError)
    func clear() throws(InterventionError)
}

/// A ``PhoneDownSessionStore`` in `phone-down-session.json`.
public final class FilePhoneDownSessionStore: PhoneDownSessionStore {
    private let file: EnvelopeFile<PhoneDownSession>

    /// Never throws: the location is resolved on first use.
    public init(location: FileStoreLocation) {
        file = EnvelopeFile(ref: FileRef(location: location, name: "phone-down-session.json"))
    }

    /// A store in an already resolved directory.
    public init(resolved: ResolvedFileStoreLocation) {
        file = EnvelopeFile(ref: FileRef(resolved: resolved, name: "phone-down-session.json"))
    }

    public func load() throws(InterventionError) -> PhoneDownSession? { try file.read() }
    public func save(_ session: PhoneDownSession) throws(InterventionError) { try file.modify { $0 = session } }
    public func clear() throws(InterventionError) { try file.modify { $0 = nil } }
}

/// A ``PhoneDownSessionStore`` in memory. For tests and previews.
public final class InMemoryPhoneDownSessionStore: PhoneDownSessionStore {
    private let value = Mutex<PhoneDownSession?>(nil)
    public init(_ session: PhoneDownSession? = nil) { value.withLock { $0 = session } }
    public func load() throws(InterventionError) -> PhoneDownSession? { value.withLock { $0 } }
    public func save(_ session: PhoneDownSession) throws(InterventionError) { value.withLock { $0 = session } }
    public func clear() throws(InterventionError) { value.withLock { $0 = nil } }
}

// MARK: - Guarded opens

/// Where the decisive failure signal comes from: guarded apps opened during a session.
public protocol GuardedOpenSource: Sendable {
    /// `opened` events at or after `since` (for sessions resumed after the process died).
    func opens(since: Date) throws(InterventionError) -> [OpenEvent]
    /// `opened` events as they happen in this process.
    func liveOpens() -> AsyncStream<OpenEvent>
}

/// Reads guarded opens from an `InterventionCoordinator`: its log for the past, its event
/// stream for the present. The host's intent runs in the app process, so the live path is reliable.
public struct CoordinatorGuardedOpenSource: GuardedOpenSource {
    public let coordinator: InterventionCoordinator
    public init(_ coordinator: InterventionCoordinator) { self.coordinator = coordinator }

    public func opens(since: Date) throws(InterventionError) -> [OpenEvent] {
        try coordinator.events(in: DateInterval(start: since, end: .distantFuture)).filter { $0.kind == .opened }
    }

    public func liveOpens() -> AsyncStream<OpenEvent> {
        let upstream = coordinator.eventStream()
        return AsyncStream { continuation in
            let task = Task {
                for await event in upstream where event.kind == .opened { continuation.yield(event) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A scripted ``GuardedOpenSource``. For tests and previews.
public final class ManualGuardedOpenSource: GuardedOpenSource {
    private let events = Mutex<[OpenEvent]>([])
    private let broadcaster = Broadcaster<OpenEvent>()

    public init(_ initial: [OpenEvent] = []) { events.withLock { $0 = initial } }

    public func record(_ event: OpenEvent) {
        events.withLock { $0.append(event) }
        broadcaster.yield(event)
    }

    public func opens(since: Date) throws(InterventionError) -> [OpenEvent] {
        events.withLock { $0.filter { $0.kind == .opened && $0.date >= since } }
    }

    public func liveOpens() -> AsyncStream<OpenEvent> { broadcaster.stream() }
}

// MARK: - Device events

/// Lock, scene and call events. `UIKitPhoneDownEventSource` is the iOS implementation.
@MainActor
public protocol PhoneDownEventSource: AnyObject {
    func events() -> AsyncStream<PhoneDownEvent>
}

/// A scripted ``PhoneDownEventSource``. For tests and previews.
@MainActor
public final class ManualPhoneDownEventSource: PhoneDownEventSource {
    private let broadcaster = Broadcaster<PhoneDownEvent>()
    public init() {}
    public func events() -> AsyncStream<PhoneDownEvent> { broadcaster.stream() }
    public func send(_ event: PhoneDownEvent) { broadcaster.yield(event) }
}
