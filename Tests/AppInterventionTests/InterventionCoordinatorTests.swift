import Foundation
import Synchronization
import Testing
@testable import AppIntervention

@Suite("InterventionCoordinator")
struct InterventionCoordinatorTests {
    let clock = ManualClock(Fixture.date(2026, 9, 27, 12))
    let passes = InMemoryPassStore()
    let log = InMemoryOpenLogStore()
    let handoff = InMemoryInterventionHandoff()

    func coordinator(
        rules: [any InterventionRule] = [],
        fallback: InterventionPolicy.Fallback = .intervene(.standard),
        passes: (any PassStore)? = nil,
        handoff: (any InterventionHandoff)? = nil,
        host: any HostConditionProvider = NoHostConditions()
    ) -> InterventionCoordinator {
        InterventionCoordinator(
            catalog: StaticGuardedAppCatalog([Fixture.instagram, Fixture.youtube]),
            policy: { InterventionPolicy(rules: rules, fallback: fallback, calendar: Fixture.calendar) },
            passes: passes ?? self.passes, log: log, handoff: handoff ?? self.handoff,
            hostConditions: host, clock: clock
        )
    }

    func kinds() throws -> [String] {
        try log.events(in: nil).map { event in event.note.map { "\(event.kind.rawValue)(\($0))" } ?? event.kind.rawValue }
    }

    // MARK: - Automation runs

