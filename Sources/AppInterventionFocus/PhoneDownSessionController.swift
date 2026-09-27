import AppIntervention
import Foundation
import Observation

/// Runs a ``PhoneDownSession``: persists every transition, feeds it device events and guarded
/// opens, and publishes outcomes.
///
/// Outcomes can be delivered more than once (after a relaunch, until ``acknowledgeOutcome()``);
/// grant rewards idempotently by ``PhoneDownOutcome/sessionID``.
@MainActor @Observable
public final class PhoneDownSessionController {
    public private(set) var session: PhoneDownSession?

    @ObservationIgnored private let store: any PhoneDownSessionStore
    @ObservationIgnored private let guardedOpens: any GuardedOpenSource
    @ObservationIgnored private let clock: any InterventionClock
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private let broadcaster = Broadcaster<PhoneDownOutcome>()
    @ObservationIgnored private var emitted: UUID?

    public init(
        store: any PhoneDownSessionStore,
        guardedOpens: any GuardedOpenSource,
        clock: any InterventionClock = SystemClock(),
        tickInterval: Duration = .seconds(1)
    ) {
        self.store = store
        self.guardedOpens = guardedOpens
        self.clock = clock
        self.tickInterval = tickInterval
    }

    /// Terminal outcomes, as they happen.
    public func outcomes() -> AsyncStream<PhoneDownOutcome> { broadcaster.stream() }

    /// Starts a new session, replacing any previous one.
    public func start(duration: Duration, configuration: PhoneDownSession.Configuration = .init()) throws(InterventionError) {
        let new = PhoneDownSession.start(at: clock.now, duration: duration, configuration: configuration)
        try store.save(new)
        session = new
        emitted = nil
    }

    public func cancel() {
        guard var current = session else { return }
        current.cancel(at: clock.now)
        commit(current)
    }

    public func handle(_ event: PhoneDownEvent) {
        guard var current = session, !current.phase.isTerminal else { return }
        current.handle(event)
        commit(current)
    }

    /// Restores the persisted session after a relaunch or on scene activation.
    ///
    /// Applies guarded opens logged since the session started (the decisive signal survives the
    /// process), then, when the app is active, `becameActive(now)`. Re-publishes an outcome that
    /// was never acknowledged.
    public func resume(appIsActive: Bool) {
        guard let stored = try? store.load() else { return }
        session = stored
        if !stored.phase.isTerminal {
            if let first = (try? guardedOpens.opens(since: stored.startedAt))?.first(where: { $0.date < stored.endsAt }) {
                handle(.guardedAppOpened(appID: first.appID, at: first.date))
            }
            if appIsActive { handle(.becameActive(clock.now)) }
        }
        if let outcome = session?.outcome {
            emitted = outcome.sessionID
            broadcaster.yield(outcome)
        }
    }

    /// The host has booked the outcome: forget the session.
    public func acknowledgeOutcome() {
        try? store.clear()
        session = nil
        emitted = nil
    }

    /// Consumes device events, live guarded opens and a periodic tick until cancelled.
    /// Run it from a `.task` on a view that lives as long as the app.
    public func run(events source: some PhoneDownEventSource) async {
        let deviceEvents = source.events()
        let opens = guardedOpens.liveOpens()
        let interval = tickInterval
        let device = Task { @MainActor [weak self] in
            for await event in deviceEvents { self?.handle(event) }
        }
        let guarded = Task { @MainActor [weak self] in
            for await open in opens { self?.handle(.guardedAppOpened(appID: open.appID, at: open.date)) }
        }
        let ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.handle(.tick(self.clock.now))
            }
        }
        await withTaskCancellationHandler {
            await device.value
            await guarded.value
            await ticker.value
        } onCancel: {
            device.cancel()
            guarded.cancel()
            ticker.cancel()
        }
    }

    private func commit(_ updated: PhoneDownSession) {
        session = updated
        try? store.save(updated)
        if let outcome = updated.outcome, emitted != outcome.sessionID {
            emitted = outcome.sessionID
            broadcaster.yield(outcome)
        }
    }
}
