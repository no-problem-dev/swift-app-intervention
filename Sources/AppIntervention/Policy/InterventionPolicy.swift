import Foundation

/// The pure decision engine: given the run's input and the current pass, intervene or not.
///
/// Evaluation order:
/// 1. A pass in its return window → ``PassThroughReason/returnFromIntervention``. This is the
///    host's own reopen right after a resolution it accepted; intervening would loop.
/// 2. The first rule returning a lock with `overridesPass` → intervene, locked.
/// 3. A valid pass → ``PassThroughReason/validPass(_:)``.
/// 4. The first rule, in order, with any verdict.
/// 5. ``fallback``.
public struct InterventionPolicy: Sendable {
    /// What happens when no rule has an opinion.
    public enum Fallback: Sendable, Hashable {
        case intervene(InterventionTier)
        case passThrough
    }

    /// Evaluated in order.
    public var rules: [any InterventionRule]
    /// What happens when no rule has an opinion.
    public var fallback: Fallback
    /// The calendar rules see in ``RuleInput/calendar``.
    public var calendar: Calendar
    /// Where the host's day starts (e.g. 4 hours → 04:00). Applied to ``RuleInput/opens``, so
    /// ``OpenCountRule`` counts the same "today" as `OpenCountSummaryView(dayStartOffset:)`.
    public var dayStartOffset: Duration

    /// Creates a policy.
    public init(
        rules: [any InterventionRule] = [], fallback: Fallback = .intervene(.standard),
        calendar: Calendar = .current, dayStartOffset: Duration = .zero
    ) {
        self.rules = rules
        self.fallback = fallback
        self.calendar = calendar
        self.dayStartOffset = dayStartOffset
    }

    /// Decides one run. Pure: the same input, pass and context id always give the same decision.
    public func decide(_ input: RuleInput, pass: Pass?, contextID: UUID = UUID()) -> InterventionDecision {
        let now = input.now
        if let pass, pass.appID == input.app.id, pass.isInReturnWindow(at: now) {
            return .passThrough(.returnFromIntervention)
        }

        let verdicts = rules.lazy.compactMap { rule in rule.evaluate(input).map { (rule.id, $0) } }

        for (ruleID, verdict) in verdicts {
            if case .lock(let reason, let tier, true) = verdict {
                return .intervene(context(input, contextID, tier, .locked(ruleID: ruleID, reason)))
            }
        }

        if let pass, pass.appID == input.app.id, pass.isValid(at: now) {
            return .passThrough(.validPass(pass))
        }

        if let (ruleID, verdict) = verdicts.first {
            switch verdict {
            case .intervene(let tier):
                return .intervene(context(input, contextID, tier, .rule(id: ruleID)))
            case .lock(let reason, let tier, _):
                return .intervene(context(input, contextID, tier, .locked(ruleID: ruleID, reason)))
            case .allow:
                return .passThrough(.rule(id: ruleID))
            }
        }

        switch fallback {
        case .intervene(let tier): return .intervene(context(input, contextID, tier, .fallback))
        case .passThrough: return .passThrough(.fallback)
        }
    }

    private func context(_ input: RuleInput, _ id: UUID, _ tier: InterventionTier, _ reason: InterventionReason) -> InterventionContext {
        InterventionContext(id: id, app: input.app, requestedAt: input.now, tier: tier, reason: reason)
    }
}
