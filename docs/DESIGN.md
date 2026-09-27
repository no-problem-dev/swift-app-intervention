# swift-app-intervention — Interface Design

Status: **revision 2** (after the 2026-09-27 design review, `docs/reviews/2026-09-27-design-review.md`).
Local only: no GitHub repository, no tag. The "Review resolution" table (§12) maps every finding
to a decision and a section.

## 0. What this package is

A reusable toolkit for "pause before you open it" interventions (one sec style) in any habit
app, **without Family Controls / Screen Time**, iOS 26+, Swift 6 strict concurrency.

The mechanism is the only one iOS offers without Screen Time entitlements:

1. The user creates a Shortcuts *personal automation*: "When **<App>** is opened → Run
   Immediately (Notify When Run off) → run **<HostApp>: Pause Before Opening**".
2. Every time the guarded app comes to the foreground, iOS runs the host's `AppIntent`
   **inside the host app's main process** (launched in the background if needed).
3. The intent asks the coordinator for a decision while still in the background. Only when the
   answer is "intervene" does it call `continueInForeground`, and the host shows a pause screen
   with host-defined options ("pay 50 points to open for 15 min", "skip and save").
4. If the user proceeds, the host grants a **pass** and reopens the original app. The
   automation fires again on that reopen; the pass (return window) makes it pass through.

The package provides everything except the concrete `AppIntent` types, which **must** live in
the host's app target (§5).

### Non-goals

- Blocking an app. The intervention is a speed bump.
- Measuring usage *duration*. Only open counts and pause outcomes are observable.
- Money, ledgers, prices. The package emits opaque **tiers** and **option ids** and a
  per-intervention idempotency key (`InterventionContext.id`); the host books its own ledger.
- Sync, analytics upload, server anything.
- Shipping `AppIntent`, `AppEntity`, `AppEnum`, `AppShortcutsProvider` types, or any
  `IntentModes` constant (§5.2, B-M1).
- Private API (e.g. the `com.apple.springboard.lockcomplete` Darwin notification).

## 1. Modules and dependency direction

```
               ┌───────────────────────────┐
               │ Host app target           │ AppIntent + AppEnum, composition root,
               │                           │ UI placement, ledger
               └──┬──────────┬──────────┬──┘
                  │          │          │
  ┌───────────────▼─┐ ┌──────▼────────┐ ┌▼──────────────────────┐
  │ AppIntervention │ │ AppIntervention│ │ AppInterventionFocus  │
  │ Intents         │ │ UI             │ │ phone-down session    │
  │ (AppIntents)    │ │ (SwiftUI)      │ │ (pure + UIKit source) │
  └───────────┬─────┘ └──────┬─────────┘ └┬──────────────────────┘
              └──────────────┼────────────┘
                      ┌──────▼──────────┐
                      │ AppIntervention │ Foundation, Observation, Synchronization
                      │ (core)          │
                      └─────────────────┘
```

| Target (= product) | Imports | Meaningful on | Tested where |
|---|---|---|---|
| `AppIntervention` | Foundation, Observation, Synchronization | iOS 26, macOS 26 | `swift test` (macOS host) |
| `AppInterventionIntents` | core, AppIntents | iOS 26 (compiles on macOS 26) | compile test on macOS; sample app on iOS |
| `AppInterventionUI` | core, SwiftUI, Charts; UIKit under `#if os(iOS)` | iOS 26 (compiles on macOS 26) | iOS Simulator build; sample app |
| `AppInterventionFocus` | core; UIKit/CallKit/LocalAuthentication under `#if os(iOS)` | iOS 26 | pure state machine + controller: `swift test` |

Rules:

- Siblings never depend on each other. Shared infrastructure (atomic/coordinated file, wire
  coding, broadcaster) lives in core with **`package`** access, so it is not public API.
- `platforms: [.iOS(.v26), .macOS(.v26)]`. macOS exists so `swift build` / `swift test` run
  on the host and DocC builds with the org's standard `swift package generate-documentation`
  workflow. Only UIKit-dependent code is `#if os(iOS)` (§11 Q1 decided).
- `AppInterventionFocus` depends on core only through `GuardedOpenSource`/`FileStoreLocation`
  and the `package` file helper, so it can be split into its own package later (A-C4).
- `swift-tools-version: 6.2`, Swift 6 language mode, `defaultLocalization: "en"`.
  Only package dependency: `swift-docc-plugin`.

## 2. Core model (`AppIntervention`)

Value types are `Sendable`, `Hashable`, `Codable`. On disk, dates are **epoch milliseconds**
(integers) and enums are strings.

