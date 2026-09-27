import AppIntervention
import Foundation
import Testing
@testable import AppInterventionFocus

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

@Suite("PhoneDownSession")
struct PhoneDownSessionTests {
    func session(_ minutes: Int = 60, _ configuration: PhoneDownSession.Configuration = .init()) -> PhoneDownSession {
        .start(id: UUID(), at: t0, duration: .seconds(minutes * 60), configuration: configuration)
    }

    @Test("staying in the app until the end succeeds on tick")
    func stayInApp() {
        var s = session(1)
        #expect(s.handle(.tick(at(30))) == .running(away: nil))
        #expect(s.handle(.tick(at(61))) == .succeeded(at: at(60)))
        #expect(s.outcome?.succeeded == true)
    }

    @Test("lock → delayed lock signal → unlock → back: continues")
    func lockThenBack() {
        var s = session()
        s.handle(.enteredBackground(at(10)))
        s.handle(.lockConfirmed(at(20)))                // ~10 s later
        s.handle(.unlocked(at(600)))
        #expect(s.handle(.becameActive(at(602))) == .running(away: nil))
    }

    @Test("locked through the end succeeds at endsAt, whenever the app next hears about it")
    func lockedThroughEnd() {
        var s = session()
        s.handle(.enteredBackground(at(10)))
        s.handle(.lockConfirmed(at(15)))
        #expect(s.handle(.unlocked(at(5_000))) == .succeeded(at: at(3_600)))
    }

    @Test("leaving for another app without a lock fails when coming back")
    func leftApp() {
        var s = session()
        s.handle(.enteredBackground(at(10)))
        s.handle(.backgroundTimeExpired(at(40)))
        #expect(s.handle(.becameActive(at(300))) == .failed(.leftApp(since: at(10), undetermined: true)))
    }

    @Test("a short unconfirmed absence is forgiven (quick unlock before the lock signal)")
    func graceForgives() {
        var s = session()
        s.handle(.enteredBackground(at(10)))
        #expect(s.handle(.becameActive(at(24))) == .running(away: nil))
    }

    @Test("tolerate policy lets unconfirmed absences pass (devices without passcode)")
    func tolerate() {
        var s = session(60, .init(unconfirmedAbsence: .tolerate))
        s.handle(.enteredBackground(at(10)))
        s.handle(.backgroundTimeExpired(at(40)))
        #expect(s.handle(.becameActive(at(4_000))) == .succeeded(at: at(3_600)))
    }

    @Test("unlock restarts the grace period: unlock then leave fails")
    func unlockThenLeave() {
        var s = session()
        s.handle(.enteredBackground(at(10)))
        s.handle(.lockConfirmed(at(20)))
        s.handle(.unlocked(at(100)))
        #expect(s.handle(.becameActive(at(400))) == .failed(.leftApp(since: at(100), undetermined: false)))
    }

    @Test("a lock signal long after leaving does not confirm the absence")
    func lateLockSignal() {
        var s = session()
        s.handle(.enteredBackground(at(10)))
        s.handle(.lockConfirmed(at(100)))               // > lockSignalWindow (30 s)
        #expect(s.handle(.becameActive(at(200))) == .failed(.leftApp(since: at(10), undetermined: false)))
    }

    @Test("a guarded app opening during the session fails immediately, even while locked-confirmed")
    func guardedAppOpened() {
        var s = session()
        s.handle(.enteredBackground(at(10)))
        s.handle(.lockConfirmed(at(15)))
        #expect(s.handle(.guardedAppOpened(appID: "instagram", at: at(900))) == .failed(.openedGuardedApp(appID: "instagram", at: at(900))))
        #expect(s.handle(.becameActive(at(1_000))) == .failed(.openedGuardedApp(appID: "instagram", at: at(900))))
    }

    @Test("guarded opens outside the session window are ignored")
    func guardedOutside() {
        var s = session(1)
        #expect(s.handle(.guardedAppOpened(appID: "x", at: at(-5))) == .running(away: nil))
        #expect(s.handle(.guardedAppOpened(appID: "x", at: at(90))) == .succeeded(at: at(60)))
    }

    @Test("calls do not count as leaving; a call ending restarts the grace period")
    func calls() {
        var s = session()
        s.handle(.callChanged(active: true, at: at(10)))
        s.handle(.enteredBackground(at(11)))
        #expect(s.handle(.becameActive(at(900))) == .running(away: nil))

        s.handle(.enteredBackground(at(1_000)))
        s.handle(.callChanged(active: true, at: at(1_001)))
        s.handle(.callChanged(active: false, at: at(1_300)))
        #expect(s.handle(.becameActive(at(1_310))) == .running(away: nil))

        s.handle(.enteredBackground(at(2_000)))
        s.handle(.callChanged(active: true, at: at(2_001)))
        s.handle(.callChanged(active: false, at: at(2_100)))
        #expect(s.handle(.becameActive(at(2_400))) == .failed(.leftApp(since: at(2_100), undetermined: false)))
    }

    @Test("the absence is measured only up to endsAt")
    func absenceClippedAtEnd() {
        var s = session(1)
        s.handle(.enteredBackground(at(50)))            // 10 s before the end, within grace
        #expect(s.handle(.becameActive(at(500))) == .succeeded(at: at(60)))
    }

    @Test("duplicate events are no-ops; terminal phases ignore everything")
    func idempotent() {
        var s = session()
        s.handle(.enteredBackground(at(10)))
        s.handle(.enteredBackground(at(12)))
        #expect(s.phase == .running(away: .init(since: at(10))))
        s.handle(.becameActive(at(15)))
        s.handle(.becameActive(at(16)))
        #expect(s.phase == .running(away: nil))
        s.cancel(at: at(20))
        #expect(s.handle(.tick(at(99_999))) == .failed(.cancelled(at: at(20))))
        s.cancel(at: at(30))
        #expect(s.phase == .failed(.cancelled(at: at(20))))
    }

    @Test("lock while active starts a confirmed absence")
    func lockWhileActive() {
        var s = session()
        s.handle(.lockConfirmed(at(10)))
        #expect(s.phase == .running(away: .init(since: at(10), lockConfirmed: true)))
    }

    @Test("sessions round-trip through Codable mid-absence")
    func codable() throws {
        var s = session()
        s.handle(.enteredBackground(at(10)))
        s.handle(.backgroundTimeExpired(at(40)))
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(PhoneDownSession.self, from: data)
        #expect(decoded == s)
    }
}
