import AppIntervention
import Foundation

/// Something that happened during a phone-down session, with the time it happened.
public enum PhoneDownEvent: Sendable, Hashable {
    /// The app entered the background. `.inactive` (Notification Center, Control Center, Siri,
    /// call banners) is deliberately not an event.
    case enteredBackground(Date)
    case becameActive(Date)
    /// The device locked: `protectedDataWillBecomeUnavailable`, or `isProtectedDataAvailable`
    /// turned false while polling. Needs a passcode and typically arrives ~10 s after locking.
    case lockConfirmed(Date)
    /// `protectedDataDidBecomeAvailable`: the device was unlocked.
    case unlocked(Date)
    /// The background task ended without a lock signal. The absence is now undetermined.
    case backgroundTimeExpired(Date)
    /// A phone call started or ended (`CXCallObserver`). Calls do not count as leaving.
    case callChanged(active: Bool, at: Date)
    /// A guarded app's automation ran. Decisive: the user opened a guarded app.
    case guardedAppOpened(appID: GuardedApp.ID, at: Date)
    /// Periodic time signal while the app runs.
    case tick(Date)
}

/// A "put the phone down" session as a pure, persistable state machine.
///
/// iOS gives no reliable signal after the app is suspended, so the session decides from what
/// it can see: a lock signal confirms an absence, a guarded app's automation is a decisive
/// failure, and an absence nobody confirmed is judged by ``Configuration/unconfirmedAbsence``
/// when the app comes back. Every transition is idempotent against duplicate events.
public struct PhoneDownSession: Identifiable, Sendable, Hashable, Codable {
    public struct Configuration: Sendable, Hashable, Codable {
        /// Unconfirmed absences this short are forgiven (quick unlock before the lock signal,
        /// a glance at another screen). Default 15 s.
        public var grace: Duration
        /// A lock signal later than this after leaving does not confirm the absence (the user
        /// went elsewhere first). Default 30 s, about a background task's lifetime.
        public var lockSignalWindow: Duration
        /// What an unconfirmed absence longer than ``grace`` means. Default ``AbsencePolicy/fail``.
        public var unconfirmedAbsence: AbsencePolicy

        public init(grace: Duration = .seconds(15), lockSignalWindow: Duration = .seconds(30), unconfirmedAbsence: AbsencePolicy = .fail) {
            self.grace = grace
            self.lockSignalWindow = lockSignalWindow
            self.unconfirmedAbsence = unconfirmedAbsence
        }
    }

    /// How to judge an absence that no lock signal confirmed.
    public enum AbsencePolicy: String, Sendable, Hashable, Codable {
        /// Count it as leaving the app (never pay out for an unverified session).
        case fail
        /// Let it pass. Use on devices without a passcode (``PhoneDownCapability/lockUndetectable``).
        case tolerate
    }

    /// The app is in the background.
    public struct Away: Sendable, Hashable, Codable {
        public var since: Date
        public var lockConfirmed: Bool
        /// The background task expired before a lock signal arrived.
        public var undetermined: Bool
        public var duringCall: Bool

        public init(since: Date, lockConfirmed: Bool = false, undetermined: Bool = false, duringCall: Bool = false) {
            self.since = since
            self.lockConfirmed = lockConfirmed
            self.undetermined = undetermined
            self.duringCall = duringCall
        }
    }

    public enum Phase: Sendable, Hashable, Codable {
        case running(away: Away?)
        case succeeded(at: Date)
        case failed(FailureReason)

        public var isTerminal: Bool {
            if case .running = self { return false }
            return true
        }
    }

    public enum FailureReason: Sendable, Hashable, Codable {
        /// Away without a lock since `since`, longer than the grace period.
        case leftApp(since: Date, undetermined: Bool)
        /// A guarded app's automation ran during the session.
        case openedGuardedApp(appID: GuardedApp.ID, at: Date)
        case cancelled(at: Date)
    }

    public let id: UUID
    public let startedAt: Date
    public let endsAt: Date
    public let configuration: Configuration
    public private(set) var phase: Phase
    public private(set) var inCall: Bool

    public static func start(id: UUID = UUID(), at date: Date, duration: Duration, configuration: Configuration = .init()) -> PhoneDownSession {
        PhoneDownSession(
            id: id, startedAt: date, endsAt: date.addingTimeInterval(duration.timeInterval),
            configuration: configuration, phase: .running(away: nil), inCall: false
        )
    }

