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

@Suite("Intents adapter", .timeLimit(.minutes(1)))
struct IntentsAdapterTests {
    @Test("the host-style intent declares background + dynamic foreground")
    func modes() {
        #expect(SamplePauseIntent.supportedModes.contains(.background))
        #expect(SamplePauseIntent.supportedModes.contains(.foreground(.dynamic)))
    }

    @Test("M14 / E-M2: every adapter defaults to alwaysConfirm: false")
    func defaults() {
        #expect(InterventionIntentDefaults.alwaysConfirm == false)
        let continuation = AppIntentForegroundContinuation(SamplePauseIntent())
        #expect(continuation.alwaysConfirm == false)
        #expect(continuation.dialog == nil)
        #expect(AppIntentForegroundContinuation(SamplePauseIntent(), alwaysConfirm: true).alwaysConfirm)
    }

    @Test("E-M2: the current mode maps to foreground / can-continue")
    func modeMapping() {
        let foreground = ForegroundModeState(IntentModes.Current.foreground)
        #expect(foreground.isForeground)
        #expect(foreground.canContinueInForeground == IntentModes.Current.foreground.canContinueInForeground)
        let background = ForegroundModeState(IntentModes.Current.background)
        #expect(!background.isForeground)
        #expect(background.canContinueInForeground == IntentModes.Current.background.canContinueInForeground)
    }

    @Test("an unknown app returns before touching the intent runtime")
    func runInterventionNotGuarded() async {
        let coordinator = InterventionCoordinator.inMemory(catalog: StaticGuardedAppCatalog([]), policy: { InterventionPolicy() })
        let outcome = await SamplePauseIntent().runIntervention(appID: "nope", coordinator: coordinator)
        #expect(outcome.decision == .passThrough(.notGuarded))
    }
}
