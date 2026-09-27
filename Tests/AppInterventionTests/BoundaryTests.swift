import Foundation
import Testing
@testable import AppIntervention

/// Exact-boundary and concurrency tests that kill the mutants Reviewer E saw survive
/// (M11, M13, M24, M37) plus the log-store failure paths (E-S5, E-S6, E-S7).
@Suite("Boundaries and failure paths", .timeLimit(.minutes(1)))
struct BoundaryTests {
    let clock = ManualClock(Fixture.date(2026, 9, 27, 12))

    @Test("M11: the return window is [grantedAt, returnWindowEndsAt) — its end is excluded")
    func returnWindowEndExcluded() {
        let now = clock.now
        let pass = Pass(appID: "a", grantedAt: now, expiresAt: now.addingTimeInterval(60), returnWindowEndsAt: now.addingTimeInterval(15))
        #expect(pass.isInReturnWindow(at: now))
        #expect(pass.isInReturnWindow(at: now.addingTimeInterval(14.999)))
        #expect(!pass.isInReturnWindow(at: now.addingTimeInterval(15)))
        #expect(!pass.isInReturnWindow(at: now.addingTimeInterval(-0.001)))
        #expect(pass.isValid(at: now.addingTimeInterval(59.999)))
        #expect(!pass.isValid(at: now.addingTimeInterval(60)))
    }

    @Test("M13: a context exactly maxAge old is still fresh; a millisecond later it is not")
    func handoffMaxAgeInclusive() throws {
        let handoff = InMemoryInterventionHandoff()
        let context = InterventionContext(app: Fixture.instagram, requestedAt: clock.now, tier: .standard, reason: .fallback)
        try handoff.post(context)
        #expect(try handoff.take(now: clock.now.addingTimeInterval(120), maxAge: .seconds(120)) == context)
        try handoff.post(context)
        #expect(try handoff.take(now: clock.now.addingTimeInterval(120.001), maxAge: .seconds(120)) == nil)
    }

    @Test("M37: an open logged at exactly now is visible to rules")
    func lookbackIncludesNow() async {
        let log = InMemoryOpenLogStore([OpenEvent(appID: "instagram", kind: .opened, date: clock.now)])
        let c = InterventionCoordinator(
            catalog: StaticGuardedAppCatalog([Fixture.instagram]),
            policy: { InterventionPolicy(rules: [OpenCountRule(id: "cap", threshold: 2, tier: "over")], fallback: .passThrough, calendar: Fixture.calendar) },
            passes: InMemoryPassStore(), log: log, handoff: InMemoryInterventionHandoff(), clock: clock
        )
        #expect(await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation()).decision.isIntervention)
    }

