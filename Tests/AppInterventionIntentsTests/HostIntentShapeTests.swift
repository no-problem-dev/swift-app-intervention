import AppIntents
import AppIntervention
import Testing
@testable import AppInterventionIntents

/// The shape a host writes in its own app target. Compiling it here keeps the adapter's
/// generic constraints honest; the metadata check lives in `scripts/check-intent-metadata.sh`.
private struct SamplePauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Before Opening"
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "App") var appID: String

    func perform() async throws -> some IntentResult {
        let coordinator = InterventionCoordinator(
            catalog: StaticGuardedAppCatalog([]),
            policy: { InterventionPolicy() },
            passes: InMemoryPassStore(), log: InMemoryOpenLogStore(), handoff: InMemoryInterventionHandoff()
        )
        _ = await runIntervention(appID: appID, coordinator: coordinator)
        return .result()
    }
}

@Suite("Intents adapter")
struct IntentsAdapterTests {
    @Test("the host-style intent declares background + dynamic foreground")
    func modes() {
        #expect(SamplePauseIntent.supportedModes.contains(.background))
        #expect(SamplePauseIntent.supportedModes.contains(.foreground(.dynamic)))
    }

    @Test("the adapter defaults to alwaysConfirm: false")
    func defaults() {
        let continuation = AppIntentForegroundContinuation(SamplePauseIntent())
        #expect(continuation.alwaysConfirm == false)
        #expect(continuation.dialog == nil)
    }
}
