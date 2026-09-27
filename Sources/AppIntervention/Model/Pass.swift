import Foundation

/// Permission to open an app without an intervention until ``expiresAt``.
///
/// A pass is what breaks the reopen loop: the "App is opened" automation cannot tell a
/// home-screen launch from the host reopening the app after "proceed", so the host grants a
/// pass *before* reopening and the next automation run passes through.
public struct Pass: Sendable, Hashable, Codable {
    public let appID: GuardedApp.ID
    public let grantedAt: Date
    public let expiresAt: Date
    /// While `now < returnWindowEndsAt`, the next automation run is the host's own reopen:
    /// it passes through without being counted as an open, and consumes the window.
    public var returnWindowEndsAt: Date?

    public init(appID: GuardedApp.ID, grantedAt: Date, expiresAt: Date, returnWindowEndsAt: Date? = nil) {
        self.appID = appID
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.returnWindowEndsAt = returnWindowEndsAt
    }

    /// `grantedAt <= date < expiresAt`.
    public func isValid(at date: Date) -> Bool {
        grantedAt <= date && date < expiresAt
    }

    /// Whether `date` falls inside the unconsumed return window.
    public func isInReturnWindow(at date: Date) -> Bool {
        guard let end = returnWindowEndsAt else { return false }
        return grantedAt <= date && date < end
    }
}
