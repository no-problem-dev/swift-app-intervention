import Foundation
import Synchronization
import Testing
@testable import AppIntervention

/// Regression tests for the 2026-09-27 code review (C-*, D-*), beyond Reviewer C's adversarial ones.
@Suite("Code review fixes", .timeLimit(.minutes(1)))
struct ReviewFixTests {
    let clock = ManualClock(Fixture.date(2026, 9, 27, 12))

    func coordinator(
        policy: InterventionPolicy = InterventionPolicy(calendar: Fixture.calendar),
        log: any OpenLogStore = InMemoryOpenLogStore(),
        host: any HostConditionProvider = NoHostConditions(),
        timeout: Duration = .seconds(2),
        lookback: Duration = .seconds(86_400)
    ) -> InterventionCoordinator {
        InterventionCoordinator(
            catalog: StaticGuardedAppCatalog([Fixture.instagram]), policy: { policy },
            passes: InMemoryPassStore(), log: log, handoff: InMemoryInterventionHandoff(),
            hostConditions: host, clock: clock, opensLookback: lookback, hostConditionsTimeout: timeout
        )
    }

    @Test("C-M1: removeExpired keeps a pass whose return window is still open")
    func keepPassInReturnWindow() throws {
        let now = clock.now
        let store = InMemoryPassStore([Pass(appID: "a", grantedAt: now, expiresAt: now, returnWindowEndsAt: now.addingTimeInterval(15))])
        try store.removeExpired(asOf: now.addingTimeInterval(5))
        #expect(try store.pass(for: "a") != nil)
        try store.removeExpired(asOf: now.addingTimeInterval(15))
        #expect(try store.pass(for: "a") == nil)
    }

    @Test("C-S3: the policy's dayStartOffset reaches the rules' open counts")
    func dayOffsetReachesRules() async throws {
        // 02:00 on the 28th; one open at 23:00 on the 27th. With a 04:00 boundary both are "today".
        clock.set(Fixture.date(2026, 9, 28, 2))
        let log = InMemoryOpenLogStore([OpenEvent(appID: "instagram", kind: .opened, date: Fixture.date(2026, 9, 27, 23))])
        let rule = OpenCountRule(id: "cap", threshold: 2, tier: "over")
        let midnight = coordinator(policy: InterventionPolicy(rules: [rule], fallback: .passThrough, calendar: Fixture.calendar), log: log)
        #expect(await midnight.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation()).decision == .passThrough(.fallback))

        let log2 = InMemoryOpenLogStore([OpenEvent(appID: "instagram", kind: .opened, date: Fixture.date(2026, 9, 27, 23))])
        let fourAM = coordinator(policy: InterventionPolicy(rules: [rule], fallback: .passThrough, calendar: Fixture.calendar, dayStartOffset: .seconds(4 * 3_600)), log: log2)
        #expect(await fourAM.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation()).decision.isIntervention)
    }

    @Test("C-S4: a host provider that never answers makes the run pass through on time")
    func hostTimeout() async throws {
        let slow = ClosureHostConditionProvider { _, _ in
            try? await Task.sleep(for: .seconds(30))
            return .empty
        }
        let started = ContinuousClock.now
        let outcome = await coordinator(host: slow, timeout: .milliseconds(100)).handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation())
        #expect(outcome.decision == .passThrough(.failOpen(.timeout)))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("C-C4: a negative lookback is clamped instead of crashing")
    func negativeLookback() async {
        let outcome = await coordinator(lookback: .seconds(-10)).handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation())
        #expect(outcome.decision.isIntervention)
    }

    @Test("D-S2: files(at:) never throws; an unusable location fails open at run time")
    func filesFailOpen() async {
        let broken = FileStoreLocation.directory(URL(fileURLWithPath: "/dev/null/not-a-directory"))
        let c = InterventionCoordinator.files(at: broken, catalog: StaticGuardedAppCatalog([Fixture.instagram]), policy: { InterventionPolicy() })
        let outcome = await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation())
        guard case .passThrough(.failOpen) = outcome.decision else { Issue.record("\(outcome.decision)"); return }
    }

    @Test("D-C4: inMemory coordinator works end to end")
    func inMemory() async throws {
        let c = InterventionCoordinator.inMemory(catalog: StaticGuardedAppCatalog([Fixture.instagram]), policy: { InterventionPolicy() }, clock: clock)
        #expect(await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation()).decision.isIntervention)
        #expect(try c.events(in: nil).count == 2)
    }

    @Test("C-S1: handoff instances on one path share their change stream")
    func sharedHandoffChanges() async throws {
        let location = FileStoreLocation.directory(Fixture.temporaryDirectory())
        let writer = FileInterventionHandoff(location: location)
        let reader = FileInterventionHandoff(location: location)
        let changes = reader.changes()
        let context = InterventionContext(app: Fixture.instagram, requestedAt: clock.now, tier: .standard, reason: .fallback)
        try writer.post(context)
        try writer.withdraw(contextID: context.id)
        let received = await collect(changes, count: 2)
        #expect(received == [.posted(context.id), .withdrawn(context.id)])
        #expect(try reader.take(now: clock.now, maxAge: .seconds(60)) == nil)
    }

    @Test("withdraw leaves a different pending context alone")
    func withdrawOnlyMatching() throws {
        let handoff = InMemoryInterventionHandoff()
        let context = InterventionContext(app: Fixture.instagram, requestedAt: clock.now, tier: .standard, reason: .fallback)
        try handoff.post(context)
        try handoff.withdraw(contextID: UUID())
        #expect(try handoff.take(now: clock.now, maxAge: .seconds(60)) == context)
    }

    @Test("D-S6: a custom handoff gets a finished changes() stream by default")
    func defaultChanges() async {
        #expect(await collect(FailingHandoff().changes(), count: 1).isEmpty)
    }

    @Test("D-C2: result types can be built by hosts")
    func publicInits() {
        let receipt = ResolutionReceipt(contextID: UUID(), appID: "a", tier: .standard, resolution: .abandon(optionID: nil), resolvedAt: clock.now, pass: nil)
        let outcome = AutomationRunOutcome(decision: .passThrough(.fallback), elapsed: .milliseconds(1_500))
        #expect(receipt.appID == "a")
        #expect(outcome.elapsedMilliseconds == 1_500)
    }
}

