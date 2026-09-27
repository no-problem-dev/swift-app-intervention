import Foundation
import Testing
import Synchronization
@testable import AppIntervention

struct SlowFailContinuation: ForegroundContinuation {
    var isForeground: Bool { false }
    var canContinueInForeground: Bool { true }
    func continueInForeground() async throws {
        try? await Task.sleep(for: .milliseconds(200))
        throw StubForegroundContinuation.Failure()
    }
}

final class FlakyLog: OpenLogStore, @unchecked Sendable {
    let inner = InMemoryOpenLogStore()
    let failNextProceeded = Mutex(true)
    func append(_ event: OpenEvent) throws(InterventionError) {
        if event.kind == .proceeded, failNextProceeded.withLock({ v in defer { v = false }; return v }) {
            throw InterventionError(.write)
        }
        try inner.append(event)
    }
    func events(in interval: DateInterval?) throws(InterventionError) -> [OpenEvent] { try inner.events(in: interval) }
}

@Suite("Adversarial", .timeLimit(.minutes(1)))
struct Adversarial {
    func make(clock: ManualClock, log: any OpenLogStore = InMemoryOpenLogStore(), handoff: any InterventionHandoff = InMemoryInterventionHandoff(), passes: any PassStore = InMemoryPassStore()) -> InterventionCoordinator {
        InterventionCoordinator(catalog: StaticGuardedAppCatalog([Fixture.instagram]),
                                policy: { InterventionPolicy(calendar: Fixture.calendar) },
                                passes: passes, log: log, handoff: handoff, clock: clock)
    }

    @Test("zero-duration proceed: own reopen is intervened again (loop)")
    func zeroPassLoops() async throws {
        let clock = ManualClock(Fixture.date())
        let c = make(clock: clock)
        let first = await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation(.succeed))
        guard case .intervene(let ctx) = first.decision else { Issue.record("expected intervene"); return }
        try c.resolve(ctx, .proceed(optionID: "once", passDuration: .zero))
        clock.advance(by: .seconds(2))  // host reopens instagram 2 s later
        let second = await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation(.succeed))
        #expect(second.decision == .passThrough(.returnFromIntervention), "got \(second.decision)")
    }

    @Test("short pass (5 s) + reopen at 6 s: loops too")
    func shortPassLoops() async throws {
        let clock = ManualClock(Fixture.date())
        let c = make(clock: clock)
        let first = await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation(.succeed))
        guard case .intervene(let ctx) = first.decision else { return }
        try c.resolve(ctx, .proceed(optionID: "once", passDuration: .seconds(5)))
        clock.advance(by: .seconds(6))
        let second = await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation(.succeed))
        #expect(second.decision == .passThrough(.returnFromIntervention), "got \(second.decision)")
    }

    @MainActor
    @Test("inbox keeps a stale context after foregroundUnavailable")
    func staleInbox() async throws {
        let clock = ManualClock(Fixture.date())
        let handoff = InMemoryInterventionHandoff()
        let c = make(clock: clock, handoff: handoff)
        let inbox = InterventionInbox(handoff: handoff, clock: clock)
        let observer = Task { await inbox.observe() }
        try await Task.sleep(for: .milliseconds(50))
        let outcome = await c.handleAutomationRun(appID: "instagram", continuation: SlowFailContinuation())
        #expect(outcome.decision == .passThrough(.foregroundUnavailable))
        try await Task.sleep(for: .milliseconds(50))
        #expect(inbox.pending == nil, "inbox still shows \(String(describing: inbox.pending?.id))")
        observer.cancel()
    }

    @Test("resolve: log append fails after pass saved -> free pass, no receipt")
    func freePass() async throws {
        let clock = ManualClock(Fixture.date())
        let log = FlakyLog()
        let passes = InMemoryPassStore()
        let c = make(clock: clock, log: log, passes: passes)
        let first = await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation(.succeed))
        guard case .intervene(let ctx) = first.decision else { return }
        #expect(throws: InterventionError.self) { try c.resolve(ctx, .proceed(optionID: "pay", passDuration: .seconds(900))) }
        #expect(try passes.pass(for: "instagram") == nil, "pass granted although resolve threw")
    }

    @Test("two FileOpenLogStore instances on one directory lose lines")
    func twoLogInstances() throws {
        let dir = Fixture.temporaryDirectory()
        let loc = FileStoreLocation.directory(dir)
        let a = FileOpenLogStore(location: loc)
        let b = FileOpenLogStore(location: loc)
        let n = 500
        DispatchQueue.concurrentPerform(iterations: n * 2) { i in
            let store = i % 2 == 0 ? a : b
            try? store.append(OpenEvent(appID: "instagram", kind: .opened, date: Fixture.date()))
        }
        let count = try a.events(in: nil).count
        #expect(count == n * 2, "only \(count) of \(n * 2) survived")
    }

    @Test("two FilePassStore instances on one directory lose updates")
    func twoPassInstances() throws {
        let dir = Fixture.temporaryDirectory()
        let loc = FileStoreLocation.directory(dir)
        let a = FilePassStore(location: loc)
        let b = FilePassStore(location: loc)
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let store = i % 2 == 0 ? a : b
            try? store.save(Pass(appID: "app\(i)", grantedAt: Fixture.date(), expiresAt: Fixture.date().addingTimeInterval(600)))
        }
        let count = try a.allPasses().count
        #expect(count == 200, "only \(count) of 200 passes survived")
    }

    @Test("torn last line swallows the next appended event")
    func tornLine() throws {
        let dir = Fixture.temporaryDirectory()
        let store = FileOpenLogStore(location: .directory(dir))
        try store.append(OpenEvent(appID: "instagram", kind: .opened, date: Fixture.date()))
        let url = dir.appending(path: "AppIntervention/open-log.jsonl")
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data("{\"v\":1,\"id\":\"".utf8)); try h.close()
        try store.append(OpenEvent(appID: "instagram", kind: .proceeded, date: Fixture.date(), contextID: UUID()))
        #expect(try store.events(in: nil).count == 2)
    }
}
