import Foundation

/// Ties the catalog, policy, stores and handoff together. The only type with side effects.
///
/// Build one in the composition root as a lightweight static that depends only on files: the
/// intent can run in a process launched in the background, before any scene or heavy SDK exists.
public final class InterventionCoordinator: Sendable {
    public let catalog: any GuardedAppCatalog
    public let passes: any PassStore
    public let log: any OpenLogStore
    public let handoff: any InterventionHandoff
    public let hostConditions: any HostConditionProvider
    public let clock: any InterventionClock
    public let returnWindow: Duration
    public let opensLookback: Duration
    private let policy: @Sendable () -> InterventionPolicy
    private let resolutionLock = NSLock()
    private let broadcaster = Broadcaster<OpenEvent>()

    /// - Parameters:
    ///   - policy: Re-read on every run, so settings changes apply immediately.
    ///   - returnWindow: How long after "proceed" the next run counts as the host's own reopen.
    ///   - opensLookback: How much of the log rules see through ``RuleInput/opens``.
    public init(
        catalog: any GuardedAppCatalog,
        policy: @escaping @Sendable () -> InterventionPolicy,
        passes: any PassStore,
        log: any OpenLogStore,
        handoff: any InterventionHandoff,
        hostConditions: any HostConditionProvider = NoHostConditions(),
        clock: any InterventionClock = SystemClock(),
        returnWindow: Duration = .seconds(15),
        opensLookback: Duration = .seconds(2 * 86_400)
    ) {
        self.catalog = catalog
        self.policy = policy
        self.passes = passes
        self.log = log
        self.handoff = handoff
        self.hostConditions = hostConditions
        self.clock = clock
        self.returnWindow = returnWindow
        self.opensLookback = opensLookback
    }

    /// A coordinator over the file stores at `location`.
    public static func files(
        at location: FileStoreLocation,
        catalog: any GuardedAppCatalog,
        policy: @escaping @Sendable () -> InterventionPolicy,
        hostConditions: any HostConditionProvider = NoHostConditions(),
        retention: OpenLogRetention = .init(),
        clock: any InterventionClock = SystemClock()
    ) throws(InterventionError) -> InterventionCoordinator {
        let resolved = try location.resolve()
        return InterventionCoordinator(
            catalog: catalog, policy: policy,
            passes: FilePassStore(resolved: resolved),
            log: FileOpenLogStore(resolved: resolved, retention: retention, clock: clock),
            handoff: FileInterventionHandoff(resolved: resolved),
            hostConditions: hostConditions, clock: clock
        )
    }

    // MARK: - Automation

    /// One automation run: decide in the background and continue in the foreground only to intervene.
    ///
    /// Never throws. Storage failures pass through as ``PassThroughReason/failOpen(_:)``; a
    /// continuation that is impossible or throws removes the posted context and passes through as
    /// ``PassThroughReason/foregroundUnavailable``.
    public func handleAutomationRun(appID: GuardedApp.ID, continuation: some ForegroundContinuation) async -> AutomationRunOutcome {
        let started = ContinuousClock.now
        let decision = await run(appID: appID, continuation: continuation, started: started)
        return AutomationRunOutcome(decision: decision.value, elapsed: decision.elapsed)
    }

    private func run(appID: GuardedApp.ID, continuation: some ForegroundContinuation, started: ContinuousClock.Instant) async -> (value: InterventionDecision, elapsed: Duration) {
        func done(_ decision: InterventionDecision) -> (InterventionDecision, Duration) {
            (decision, ContinuousClock.now - started)
        }

        guard let app = catalog.app(for: appID) else { return done(.passThrough(.notGuarded)) }
        let now = clock.now
        let current = policy()

        let pass: Pass?
        let recent: [OpenEvent]
        do throws(InterventionError) {
            try? passes.removeExpired(asOf: now)
            pass = try passes.pass(for: appID)
            recent = try log.events(in: DateInterval(start: now.addingTimeInterval(-opensLookback.timeInterval), end: now.addingTimeInterval(1)))
        } catch {
            record(OpenEvent(appID: appID, kind: .opened, date: now))
            let reason = PassThroughReason.failOpen(error.code)
            record(OpenEvent(appID: appID, kind: .passedThrough, date: now, note: reason.note))
            return done(.passThrough(reason))
        }

        let snapshot = await hostConditions.snapshot(for: app, at: now)
        let input = RuleInput(
            app: app, now: now, calendar: current.calendar,
            opens: OpenLogQuery(recent, calendar: current.calendar), host: snapshot
        )
        let decision = current.decide(input, pass: pass)

        if case .passThrough(.returnFromIntervention) = decision {
            _ = try? passes.update(appID: appID) { existing in
                guard var existing else { return nil }
                existing.returnWindowEndsAt = nil
                return existing
            }
            record(OpenEvent(appID: appID, kind: .passedThrough, date: now, note: PassThroughReason.returnFromIntervention.note))
            return done(decision)
        }

        record(OpenEvent(appID: appID, kind: .opened, date: now))

        switch decision {
        case .passThrough(let reason):
            record(OpenEvent(appID: appID, kind: .passedThrough, date: now, note: reason.note))
            return done(decision)

        case .intervene(let context):
            do throws(InterventionError) {
                try handoff.post(context)
            } catch {
                let reason = PassThroughReason.failOpen(error.code)
                record(OpenEvent(appID: appID, kind: .passedThrough, date: now, note: reason.note))
                return done(.passThrough(reason))
            }

            if continuation.isForeground {
                record(intervened(context))
                return done(decision)
            }
            if continuation.canContinueInForeground {
                do {
                    try await continuation.continueInForeground()
                    record(intervened(context))
                    return done(decision)
                } catch {
                    // fall through to foregroundUnavailable
                }
            }
            _ = try? handoff.clear()
            record(OpenEvent(appID: appID, kind: .passedThrough, date: now, note: PassThroughReason.foregroundUnavailable.note))
            return done(.passThrough(.foregroundUnavailable))
        }
    }

