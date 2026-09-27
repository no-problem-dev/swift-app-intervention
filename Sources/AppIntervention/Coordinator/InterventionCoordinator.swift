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
    public let hostConditionsTimeout: Duration
    private let policy: @Sendable () -> InterventionPolicy
    private let resolutionLock = NSLock()
    private let broadcaster = Broadcaster<OpenEvent>()

    /// - Parameters:
    ///   - catalog: Resolves the app id the intent receives.
    ///   - policy: Re-read on every run, so settings changes apply immediately.
    ///   - passes: Where passes live.
    ///   - log: The append-only open log.
    ///   - handoff: Carries the pending context to the host UI.
    ///   - hostConditions: Host state for rules, fetched once per run.
    ///   - clock: The source of "now".
    ///   - returnWindow: How long after "proceed" the next run counts as the host's own reopen.
    ///   - opensLookback: How much of the log rules see through ``RuleInput/opens``. Negative
    ///     values are treated as zero.
    ///   - hostConditionsTimeout: How long a run waits for ``HostConditionProvider``. When it
    ///     takes longer, the run passes through (``PassThroughReason/failOpen(_:)`` with
    ///     ``InterventionError/Code/timeout``) instead of holding the user in the guarded app.
    public init(
        catalog: any GuardedAppCatalog,
        policy: @escaping @Sendable () -> InterventionPolicy,
        passes: any PassStore,
        log: any OpenLogStore,
        handoff: any InterventionHandoff,
        hostConditions: any HostConditionProvider = NoHostConditions(),
        clock: any InterventionClock = SystemClock(),
        returnWindow: Duration = .seconds(15),
        opensLookback: Duration = .seconds(2 * 86_400),
        hostConditionsTimeout: Duration = .seconds(2)
    ) {
        self.catalog = catalog
        self.policy = policy
        self.passes = passes
        self.log = log
        self.handoff = handoff
        self.hostConditions = hostConditions
        self.clock = clock
        self.returnWindow = max(returnWindow, .zero)
        self.opensLookback = max(opensLookback, .zero)
        self.hostConditionsTimeout = max(hostConditionsTimeout, .zero)
    }

    /// A coordinator over the file stores at `location`.
    ///
    /// Never throws: the location is resolved on first use. If it cannot be (a missing App Group
    /// entitlement, a read-only disk), automation runs pass through with
    /// ``PassThroughReason/failOpen(_:)`` rather than crashing the intent's process.
    public static func files(
        at location: FileStoreLocation,
        catalog: any GuardedAppCatalog,
        policy: @escaping @Sendable () -> InterventionPolicy,
        hostConditions: any HostConditionProvider = NoHostConditions(),
        retention: OpenLogRetention = .init(),
        clock: any InterventionClock = SystemClock(),
        returnWindow: Duration = .seconds(15),
        opensLookback: Duration = .seconds(2 * 86_400),
        hostConditionsTimeout: Duration = .seconds(2)
    ) -> InterventionCoordinator {
        InterventionCoordinator(
            catalog: catalog, policy: policy,
            passes: FilePassStore(location: location),
            log: FileOpenLogStore(location: location, retention: retention, clock: clock),
            handoff: FileInterventionHandoff(location: location),
            hostConditions: hostConditions, clock: clock,
            returnWindow: returnWindow, opensLookback: opensLookback, hostConditionsTimeout: hostConditionsTimeout
        )
    }

    /// A coordinator that keeps everything in memory. For previews, tests and demos.
    public static func inMemory(
        catalog: any GuardedAppCatalog,
        policy: @escaping @Sendable () -> InterventionPolicy,
        hostConditions: any HostConditionProvider = NoHostConditions(),
        clock: any InterventionClock = SystemClock()
    ) -> InterventionCoordinator {
        InterventionCoordinator(
            catalog: catalog, policy: policy,
            passes: InMemoryPassStore(), log: InMemoryOpenLogStore(), handoff: InMemoryInterventionHandoff(),
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

        guard let snapshot = await snapshotWithinTimeout(for: app, at: now) else {
            record(OpenEvent(appID: appID, kind: .opened, date: now))
            let reason = PassThroughReason.failOpen(.timeout)
            record(OpenEvent(appID: appID, kind: .passedThrough, date: now, note: reason.note))
            return done(.passThrough(reason))
        }
        let input = RuleInput(
            app: app, now: now, calendar: current.calendar,
            opens: OpenLogQuery(recent, calendar: current.calendar, dayStartOffset: current.dayStartOffset),
            host: snapshot
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
            // Withdraw, not clear: an inbox may already have taken the context in-process.
            try? handoff.withdraw(contextID: context.id)
            record(OpenEvent(appID: appID, kind: .passedThrough, date: now, note: PassThroughReason.foregroundUnavailable.note))
            return done(.passThrough(.foregroundUnavailable))
        }
    }

    /// `nil` when the provider did not answer within ``hostConditionsTimeout``.
    private func snapshotWithinTimeout(for app: GuardedApp, at now: Date) async -> HostSnapshot? {
        let provider = hostConditions
        let timeout = hostConditionsTimeout
        return await withTaskGroup(of: HostSnapshot?.self) { group in
            group.addTask { await provider.snapshot(for: app, at: now) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
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
            var previous: Pass?
            try passes.update(appID: context.app.id) { existing in
                previous = existing
                return pass
            }
            do throws(InterventionError) {
                try appendAndBroadcast(OpenEvent(appID: context.app.id, kind: .proceeded, date: now, tier: context.tier, contextID: context.id, optionID: optionID))
            } catch {
                // No record, no pass: otherwise the user would get in for free and a retry
                // could not tell that nothing was booked.
                _ = try? passes.update(appID: context.app.id) { _ in previous }
                throw error
            }
            granted = pass
        case .abandon(let optionID):
            try appendAndBroadcast(OpenEvent(appID: context.app.id, kind: .abandoned, date: now, tier: context.tier, contextID: context.id, optionID: optionID))
        }

        try? handoff.withdraw(contextID: context.id)

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

    /// Grants a pass outside an intervention (e.g. a reward). It has no return window.
    @discardableResult
    public func grantPass(appID: GuardedApp.ID, duration: Duration) throws(InterventionError) -> Pass {
        let now = clock.now
        let pass = Pass(appID: appID, grantedAt: now, expiresAt: now.adding(duration))
        try passes.save(pass)
        return pass
    }

    /// Removes the app's pass, e.g. when a lock starts.
    public func revokePass(appID: GuardedApp.ID) throws(InterventionError) {
        try passes.removePass(for: appID)
    }

    // MARK: - Log

    /// Open-log events, ascending, limited to `interval` when given.
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