@Suite("Day boundaries across DST (C-C2)", .timeLimit(.minutes(1)))
struct DaylightSavingTests {
    @Test("a 04:00 boundary stays at wall-clock 04:00 on the spring-forward day")
    func springForward() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func date(_ d: Int, _ h: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: d, hour: h))! }
        let query = OpenLogQuery([], calendar: calendar, dayStartOffset: .seconds(4 * 3_600))
        let day = query.day(containing: date(8, 12))       // 2026-03-08 is the spring-forward day
        #expect(day.start == date(8, 4))
        #expect(day.end == date(9, 4))
        #expect(day.duration == 24 * 3_600)
        let before = query.day(containing: date(8, 3))   // 03:00 EDT, still the 7th's host day
        #expect(before.start == date(7, 4))
        #expect(before.end == date(8, 4))
        #expect(before.duration == 23 * 3_600)            // the lost hour falls in this day
    }
}

@MainActor
@Suite("Presenter review fixes", .timeLimit(.minutes(1)))
struct PresenterReviewFixTests {
    let clock = ManualClock(Fixture.date(2026, 9, 27, 12))

    @Test("D-M1: onResolved runs before the other app is opened")
    func onResolvedBeforeReopen() async throws {
        let handoff = InMemoryInterventionHandoff()
        let c = InterventionCoordinator(
            catalog: StaticGuardedAppCatalog([Fixture.instagram]), policy: { InterventionPolicy() },
            passes: InMemoryPassStore(), log: InMemoryOpenLogStore(), handoff: handoff, clock: clock
        )
        let inbox = InterventionInbox(handoff: handoff, clock: clock)
        let order = OrderRecorder()
        let reopener = OrderedReopener(order: order)
        let presenter = InterventionPresenter(coordinator: c, inbox: inbox, reopener: reopener)
        try handoff.post(InterventionContext(app: Fixture.instagram, requestedAt: clock.now, tier: .standard, reason: .fallback))
        inbox.refresh()
        _ = try await presenter.proceed(optionID: "pay", passDuration: .seconds(60)) { _ in order.steps.append("ledger") }
        #expect(order.steps == ["ledger", "open"])
    }

    @Test("C-M2: a stale pending context is not actionable")
    func staleContext() async throws {
        let handoff = InMemoryInterventionHandoff()
        let c = InterventionCoordinator.inMemory(catalog: StaticGuardedAppCatalog([Fixture.instagram]), policy: { InterventionPolicy() }, clock: clock)
        let inbox = InterventionInbox(handoff: handoff, clock: clock, maxAge: .seconds(120))
        try handoff.post(InterventionContext(app: Fixture.instagram, requestedAt: clock.now, tier: .standard, reason: .fallback))
        inbox.refresh()
        clock.advance(by: .seconds(600))
        let presenter = InterventionPresenter(coordinator: c, inbox: inbox, reopener: RecordingAppReopener())
        #expect(presenter.context == nil)
        do {
            _ = try await presenter.proceed(optionID: "pay", passDuration: .seconds(60))
            Issue.record("expected expired")
        } catch {
            #expect(error.code == .expired)
        }
        #expect(inbox.pending == nil)

        try handoff.post(InterventionContext(app: Fixture.instagram, requestedAt: clock.now.addingTimeInterval(-10), tier: .standard, reason: .fallback))
        inbox.refresh()
        clock.advance(by: .seconds(600))
        inbox.refresh()
        #expect(inbox.pending == nil)
    }
}

@MainActor
final class OrderRecorder {
    var steps: [String] = []
}

@MainActor
final class OrderedReopener: AppReopener {
    let order: OrderRecorder
    init(order: OrderRecorder) { self.order = order }
    func open(_ url: URL, universalLinksOnly: Bool) async -> Bool {
        order.steps.append("open")
        return true
    }
}
