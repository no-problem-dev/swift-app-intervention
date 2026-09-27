# Design review — 2026-09-27

Two independent, fresh-context reviewers read `docs/DESIGN.md` (first draft).
This file records their findings so the revision can be checked against them.

## Reviewer A — API & protocol design

### Must
- **A-M1 Rules can't see host state.** `LockRule.isLocked` / `InterventionRule.evaluate` are synchronous, but "locked until today's habits are done" needs the host's async store; open-count rules read `OpenLogStore` themselves (repeated reads, poor composition).
  Proposal: keep rule evaluation pure/sync but feed it a `RuleInput { app, now, calendar, opens: OpenLogQuery (read once by the coordinator), host: HostSnapshot }`; add `protocol HostConditionProvider: Sendable { func snapshot(for:at:) async -> HostSnapshot }`; make `evaluateOpen` async.
- **A-M2 Resolution isn't recorded or idempotent.** `proceed(context, passDuration:)` / `abandon(context)` don't carry which option the user picked; the host writes its ledger separately → double charge on double tap / double inbox.
  Proposal: single `resolve(_ context:, _ r: InterventionResolution) throws(InterventionError) -> ResolutionReceipt` with `enum InterventionResolution { case proceed(optionID: String, passDuration: Duration); case abandon(optionID: String?) }`; second call → `.alreadyResolved`; `OpenEvent` gains `optionID`; document `context.id` as the host ledger idempotency key. Package stays ignorant of money.
- **A-M3 Phone-down session isn't persisted.** Background task ≈ 30 s; a 60-min session outlives the process. Make `PhoneDownSession` `Codable` with `id`, add `PhoneDownSessionStore` (file), `resume(at:lastKnownLocked:)`, and publish `AsyncStream<PhoneDownOutcome>` with `sessionID` so the host grants rewards idempotently.
- **A-M4 Closed typed-throws enum can't wrap host store errors and breaks exhaustive switches when cases are added.**
  Proposal: `struct InterventionError: Error, Sendable { enum Code { appGroupUnavailable, read, write, corrupt, unsupportedVersion, alreadyResolved, custom }; code; file; underlying: (any Error & Sendable)? }`; `PassThroughReason.failOpen` carries only `Code`.

