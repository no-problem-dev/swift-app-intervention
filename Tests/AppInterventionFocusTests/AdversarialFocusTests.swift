import Foundation
import Testing
@testable import AppIntervention
@testable import AppInterventionFocus

@MainActor
@Suite("Adversarial (focus): regressions from code review", .timeLimit(.minutes(1)))
struct AdversarialFocus {
    @Test("C-S5: a subscriber that starts after resume() still receives the unacknowledged outcome")
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
