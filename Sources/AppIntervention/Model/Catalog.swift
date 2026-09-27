import Foundation

/// Resolves the app id an intent receives into a ``GuardedApp``.
public protocol GuardedAppCatalog: Sendable {
    /// `nil` for ids the host no longer guards; the run then passes through as ``PassThroughReason/notGuarded``.
    func app(for id: GuardedApp.ID) -> GuardedApp?
}

/// A fixed list of apps.
public struct StaticGuardedAppCatalog: GuardedAppCatalog {
    /// The guarded apps.
    public let apps: [GuardedApp]
    /// Creates a catalog of `apps`.
    public init(_ apps: [GuardedApp]) { self.apps = apps }
    /// The app with `id`, if listed.
    public func app(for id: GuardedApp.ID) -> GuardedApp? { apps.first { $0.id == id } }
}

/// A catalog backed by a closure, e.g. over the host's settings.
public struct ClosureGuardedAppCatalog: GuardedAppCatalog {
    private let lookup: @Sendable (GuardedApp.ID) -> GuardedApp?
    /// Creates a catalog that asks `lookup`.
    public init(_ lookup: @escaping @Sendable (GuardedApp.ID) -> GuardedApp?) { self.lookup = lookup }
    /// Calls the lookup closure.
    public func app(for id: GuardedApp.ID) -> GuardedApp? { lookup(id) }
}

/// Host state that rules need, captured once per automation run.
///
/// A small keyed bag keeps the package ignorant of host types: the host writes
/// `flags: ["habits-done"]` or `numbers: ["balance": 120]`, and its own rules read them.
public struct HostSnapshot: Sendable, Hashable {
    /// Boolean facts, e.g. `"habits-done"`.
    public var flags: Set<String>
    /// Numeric facts, e.g. `"balance": 120`.
    public var numbers: [String: Int]

    /// Creates a snapshot.
    public init(flags: Set<String> = [], numbers: [String: Int] = [:]) {
        self.flags = flags
        self.numbers = numbers
    }

    public static let empty = HostSnapshot()

    /// Whether `flag` is set.
    public func contains(_ flag: String) -> Bool { flags.contains(flag) }
    public subscript(number key: String) -> Int? { numbers[key] }
}

/// Supplies ``HostSnapshot``s. Asynchronous so the host can read its own stores.
///
/// Runs inside the automation, possibly in a process launched in the background just for the
/// intent: read shared persisted state, not in-memory state a scene would have built.
public protocol HostConditionProvider: Sendable {
    /// The host state that rules need for this run. Keep it fast: runs wait at most `hostConditionsTimeout`.
    func snapshot(for app: GuardedApp, at date: Date) async -> HostSnapshot
}

/// No host state.
public struct NoHostConditions: HostConditionProvider {
    public init() {}
    public func snapshot(for app: GuardedApp, at date: Date) async -> HostSnapshot { .empty }
}

/// Host state from a closure.
public struct ClosureHostConditionProvider: HostConditionProvider {
    private let body: @Sendable (GuardedApp, Date) async -> HostSnapshot
    /// Creates a provider that calls `body`.
    public init(_ body: @escaping @Sendable (GuardedApp, Date) async -> HostSnapshot) { self.body = body }
    public func snapshot(for app: GuardedApp, at date: Date) async -> HostSnapshot { await body(app, date) }
}
