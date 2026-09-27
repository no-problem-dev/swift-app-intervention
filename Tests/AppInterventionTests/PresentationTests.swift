import Foundation
import Testing
@testable import AppIntervention

@MainActor
@Suite("Inbox and presenter", .timeLimit(.minutes(1)))
struct PresentationTests {
    let clock = ManualClock(Fixture.date(2026, 9, 27, 12))
    let passes = InMemoryPassStore()
    let log = InMemoryOpenLogStore()
    let handoff = InMemoryInterventionHandoff()

    func coordinator() -> InterventionCoordinator {
        InterventionCoordinator(
            catalog: StaticGuardedAppCatalog([Fixture.instagram, Fixture.youtube]),
            policy: { InterventionPolicy(calendar: Fixture.calendar) },
            passes: passes, log: log, handoff: handoff, clock: clock
        )
    }

    func context(_ app: GuardedApp = Fixture.instagram) -> InterventionContext {
        InterventionContext(app: app, requestedAt: clock.now, tier: .standard, reason: .fallback)
    }

    @Test("refresh takes a fresh context; stale ones are dropped")
    func refresh() throws {
        let inbox = InterventionInbox(handoff: handoff, clock: clock, maxAge: .seconds(120))
        try handoff.post(context())
        clock.advance(by: .seconds(121))
        inbox.refresh()
        #expect(inbox.pending == nil)

        let fresh = context()
        try handoff.post(fresh)
        inbox.refresh()
        #expect(inbox.pending == fresh)
        inbox.refresh()               // nothing new: keeps the current one
        #expect(inbox.pending == fresh)
    }

    @Test("observe() picks up a context posted by the automation run")
    func observe() async throws {
        let inbox = InterventionInbox(handoff: handoff, clock: clock)
        let task = Task { await inbox.observe() }
        defer { task.cancel() }
        await Task.yield()
        _ = await coordinator().handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation())
        for _ in 0..<200 where inbox.pending == nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(inbox.pending?.app == Fixture.instagram)
    }

    @Test("proceed: pass, log, dismiss, reopen with the scheme first")
    func proceed() async throws {
        let inbox = InterventionInbox(handoff: handoff, clock: clock)
        let reopener = RecordingAppReopener()
        let presenter = InterventionPresenter(coordinator: coordinator(), inbox: inbox, reopener: reopener)
        try handoff.post(context())
        inbox.refresh()

        let result = try await presenter.proceed(optionID: "pay-50", passDuration: .seconds(900))
        #expect(result.reopen == .reopened(URL(string: "instagram://")!))
        #expect(reopener.requests.map(\.universalLinksOnly) == [false])
        #expect(inbox.pending == nil)
        #expect(try passes.pass(for: "instagram")?.returnWindowEndsAt != nil)
        #expect(result.receipt.resolution == .proceed(optionID: "pay-50", passDuration: .seconds(900)))
    }

    @Test("proceed falls back to the universal link, then consumes the window when all fail")
    func reopenFallbacks() async throws {
        let inbox = InterventionInbox(handoff: handoff, clock: clock)
        let https = RecordingAppReopener { $0.scheme == "https" }
        let presenter = InterventionPresenter(coordinator: coordinator(), inbox: inbox, reopener: https)
        try handoff.post(context()); inbox.refresh()
        let first = try await presenter.proceed(optionID: "go", passDuration: .seconds(60))
        #expect(first.reopen == .reopened(URL(string: "https://instagram.com")!))
        #expect(https.requests.map(\.universalLinksOnly) == [false, true])
        #expect(try passes.pass(for: "instagram")?.returnWindowEndsAt != nil)

        let none = RecordingAppReopener { _ in false }
        let presenter2 = InterventionPresenter(coordinator: coordinator(), inbox: inbox, reopener: none)
        try handoff.post(context()); inbox.refresh()
        let second = try await presenter2.proceed(optionID: "go", passDuration: .seconds(60))
        #expect(second.reopen == .failed)
        #expect(try passes.pass(for: "instagram")?.returnWindowEndsAt == nil)
    }

    @Test("no reopen URL: consumes the window and reports noURL")
    func noURL() async throws {
        let inbox = InterventionInbox(handoff: handoff, clock: clock)
        let presenter = InterventionPresenter(coordinator: coordinator(), inbox: inbox, reopener: RecordingAppReopener())
        try handoff.post(context(Fixture.youtube)); inbox.refresh()
        let result = try await presenter.proceed(optionID: "go", passDuration: .seconds(60))
        #expect(result.reopen == .noURL)
        #expect(try passes.pass(for: "youtube")?.returnWindowEndsAt == nil)
    }

    @Test("abandon logs once; a second resolution of the same context is rejected and dismissed")
    func abandonTwice() throws {
        let inbox = InterventionInbox(handoff: handoff, clock: clock)
        let presenter = InterventionPresenter(coordinator: coordinator(), inbox: inbox, reopener: RecordingAppReopener())
        let ctx = context()
        try handoff.post(ctx); inbox.refresh()
        let receipt = try presenter.abandon(optionID: "skip")
        #expect(receipt.contextID == ctx.id)
        #expect(inbox.pending == nil)

        try handoff.post(ctx); inbox.refresh()     // e.g. a duplicate delivery
        do {
            try presenter.abandon(optionID: "skip")
            Issue.record("expected alreadyResolved")
        } catch {
            #expect(error.code == .alreadyResolved)
        }
        #expect(inbox.pending == nil)
        #expect(try log.events(in: nil).filter { $0.kind == .abandoned }.count == 1)
    }

    @Test("resolving with nothing pending throws")
    func nothingPending() async {
        let presenter = InterventionPresenter(coordinator: coordinator(), inbox: InterventionInbox(handoff: handoff), reopener: RecordingAppReopener())
        await #expect(throws: InterventionError.self) { try await presenter.proceed(optionID: "x", passDuration: .seconds(1)) }
    }
}
