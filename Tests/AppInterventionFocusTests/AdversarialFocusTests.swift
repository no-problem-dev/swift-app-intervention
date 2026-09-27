import Foundation
import Testing
@testable import AppIntervention
@testable import AppInterventionFocus

@MainActor
@Suite("AdversarialFocus")
struct AdversarialFocus {
    @Test("outcome re-emitted by resume() before outcomes() subscription is lost")
    func replayLost() async throws {
        let clock = ManualClock()
        var s = PhoneDownSession.start(at: clock.now, duration: .seconds(60))
        s.cancel(at: clock.now)
        let c = PhoneDownSessionController(store: InMemoryPhoneDownSessionStore(s), guardedOpens: ManualGuardedOpenSource(), clock: clock)
        c.resume(appIsActive: true)
        let stream = c.outcomes()
        let t = Task { var got = 0; for await _ in stream { got += 1; break }; return got }
        try await Task.sleep(for: .milliseconds(100))
        t.cancel()
        #expect(await t.value == 1, "subscriber that attached after resume() saw nothing")
    }
}