### Should
- A-S1 Shrink protocol requirements: `PassStore` needs only `update(appID:_:)` + `allPasses()` (rest in extensions); `InterventionHandoff` only `post`/`take`; drop `OpenLogStore.removeAll` (retention internal); drop `AnyInterventionRule`.
- A-S2 Pass must not always beat locks. Order: return window → `RuleVerdict.lock(..., overridesPass: true)` → valid pass → other rules → fallback.
- A-S3 Replace `Notification.Name` with `InterventionHandoff.changes() -> AsyncStream<Void>`.
- A-S4 Replace the static `InterventionActions` enum (4–5 args) with `@MainActor final class InterventionPresenter(coordinator:inbox:reopener:)`.
- A-S5 Storage location: `FileStoreLocation { case appGroup(String), directory(URL) }`; App Group only needed when widgets/extensions read; `NSFileCoordinator` only for cross-process, `Mutex` in-process.
- A-S6 Unify `handleAutomationRun` error policy: if `continueInForeground` throws, remove the context from handoff and return `.passThrough(.foregroundUnavailable)`; never throw.
- A-S7 `OpenLogQuery.dayStartOffset: Duration` (day boundary must match the host's "today"); weekdays as `Set<Locale.Weekday>`.
- A-S8 Forward compatibility on disk: JSONL readers skip unknown `kind` lines instead of marking the file corrupt; the "don't rewrite newer format" rule applies to JSON envelopes only.

### Could
- A-C1 `InterventionClock` → `@Sendable () -> Date`.
- A-C2 `ScheduleRule.Effect { case intervene(tier), allow }` instead of accepting `.lock`.
- A-C3 `LockReason.message` → `LocalizedStringResource` or an ID resolved in UI.
- A-C4 Keep `PhoneDownSession` loosely coupled (may become its own package).

### Answers to §11
1. Keep macOS-compilable (DocC workflow); `#if os(iOS)` only for UIKit parts.
2. Locks may override passes, opt-in (A-S2); the return window always wins.
3. Expose capability: `PhoneDownSession.Capability { lockDetectable, lockUndetectable }` (via `LAContext` in Focus target) and `Configuration.unlockedAbsence: .fail | .tolerate`, default `.fail`.
4. `alwaysConfirm: false` is fine; list as a device gate.
5. Stores stay synchronous (small files, `Mutex` + atomic writes); entry points async; bridge to async host via A-M1/A-M2/A-M3.

## Reviewer B — iOS platform feasibility

### Must
- **B-M1 `supportedModes` via a package constant silently breaks.** Built a minimal app with Xcode 27 and inspected `Metadata.appintents/extract.actionsdata`: array literal `[.background, .foreground(.dynamic)]` → `supportedModes: 9`; `static let supportedModes = Modes.bgThenFg` → `supportedModes: 1`, no warning. Remove `InterventionIntentModes.backgroundThenForeground`; hosts must write the literal; ship a script that checks `extract.actionsdata` has 9.
- **B-M2 `OpenURLIntent` can't open other apps** — docs: "an app intent that opens one of your universal links". Remove `InterventionReturn.openIntent(for:)`; return to the original app only via `UIApplication.open` from the foreground UI.
- **B-M3 Phone-down detection can't see events after suspension** (~30 s background task, not guaranteed; lock → open another app from the lock screen goes undetected; devices with delayed passcode requirement never deliver the lock signal within 30 s). Replace with the algorithm below.

### Should
- B-S1 `continueInForeground` defaults to `alwaysConfirm: true`; pass `false` explicitly. It throws `notAllowed` when it can't foreground → fail open, keep the context; the inbox picks it up on next active. Confirmation-free foregrounding from an automation is reported by an OSS app but unverified here (device gate). iOS 18.2 had a regression where "Run Immediately" asked every time.
- B-S2 The intent runs in the main app process, launched in background; the whole app initializes. Keep `Intervention.coordinator` a lightweight static depending only on files; defer heavy init (Firebase/RevenueCat/DB) until a scene connects; log launch→decision ms as device-gate evidence.
- B-S3 Third-party URL schemes are undocumented and may change. `reopenURL` → `[URL]` fallback list (scheme first, then `https://…` with `.universalLinksOnly`); if all fail, tell the user to switch back manually. `LSApplicationQueriesSchemes` is only needed for `canOpenURL` (max 50).
- B-S4 Since iOS 17 "Run Immediately" automations have a "Notify When Run" toggle — add "turn off Notify When Run" to the setup guide; fix §8.
- B-S5 If `reopen` returns false, immediately consume `returnWindowEndsAt`.

### Could
- B-C1 iOS 27 `allowedExecutionTargets` (`.main`) compiles with an iOS 26 target under `@available(iOS 27, *)`.
- B-C2 `.completeUntilFirstUserAuthentication` is fine; warn in README about 0xdead10cc if a custom store holds SQLite locks in the App Group while suspended.
- B-C3 "App is closed" trigger can measure time-away (one sec uses it).
- B-C4 App Review risk low (one sec ships). Add setup steps + video to review notes; state that "payment" is in-app points, not real money; never use private Darwin notifications (`com.apple.springboard.lockcomplete`).

### Recommended phone-down algorithm
1. Only `didEnterBackground` counts; ignore `.inactive` (Notification Center, Control Center, Siri, call banner).
2. On background: `beginBackgroundTask`, poll `isProtectedDataAvailable` each second; `protectedDataWillBecomeUnavailable` or `false` → lock confirmed.
3. If the task expires without a lock signal, persist `undetermined(since:)` instead of failing.
4. On `becameActive`: lock confirmed → keep going; `undetermined` → host policy (fail / tolerate), considering delayed-passcode devices.
5. **Decisive failure signal:** if a guarded app's automation fires during the session, fail immediately (the intent runs in-process, so this is reliable).
6. Calls (`CXCallObserver`) don't count as leaving.
7. No passcode → `undetermined` by default.

### Device checklist (all unverified)
1. `continueInForeground(alwaysConfirm: false)` from an automation: no confirmation? latency? cold start?
2. With a valid pass, the second automation run shows nothing; timing (is 15 s enough?).
3. Does the automation fire from App Switcher / Safari URL opens?
4. Reopen via `instagram://`, `twitter://`, `youtube://`, TikTok, universal links.
5. Lock → `protectedDataWillBecomeUnavailable` latency (Face ID device, "require passcode after 1 minute"); actual `backgroundTimeRemaining`.
6. Order of `protectedDataDidBecomeAvailable` vs `didBecomeActive` on unlock.
7. scenePhase during incoming/ongoing calls.
8. With "Notify When Run" off, is the banner gone?
