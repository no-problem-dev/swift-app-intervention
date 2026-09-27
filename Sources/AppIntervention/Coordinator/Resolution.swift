import Foundation

/// How the user resolved an intervention. Option ids are the host's (e.g. `"pay-50"`, `"skip"`).
public enum InterventionResolution: Sendable, Hashable {
    /// Open anyway: grant a pass for `passDuration`.
    case proceed(optionID: String, passDuration: Duration)
    /// Do not open.
    case abandon(optionID: String?)

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
    public let contextID: UUID
    public let appID: GuardedApp.ID
    public let tier: InterventionTier
    public let resolution: InterventionResolution
    public let resolvedAt: Date
    /// The pass granted by ``InterventionResolution/proceed(optionID:passDuration:)``.
    public let pass: Pass?
}

/// What one automation run did.
public struct AutomationRunOutcome: Sendable, Hashable {
    public let decision: InterventionDecision
    /// From the start of the run to the decision. Useful device-gate evidence for launch latency.
    public let elapsed: Duration
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
    func continueInForeground() async throws
}

/// A scripted ``ForegroundContinuation``. For tests and previews.
public struct StubForegroundContinuation: ForegroundContinuation {
    public enum Behavior: Sendable, Hashable { case succeed, fail, unavailable, alreadyForeground }
    public struct Failure: Error {}

    public let behavior: Behavior
    private let onContinue: @Sendable () -> Void

    public init(_ behavior: Behavior = .succeed, onContinue: @escaping @Sendable () -> Void = {}) {
        self.behavior = behavior
        self.onContinue = onContinue
    }

    public var isForeground: Bool { behavior == .alreadyForeground }
    public var canContinueInForeground: Bool { behavior == .succeed || behavior == .fail }

    public func continueInForeground() async throws {
        onContinue()
        if behavior == .fail { throw Failure() }
    }
}