    @Test("intervention: posts the context, continues in the foreground, logs opened + intervened")
    func intervene() async throws {
        let continued = Mutex(0)
        let outcome = await coordinator().handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation(.succeed) { continued.withLock { $0 += 1 } })
        guard case .intervene(let context) = outcome.decision else { Issue.record(); return }
        #expect(continued.withLock { $0 } == 1)
        #expect(try kinds() == ["opened", "intervened"])
        #expect(try handoff.take(now: clock.now, maxAge: .seconds(60)) == context)
        let intervened = try log.events(in: nil).last
        #expect(intervened?.contextID == context.id)
        #expect(intervened?.tier == .standard)
    }

    @Test("pass-through never continues in the foreground")
    func passThroughStaysInBackground() async throws {
        let continued = Mutex(0)
        let outcome = await coordinator(fallback: .passThrough).handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation(.succeed) { continued.withLock { $0 += 1 } })
        #expect(outcome.decision == .passThrough(.fallback))
        #expect(continued.withLock { $0 } == 0)
        #expect(try kinds() == ["opened", "passedThrough(fallback)"])
        #expect(try handoff.take(now: clock.now, maxAge: .seconds(60)) == nil)
    }

    @Test("already in the foreground: intervene without continuing")
    func alreadyForeground() async throws {
        let outcome = await coordinator().handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation(.alreadyForeground))
        #expect(outcome.decision.isIntervention)
        #expect(try kinds() == ["opened", "intervened"])
    }

    @Test("continueInForeground throwing removes the context and passes through")
    func continuationThrows() async throws {
        let outcome = await coordinator().handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation(.fail))
        #expect(outcome.decision == .passThrough(.foregroundUnavailable))
        #expect(try kinds() == ["opened", "passedThrough(foregroundUnavailable)"])
        #expect(try handoff.take(now: clock.now, maxAge: .seconds(60)) == nil)
    }

    @Test("foreground not allowed: same as a failed continuation")
    func continuationUnavailable() async throws {
        let outcome = await coordinator().handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation(.unavailable))
        #expect(outcome.decision == .passThrough(.foregroundUnavailable))
        #expect(try handoff.take(now: clock.now, maxAge: .seconds(60)) == nil)
    }

    @Test("unknown app passes through without logging")
    func unknownApp() async throws {
        let outcome = await coordinator().handleAutomationRun(appID: "tiktok", continuation: StubForegroundContinuation())
        #expect(outcome.decision == .passThrough(.notGuarded))
        #expect(try log.events(in: nil).isEmpty)
    }

    @Test("a failing pass store fails open")
    func failOpenOnStore() async throws {
        let outcome = await coordinator(passes: FailingPassStore()).handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation())
        #expect(outcome.decision == .passThrough(.failOpen(.read)))
        #expect(try kinds() == ["opened", "passedThrough(failOpen:read)"])
    }

    @Test("a failing handoff fails open instead of foregrounding with nothing to show")
    func failOpenOnHandoff() async throws {
        let continued = Mutex(0)
        let outcome = await coordinator(handoff: FailingHandoff()).handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation(.succeed) { continued.withLock { $0 += 1 } })
        #expect(outcome.decision == .passThrough(.failOpen(.write)))
        #expect(continued.withLock { $0 } == 0)
    }

    @Test("host conditions are fetched once per run and reach the rules")
    func hostConditionsOnce() async throws {
        let host = CountingHostConditions(HostSnapshot(flags: ["habits-done"]))
        let lock = LockRule(id: "habits") { $0.host.contains("habits-done") ? nil : LockReason(id: "todo") }
        let outcome = await coordinator(rules: [lock], fallback: .passThrough, host: host).handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation())
        #expect(outcome.decision == .passThrough(.fallback))
        #expect(host.calls == 1)
    }

    @Test("rules see today's opens from the log")
    func rulesSeeOpens() async throws {
        let c = coordinator(rules: [OpenCountRule(id: "cap", threshold: 3, tier: "over")], fallback: .passThrough)
        var decisions: [InterventionDecision] = []
        for _ in 0..<3 {
            decisions.append(await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation(.alreadyForeground)).decision)
            clock.advance(by: .seconds(60))
        }
        #expect(decisions[0] == .passThrough(.fallback))
        #expect(decisions[1] == .passThrough(.fallback))
        #expect(decisions[2].isIntervention)
    }

    // MARK: - Resolution and the return window

    @Test("proceed grants a pass; the reopen passes through uncounted once; later opens count")
    func proceedAndReturn() async throws {
        let c = coordinator()
        guard case .intervene(let context) = await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation()).decision else { Issue.record(); return }

        clock.advance(by: .seconds(5))
        let receipt = try c.resolve(context, .proceed(optionID: "pay-50", passDuration: .seconds(900)))
        #expect(receipt.pass?.expiresAt == clock.now.addingTimeInterval(900))
        #expect(receipt.pass?.returnWindowEndsAt == clock.now.addingTimeInterval(15))
        #expect(receipt.contextID == context.id)

        clock.advance(by: .seconds(2))
        let back = await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation())
        #expect(back.decision == .passThrough(.returnFromIntervention))
        #expect(try passes.pass(for: "instagram")?.returnWindowEndsAt == nil)

        clock.advance(by: .seconds(2))
        let again = await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation())
        guard case .passThrough(.validPass) = again.decision else { Issue.record("\(again.decision)"); return }

        #expect(try kinds() == [
            "opened", "intervened", "proceeded", "passedThrough(return)", "opened", "passedThrough(pass)"
        ])
        #expect(try log.events(in: nil).first { $0.kind == .proceeded }?.optionID == "pay-50")
    }

    @Test("resolving twice throws alreadyResolved and books nothing twice")
    func resolveIdempotent() async throws {
        let c = coordinator()
        guard case .intervene(let context) = await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation()).decision else { Issue.record(); return }
        try c.resolve(context, .abandon(optionID: "skip"))
        #expect(throws: InterventionError.self) { try c.resolve(context, .proceed(optionID: "pay", passDuration: .seconds(60))) }
        do {
            try c.resolve(context, .abandon(optionID: "skip"))
        } catch {
            #expect(error.code == .alreadyResolved)
        }
        #expect(try log.events(in: nil).filter { $0.kind == .abandoned || $0.kind == .proceeded }.count == 1)
        #expect(try passes.pass(for: "instagram") == nil)
    }

    @Test("resolve clears the pending handoff for that context only")
    func resolveClearsHandoff() async throws {
        let c = coordinator()
        guard case .intervene(let context) = await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation()).decision else { Issue.record(); return }
        try c.resolve(context, .abandon(optionID: nil))
        #expect(try handoff.take(now: clock.now, maxAge: .seconds(60)) == nil)

        let other = InterventionContext(app: Fixture.youtube, requestedAt: clock.now, tier: .standard, reason: .fallback)
        try handoff.post(other)
        let third = InterventionContext(app: Fixture.instagram, requestedAt: clock.now, tier: .standard, reason: .fallback)
        try c.resolve(third, .abandon(optionID: nil))
        #expect(try handoff.take(now: clock.now, maxAge: .seconds(60)) == other)
    }

    @Test("consumeReturnWindow keeps the pass but ends the window")
    func consumeWindow() throws {
        let c = coordinator()
        let context = InterventionContext(app: Fixture.instagram, requestedAt: clock.now, tier: .standard, reason: .fallback)
        try c.resolve(context, .proceed(optionID: "go", passDuration: .seconds(60)))
        try c.consumeReturnWindow(appID: "instagram")
        let pass = try passes.pass(for: "instagram")
        #expect(pass != nil)
        #expect(pass?.returnWindowEndsAt == nil)
    }

    @Test("grant and revoke passes; expired passes are pruned on the next run")
    func grantRevoke() async throws {
        let c = coordinator()
        try c.grantPass(appID: "youtube", duration: .seconds(10))
        #expect(try passes.pass(for: "youtube") != nil)
        try c.revokePass(appID: "youtube")
        #expect(try passes.pass(for: "youtube") == nil)

        try c.grantPass(appID: "youtube", duration: .seconds(10))
        clock.advance(by: .seconds(11))
        _ = await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation(.alreadyForeground))
        #expect(try passes.allPasses().isEmpty)
    }

    @Test("eventStream carries every appended event in process")
    func eventStream() async throws {
        let c = coordinator(fallback: .passThrough)
        let stream = c.eventStream()
        _ = await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation())
        var received: [OpenEvent.Kind] = []
        for await event in stream {
            received.append(event.kind)
            if received.count == 2 { break }
        }
        #expect(received == [.opened, .passedThrough])
    }

    @Test("elapsed is measured")
    func elapsed() async {
        let outcome = await coordinator().handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation())
        #expect(outcome.elapsed >= .zero)
    }
}
