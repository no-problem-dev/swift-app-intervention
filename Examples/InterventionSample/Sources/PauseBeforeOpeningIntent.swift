import AppIntents
import AppIntervention
import AppInterventionIntents

/// The host's intent. It lives in the app target on purpose: App Intents metadata is extracted
/// from this target's source, and `supportedModes` must be the literal below.
struct PauseBeforeOpeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Before Opening"
    static let description = IntentDescription("Shows a short pause before the chosen app opens.")
    // Keep this a literal. A constant from a package is extracted as background-only.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "App")
    var app: GuardedAppOption

    init() {}

    init(app: GuardedAppOption) {
        self.app = app
    }

    func perform() async throws -> some IntentResult {
        let outcome = await runIntervention(appID: app.rawValue, coordinator: Intervention.coordinator)
        print("[SPIKE] app=\(app.rawValue) intervene=\(outcome.decision.isIntervention) decisionMs=\(outcome.elapsed.components.seconds * 1_000 + outcome.elapsed.components.attoseconds / 1_000_000_000_000_000)")
        return .result()
    }
}

/// Which app the automation guards. `rawValue` is `GuardedApp.id`.
enum GuardedAppOption: String, AppEnum {
    case instagram
    case youtube
    case x

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "App"
    static let caseDisplayRepresentations: [GuardedAppOption: DisplayRepresentation] = [
        .instagram: "Instagram",
        .youtube: "YouTube",
        .x: "X",
    ]
}
