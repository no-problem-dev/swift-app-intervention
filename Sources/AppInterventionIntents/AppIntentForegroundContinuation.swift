import AppIntervention
import AppIntents

/// Adapts `AppIntent.continueInForeground(_:alwaysConfirm:)` (iOS 26) to ``ForegroundContinuation``.
///
/// The host intent must declare, **as a literal in its own source**:
///
/// ```swift
/// static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
/// ```
///
/// The App Intents metadata extractor reads that literal at build time. A constant imported
/// from a package compiles, but is extracted as background-only (`supportedModes: 1` instead of
/// `9` in `extract.actionsdata`) without any warning, and `continueInForeground` then cannot
/// bring the app forward. That is why this package ships no `IntentModes` constant.
public struct AppIntentForegroundContinuation<Intent: AppIntent>: ForegroundContinuation {
    public let intent: Intent
    public let dialog: IntentDialog?
    /// The system default is `true`; interventions pass `false` so an automation run does not
    /// ask for confirmation every time. Whether iOS honours that from an automation is a
    /// device-gate item.
    public let alwaysConfirm: Bool

    public init(_ intent: Intent, dialog: IntentDialog? = nil, alwaysConfirm: Bool = false) {
        self.intent = intent
        self.dialog = dialog
        self.alwaysConfirm = alwaysConfirm
    }

    public var isForeground: Bool {
        intent.systemContext.currentMode == .foreground
    }

    public var canContinueInForeground: Bool {
        intent.systemContext.currentMode.canContinueInForeground
    }

    public func continueInForeground() async throws {
        try await intent.continueInForeground(dialog, alwaysConfirm: alwaysConfirm)
    }
}

extension AppIntent {
    /// Runs one intervention from the host's intent: decide in the background, and continue in
    /// the foreground only when the pause screen must be shown.
    ///
    /// Never throws; see ``InterventionCoordinator/handleAutomationRun(appID:continuation:)``.
    ///
    /// ```swift
    /// func perform() async throws -> some IntentResult {
    ///     _ = await runIntervention(appID: app.rawValue, coordinator: Intervention.coordinator)
    ///     return .result()
    /// }
    /// ```
    @discardableResult
    public func runIntervention(
        appID: GuardedApp.ID,
        coordinator: InterventionCoordinator,
        dialog: IntentDialog? = nil,
        alwaysConfirm: Bool = false
    ) async -> AutomationRunOutcome {
        await coordinator.handleAutomationRun(
            appID: appID,
            continuation: AppIntentForegroundContinuation(self, dialog: dialog, alwaysConfirm: alwaysConfirm)
        )
    }
}
