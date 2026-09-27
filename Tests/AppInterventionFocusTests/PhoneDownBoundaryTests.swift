import AppIntervention
import Foundation
import Testing
@testable import AppInterventionFocus

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// Boundaries and transitions Reviewer E found untested (M04, M09, M17, E-S8, E-S10).
@Suite("PhoneDownSession boundaries", .timeLimit(.minutes(1)))
struct PhoneDownBoundaryTests {
    func session(_ seconds: Int = 3_600) -> PhoneDownSession {
        .start(id: UUID(), at: t0, duration: .seconds(seconds))
    }

    @Test("M04: an absence of exactly `grace` is forgiven; a millisecond more is not")
    func graceInclusive() {
        var ok = session()
        ok.handle(.enteredBackground(at(10)))
        #expect(ok.handle(.becameActive(at(25))) == .running(away: nil))
        var bad = session()
        bad.handle(.enteredBackground(at(10)))
        #expect(bad.handle(.becameActive(at(25.001))) == .failed(.leftApp(since: at(10), undetermined: false)))
    }

    @Test("M09: a lock signal exactly lockSignalWindow after leaving still confirms")
    func lockSignalWindowInclusive() {
        var ok = session()
        ok.handle(.enteredBackground(at(10)))
        ok.handle(.lockConfirmed(at(40)))
        #expect(ok.phase == .running(away: .init(since: at(10), lockConfirmed: true)))
        var late = session()
        late.handle(.enteredBackground(at(10)))
        late.handle(.lockConfirmed(at(40.001)))
        #expect(late.phase == .running(away: .init(since: at(10))))
    }

    @Test("M17: a guarded open exactly at endsAt does not fail the session")
    func guardedOpenAtEnd() {
        var s = session(60)
        #expect(s.handle(.guardedAppOpened(appID: "x", at: at(59.999))) == .failed(.openedGuardedApp(appID: "x", at: at(59.999))))
        var t = session(60)
        #expect(t.handle(.guardedAppOpened(appID: "x", at: at(60))) == .succeeded(at: at(60)))
    }

    @Test("E-S8: background after the end succeeds")
    func backgroundAfterEnd() {
        var s = session(60)
        #expect(s.handle(.enteredBackground(at(61))) == .succeeded(at: at(60)))
    }

    @Test("E-S8: lockConfirmed while not away, after the end, succeeds")
    func lockAfterEnd() {
        var s = session(60)
        #expect(s.handle(.lockConfirmed(at(70))) == .succeeded(at: at(60)))
    }

    @Test("E-S8: a tick past the end while away unconfirmed waits for becameActive")
    func tickWhileUnconfirmed() {
        var s = session(60)
        s.handle(.enteredBackground(at(10)))
        #expect(s.handle(.tick(at(100))) == .running(away: .init(since: at(10))))
    }

    @Test("E-S8: backgroundTimeExpired while not away changes nothing")
    func expiredWhileActive() {
        var s = session()
        #expect(s.handle(.backgroundTimeExpired(at(10))) == .running(away: nil))
    }

    @Test("E-S10: .inactive and foreground-entering signals never reach the session")
    func signalMapping() {
        let now = at(5)
        #expect(PhoneDownEvent(signal: .willResignActive, at: now) == nil)
        #expect(PhoneDownEvent(signal: .willEnterForeground, at: now) == nil)
        #expect(PhoneDownEvent(signal: .protectedDataPoll(available: true), at: now) == nil)
        #expect(PhoneDownEvent(signal: .protectedDataPoll(available: false), at: now) == .lockConfirmed(now))
        #expect(PhoneDownEvent(signal: .didEnterBackground, at: now) == .enteredBackground(now))
        #expect(PhoneDownEvent(signal: .didBecomeActive, at: now) == .becameActive(now))
        #expect(PhoneDownEvent(signal: .protectedDataWillBecomeUnavailable, at: now) == .lockConfirmed(now))
        #expect(PhoneDownEvent(signal: .protectedDataDidBecomeAvailable, at: now) == .unlocked(now))
        #expect(PhoneDownEvent(signal: .backgroundTaskExpired, at: now) == .backgroundTimeExpired(now))
        #expect(PhoneDownEvent(signal: .callsChanged(activeCalls: 2), at: now) == .callChanged(active: true, at: now))
        #expect(PhoneDownEvent(signal: .callsChanged(activeCalls: 0), at: now) == .callChanged(active: false, at: now))
    }
}

@MainActor
@Suite("PhoneDownSessionController lifecycle", .timeLimit(.minutes(1)))
struct PhoneDownControllerLifecycleTests {
    let clock = ManualClock(t0)

    @Test("E-S8: resume(appIsActive: false) keeps the absence open")
    func resumeInactive() throws {
        let store = InMemoryPhoneDownSessionStore()
        let first = PhoneDownSessionController(store: store, guardedOpens: ManualGuardedOpenSource(), clock: clock)
        try first.start(duration: .seconds(3_600))
        first.handle(.enteredBackground(at(10)))
        clock.advance(by: .seconds(600))
        let second = PhoneDownSessionController(store: store, guardedOpens: ManualGuardedOpenSource(), clock: clock)
        second.resume(appIsActive: false)
        #expect(second.session?.phase == .running(away: .init(since: at(10))))
    }

    @Test("E-S8: start replaces a running session")
    func startReplaces() throws {
        let store = InMemoryPhoneDownSessionStore()
        let c = PhoneDownSessionController(store: store, guardedOpens: ManualGuardedOpenSource(), clock: clock)
        try c.start(duration: .seconds(60))
        let first = try #require(c.session?.id)
        try c.start(duration: .seconds(120))
        #expect(c.session?.id != first)
        #expect(try store.load()?.id == c.session?.id)
        #expect(c.session?.endsAt == t0.addingTimeInterval(120))
    }

    @Test("E-S7: the session file quarantines corruption and refuses newer versions")
    func sessionFileRobustness() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "PhoneDown-\(UUID().uuidString)")
        let location = FileStoreLocation.directory(dir)
        let resolved = try location.resolve()
        let url = resolved.directory.appending(path: "phone-down-session.json")
        let store = FilePhoneDownSessionStore(location: location)

        try Data("{broken".utf8).write(to: url)
        #expect(try store.load() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: resolved.directory.path(percentEncoded: false)).contains { $0.hasPrefix("phone-down-session.json.corrupt-") })

        let newer = Data(#"{"formatVersion":9,"payload":{}}"#.utf8)
        try newer.write(to: url)
        #expect(throws: InterventionError.self) { try store.load() }
        #expect(throws: InterventionError.self) { try store.save(.start(at: t0, duration: .seconds(60))) }
        #expect(try Data(contentsOf: url) == newer)
    }
}
