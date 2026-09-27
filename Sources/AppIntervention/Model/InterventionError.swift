import Foundation

/// The single error type thrown by the package's stores and resolution APIs.
///
/// The automation path never throws: storage failures there become
/// ``PassThroughReason/failOpen(_:)`` so a broken store can never make an app unopenable.
/// UI paths (``InterventionCoordinator/resolve(_:_:)``, the presenter) throw this error.
///
/// ``Code`` is an open set (a struct, not an enum), so adding codes in a later version does not
/// break a host's `switch`. Custom stores wrap their own failures with ``Code/custom`` and
/// ``underlying``.
public struct InterventionError: Error, Sendable, CustomStringConvertible {
    /// What went wrong.
    public struct Code: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// The App Group container could not be resolved (usually a missing entitlement).
        public static let appGroupUnavailable = Code(rawValue: "appGroupUnavailable")
        /// A file could not be read.
        public static let read = Code(rawValue: "read")
        /// A file could not be written.
        public static let write = Code(rawValue: "write")
        /// A file could not be decoded. It has been moved aside and treated as empty.
        public static let corrupt = Code(rawValue: "corrupt")
        /// A file was written by a newer format version; it is left untouched.
        public static let unsupportedVersion = Code(rawValue: "unsupportedVersion")
        /// The intervention was already resolved (double tap, second presenter, retry).
        public static let alreadyResolved = Code(rawValue: "alreadyResolved")
        /// The host's conditions did not arrive in time; the run passed through.
        public static let timeout = Code(rawValue: "timeout")
        /// The pending intervention is too old to act on.
        public static let expired = Code(rawValue: "expired")
        /// A host-provided store failed; see ``InterventionError/underlying``.
        public static let custom = Code(rawValue: "custom")

        public var description: String { rawValue }
    }

    /// What went wrong.
    public let code: Code
    /// The file involved, when there is one (last path component).
    public let file: String?
    /// Human-readable detail for logs.
    public let message: String?
    /// The error this one wraps, e.g. a Foundation error or a custom store's error.
    public let underlying: (any Error & Sendable)?

    /// Creates an error. Custom stores use ``Code/custom`` with their own error as `underlying`.
    public init(_ code: Code, file: String? = nil, message: String? = nil, underlying: (any Error & Sendable)? = nil) {
        self.code = code
        self.file = file
        self.message = message
        self.underlying = underlying
    }

    public var description: String {
        var parts = ["InterventionError(\(code.rawValue)"]
        if let file { parts.append("file: \(file)") }
        if let message { parts.append("message: \(message)") }
        if let underlying { parts.append("underlying: \(underlying)") }
        return parts.joined(separator: ", ") + ")"
    }
}