```swift
public struct GuardedApp: Identifiable, Sendable, Hashable, Codable {
    public let id: String                 // stable, host-chosen ("instagram"); == AppEnum rawValue
    public var displayName: String
    public var bundleIdentifier: String?  // informational only
    /// Tried in order after "proceed". Custom schemes are opened plainly; http(s) URLs are
    /// opened with `universalLinksOnly`. Empty → the UI asks the user to switch back (B-S3).
    public var reopenURLs: [URL]
    public init(id: String, displayName: String, bundleIdentifier: String? = nil, reopenURLs: [URL] = [])
}

public struct Pass: Sendable, Hashable, Codable {
    public let appID: GuardedApp.ID
    public let grantedAt: Date
    public let expiresAt: Date
    /// While `now < returnWindowEndsAt`, the next automation run is our own reopen (§3.4).
    public var returnWindowEndsAt: Date?
    public func isValid(at date: Date) -> Bool              // grantedAt <= date < expiresAt
    public func isInReturnWindow(at date: Date) -> Bool
}

public struct InterventionTier: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String
    public static let standard: InterventionTier
}

public struct LockReason: Sendable, Hashable, Codable {
    public let id: String        // host-defined; the host UI resolves copy from it (A-C3)
    public let detail: String?   // optional host-provided extra (already localized)
}

public struct InterventionContext: Identifiable, Sendable, Hashable, Codable {
    /// Also the host ledger's idempotency key (A-M2).
    public let id: UUID
    public let app: GuardedApp
    public let requestedAt: Date
    public let tier: InterventionTier
    public let reason: InterventionReason
}

public enum InterventionReason: Sendable, Hashable, Codable {
    case rule(id: String)
    case locked(ruleID: String, LockReason)   // host should not offer "proceed" unless it wants to
    case fallback
}

public enum InterventionDecision: Sendable, Hashable {
    case passThrough(PassThroughReason)
    case intervene(InterventionContext)
}

public enum PassThroughReason: Sendable, Hashable {
    case returnFromIntervention            // our own reopen inside the return window
    case validPass(Pass)
    case rule(id: String)                  // a rule said .allow
    case fallback
    case notGuarded                        // catalog does not know the id
    case failOpen(InterventionError.Code)  // storage failed; never trap the user
    case foregroundUnavailable             // continueInForeground was impossible or threw
}
```

### 2.1 Open log

```swift
public struct OpenEvent: Identifiable, Sendable, Hashable, Codable {
    public struct Kind: RawRepresentable, Sendable, Hashable, Codable {  // open set: readers skip unknown kinds
        public static let opened, passedThrough, intervened, proceeded, abandoned: Kind
    }
    public let id: UUID
    public let appID: GuardedApp.ID
    public let kind: Kind
    public let date: Date
    public let tier: InterventionTier?
    public let contextID: UUID?     // intervened → proceeded/abandoned
    public let optionID: String?    // which host option resolved it (A-M2)
    public let note: String?        // pass-through reason code, e.g. "pass", "return", "failOpen"
}
```

| Situation | Events |
|---|---|
| Fresh open, passes through | `opened`, `passedThrough(note)` |
| Fresh open, intervention shown | `opened`, `intervened`, later `proceeded(optionID)` or `abandoned(optionID)` |
| Intervention decided but foreground impossible | `opened`, `passedThrough(note: "foregroundUnavailable")` |
| Our own reopen inside return window | `passedThrough(note: "return")` only — not an open |

```swift
public struct OpenLogQuery: Sendable {
    /// `dayStartOffset` shifts the day boundary (e.g. 4 h → "today" runs 04:00–04:00) so counts
    /// match the host's notion of a day (A-S7).
    public init(_ events: [OpenEvent], calendar: Calendar = .current, dayStartOffset: Duration = .zero)
    public func day(containing date: Date) -> DateInterval
    public func count(_ kind: OpenEvent.Kind, in interval: DateInterval? = nil, appID: GuardedApp.ID? = nil) -> Int
    public func count(_ kind: OpenEvent.Kind, onDayContaining date: Date, appID: GuardedApp.ID? = nil) -> Int
    public func countsByDay(_ kind: OpenEvent.Kind, from start: Date, days: Int) -> [DayCount]  // zero-filled
    public func countsByHourOfDay(_ kind: OpenEvent.Kind, in interval: DateInterval? = nil) -> [Int] // 24 slots, wall clock
    public func countsByApp(_ kind: OpenEvent.Kind, in interval: DateInterval? = nil) -> [GuardedApp.ID: Int]
    /// Last automation run (opened / passedThrough / intervened) — "automation probably disabled" hint.
    public func lastRun(appID: GuardedApp.ID? = nil) -> Date?
}
public struct DayCount: Sendable, Hashable { public let day: DateInterval; public let count: Int }
```

## 3. Protocols, defaults, decision engine

### 3.1 Protocols and defaults

| Protocol | Requirements | Production default | Fake (shipped) |
|---|---|---|---|
| `InterventionClock` | `now` | `SystemClock` | `ManualClock` |
| `GuardedAppCatalog` | `app(for:)` | `StaticGuardedAppCatalog` | same |
| `HostConditionProvider` | `snapshot(for:at:) async` | `NoHostConditions` | closure-based `HostConditions` |
| `PassStore` | `allPasses()`, `update(appID:_:)` | `FilePassStore` | `InMemoryPassStore` |
| `OpenLogStore` | `append(_:)`, `events(in:)` | `FileOpenLogStore` (JSONL) | `InMemoryOpenLogStore` |
| `InterventionHandoff` | `post(_:)`, `take(now:maxAge:)`, `changes()` | `FileInterventionHandoff` | `InMemoryInterventionHandoff` |
| `InterventionRule` | `id`, `evaluate(_:)` | `ScheduleRule`, `LockRule`, `OpenCountRule` | — |
| `ForegroundContinuation` | `isForeground`, `canContinueInForeground`, `continueInForeground()` | `AppIntentForegroundContinuation` (Intents) | `StubForegroundContinuation` |
| `AppReopener` (`@MainActor`) | `open(_:universalLinksOnly:) async -> Bool` | `SystemAppReopener` (UI, iOS) | `RecordingAppReopener` |
| `PhoneDownEventSource` (`@MainActor`) | `events()` | `UIKitPhoneDownEventSource` (Focus, iOS) | `ManualPhoneDownEventSource` |
| `PhoneDownSessionStore` | `load()`, `save(_:)`, `clear()` | `FilePhoneDownSessionStore` | `InMemoryPhoneDownSessionStore` |
| `GuardedOpenSource` | `opens(since:)`, `liveOpens()` | `CoordinatorGuardedOpenSource` | `ManualGuardedOpenSource` |

