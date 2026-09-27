#if os(iOS)
import AppIntervention
import CallKit
import LocalAuthentication
import UIKit

/// The iOS ``PhoneDownEventSource``.
///
/// - `didEnterBackground` / `didBecomeActive` (never `.inactive`).
/// - On background it begins a background task (about 30 s, not guaranteed) and polls
///   `isProtectedDataAvailable` every `pollInterval`; `false`, or
///   `protectedDataWillBecomeUnavailable`, emits ``PhoneDownEvent/lockConfirmed(_:)``.
///   If the task expires first, ``PhoneDownEvent/backgroundTimeExpired(_:)`` is emitted.
/// - `protectedDataDidBecomeAvailable` emits ``PhoneDownEvent/unlocked(_:)``.
/// - `CXCallObserver` emits ``PhoneDownEvent/callChanged(active:at:)``.
///
/// Uses public API only (no `com.apple.springboard.lockcomplete`).
@MainActor
public final class UIKitPhoneDownEventSource: NSObject, PhoneDownEventSource, CXCallObserverDelegate {
    private let clock: any InterventionClock
    private let pollInterval: Duration
    private let broadcaster = Broadcaster<PhoneDownEvent>()
    private let callObserver = CXCallObserver()
    private var observers: [NSObjectProtocol] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var poller: Task<Void, Never>?

    /// - Parameters:
    ///   - clock: Timestamps events.
    ///   - pollInterval: How often `isProtectedDataAvailable` is read while in the background.
    public init(clock: any InterventionClock = SystemClock(), pollInterval: Duration = .seconds(1)) {
        self.clock = clock
        self.pollInterval = pollInterval
        super.init()
        callObserver.setDelegate(self, queue: .main)
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor (UIKitPhoneDownEventSource) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            })
        }
        observe(UIApplication.didEnterBackgroundNotification) { $0.didEnterBackground() }
        observe(UIApplication.didBecomeActiveNotification) { $0.didBecomeActive() }
        observe(UIApplication.protectedDataWillBecomeUnavailableNotification) { $0.lockConfirmed(.protectedDataWillBecomeUnavailable) }
        observe(UIApplication.protectedDataDidBecomeAvailableNotification) { $0.signal(.protectedDataDidBecomeAvailable) }
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        poller?.cancel()
    }

    public func events() -> AsyncStream<PhoneDownEvent> { broadcaster.stream() }

    /// Every signal goes through the pure mapping ``PhoneDownEvent/init(signal:at:)``.
    private func signal(_ signal: DeviceSignal) {
        if let event = PhoneDownEvent(signal: signal, at: clock.now) { broadcaster.yield(event) }
    }

    private func didEnterBackground() {
        signal(.didEnterBackground)
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AppIntervention.PhoneDown") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.signal(.backgroundTaskExpired)
                self.endBackgroundTask()
            }
        }
        let interval = pollInterval
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                let available = UIApplication.shared.isProtectedDataAvailable
                if !available {
                    self.lockConfirmed(.protectedDataPoll(available: false))
                    return
                }
            }
        }
    }

    private func didBecomeActive() {
        endBackgroundTask()
        signal(.didBecomeActive)
    }

    private func lockConfirmed(_ source: DeviceSignal) {
        signal(source)
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        poller?.cancel()
        poller = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    public nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        MainActor.assumeIsolated {
            let active = self.callObserver.calls.filter { !$0.hasEnded }.count
            self.signal(.callsChanged(activeCalls: active))
        }
    }
}

extension PhoneDownCapability {
    /// `.lockDetectable` when a passcode (or biometrics with passcode) is set.
    @MainActor
    public static var current: PhoneDownCapability {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) ? .lockDetectable : .lockUndetectable
    }
}
#endif
