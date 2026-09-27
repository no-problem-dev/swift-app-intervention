import Foundation

/// How the user resolved an intervention. Option ids are the host's (e.g. `"pay-50"`, `"skip"`).
public enum InterventionResolution: Sendable, Hashable {
    /// Open anyway: grant a pass for `passDuration`.
    case proceed(optionID: String, passDuration: Duration)
    /// Do not open.
    case abandon(optionID: String?)

    /// The host option that produced this resolution.
    public var optionID: String? {
        switch self {
        case .proceed(let id, _): id
        case .abandon(let id): id
        }
    }
}

/// Proof that a resolution was recorded exactly once.
///
/// Book costs or rewards in the host ledger with ``contextID`` as the idempotency key.
public struct ResolutionReceipt: Sendable, Hashable {
    /// The intervention's id — the ledger's idempotency key.
    public let contextID: UUID
    /// The guarded app.
    public let appID: GuardedApp.ID
    /// The tier of the intervention.
    public let tier: InterventionTier
    /// What the user chose.
    public let resolution: InterventionResolution
    /// When it was recorded.
    public let resolvedAt: Date
    /// The pass granted by ``InterventionResolution/proceed(optionID:passDuration:)``.
    public let pass: Pass?

    /// Creates a receipt. The coordinator makes these; hosts build them in tests.
    public init(contextID: UUID, appID: GuardedApp.ID, tier: InterventionTier, resolution: InterventionResolution, resolvedAt: Date, pass: Pass?) {
        self.contextID = contextID
        self.appID = appID
        self.tier = tier
        self.resolution = resolution
        self.resolvedAt = resolvedAt
        self.pass = pass
    }
}

/// What one automation run did.
public struct AutomationRunOutcome: Sendable, Hashable {
    /// What the run decided.
    public let decision: InterventionDecision
    /// From the start of the run to the decision. Useful device-gate evidence for launch latency.
    public let elapsed: Duration

    /// Creates an outcome.
    public init(decision: InterventionDecision, elapsed: Duration) {
        self.decision = decision
        self.elapsed = elapsed
    }

    /// ``elapsed`` in whole milliseconds, for logs.
    public var elapsedMilliseconds: Int64 { elapsed.milliseconds }
}

/// Bringing the host app to the foreground from a running intent.
///
/// `AppInterventionIntents` adapts `AppIntent.continueInForeground(_:alwaysConfirm:)`;
/// this protocol keeps the orchestration testable without the App Intents runtime.
public protocol ForegroundContinuation: Sendable {
    /// The intent already runs in the foreground (nothing to do).
    var isForeground: Bool { get }
    /// The system allows moving to the foreground from here.
    var canContinueInForeground: Bool { get }
    /// Brings the host app forward. Throws when the system refuses.
    func continueInForeground() async throws
}

/// A scripted ``ForegroundContinuation``. For tests and previews.
public struct StubForegroundContinuation: ForegroundContinuation {
    public enum Behavior: Sendable, Hashable {
        /// Background; continuing succeeds.
        case succeed
        /// Background; continuing throws ``Failure``.
        case fail
        /// Background; the system does not allow continuing.
        case unavailable
        /// Already in the foreground.
        case alreadyForeground
    }
    /// Thrown by ``Behavior/fail``.
    public struct Failure: Error {
        public init() {}
    }

    /// What the stub does.
    public let behavior: Behavior
    private let onContinue: @Sendable () -> Void

    /// - Parameters:
    ///   - behavior: What the stub does.
    ///   - onContinue: Called on every ``continueInForeground()``.
    public init(_ behavior: Behavior = .succeed, onContinue: @escaping @Sendable () -> Void = {}) {
        self.behavior = behavior
        self.onContinue = onContinue
    }

    /// `true` for ``Behavior/alreadyForeground``.
    public var isForeground: Bool { behavior == .alreadyForeground }
    /// `true` for ``Behavior/succeed`` and ``Behavior/fail``.
    public var canContinueInForeground: Bool { behavior == .succeed || behavior == .fail }

    /// Calls `onContinue`, then throws for ``Behavior/fail``.
    public func continueInForeground() async throws {
        onContinue()
        if behavior == .fail { throw Failure() }
    }
}
