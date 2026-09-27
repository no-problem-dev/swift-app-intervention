import Foundation
import Observation

/// Opens a URL that returns the user to a guarded app.
///
/// `AppInterventionUI` provides `SystemAppReopener` (UIKit) on iOS.
@MainActor
public protocol AppReopener {
    /// `universalLinksOnly` is set for `http(s)` URLs so they never fall back to Safari.
    /// Returns whether the system opened the URL.
    func open(_ url: URL, universalLinksOnly: Bool) async -> Bool
}

/// Records every request and answers from a script. For tests and previews.
@MainActor
public final class RecordingAppReopener: AppReopener {
    /// Every URL asked for, in order.
    public private(set) var requests: [(url: URL, universalLinksOnly: Bool)] = []
    private let accepts: (URL) -> Bool

    /// - Parameter accepts: Whether a URL "opens". Defaults to accepting everything.
    public init(accepts: @escaping (URL) -> Bool = { _ in true }) {
        self.accepts = accepts
    }

    public func open(_ url: URL, universalLinksOnly: Bool) async -> Bool {
        requests.append((url, universalLinksOnly))
        return accepts(url)
    }
}

/// The pending intervention, observed by the host UI.
///
/// The intent posts to the ``InterventionHandoff``; the inbox takes it. Call ``refresh()`` when the
/// scene becomes active (the process may have been launched in the background just for the
/// intent, before any view existed) and run ``observe()`` in a `.task` for the fast path.
/// A context the coordinator withdraws (the app could not come forward) is dropped, and
/// contexts older than `maxAge` are never shown.
@MainActor @Observable
public final class InterventionInbox {
    /// The intervention to show, if any.
    public private(set) var pending: InterventionContext?

    @ObservationIgnored private let handoff: any InterventionHandoff
    @ObservationIgnored private let clock: any InterventionClock
    @ObservationIgnored public let maxAge: Duration

    /// - Parameters:
    ///   - handoff: Usually `coordinator.handoff`.
    ///   - clock: The source of "now" for the age check.
    ///   - maxAge: Older contexts are dropped. Default two minutes.
    public init(handoff: any InterventionHandoff, clock: any InterventionClock = SystemClock(), maxAge: Duration = .seconds(120)) {
        self.handoff = handoff
        self.clock = clock
        self.maxAge = maxAge
    }

    /// Takes a fresh pending context from the handoff, if any, and drops a current one that
    /// has gone stale.
    public func refresh() {
        let now = clock.now
        if let context = try? handoff.take(now: now, maxAge: maxAge) {
            pending = context
        } else if let current = pending, !isFresh(current, now: now, maxAge: maxAge) {
            pending = nil
        }
    }

    /// Follows handoff changes until the task is cancelled.
    public func observe() async {
        refresh()
        for await change in handoff.changes() {
            switch change {
            case .posted:
                refresh()
            case .withdrawn(let id):
                if pending?.id == id { pending = nil }
            case .taken:
                break
            }
        }
    }

    /// The pending context if it is still young enough to act on.
    public var current: InterventionContext? {
        guard let pending, isFresh(pending, now: clock.now, maxAge: maxAge) else { return nil }
        return pending
    }

    /// Hides the pause screen without recording anything.
    public func dismiss() {
        pending = nil
    }
}

/// Resolves the pending intervention: records it, grants the pass, reopens the app.
@MainActor @Observable
public final class InterventionPresenter {
    /// Result of ``proceed(optionID:passDuration:onResolved:)``.
    public struct ProceedResult: Sendable, Hashable {
        public enum Reopen: Sendable, Hashable {
            case reopened(URL)
            /// The app has no reopen URL; ask the user to switch back.
            case noURL
            /// Every URL was refused; ask the user to switch back.
            case failed
        }
        public let receipt: ResolutionReceipt
        public let reopen: Reopen

        public init(receipt: ResolutionReceipt, reopen: Reopen) {
            self.receipt = receipt
            self.reopen = reopen
        }
    }

    @ObservationIgnored public let coordinator: InterventionCoordinator
    public let inbox: InterventionInbox
    @ObservationIgnored private let reopener: any AppReopener

    public init(coordinator: InterventionCoordinator, inbox: InterventionInbox, reopener: any AppReopener) {
        self.coordinator = coordinator
        self.inbox = inbox
        self.reopener = reopener
    }

    /// The intervention to act on: ``InterventionInbox/current`` (fresh contexts only).
    public var context: InterventionContext? { inbox.current }

    /// Grants a pass, logs `proceeded`, calls `onResolved`, dismisses, then tries the app's
    /// reopen URLs in order. When nothing reopens, the return window is consumed so a later
    /// manual open is counted.
    ///
    /// - Parameter onResolved: Runs synchronously right after the resolution is recorded and
    ///   **before** the other app is opened. Book the cost in your ledger here: once the other
    ///   app is in front, this process may be suspended or terminated. If the process dies
    ///   anyway, reconcile from `proceeded` events by `contextID`.
    public func proceed(
        optionID: String,
        passDuration: Duration,
        onResolved: (ResolutionReceipt) -> Void = { _ in }
    ) async throws(InterventionError) -> ProceedResult {
        let context = try actionableContext()
        let receipt: ResolutionReceipt
        do {
            receipt = try coordinator.resolve(context, .proceed(optionID: optionID, passDuration: passDuration))
        } catch {
            if error.code == .alreadyResolved { inbox.dismiss() }
            throw error
        }
        onResolved(receipt)
        inbox.dismiss()

        let urls = context.app.reopenURLs
        guard !urls.isEmpty else {
            try? coordinator.consumeReturnWindow(appID: context.app.id)
            return ProceedResult(receipt: receipt, reopen: .noURL)
        }
        for url in urls {
            let universal = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            if await reopener.open(url, universalLinksOnly: universal) {
                return ProceedResult(receipt: receipt, reopen: .reopened(url))
            }
        }
        try? coordinator.consumeReturnWindow(appID: context.app.id)
        return ProceedResult(receipt: receipt, reopen: .failed)
    }

    /// Logs `abandoned` and dismisses.
    @discardableResult
    public func abandon(optionID: String? = nil) throws(InterventionError) -> ResolutionReceipt {
        let context = try actionableContext()
        do {
            let receipt = try coordinator.resolve(context, .abandon(optionID: optionID))
            inbox.dismiss()
            return receipt
        } catch {
            if error.code == .alreadyResolved { inbox.dismiss() }
            throw error
        }
    }

    private func actionableContext() throws(InterventionError) -> InterventionContext {
        guard let pending = inbox.pending else {
            throw InterventionError(.alreadyResolved, message: "No pending intervention")
        }
        guard inbox.current != nil else {
            inbox.dismiss()
            throw InterventionError(.expired, message: "Intervention \(pending.id) is older than \(inbox.maxAge)")
        }
        return pending
    }
}