Requirements are minimal (A-S1); conveniences are protocol extensions:
`PassStore.pass(for:)`, `save(_:)`, `removePass(for:)`, `removeExpired(asOf:)`;
`InterventionHandoff.clear()` (= `take` with any age).

```swift
public protocol InterventionClock: Sendable { var now: Date { get } }

public protocol GuardedAppCatalog: Sendable { func app(for id: GuardedApp.ID) -> GuardedApp? }

/// Host state that rules need (A-M1), fetched once per automation run, asynchronously.
public protocol HostConditionProvider: Sendable {
    func snapshot(for app: GuardedApp, at date: Date) async -> HostSnapshot
}
/// A small keyed bag, so the package stays ignorant of host types.
public struct HostSnapshot: Sendable, Hashable {
    public var flags: Set<String>
    public var numbers: [String: Int]
    public static let empty: HostSnapshot
}

/// Synchronous: small files, `Mutex` + atomic writes (§11 Q5). Safe from any thread; file-backed
/// implementations are also safe across processes.
public protocol PassStore: Sendable {
    func allPasses() throws(InterventionError) -> [Pass]
    /// Atomic read-modify-write for one app; returning nil removes the pass.
    @discardableResult
    func update(appID: GuardedApp.ID, _ transform: (Pass?) -> Pass?) throws(InterventionError) -> Pass?
}

public protocol OpenLogStore: Sendable {
    func append(_ event: OpenEvent) throws(InterventionError)
    /// Ascending by date. Retention is the implementation's business (A-S1).
    func events(in interval: DateInterval?) throws(InterventionError) -> [OpenEvent]
}

public protocol InterventionHandoff: Sendable {
    func post(_ context: InterventionContext) throws(InterventionError)
    /// Removes and returns the pending context; returns nil when absent or older than `maxAge`.
    func take(now: Date, maxAge: Duration) throws(InterventionError) -> InterventionContext?
    /// In-process change signal (post/take) replacing NotificationCenter (A-S3).
    func changes() -> AsyncStream<Void>
}

public protocol ForegroundContinuation: Sendable {
    var isForeground: Bool { get }
    var canContinueInForeground: Bool { get }
    func continueInForeground() async throws
}

@MainActor public protocol AppReopener {
    func open(_ url: URL, universalLinksOnly: Bool) async -> Bool
}
```

### 3.2 Rules and policy (pure)

```swift
public struct RuleInput: Sendable {
    public let app: GuardedApp
    public let now: Date
    public let calendar: Calendar
    public let opens: OpenLogQuery      // read once by the coordinator (A-M1)
    public let host: HostSnapshot       // fetched once, async (A-M1)
}

public enum RuleVerdict: Sendable, Hashable {
    case intervene(InterventionTier)
    case lock(LockReason, tier: InterventionTier, overridesPass: Bool)
    case allow
}

public protocol InterventionRule: Sendable {
    var id: String { get }
    func evaluate(_ input: RuleInput) -> RuleVerdict?     // nil = no opinion
}

public struct ScheduleRule: InterventionRule, Hashable, Codable {
    public enum Effect: Sendable, Hashable, Codable { case intervene(InterventionTier), allow }  // A-C2
    public let id: String
    public var window: DailyWindow
    public var weekdays: Set<Locale.Weekday>?     // A-S7; nil = every day
    public var appIDs: Set<GuardedApp.ID>?        // nil = all guarded apps
    public var effect: Effect
}
/// [start, end) local time. start == end → all day. start > end wraps midnight; the weekday
/// filter applies to the day the window started.
public struct DailyWindow: Sendable, Hashable, Codable { public var start: TimeOfDay; public var end: TimeOfDay }
public struct TimeOfDay: Sendable, Hashable, Codable, Comparable { public let hour: Int; public let minute: Int }

/// "Locked until a host condition holds", reading `input.host`.
public struct LockRule: InterventionRule {
    public init(id: String, tier: InterventionTier = .standard, overridesPass: Bool = false,
                isLocked: @escaping @Sendable (RuleInput) -> LockReason?)
}

/// "More than N opens today (host day) → intervene with tier".
public struct OpenCountRule: InterventionRule, Hashable {
    public init(id: String, threshold: Int, tier: InterventionTier, appIDs: Set<GuardedApp.ID>? = nil)
}

public struct InterventionPolicy: Sendable {
    public enum Fallback: Sendable, Hashable { case intervene(InterventionTier), passThrough }
    public var rules: [any InterventionRule]
    public var fallback: Fallback
    public var calendar: Calendar
    /// Pure. Order (A-S2):
    ///   1. pass in return window        → .passThrough(.returnFromIntervention)
    ///   2. first lock with overridesPass → .intervene(.locked)
    ///   3. valid pass                   → .passThrough(.validPass)
    ///   4. first rule with a verdict    → intervene / lock / allow
    ///   5. fallback
    public func decide(_ input: RuleInput, pass: Pass?, contextID: UUID = UUID()) -> InterventionDecision
}
```