    private func intervened(_ context: InterventionContext) -> OpenEvent {
        OpenEvent(appID: context.app.id, kind: .intervened, date: context.requestedAt, tier: context.tier, contextID: context.id)
    }

    // MARK: - Resolution

    /// Records how the user resolved `context`, exactly once.
    ///
    /// `.proceed` grants a pass (with a return window, so the reopen that follows passes through
    /// uncounted) and logs `proceeded`; `.abandon` logs `abandoned`. A second call for the same
    /// context throws ``InterventionError/Code/alreadyResolved``. A pending handoff for this
    /// context is cleared.
    @discardableResult
    public func resolve(_ context: InterventionContext, _ resolution: InterventionResolution) throws(InterventionError) -> ResolutionReceipt {
        resolutionLock.lock()
        defer { resolutionLock.unlock() }

        let now = clock.now
        let since = min(context.requestedAt, now).addingTimeInterval(-1)
        let prior = try log.events(in: DateInterval(start: since, end: .distantFuture))
        if prior.contains(where: { $0.contextID == context.id && ($0.kind == .proceeded || $0.kind == .abandoned) }) {
            throw InterventionError(.alreadyResolved, message: "Intervention \(context.id) was already resolved")
        }

        var granted: Pass?
        switch resolution {
        case .proceed(let optionID, let duration):
            let pass = Pass(appID: context.app.id, grantedAt: now, expiresAt: now.adding(duration), returnWindowEndsAt: now.adding(returnWindow))
            try passes.save(pass)
            granted = pass
            try appendAndBroadcast(OpenEvent(appID: context.app.id, kind: .proceeded, date: now, tier: context.tier, contextID: context.id, optionID: optionID))
        case .abandon(let optionID):
            try appendAndBroadcast(OpenEvent(appID: context.app.id, kind: .abandoned, date: now, tier: context.tier, contextID: context.id, optionID: optionID))
        }

        // Clear a still-pending copy of this context; put back anything else.
        if let pending = try? handoff.take(now: now, maxAge: .seconds(Int64.max / 2)), pending.id != context.id {
            try? handoff.post(pending)
        }

        return ResolutionReceipt(contextID: context.id, appID: context.app.id, tier: context.tier, resolution: resolution, resolvedAt: now, pass: granted)
    }

    // MARK: - Passes

    /// Ends the return window early, e.g. when reopening the app failed, so a later manual open counts.
    public func consumeReturnWindow(appID: GuardedApp.ID) throws(InterventionError) {
        try passes.update(appID: appID) { existing in
            guard var existing else { return nil }
            existing.returnWindowEndsAt = nil
            return existing
        }
    }

    @discardableResult
    public func grantPass(appID: GuardedApp.ID, duration: Duration) throws(InterventionError) -> Pass {
        let now = clock.now
        let pass = Pass(appID: appID, grantedAt: now, expiresAt: now.adding(duration))
        try passes.save(pass)
        return pass
    }

    public func revokePass(appID: GuardedApp.ID) throws(InterventionError) {
        try passes.removePass(for: appID)
    }

    // MARK: - Log

    public func events(in interval: DateInterval?) throws(InterventionError) -> [OpenEvent] {
        try log.events(in: interval)
    }

    /// Every event this coordinator appends, in this process.
    public func eventStream() -> AsyncStream<OpenEvent> { broadcaster.stream() }

    /// Best effort: the automation path must not fail on logging, and the live stream still
    /// fires (the phone-down detector relies on it) even when the append failed.
    private func record(_ event: OpenEvent) {
        try? log.append(event)
        broadcaster.yield(event)
    }

    private func appendAndBroadcast(_ event: OpenEvent) throws(InterventionError) {
        try log.append(event)
        broadcaster.yield(event)
    }
}
