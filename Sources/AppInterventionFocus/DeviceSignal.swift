import Foundation

/// A raw system signal, before it becomes a ``PhoneDownEvent``.
///
/// `UIKitPhoneDownEventSource` turns UIKit notifications, the protected-data poll, the background
/// task's expiration and `CXCallObserver` into these; ``PhoneDownEvent/init(signal:at:)`` decides
/// which of them matter. Keeping that decision pure makes it testable without UIKit.
public enum DeviceSignal: Sendable, Hashable {
    case didEnterBackground
    case didBecomeActive
    /// `.inactive`: Control Center, Notification Center, Siri, call banners, the app switcher.
    case willResignActive
    case willEnterForeground
    case protectedDataWillBecomeUnavailable
    case protectedDataDidBecomeAvailable
    /// One reading of `UIApplication.isProtectedDataAvailable` while polling in the background.
    case protectedDataPoll(available: Bool)
    case backgroundTaskExpired
    /// `CXCallObserver` changed; `activeCalls` counts calls that have not ended.
    case callsChanged(activeCalls: Int)
}

extension PhoneDownEvent {
    /// Maps a system signal to a session event, or `nil` when the signal must not affect the
    /// session (`.inactive` transitions, foreground-entering, a poll that still sees the device
    /// unlocked).
    public init?(signal: DeviceSignal, at date: Date) {
        switch signal {
        case .didEnterBackground: self = .enteredBackground(date)
        case .didBecomeActive: self = .becameActive(date)
        case .willResignActive, .willEnterForeground: return nil
        case .protectedDataWillBecomeUnavailable: self = .lockConfirmed(date)
        case .protectedDataDidBecomeAvailable: self = .unlocked(date)
        case .protectedDataPoll(let available):
            guard !available else { return nil }
            self = .lockConfirmed(date)
        case .backgroundTaskExpired: self = .backgroundTimeExpired(date)
        case .callsChanged(let active): self = .callChanged(active: active > 0, at: date)
        }
    }
}