The return window always wins: it is our own reopen immediately after a resolution the host
accepted, and intervening there would loop.

### 3.3 Coordinator

```swift
public final class InterventionCoordinator: Sendable {
    public init(catalog: any GuardedAppCatalog,
                policy: @escaping @Sendable () -> InterventionPolicy,   // re-read per run
                passes: any PassStore, log: any OpenLogStore, handoff: any InterventionHandoff,
                hostConditions: any HostConditionProvider = NoHostConditions(),
                clock: any InterventionClock = SystemClock(),
                returnWindow: Duration = .seconds(15),
                opensLookback: Duration = .seconds(2 * 86_400))
    /// Convenience: file stores at `location`.
    public static func files(at location: FileStoreLocation, catalog:, policy:, hostConditions:, retention:) throws(InterventionError) -> InterventionCoordinator

    /// Whole automation run. Never throws (A-S6).
    public func handleAutomationRun(appID: GuardedApp.ID,
                                    continuation: some ForegroundContinuation) async -> AutomationRunOutcome

    /// Idempotent resolution (A-M2). Second call for the same context → `.alreadyResolved`.
    @discardableResult
    public func resolve(_ context: InterventionContext, _ resolution: InterventionResolution) throws(InterventionError) -> ResolutionReceipt

    public func consumeReturnWindow(appID: GuardedApp.ID) throws(InterventionError)  // B-S5
    public func grantPass(appID: GuardedApp.ID, duration: Duration) throws(InterventionError) -> Pass
    public func revokePass(appID: GuardedApp.ID) throws(InterventionError)
    public func events(in interval: DateInterval?) throws(InterventionError) -> [OpenEvent]
    /// In-process stream of every event the coordinator appends (feeds the phone-down detector).
    public func eventStream() -> AsyncStream<OpenEvent>
}

public struct AutomationRunOutcome: Sendable, Hashable {
    public let decision: InterventionDecision
    public let elapsed: Duration        // run start → decision; device-gate evidence (B-S2)
}

public enum InterventionResolution: Sendable, Hashable {
    case proceed(optionID: String, passDuration: Duration)
    case abandon(optionID: String?)
}
public struct ResolutionReceipt: Sendable, Hashable {
    public let contextID: UUID
    public let resolution: InterventionResolution
    public let resolvedAt: Date
    public let pass: Pass?
}
```

`handleAutomationRun` steps:
1. Unknown app → `.passThrough(.notGuarded)` (not logged).
2. Read pass, open-log window (`opensLookback`), host snapshot. Read error → log best-effort,
   `.passThrough(.failOpen(code))`.
3. `policy.decide`. Return window → consume it (atomic `update`), log `passedThrough("return")`.
4. Otherwise log `opened`. Pass-through → log `passedThrough(note)`.
5. Intervene → `handoff.post`. If `continuation.isForeground` → log `intervened`. Else if
   `canContinueInForeground` → `try await continueInForeground()`; success → `intervened`;
   throws (e.g. `notAllowed`) → `take` the context back, log
   `passedThrough("foregroundUnavailable")`, return `.passThrough(.foregroundUnavailable)`.
   Not allowed to continue → same.

`resolve` runs under an in-process lock, scans the log for a `proceeded`/`abandoned` event with
this `contextID` (→ `.alreadyResolved`), then for `.proceed` saves a pass with
`returnWindowEndsAt = now + returnWindow` and logs `proceeded(optionID)`; for `.abandon` logs
`abandoned(optionID)`. It also clears a pending handoff for the same context.

### 3.4 The reopen loop

The "App is opened" automation cannot tell a home-screen launch from our own `UIApplication.open`.
Proceed = pass with return window **before** reopening. The run inside the window passes through
and is not counted; the window is consumed once. If reopening fails, the presenter consumes the
window immediately (B-S5) so a later manual open is counted. Pass expiry cannot eject the user.

### 3.5 Error model (A-M4)

```swift
public struct InterventionError: Error, Sendable, CustomStringConvertible {
    /// Open set (struct, not enum) so new codes do not break host switches.
    public struct Code: RawRepresentable, Sendable, Hashable, Codable {
        public static let appGroupUnavailable, read, write, corrupt, unsupportedVersion, alreadyResolved, custom: Code
    }
    public let code: Code
    public let file: String?
    public let message: String?
    public let underlying: (any Error & Sendable)?
    public init(_ code: Code, file: String? = nil, message: String? = nil, underlying: (any Error & Sendable)? = nil)
}
```

Custom stores wrap their own errors with `.custom` + `underlying`. Automation path fails open;
UI paths throw. Corrupt JSON envelope → renamed `<name>.corrupt-<epochms>`, treated as empty.
Envelope with a newer `formatVersion` → `.unsupportedVersion` and **never rewritten**.

### 3.6 Handoff and presentation

```swift
@MainActor @Observable
public final class InterventionInbox {
    public private(set) var pending: InterventionContext?
    public init(handoff: any InterventionHandoff, clock: any InterventionClock = SystemClock(), maxAge: Duration = .seconds(120))
    public func refresh()             // take from handoff; call on scenePhase .active
    public func observe() async       // loops over handoff.changes(); run in .task
    public func dismiss()
}

@MainActor @Observable
public final class InterventionPresenter {                 // A-S4
    public init(coordinator: InterventionCoordinator, inbox: InterventionInbox, reopener: any AppReopener)
    public var context: InterventionContext? { get }       // inbox.pending
    public func proceed(optionID: String, passDuration: Duration) async throws(InterventionError) -> ProceedResult
    public func abandon(optionID: String? = nil) throws(InterventionError) -> ResolutionReceipt
}
public struct ProceedResult: Sendable, Hashable {
    public enum Reopen: Sendable, Hashable { case reopened(URL), noURL, failed }
    public let receipt: ResolutionReceipt
    public let reopen: Reopen
}
```