    @Test("M24: two resolutions that read at the same moment still record exactly one")
    func concurrentResolveBarrier() async throws {
        // The log's reads meet at a barrier: without serialization both resolutions read an
        // empty log before either writes, and both would succeed. With it, the first reader
        // waits out the barrier alone, writes, and the second sees the first's event.
        // Two dedicated threads, not the cooperative pool: under a full parallel test run the
        // pool can be busy enough to start the second task only after the first finished.
        let log = BarrierReadLog(parties: 2, timeout: 1)
        let c = InterventionCoordinator(
            catalog: StaticGuardedAppCatalog([Fixture.instagram]), policy: { InterventionPolicy() },
            passes: InMemoryPassStore(), log: log, handoff: InMemoryInterventionHandoff(), clock: clock
        )
        let context = InterventionContext(app: Fixture.instagram, requestedAt: clock.now, tier: .standard, reason: .fallback)
        let choices: [InterventionResolution] = [.proceed(optionID: "pay", passDuration: .seconds(60)), .abandon(optionID: "skip")]
        let collected = ResultBox()
        let done = DispatchGroup()
        for choice in choices {
            done.enter()
            Thread {
                do throws(InterventionError) {
                    try c.resolve(context, choice)
                    collected.append(nil)
                } catch {
                    collected.append(error.code)
                }
                done.leave()
            }.start()
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                done.wait()
                continuation.resume()
            }
        }
        let results = collected.values
        #expect(results.filter { $0 == nil }.count == 1)
        #expect(results.filter { $0 == InterventionError.Code.alreadyResolved }.count == 1)
    }

    @Test("E-S5: 20 concurrent resolutions of one context — exactly one succeeds")
    func concurrentResolve() async throws {
        let c = InterventionCoordinator.inMemory(catalog: StaticGuardedAppCatalog([Fixture.instagram]), policy: { InterventionPolicy() }, clock: clock)
        let context = InterventionContext(app: Fixture.instagram, requestedAt: clock.now, tier: .standard, reason: .fallback)
        let results = await withTaskGroup(of: InterventionError.Code?.self) { group in
            for i in 0..<20 {
                group.addTask { () -> InterventionError.Code? in
                    do throws(InterventionError) {
                        try c.resolve(context, i.isMultiple(of: 2) ? .proceed(optionID: "pay", passDuration: .seconds(60)) : .abandon(optionID: "skip"))
                        return nil
                    } catch {
                        return error.code
                    }
                }
            }
            var all: [InterventionError.Code?] = []
            while let result = await group.next() { all.append(result) }
            return all
        }
        #expect(results.filter { $0 == nil }.count == 1)
        #expect(results.filter { $0 == InterventionError.Code.alreadyResolved }.count == 19)
        #expect(try c.events(in: nil).filter { $0.kind == .proceeded || $0.kind == .abandoned }.count == 1)
    }

    @Test("E-S6: a log that cannot be read fails the run open with .read")
    func logReadFailure() async {
        let c = InterventionCoordinator(
            catalog: StaticGuardedAppCatalog([Fixture.instagram]), policy: { InterventionPolicy() },
            passes: InMemoryPassStore(), log: FailingOpenLogStore(failReads: true), handoff: InMemoryInterventionHandoff(), clock: clock
        )
        #expect(await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation()).decision == .passThrough(.failOpen(.read)))
    }

    @Test("E-S6: a log that cannot be written does not change the decision; resolve throws and grants nothing")
    func logWriteFailure() async throws {
        let log = FailingOpenLogStore(failWrites: true)
        let passes = InMemoryPassStore()
        let handoff = InMemoryInterventionHandoff()
        let c = InterventionCoordinator(
            catalog: StaticGuardedAppCatalog([Fixture.instagram]), policy: { InterventionPolicy() },
            passes: passes, log: log, handoff: handoff, clock: clock
        )
        let outcome = await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation())
        guard case .intervene(let context) = outcome.decision else { Issue.record("\(outcome.decision)"); return }
        #expect(throws: InterventionError.self) { try c.resolve(context, .proceed(optionID: "pay", passDuration: .seconds(60))) }
        #expect(try passes.allPasses().isEmpty)
    }

    @Test("E-S6: a failing handoff logs opened + passedThrough(failOpen:write)")
    func handoffFailureLog() async throws {
        let log = InMemoryOpenLogStore()
        let c = InterventionCoordinator(
            catalog: StaticGuardedAppCatalog([Fixture.instagram]), policy: { InterventionPolicy() },
            passes: InMemoryPassStore(), log: log, handoff: FailingHandoff(), clock: clock
        )
        _ = await c.handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation())
        #expect(try log.events(in: nil).map { "\($0.kind)|\($0.note ?? "")" } == ["opened|", "passedThrough|failOpen:write"])
    }

    @Test("E-S7: file-backed flow survives re-creating every instance (process restarts)")
    func fileBackedEndToEnd() async throws {
        let location = FileStoreLocation.directory(Fixture.temporaryDirectory())
        func fresh() -> InterventionCoordinator {
            .files(at: location, catalog: StaticGuardedAppCatalog([Fixture.instagram]), policy: { InterventionPolicy(calendar: Fixture.calendar) }, clock: clock)
        }
        let first = await fresh().handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation())
        guard case .intervene(let context) = first.decision else { Issue.record("\(first.decision)"); return }

        // The UI process side: a new inbox reads the persisted context.
        let pending = try FileInterventionHandoff(location: location).take(now: clock.now, maxAge: .seconds(120))
        #expect(pending == context)

        clock.advance(by: .seconds(3))
        try fresh().resolve(context, .proceed(optionID: "pay", passDuration: .seconds(600)))
        #expect(throws: InterventionError.self) { try fresh().resolve(context, .abandon(optionID: nil)) }

        clock.advance(by: .seconds(2))
        #expect(await fresh().handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation()).decision == .passThrough(.returnFromIntervention))
        clock.advance(by: .seconds(60))
        guard case .passThrough(.validPass) = await fresh().handleAutomationRun(appID: "instagram", continuation: StubForegroundContinuation()).decision else {
            Issue.record("expected validPass"); return
        }
        #expect(try fresh().events(in: nil).map(\.kind.rawValue) == ["opened", "intervened", "proceeded", "passedThrough", "opened", "passedThrough"])
    }
}

/// A log whose reads take their snapshot, then wait at a barrier until `parties` readers have
/// arrived (or `timeout` elapses), so concurrent readers are guaranteed to see the same state.
final class BarrierReadLog: OpenLogStore, @unchecked Sendable {
    let inner = InMemoryOpenLogStore()
    private let condition = NSCondition()
    private let parties: Int
    private let timeout: TimeInterval
    private var arrived = 0

    init(parties: Int, timeout: TimeInterval) {
        self.parties = parties
        self.timeout = timeout
    }

    func append(_ event: OpenEvent) throws(InterventionError) { try inner.append(event) }

    func events(in interval: DateInterval?) throws(InterventionError) -> [OpenEvent] {
        // Read first, then wait: every reader that overlaps returns what it saw before anyone
        // could write, whichever thread wakes first after the barrier.
        let snapshot = try inner.events(in: interval)
        condition.lock()
        arrived += 1
        if arrived >= parties {
            condition.broadcast()
        } else {
            let deadline = Date().addingTimeInterval(timeout)
            while arrived < parties, condition.wait(until: deadline) {}
        }
        condition.unlock()
        return snapshot
    }
}

final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [InterventionError.Code?] = []
    func append(_ value: InterventionError.Code?) { lock.withLock { _values.append(value) } }
    var values: [InterventionError.Code?] { lock.withLock { _values } }
}
