import AppIntervention
import Foundation
import Testing
@testable import AppInterventionFocus

@MainActor
@Suite("PhoneDownSessionController")
struct PhoneDownSessionControllerTests {
    let clock = ManualClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = InMemoryPhoneDownSessionStore()
    let opens = ManualGuardedOpenSource()

    func controller() -> PhoneDownSessionController {
        PhoneDownSessionController(store: store, guardedOpens: opens, clock: clock, tickInterval: .milliseconds(5))
    }

    @Test("every transition is persisted; the outcome is published once")
    func persistsAndPublishes() async throws {
        let c = controller()
        let outcomes = c.outcomes()
        try c.start(duration: .seconds(60))
        let id = try #require(c.session?.id)
        c.handle(.enteredBackground(clock.now.addingTimeInterval(5)))
        #expect(try store.load()?.phase == .running(away: .init(since: clock.now.addingTimeInterval(5))))
        c.handle(.becameActive(clock.now.addingTimeInterval(10)))
        c.handle(.tick(clock.now.addingTimeInterval(61)))
        c.handle(.tick(clock.now.addingTimeInterval(62)))

        var received: [PhoneDownOutcome] = []
        for await outcome in outcomes { received.append(outcome); break }
        #expect(received.map(\.sessionID) == [id])
        #expect(received.first?.succeeded == true)
        #expect(try store.load()?.outcome?.sessionID == id)
    }

    @Test("resume after relaunch: judged on becameActive, with the persisted absence")
    func resumeUndetermined() throws {
        let first = controller()
        try first.start(duration: .seconds(3_600))
        first.handle(.enteredBackground(clock.now.addingTimeInterval(10)))
        first.handle(.backgroundTimeExpired(clock.now.addingTimeInterval(40)))

        clock.advance(by: .seconds(1_800))
        let relaunched = controller()
        relaunched.resume(appIsActive: true)
        guard case .failed(.leftApp(_, let undetermined)) = relaunched.session?.phase else {
            Issue.record("expected leftApp, got \(String(describing: relaunched.session?.phase))"); return
        }
        #expect(undetermined)
    }

    @Test("resume applies a guarded open logged while the process was gone")
    func resumeGuardedOpen() throws {
        let first = controller()
        try first.start(duration: .seconds(3_600))
        first.handle(.enteredBackground(clock.now.addingTimeInterval(10)))
        first.handle(.lockConfirmed(clock.now.addingTimeInterval(15)))
        opens.record(OpenEvent(appID: "instagram", kind: .opened, date: clock.now.addingTimeInterval(600)))

        clock.advance(by: .seconds(700))
        let relaunched = controller()
        relaunched.resume(appIsActive: true)
        #expect(relaunched.session?.phase == .failed(.openedGuardedApp(appID: "instagram", at: clock.now.addingTimeInterval(-100))))
    }

    @Test("an unacknowledged outcome is re-published on resume; acknowledging clears it")
    func republish() async throws {
        let first = controller()
        try first.start(duration: .seconds(60))
        first.cancel()

        let relaunched = controller()
        let outcomes = relaunched.outcomes()
        relaunched.resume(appIsActive: false)
        var got: PhoneDownOutcome?
        for await outcome in outcomes { got = outcome; break }
        #expect(got?.result == .failed(.cancelled(at: clock.now)))

        relaunched.acknowledgeOutcome()
        #expect(relaunched.session == nil)
        #expect(try store.load() == nil)
    }

    @Test("run(): device events and live guarded opens drive the session")
    func runLoop() async throws {
        let c = controller()
        let source = ManualPhoneDownEventSource()
        try c.start(duration: .seconds(3_600))
        let task = Task { await c.run(events: source) }
        defer { task.cancel() }
        for _ in 0..<5 { await Task.yield() }

        source.send(.enteredBackground(clock.now.addingTimeInterval(5)))
        for _ in 0..<100 where c.session?.phase == .running(away: nil) { try await Task.sleep(for: .milliseconds(2)) }
        #expect(c.session?.phase == .running(away: .init(since: clock.now.addingTimeInterval(5))))

        opens.record(OpenEvent(appID: "youtube", kind: .opened, date: clock.now.addingTimeInterval(20)))
        for _ in 0..<100 where !(c.session?.phase.isTerminal ?? true) { try await Task.sleep(for: .milliseconds(2)) }
        #expect(c.session?.phase == .failed(.openedGuardedApp(appID: "youtube", at: clock.now.addingTimeInterval(20))))
    }

    @Test("the file store round-trips a session")
    func fileStore() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "PhoneDown-\(UUID().uuidString)")
        let file = try FilePhoneDownSessionStore(location: .directory(dir))
        var session = PhoneDownSession.start(at: clock.now, duration: .seconds(60))
        session.handle(.enteredBackground(clock.now.addingTimeInterval(1)))
        try file.save(session)
        #expect(try FilePhoneDownSessionStore(location: .directory(dir)).load() == session)
        try file.clear()
        #expect(try file.load() == nil)
    }

    @Test("CoordinatorGuardedOpenSource reads opened events from the coordinator")
    func coordinatorSource() async throws {
        let log = InMemoryOpenLogStore()
        let coordinator = InterventionCoordinator(
            catalog: StaticGuardedAppCatalog([GuardedApp(id: "instagram", displayName: "Instagram")]),
            policy: { InterventionPolicy(fallback: .passThrough) },
            passes: InMemoryPassStore(), log: log, handoff: InMemoryInterventionHandoff(), clock: clock
        )
        let source = CoordinatorGuardedOpenSource(coordinator)
        let live = source.liveOpens()
        _ = await coordinator.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation())
        #expect(try source.opens(since: clock.now.addingTimeInterval(-1)).map(\.kind) == [.opened])
        var first: OpenEvent?
        for await event in live { first = event; break }
        #expect(first?.appID == "instagram")
    }
}