The intent runs in the host's main process, so `changes()` delivers immediately when the UI is
alive. When the process was launched in the background just for the intent, the file keeps the
context until the scene becomes active and calls `refresh()`.

### 3.7 Storage location (A-S5)

```swift
public enum FileStoreLocation: Sendable, Hashable {
    case appGroup(String)                         // needed only if widgets/extensions read the data
    case directory(URL, crossProcess: Bool = false)
    public static var applicationSupport: FileStoreLocation   // <AppSupport>/AppIntervention
    public func resolve() throws(InterventionError) -> ResolvedLocation
}
```

`NSFileCoordinator` is used only when `crossProcess` (always for `.appGroup`); a `Mutex`
serializes in-process access in every case.

## 4. Persistence

- Directory `<location>/AppIntervention/`: `passes.json`, `open-log.jsonl`,
  `pending-intervention.json`, `phone-down-session.json`.
- Not `UserDefaults` (not shared / no atomic read-modify-write / cfprefsd caching).
- JSON files: `{"formatVersion": 1, "payload": …}`. Reader refuses newer versions and never
  rewrites them; corrupt files are quarantined.
- JSONL log: one event per line with `"v":1`. Lines with unknown `kind` or newer `v` are
  **skipped by readers and preserved by compaction** (A-S8). A malformed line is skipped.
- Atomic writes (`Data.write(options: .atomic)`), file protection
  `.completeUntilFirstUserAuthentication` on iOS (B-C2: a custom SQLite store in an App Group
  must not hold locks while suspended — 0xdead10cc).
- Log retention: `OpenLogRetention(maxAge: 90 days, maxCount: 5_000)`; compaction when the
  cached line count exceeds `maxCount × 1.25`, and on explicit `compact(now:)`.

## 5. What the host app implements, and why

### 5.1 App Intents live in the host's app target

The package ships **no** App Intents types. Reasons:

1. Metadata (`Metadata.appintents`) is extracted per target; from packages it merges
   unreliably (jibun-bgm: package intents appeared but `autoShortcuts` were silently empty).
2. **Constant evaluation (B-M1, measured):** the metadata extractor reads `supportedModes` from
   the literal in source. `[.background, .foreground(.dynamic)]` → `supportedModes: 9` in
   `extract.actionsdata`; a reference to a package constant → `1` (background only), with no
   warning. Hosts must write the literal; `scripts/check-intent-metadata.sh` asserts 9.
3. `.foreground(.dynamic)` needs the intent in the app process (not an App Intents extension).
4. Parameter types and titles are host vocabulary and localization.

### 5.2 Verified API (iOS 26 SDK surface, compiled with Xcode 27.0 / iPhoneSimulator27.0.sdk)

- `AppIntent.supportedModes: IntentModes` (`anyAppleOS 26.0`); `openAppWhenRun` deprecated.
- `IntentModes` option set: `.background`, `.foreground`, `.foreground(.immediate|.deferred|.dynamic)`.
- `AppIntent.continueInForeground(_ dialog: IntentDialog? = nil, alwaysConfirm: Bool = true) async throws`
  — default is `true`; we pass `false` explicitly (B-S1).
- `systemContext.currentMode: IntentModes.Current`, `.canContinueInForeground`, `== .foreground`.
- `UIApplication.protectedDataWillBecomeUnavailableNotification`, `…DidBecomeAvailableNotification`,
  `UIApplication.isProtectedDataAvailable`.
- `OpenURLIntent` is **not** used: it opens the app's own universal links only (B-M2).

```swift
struct PauseBeforeOpeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Before Opening"
    // Write the literal. A constant from a package compiles but is extracted as background-only.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "App") var app: GuardedAppOption      // host AppEnum, rawValue == GuardedApp.id

    func perform() async throws -> some IntentResult {
        let outcome = await runIntervention(appID: app.rawValue, coordinator: Intervention.coordinator)
        print("[SPIKE] decision=\(outcome.decision) elapsed=\(outcome.elapsed)")
        return .result()
    }
}
```

`AppInterventionIntents` API:

```swift
public struct AppIntentForegroundContinuation<Intent: AppIntent>: ForegroundContinuation {
    public init(_ intent: Intent, dialog: IntentDialog? = nil, alwaysConfirm: Bool = false)
}
extension AppIntent {
    public func runIntervention(appID: GuardedApp.ID, coordinator: InterventionCoordinator,
                                dialog: IntentDialog? = nil, alwaysConfirm: Bool = false) async -> AutomationRunOutcome
}
```

### 5.3 Host checklist

1. Build the coordinator as a **lightweight static** that depends only on files; defer heavy
   SDK initialization (Firebase, purchases, databases) until a scene connects (B-S2).
2. App Group entitlement only if widgets/extensions read the data; otherwise
   `.applicationSupport`.
3. AppIntent + AppEnum in the app target with the literal `supportedModes`; run
   `scripts/check-intent-metadata.sh`-style check in the host's CI/gate.
