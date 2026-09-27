import Foundation

/// An opaque strictness level chosen by rules. The host maps it to prices, copy and pause length.
public struct InterventionTier: RawRepresentable, Sendable, Hashable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    /// The tier used when nothing more specific applies.
    public static let standard = InterventionTier(rawValue: "standard")

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Why an app is locked. The host UI resolves its copy from ``id``.
public struct LockReason: Sendable, Hashable, Codable {
    /// Host-defined, e.g. `"habits-unfinished"`.
    public let id: String
    /// Optional extra text, already localized by the host.
    public let detail: String?

    /// Creates a lock reason.
    public init(id: String, detail: String? = nil) {
        self.id = id
        self.detail = detail
    }
}

/// Everything the pause screen needs. Crosses the process boundary through the handoff.
public struct InterventionContext: Identifiable, Sendable, Hashable, Codable {
    /// Unique per intervention. Use it as the idempotency key when booking costs in the host's ledger.
    public let id: UUID
    /// The app the user was opening.
    public let app: GuardedApp
    /// When the automation run decided to intervene.
    public let requestedAt: Date
    /// The strictness chosen by the policy.
    public let tier: InterventionTier
    /// Why the policy intervened.
    public let reason: InterventionReason

    /// Creates a context. The coordinator makes these; hosts build them in tests and previews.
    public init(id: UUID = UUID(), app: GuardedApp, requestedAt: Date, tier: InterventionTier, reason: InterventionReason) {
        self.id = id
        self.app = app
        self.requestedAt = requestedAt
        self.tier = tier
        self.reason = reason
    }

    /// The lock, when this intervention comes from a lock rule. Hosts usually offer no "proceed" then.
    public var lock: LockReason? {
        if case .locked(_, let reason) = reason { return reason }
        return nil
    }
}

/// Why the pause screen is shown.
public enum InterventionReason: Sendable, Hashable, Codable {
    /// A rule returned ``RuleVerdict/intervene(_:)``.
    case rule(id: String)
    /// A rule returned ``RuleVerdict/lock(_:tier:overridesPass:)``.
    case locked(ruleID: String, LockReason)
    /// No rule matched and the policy's fallback intervenes.
    case fallback
}

/// The result of evaluating one automation run.
public enum InterventionDecision: Sendable, Hashable {
    case passThrough(PassThroughReason)
    case intervene(InterventionContext)

    /// Whether this decision shows the pause screen.
    public var isIntervention: Bool {
        if case .intervene = self { return true }
        return false
    }
}

/// Why no pause screen is shown.
public enum PassThroughReason: Sendable, Hashable {
    /// The host's own reopen after "proceed", inside the pass's return window. Not counted as an open.
    case returnFromIntervention
    case validPass(Pass)
    /// A rule returned ``RuleVerdict/allow``.
    case rule(id: String)
    /// No rule matched and the policy's fallback passes through.
    case fallback
    /// The catalog does not know the app id.
    case notGuarded
    /// Storage failed. The automation path never traps the user.
    case failOpen(InterventionError.Code)
    /// An intervention was decided, but the host could not come to the foreground.
    case foregroundUnavailable

    /// The short code written to ``OpenEvent/note``.
    public var note: String {
        switch self {
        case .returnFromIntervention: "return"
        case .validPass: "pass"
        case .rule(let id): "rule:\(id)"
        case .fallback: "fallback"
        case .notGuarded: "notGuarded"
        case .failOpen(let code): "failOpen:\(code.rawValue)"
        case .foregroundUnavailable: "foregroundUnavailable"
        }
    }
}
