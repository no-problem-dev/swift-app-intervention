import Foundation

/// One entry of the append-only open log.
///
/// | Situation | Events |
/// |---|---|
/// | Fresh open, passes through | `opened`, `passedThrough` |
/// | Fresh open, pause shown | `opened`, `intervened`, later `proceeded` or `abandoned` |
/// | Pause decided but foreground impossible | `opened`, `passedThrough` (`note: "foregroundUnavailable"`) |
/// | The host's own reopen inside the return window | `passedThrough` (`note: "return"`) only |
public struct OpenEvent: Identifiable, Sendable, Hashable, Codable {
    /// An open set: readers skip kinds they do not know, so later versions can add kinds
    /// without breaking older readers of the same file.
    public struct Kind: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// The user opened a guarded app (not the host's own reopen).
        public static let opened = Kind(rawValue: "opened")
        /// The automation ran and no pause was shown.
        public static let passedThrough = Kind(rawValue: "passedThrough")
        /// The pause screen was shown.
        public static let intervened = Kind(rawValue: "intervened")
        /// The user chose to open anyway; a pass was granted.
        public static let proceeded = Kind(rawValue: "proceeded")
        /// The user chose not to open.
        public static let abandoned = Kind(rawValue: "abandoned")

        /// Kinds this version understands.
        public static let known: Set<Kind> = [.opened, .passedThrough, .intervened, .proceeded, .abandoned]

        public var description: String { rawValue }

        public init(from decoder: any Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public let id: UUID
    public let appID: GuardedApp.ID
    public let kind: Kind
    public let date: Date
    /// Set for `intervened`, `proceeded`, `abandoned`.
    public let tier: InterventionTier?
    /// Links `intervened` to its `proceeded` / `abandoned`.
    public let contextID: UUID?
    /// The host option that resolved the intervention.
    public let optionID: String?
    /// A short machine-readable note, e.g. the pass-through reason.
    public let note: String?

    public init(
        id: UUID = UUID(), appID: GuardedApp.ID, kind: Kind, date: Date,
        tier: InterventionTier? = nil, contextID: UUID? = nil, optionID: String? = nil, note: String? = nil
    ) {
        self.id = id
        self.appID = appID
        self.kind = kind
        self.date = date
        self.tier = tier
        self.contextID = contextID
        self.optionID = optionID
        self.note = note
    }
}