4. `InterventionInbox.refresh()` on `scenePhase == .active`, `.task { await inbox.observe() }`;
   present the pause screen on its own node.
5. Setup guide in onboarding (includes "turn off Notify When Run", B-S4).
6. Use `context.id` as the ledger idempotency key when booking costs/rewards; phone-down
   outcomes carry `sessionID` for the same purpose.

## 6. UI (`AppInterventionUI`)

```swift
public struct InterventionTheme: Sendable { accent, background: AnyShapeStyle, primaryText, secondaryText, cornerRadius }
extension View { public func interventionTheme(_ theme: InterventionTheme) -> some View }

public struct InterventionPauseView<Content: View, Actions: View>: View {
    public init(context: InterventionContext, pause: Duration = .seconds(3), title: Text? = nil,
                @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions)
}
public struct InterventionActionButton: View {
    public enum Prominence: Sendable { case primary, secondary }
    public init(_ title: Text, prominence: Prominence = .primary, action: @escaping () -> Void)
}
public struct AutomationSetupGuideView: View {
    public init(hostAppName: String, actionName: String, steps: [AutomationSetupStep]? = nil, footer: Text? = nil)
}
public struct AutomationSetupStep: Identifiable, Sendable { public let id: Int; public let text: Text }
public struct OpenCountSummaryView: View {
    public init(events: [OpenEvent], kind: OpenEvent.Kind = .opened, calendar: Calendar = .current,
                dayStartOffset: Duration = .zero, now: Date = .now)
}
#if os(iOS)
@MainActor public struct SystemAppReopener: AppReopener { public init() }
#endif
```

Strings: `Localizable.xcstrings`, en / ja / zh-Hans / zh-Hant, `bundle: .module`, every string
overridable by parameters. Default steps include "Run Immediately" and "turn off Notify When Run".

## 7. Phone-down session (`AppInterventionFocus`) — B-M3 algorithm + A-M3 persistence

```swift
public enum PhoneDownEvent: Sendable, Hashable {
    case enteredBackground(Date)             // only didEnterBackground; .inactive is ignored
    case becameActive(Date)
    case lockConfirmed(Date)                 // protectedDataWillBecomeUnavailable or isProtectedDataAvailable == false
    case unlocked(Date)                      // protectedDataDidBecomeAvailable
    case backgroundTimeExpired(Date)         // background task ended without a lock signal
    case callChanged(active: Bool, at: Date) // CXCallObserver
    case guardedAppOpened(appID: String, at: Date)  // decisive failure signal
    case tick(Date)
}

public struct PhoneDownSession: Identifiable, Sendable, Hashable, Codable {
    public struct Configuration: Sendable, Hashable, Codable {
        public var grace: Duration                  // default 15 s: unconfirmed absences this short are forgiven
        public var lockSignalWindow: Duration       // default 30 s: a lock signal later than this after leaving does not confirm
        public var unconfirmedAbsence: AbsencePolicy   // .fail (default) | .tolerate
    }
    public enum AbsencePolicy: String, Sendable, Hashable, Codable { case fail, tolerate }
    public struct Away: Sendable, Hashable, Codable {
        public var since: Date; public var lockConfirmed: Bool; public var undetermined: Bool; public var duringCall: Bool
    }
    public enum Phase: Sendable, Hashable, Codable {
        case running(away: Away?)
        case succeeded(at: Date)
        case failed(FailureReason)
    }
    public enum FailureReason: Sendable, Hashable, Codable {
        case leftApp(since: Date, undetermined: Bool)
        case openedGuardedApp(appID: String, at: Date)
        case cancelled(at: Date)
    }
    public let id: UUID
    public let startedAt: Date
    public let endsAt: Date
    public let configuration: Configuration
    public private(set) var phase: Phase
    public private(set) var inCall: Bool
    public static func start(id: UUID = UUID(), at: Date, duration: Duration, configuration: Configuration = .init()) -> PhoneDownSession
    @discardableResult public mutating func handle(_ event: PhoneDownEvent) -> Phase
    public var outcome: PhoneDownOutcome? { get }
}
public struct PhoneDownOutcome: Sendable, Hashable, Codable {
    public let sessionID: UUID
    public let startedAt: Date
    public let endsAt: Date
    public let result: Result
    public enum Result: Sendable, Hashable, Codable { case succeeded(at: Date), failed(PhoneDownSession.FailureReason) }
}
public enum PhoneDownCapability: Sendable, Hashable { case lockDetectable, lockUndetectable }  // LAContext on iOS
```

Transitions (terminal phases ignore everything; duplicates are no-ops):

| Event at `t` | Effect while running |
|---|---|
| `guardedAppOpened` with `startedAt ≤ t < endsAt` | **fail** `.openedGuardedApp` (reliable: the intent runs in-process and is logged) |
| `enteredBackground` | `t ≥ endsAt` → succeed; else if not away → `away(since: t, duringCall: inCall)` |
| `lockConfirmed` | not away → `away(since: t, lockConfirmed)`; away and `t − since ≤ lockSignalWindow` → confirm |
| `unlocked` | away & confirmed → `away(since: t)` (grace restarts: after unlock the user must come back) |
| `backgroundTimeExpired` | away → `undetermined = true` (persisted; no failure) |
| `callChanged(active)` | sets `inCall`; call start marks away `duringCall`; call end while away → `away(since: t)` |
| `becameActive` | if away: absence = `min(t, endsAt) − since`; ok if confirmed, during call, or `≤ grace`; else policy `.fail` → **fail** `.leftApp(since, undetermined)` / `.tolerate` → ok. Then `t ≥ endsAt` → succeed, else clear away |
| `tick` | not away (or away & confirmed) and `t ≥ endsAt` → succeed |

