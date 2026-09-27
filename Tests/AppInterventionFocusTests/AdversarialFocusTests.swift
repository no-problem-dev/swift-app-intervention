import Foundation
import Testing
@testable import AppIntervention
@testable import AppInterventionFocus

@MainActor
@Suite("AdversarialFocus", .timeLimit(.minutes(1)))
struct AdversarialFocus {
    @Test("outcome re-emitted by resume() before outcomes() subscription is lost")
    func replayLost() async throws {
        let clock = ManualClock()
        var s = PhoneDownSession.start(at: clock.now, duration: .seconds(60))
        s.cancel(at: clock.now)
        let c = PhoneDownSessionController(store: InMemoryPhoneDownSessionStore(s), guardedOpens: ManualGuardedOpenSource(), clock: clock)
        c.resume(appIsActive: true)
        let got = await collect(c.outcomes(), count: 1, within: .milliseconds(500))
        #expect(got.count == 1, "subscriber that attached after resume() saw nothing")
    }
}
