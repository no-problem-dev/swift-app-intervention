import Foundation

/// An app the user wants to pause before opening. The host defines the set.
public struct GuardedApp: Identifiable, Sendable, Hashable, Codable {
    /// Stable, host-chosen identifier such as `"instagram"`. Never localized.
    ///
    /// This is the value the host's `AppEnum` (or `AppEntity`) parameter carries into its
    /// intent, and the key every store uses.
    public let id: String
    /// The name shown on the pause screen.
    public var displayName: String
    /// Informational only: iOS cannot open another app by bundle identifier.
    public var bundleIdentifier: String?
    /// URLs tried in order to return the user to the app after they choose to proceed.
    ///
    /// Custom schemes (`instagram://`) are opened plainly; `http(s)` URLs are opened as
    /// universal links only, so they never fall back to Safari. Third-party schemes are
    /// undocumented and may change, so list a universal link as a fallback when one exists.
    /// When the list is empty or every URL fails, the UI asks the user to switch back.
    public var reopenURLs: [URL]

    public init(id: String, displayName: String, bundleIdentifier: String? = nil, reopenURLs: [URL] = []) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.reopenURLs = reopenURLs
    }
}