```swift
public protocol PhoneDownSessionStore: Sendable {
    func load() throws(InterventionError) -> PhoneDownSession?
    func save(_ session: PhoneDownSession) throws(InterventionError)
    func clear() throws(InterventionError)
}
public protocol GuardedOpenSource: Sendable {
    func opens(since: Date) throws(InterventionError) -> [OpenEvent]   // kind == .opened
    func liveOpens() -> AsyncStream<OpenEvent>
}
@MainActor public protocol PhoneDownEventSource: AnyObject {
    func events() -> AsyncStream<PhoneDownEvent>
}

@MainActor @Observable
public final class PhoneDownSessionController {
    public private(set) var session: PhoneDownSession?
    public init(store: any PhoneDownSessionStore, guardedOpens: any GuardedOpenSource,
                clock: any InterventionClock = SystemClock())
    public func outcomes() -> AsyncStream<PhoneDownOutcome>
    public func start(duration: Duration, configuration: PhoneDownSession.Configuration = .init()) throws(InterventionError)
    public func cancel()
    /// Load the persisted session, apply guarded opens since `startedAt`, and if the app is active
    /// feed `becameActive(now)`. Re-emits an unacknowledged terminal outcome.
    public func resume(appIsActive: Bool)
    public func handle(_ event: PhoneDownEvent)
    public func run(events source: some PhoneDownEventSource) async   // consumes source + live opens
    public func acknowledgeOutcome()                                   // clears the stored session
}
```

`UIKitPhoneDownEventSource` (iOS): observes `didEnterBackground`, `didBecomeActive`,
protected-data notifications; on background begins a background task and polls
`isProtectedDataAvailable` each second (false → `lockConfirmed`); the expiration handler emits
`backgroundTimeExpired`; `CXCallObserver` emits `callChanged`. `PhoneDownCapability.current`
uses `LAContext.canEvaluatePolicy(.deviceOwnerAuthentication)`; without a passcode the host
should use `.tolerate` or tell the user (§11 Q3).

## 8. Limitations (README)

- Cannot block; the user can dismiss, disable or delete the automation; the host cannot see a
  disabled automation (use `OpenLogQuery.lastRun`).
- A banner appears on each run unless the user turns off **Notify When Run** (iOS 17+).
- The guarded app may be visible briefly before the host comes forward; cold launches are slower.
- Pass expiry cannot eject the user.
- Reopening relies on undocumented third-party URL schemes; fallbacks, then manual switch.
- Phone-down: lock signals require a passcode and may be late ("require passcode after 1 min"),
  events after suspension are invisible; unconfirmed absences follow `unconfirmedAbsence`.

## 9. Test strategy

| Layer | What | Where |
|---|---|---|
| Policy | order return window > overriding lock > pass > rules > fallback; schedule windows (wrap, weekday of start day, all day); open-count rule; lock reads host snapshot | macOS `swift test` |
| Coordinator | event sequences; return window consumed once; fail-open with failing stores; foreground unavailable/throws → context removed; `resolve` idempotent (`.alreadyResolved`); host conditions fetched once | macOS, fakes + `ManualClock` |
| File stores | round trip; atomic write; corrupt quarantine; newer envelope not overwritten; JSONL unknown kind skipped and preserved; retention compaction | macOS, temp dirs |
| Queries | day boundaries with `dayStartOffset`; zero-filled days; hour-of-day; per app; lastRun | macOS |
| Handoff/Inbox/Presenter | stale dropped; `changes()` stream; proceed → pass + reopen, fallback URLs, reopen failure consumes window | macOS `@MainActor` |
| Phone-down | every transition in §7; persistence round trip and resume; undetermined; automation-fired failure (live and on resume) | macOS |
| Intents adaptor | compiles (macOS test target); sample app compiles on iOS; **metadata check `supportedModes == 9`** | `make check-metadata` |
| UI | iOS Simulator build of every target and of the sample | `make build-ios`, `make sample` |
| Real device only | §10 checklist | host device gate |

## 10. Device checklist (unverified; from review B)

1. `continueInForeground(alwaysConfirm: false)` from an automation: confirmation? latency? cold start?
2. With a valid pass the second run shows nothing; is 15 s return window enough?
3. Does the automation fire from the App Switcher / URL opens?
4. Reopen via `instagram://`, `twitter://`, `youtube://`, TikTok, universal links.
5. Lock → protected-data latency (Face ID, "require passcode after 1 minute"); `backgroundTimeRemaining`.
6. Order of `protectedDataDidBecomeAvailable` vs `didBecomeActive` on unlock.
7. scenePhase during calls. 8. With Notify When Run off, is the banner gone?

App Review notes (B-C4): include setup steps and a video; state that "pay" uses in-app points.

## 11. Decided questions

1. **macOS-compilable Intents/UI**, `#if os(iOS)` only for UIKit — keeps the org DocC workflow (both reviewers).
2. **Locks may override passes, opt-in** (`overridesPass`), return window always wins (A).
3. **Phone-down without passcode:** expose `PhoneDownCapability`; `unconfirmedAbsence` default
   `.fail` (A). Reason to keep `.fail` over B's "undetermined by default": the outcome still
   carries `undetermined: true`, so the host can choose to be lenient with full information,
   while the default never pays a reward for an unverified session.