    /// The terminal result, or `nil` while running.
    public var outcome: PhoneDownOutcome? {
        switch phase {
        case .running: nil
        case .succeeded(let at): PhoneDownOutcome(sessionID: id, startedAt: startedAt, endsAt: endsAt, result: .succeeded(at: at))
        case .failed(let reason): PhoneDownOutcome(sessionID: id, startedAt: startedAt, endsAt: endsAt, result: .failed(reason))
        }
    }

    public mutating func cancel(at date: Date) {
        guard !phase.isTerminal else { return }
        phase = .failed(.cancelled(at: date))
    }

    @discardableResult
    public mutating func handle(_ event: PhoneDownEvent) -> Phase {
        guard case .running(var away) = phase else { return phase }

        // Decisive failure first: opening a guarded app during the session.
        if case .guardedAppOpened(let appID, let t) = event {
            if startedAt <= t, t < endsAt {
                phase = .failed(.openedGuardedApp(appID: appID, at: t))
            } else {
                settleIfOver(at: t, away: away)
            }
            return phase
        }

        switch event {
        case .becameActive(let t):
            if let current = away {
                let absence = min(t, endsAt).timeIntervalSince(current.since)
                let forgiven = current.lockConfirmed || current.duringCall
                    || absence <= configuration.grace.timeInterval
                    || configuration.unconfirmedAbsence == .tolerate
                guard forgiven else {
                    phase = .failed(.leftApp(since: current.since, undetermined: current.undetermined))
                    return phase
                }
                away = nil
            }
            phase = t >= endsAt ? .succeeded(at: endsAt) : .running(away: away)

        case .enteredBackground(let t):
            if away == nil {
                if t >= endsAt {
                    phase = .succeeded(at: endsAt)
                } else {
                    phase = .running(away: Away(since: t, duringCall: inCall))
                }
            } else {
                settleIfOver(at: t, away: away)
            }

        case .lockConfirmed(let t):
            if var current = away {
                if !current.lockConfirmed, t.timeIntervalSince(current.since) <= configuration.lockSignalWindow.timeInterval {
                    current.lockConfirmed = true
                }
                away = current
                phase = .running(away: away)
                settleIfOver(at: t, away: away)
            } else if t >= endsAt {
                phase = .succeeded(at: endsAt)
            } else {
                phase = .running(away: Away(since: t, lockConfirmed: true, duringCall: inCall))
            }

        case .unlocked(let t):
            if let current = away, current.lockConfirmed {
                if t >= endsAt {
                    phase = .succeeded(at: endsAt)
                } else {
                    // After unlocking, the user has to come back: the grace period restarts.
                    phase = .running(away: Away(since: t, duringCall: inCall))
                }
            } else {
                settleIfOver(at: t, away: away)
            }

        case .backgroundTimeExpired(let t):
            if var current = away {
                current.undetermined = true
                phase = .running(away: current)
            }
            settleIfOver(at: t, away: away)

        case .callChanged(let active, let t):
            inCall = active
            if var current = away {
                if active {
                    current.duringCall = true
                } else if !current.lockConfirmed {
                    current = Away(since: t)
                }
                phase = .running(away: current)
            }
            if case .running(let latest) = phase { settleIfOver(at: t, away: latest) }

        case .tick(let t):
            settleIfOver(at: t, away: away)

        case .guardedAppOpened:
            break
        }
        return phase
    }

    /// Succeeds at `endsAt` when the time is up and nothing is unexplained.
    private mutating func settleIfOver(at t: Date, away: Away?) {
        guard case .running = phase, t >= endsAt else { return }
        if let away, !(away.lockConfirmed || away.duringCall) { return }   // judged on becameActive
        phase = .succeeded(at: endsAt)
    }
}

/// The terminal result of a session. Use ``sessionID`` as the idempotency key for rewards.
public struct PhoneDownOutcome: Sendable, Hashable, Codable {
    public enum Result: Sendable, Hashable, Codable {
        case succeeded(at: Date)
        case failed(PhoneDownSession.FailureReason)
    }

    public let sessionID: UUID
    public let startedAt: Date
    public let endsAt: Date
    public let result: Result

    public var succeeded: Bool {
        if case .succeeded = result { return true }
        return false
    }
}

/// Whether the device can tell locking from leaving.
public enum PhoneDownCapability: Sendable, Hashable {
    /// A passcode is set: protected-data signals arrive (possibly late).
    case lockDetectable
    /// No passcode: locking and leaving look the same. Consider ``PhoneDownSession/AbsencePolicy/tolerate``.
    case lockUndetectable
}
