import Foundation
import Observation

/// Opens a URL that returns the user to a guarded app.
///
/// `AppInterventionUI` provides `SystemAppReopener` (UIKit) on iOS.
@MainActor
public protocol AppReopener: AnyObject {
    /// `universalLinksOnly` is set for `http(s)` URLs so they never fall back to Safari.
    /// Returns whether the system opened the URL.
    func open(_ url: URL, universalLinksOnly: Bool) async -> Bool
}

/// Records every request and answers from a script. For tests and previews.
@MainActor
public final class RecordingAppReopener: AppReopener {
    public private(set) var requests: [(url: URL, universalLinksOnly: Bool)] = []
    private let accepts: (URL) -> Bool

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
@MainActor @Observable
public final class InterventionInbox {
    public private(set) var pending: InterventionContext?

    @ObservationIgnored private let handoff: any InterventionHandoff
    @ObservationIgnored private let clock: any InterventionClock
    @ObservationIgnored private let maxAge: Duration

    public init(handoff: any InterventionHandoff, clock: any InterventionClock = SystemClock(), maxAge: Duration = .seconds(120)) {
        self.handoff = handoff
        self.clock = clock
        self.maxAge = maxAge
    }

    /// Takes a fresh pending context from the handoff, if any. Keeps the current one otherwise.
    public func refresh() {
        if let context = try? handoff.take(now: clock.now, maxAge: maxAge) {
            pending = context
        }
    }

    /// Refreshes on every handoff change until the task is cancelled.
    public func observe() async {
        refresh()
        for await _ in handoff.changes() {
            refresh()
        }
    }

    public func dismiss() {
        pending = nil
    }
}

/// Resolves the pending intervention: records it, grants the pass, reopens the app.
@MainActor @Observable
public final class InterventionPresenter {
    /// Result of ``proceed(optionID:passDuration:)``.
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
    }

    @ObservationIgnored public let coordinator: InterventionCoordinator
    public let inbox: InterventionInbox
    @ObservationIgnored private let reopener: any AppReopener

    public init(coordinator: InterventionCoordinator, inbox: InterventionInbox, reopener: any AppReopener) {
        self.coordinator = coordinator
        self.inbox = inbox
        self.reopener = reopener
    }

    public var context: InterventionContext? { inbox.pending }

    /// Grants a pass, logs `proceeded`, dismisses, then tries the app's reopen URLs in order.
    /// When nothing reopens, the return window is consumed so a later manual open is counted.
    public func proceed(optionID: String, passDuration: Duration) async throws(InterventionError) -> ProceedResult {
        guard let context = inbox.pending else {
            throw InterventionError(.alreadyResolved, message: "No pending intervention")
        }
        let receipt: ResolutionReceipt
        do {
            receipt = try coordinator.resolve(context, .proceed(optionID: optionID, passDuration: passDuration))
        } catch {
            if error.code == .alreadyResolved { inbox.dismiss() }
            throw error
        }
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
        guard let context = inbox.pending else {
            throw InterventionError(.alreadyResolved, message: "No pending intervention")
        }
        do {
            let receipt = try coordinator.resolve(context, .abandon(optionID: optionID))
            inbox.dismiss()
            return receipt
        } catch {
            if error.code == .alreadyResolved { inbox.dismiss() }
            throw error
        }
    }
}