4. **`alwaysConfirm: false`** passed explicitly; device gate item 1.
5. **Stores synchronous**, entry points async (`handleAutomationRun`, host snapshot).

## 12. Review resolution

| ID | Decision | Section |
|---|---|---|
| A-M1 | Adopted: `RuleInput.opens` + `.host`, `HostConditionProvider` async, run is async | 3.1, 3.2, 3.3 |
| A-M2 | Adopted: `resolve(_:_:)`, `InterventionResolution` with `optionID`, `ResolutionReceipt`, `.alreadyResolved`, `OpenEvent.optionID`, `context.id` = ledger key | 2, 3.3 |
| A-M3 | Adopted: `PhoneDownSession` Codable with `id`, `PhoneDownSessionStore`, `resume`, `outcomes()` with `sessionID` | 7 |
| A-M4 | Adopted: struct error with open `Code` struct, `underlying`, `failOpen(Code)` | 3.5 |
| A-S1 | Adopted: minimal requirements, conveniences in extensions; `removeAll` and `AnyInterventionRule` dropped | 3.1 |
| A-S2 | Adopted: order return window > overriding lock > pass > rules > fallback | 3.2 |
| A-S3 | Adopted: `InterventionHandoff.changes()`; no `Notification.Name` | 3.1, 3.6 |
| A-S4 | Adopted: `InterventionPresenter` class | 3.6 |
| A-S5 | Adopted: `FileStoreLocation`; coordination only cross-process | 3.7 |
| A-S6 | Adopted: `handleAutomationRun` never throws; context removed; `.foregroundUnavailable` | 3.3 |
| A-S7 | Adopted: `dayStartOffset`; `Set<Locale.Weekday>` | 2.1, 3.2 |
| A-S8 | Adopted: JSONL skips/preserves unknown kinds; newer-version rule for envelopes only | 4 |
| A-C1 | Rejected: a protocol lets `ManualClock` be a named, shareable test double; closures add nothing | 3.1 |
| A-C2 | Accepted: `ScheduleRule.Effect` | 3.2 |
| A-C3 | Accepted in spirit: `LockReason.id` is resolved to copy by the host UI; `detail` optional | 2 |
| A-C4 | Accepted: Focus depends on core only via small protocols + `package` helpers | 1, 7 |
| B-M1 | Adopted: no modes constant; literal in host; `scripts/check-intent-metadata.sh` asserts 9 | 5.1, 9 |
| B-M2 | Adopted: `OpenURLIntent` helper removed; reopen only via `UIApplication.open` | 5.2, 6 |
| B-M3 | Adopted: B's algorithm (+ persistence, decisive automation signal, calls, undetermined) | 7 |
| B-S1 | Adopted: `alwaysConfirm: false` explicit; throw → fail open. Deviation: context is **removed** (A-S6) rather than kept, because a pause screen for an open the user already completed in the guarded app is misleading | 3.3, 5.2 |
| B-S2 | Adopted: lightweight static coordinator guidance; `AutomationRunOutcome.elapsed` | 3.3, 5.3 |
| B-S3 | Adopted: `reopenURLs: [URL]`, universal links with `universalLinksOnly` | 2, 3.6 |
| B-S4 | Adopted: setup step "turn off Notify When Run"; §8 corrected | 6, 8 |
| B-S5 | Adopted: presenter consumes return window when reopen fails | 3.4, 3.6 |
| B-C1 | Rejected for 0.1: iOS 27 `allowedExecutionTargets` is unverified here and main-process execution is already the default for app-target intents | — |
| B-C2 | Accepted: file protection note + 0xdead10cc warning | 4 |
| B-C3 | Rejected for 0.1: "App is closed" timing is a separate feature; the open `Kind` set allows adding it later without a format break | 2.1 |
| B-C4 | Accepted: App Review notes; no private notifications | 0, 10 |

## 13. Implementation notes (revision 2 as built)

Differences between the signatures above and the code, all additive or naming-level:

- `ResolutionReceipt` also carries `appID` and `tier` (so a ledger entry needs nothing else).
- `ProceedResult` is nested: `InterventionPresenter.ProceedResult`.
- `FileOpenLogStore.compact()` takes no date; it uses the injected clock.
- `OpenLogQuery.countsByDay` / `countsByHourOfDay` take an optional `appID`.
- File stores also have `init(resolved: ResolvedFileStoreLocation)` so one resolved directory
  is shared; `InterventionCoordinator.files(at:…)` uses it.
- Extra conveniences: `ClosureGuardedAppCatalog`, `HostConditions` (closure provider),
  `InterventionContext.lock`, `InterventionDecision.isIntervention`,
  `PhoneDownSession.cancel(at:)`, `PhoneDownSessionController(tickInterval:)`.
- `InterventionTheme` and `AutomationSetupStep` are not `Sendable` (they hold SwiftUI values).
- `ForegroundContinuation` and `StubForegroundContinuation` live in core; `Duration` helpers
  are `package`, not public, to avoid clashing with hosts' own extensions.
- B-M1 was re-measured independently: the sample app's literal gives `supportedModes: 9`; the
  same value through a public constant in `AppInterventionIntents` gives `1`, and
  `scripts/check-intent-metadata.sh` fails on it (exit 1).
