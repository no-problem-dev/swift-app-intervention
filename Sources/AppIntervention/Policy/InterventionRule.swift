import Foundation

/// Everything a rule may look at. Built once per automation run by the coordinator.
public struct RuleInput: Sendable {
    /// The app being opened.
    public let app: GuardedApp
    /// The instant of the run.
    public let now: Date
    /// The policy's calendar.
    public let calendar: Calendar
    /// Recent open-log events, read once per run.
    public let opens: OpenLogQuery
    /// Host state, fetched once per run from the ``HostConditionProvider``.
    public let host: HostSnapshot

    /// Creates an input. The coordinator builds these; tests build them directly.
    public init(app: GuardedApp, now: Date, calendar: Calendar = .current, opens: OpenLogQuery? = nil, host: HostSnapshot = .empty) {
        self.app = app
        self.now = now
        self.calendar = calendar
        self.opens = opens ?? OpenLogQuery([], calendar: calendar)
        self.host = host
    }
}

/// What a rule wants.
public enum RuleVerdict: Sendable, Hashable {
    /// Show the pause screen with this tier.
    case intervene(InterventionTier)
    /// Show the pause screen as locked. With `overridesPass`, even a valid pass does not help
    /// (the host's own reopen inside the return window still passes through).
    case lock(LockReason, tier: InterventionTier, overridesPass: Bool)
    /// Let the open through (e.g. "free hours").
    case allow
}

/// One clause of an ``InterventionPolicy``. Pure and synchronous.
public protocol InterventionRule: Sendable {
    /// Stable id, recorded in decisions and the log.
    var id: String { get }
    /// `nil` when the rule has no opinion about this run.
    func evaluate(_ input: RuleInput) -> RuleVerdict?
}

/// "Locked until a host condition holds" — for example until today's habits are done.
///
/// The predicate reads ``RuleInput/host``; fetch what it needs in the ``HostConditionProvider``.
public struct LockRule: InterventionRule {
    public let id: String
    /// The tier of the pause screen when locked.
    public let tier: InterventionTier
    /// Whether the lock applies even with a valid pass.
    public let overridesPass: Bool
    private let isLocked: @Sendable (RuleInput) -> LockReason?

    /// Creates a lock rule. `isLocked` returns a reason while locked, `nil` otherwise.
    public init(
        id: String, tier: InterventionTier = .standard, overridesPass: Bool = false,
        isLocked: @escaping @Sendable (RuleInput) -> LockReason?
    ) {
        self.id = id
        self.tier = tier
        self.overridesPass = overridesPass
        self.isLocked = isLocked
    }

    /// Asks the predicate.
    public func evaluate(_ input: RuleInput) -> RuleVerdict? {
        isLocked(input).map { .lock($0, tier: tier, overridesPass: overridesPass) }
    }
}

/// "From the Nth open of the (host) day on, intervene with this tier."
///
/// Counts `opened` events on the day containing now, including the current open, which the
/// coordinator has not logged yet when rules run: `threshold: 20` intervenes on the 20th open.
public struct OpenCountRule: InterventionRule, Hashable {
    public let id: String
    /// The open (1-based, counting the current one) from which the rule intervenes.
    public let threshold: Int
    /// The tier of the pause screen.
    public let tier: InterventionTier
    /// `nil` counts opens of every app; otherwise only the listed apps (and only applies to them).
    public let appIDs: Set<GuardedApp.ID>?

    /// Creates an open-count rule.
    public init(id: String, threshold: Int, tier: InterventionTier, appIDs: Set<GuardedApp.ID>? = nil) {
        self.id = id
        self.threshold = threshold
        self.tier = tier
        self.appIDs = appIDs
    }

    /// Intervenes from the `threshold`-th open of the host day.
    public func evaluate(_ input: RuleInput) -> RuleVerdict? {
        if let appIDs, !appIDs.contains(input.app.id) { return nil }
        let day = input.opens.day(containing: input.now)
        let earlier: Int
        if let appIDs {
            earlier = appIDs.reduce(0) { $0 + input.opens.count(.opened, in: day, appID: $1) }
        } else {
            earlier = input.opens.count(.opened, in: day)
        }
        return earlier + 1 >= threshold ? .intervene(tier) : nil
    }
}
