import AppIntervention
import AppIntents

/// Adapts `AppIntent.continueInForeground(_:alwaysConfirm:)` (iOS 26) to `ForegroundContinuation`.
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
/// Defaults shared by the adapters.
public enum InterventionIntentDefaults {
    /// `continueInForeground`'s system default is `true`; interventions use `false` so an
    /// automation run does not ask for confirmation every time. Whether iOS honours that from an
    /// automation is a device-gate item.
    public static let alwaysConfirm = false
}

/// How the adapter reads the intent's current mode. Pure, so it is tested without the runtime.
public struct ForegroundModeState: Sendable, Hashable {
    /// The intent already runs in the foreground.
    public let isForeground: Bool
    /// The system allows continuing in the foreground.
    public let canContinueInForeground: Bool

    /// Creates a state.
    public init(isForeground: Bool, canContinueInForeground: Bool) {
        self.isForeground = isForeground
        self.canContinueInForeground = canContinueInForeground
    }

    /// Reads `systemContext.currentMode`.
    public init(_ current: IntentModes.Current) {
        self.init(isForeground: current == .foreground, canContinueInForeground: current.canContinueInForeground)
    }
}

public struct AppIntentForegroundContinuation<Intent: AppIntent>: ForegroundContinuation {
    /// The running intent.
    public let intent: Intent
    /// Shown if the system asks for confirmation.
    public let dialog: IntentDialog?
    /// Defaults to ``InterventionIntentDefaults/alwaysConfirm`` (`false`).
    public let alwaysConfirm: Bool

    /// - Parameters:
    ///   - intent: The host's running intent.
    ///   - dialog: Shown if the system asks for confirmation.
    ///   - alwaysConfirm: Passed to `continueInForeground(_:alwaysConfirm:)`.
    public init(_ intent: Intent, dialog: IntentDialog? = nil, alwaysConfirm: Bool = InterventionIntentDefaults.alwaysConfirm) {
        self.intent = intent
        self.dialog = dialog
        self.alwaysConfirm = alwaysConfirm
    }

    public var isForeground: Bool {
        ForegroundModeState(intent.systemContext.currentMode).isForeground
    }

    public var canContinueInForeground: Bool {
        ForegroundModeState(intent.systemContext.currentMode).canContinueInForeground
    }

    public func continueInForeground() async throws {
        try await intent.continueInForeground(dialog, alwaysConfirm: alwaysConfirm)
    }
}

extension AppIntent {
    /// Runs one intervention from the host's intent: decide in the background, and continue in
    /// the foreground only when the pause screen must be shown.
    ///
    /// Never throws; see `InterventionCoordinator/handleAutomationRun(appID:continuation:)`.
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
        alwaysConfirm: Bool = InterventionIntentDefaults.alwaysConfirm
    ) async -> AutomationRunOutcome {
        await coordinator.handleAutomationRun(
            appID: appID,
            continuation: AppIntentForegroundContinuation(self, dialog: dialog, alwaysConfirm: alwaysConfirm)
        )
    }
}
