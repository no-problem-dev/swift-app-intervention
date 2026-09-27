English | [日本語](./README.ja.md)

# swift-app-intervention

"Pause before you open it" interventions for any habit app — without Family Controls. A
Shortcuts automation runs your app's intent whenever a chosen app opens; this package decides,
in the background, whether to step in, and brings your pause screen forward only when it does.

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2026+-blue.svg)
![SPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

## How it works

1. The user creates a personal automation in Shortcuts: **When Instagram is opened → Run
   Immediately → Your App: Pause Before Opening** (with *Notify When Run* off).
2. On every open, iOS runs your app's intent in your app's process, in the background.
3. The coordinator reads the pass, recent opens and your app's conditions, and asks a pure
   policy. Most runs pass through silently.
4. When it intervenes, the intent calls `continueInForeground` and your pause screen appears.
5. If the user proceeds, the package grants a **pass** and reopens Instagram. The automation
   fires again on that reopen; the pass lets it through without counting it as a new open.

## Design

| Target | Role | Depends on |
|---|---|---|
| **`AppIntervention`** | Models, pure policy, file stores, coordinator, inbox/presenter | Foundation only |
| **`AppInterventionIntents`** | `runIntervention(appID:coordinator:)` for your own `AppIntent` | AppIntents |
| **`AppInterventionUI`** | Pause screen, automation setup guide, open-count summary | SwiftUI, Charts |
| **`AppInterventionFocus`** | "Put the phone down" sessions that tell locking from leaving | UIKit, CallKit (iOS) |

- **Decision order:** return window → lock that overrides passes → valid pass → your rules in
  order → fallback. Rules are pure; they read recent opens and a `HostSnapshot` your
  `HostConditionProvider` fetches once per run.
- **Fail open:** the automation path never throws. If storage fails, or the app cannot come
  forward, the open passes through — the user is never trapped.
- **Exactly once:** `resolve` records each intervention once (`alreadyResolved` on a second
  try, even from concurrent taps). Use `InterventionContext.id` as the idempotency key in your
  ledger; the package knows nothing about money.
- **Never stale:** a pause the app could not bring forward is withdrawn, and pauses older than
  two minutes are never shown or resolved.
- **Storage:** small JSON files with a format version (newer files are never overwritten,
  corrupt ones are moved aside) and an append-only JSONL open log that skips — and keeps —
  event kinds it does not know.

## Integration

### 1. Your intent lives in your app target

The package ships **no** `AppIntent`, `AppEnum`, `AppShortcutsProvider` or `IntentModes`
constant. Two measured reasons:

- App Intents metadata is extracted per target; from packages it merges unreliably (App
  Shortcut phrases have vanished silently while everything built and tested green).
- The extractor reads `supportedModes` from the **literal**. `[.background, .foreground(.dynamic)]`
  produces `supportedModes: 9` in `extract.actionsdata`; the same value through a constant
  from a package produces `1` (background only), with no warning, and the app never comes
  forward.

```swift
import AppIntents
import AppIntervention
import AppInterventionIntents

struct PauseBeforeOpeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Before Opening"
    // Keep this a literal in this file.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "App") var app: GuardedAppOption   // rawValue == GuardedApp.id

    func perform() async throws -> some IntentResult {
        await runIntervention(appID: app.rawValue, coordinator: Intervention.coordinator)
        return .result()
    }
}

enum GuardedAppOption: String, AppEnum {
    case instagram, youtube
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "App"
    static let caseDisplayRepresentations: [GuardedAppOption: DisplayRepresentation] = [
        .instagram: "Instagram", .youtube: "YouTube",
    ]
}
```

Add the metadata check to your build checks. It needs `jq`. With the package resolved by Xcode,
the script is at `<DerivedData>/<Project>/SourcePackages/checkouts/swift-app-intervention/scripts/check-intent-metadata.sh`
(or copy it into your repository):

```sh
check-intent-metadata.sh --app "$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME" --intent PauseBeforeOpeningIntent
```

### 2. A lightweight coordinator

The intent may run in a process iOS launched in the background just for it. Keep the
coordinator a static that depends only on files, and defer heavy SDKs until a scene connects.

```swift
enum Intervention {
    static let apps = [
        GuardedApp(id: "instagram", displayName: "Instagram",
                   reopenURLs: [URL(string: "instagram://")!, URL(string: "https://www.instagram.com")!]),
    ]
    // Never throws: an unusable location makes runs pass through instead of crashing the intent.
    static let coordinator = InterventionCoordinator.files(
        at: .applicationSupport,               // .appGroup("group.…") only if a widget reads the data
        catalog: StaticGuardedAppCatalog(apps),
        policy: {
            InterventionPolicy(
                rules: [
                    LockRule(id: "habits") { $0.host.contains("habits-done") ? nil : LockReason(id: "habits") },
                    ScheduleRule(id: "night", window: DailyWindow(start: .init(hour: 22), end: .init(hour: 2)),
                                 effect: .intervene("strict")),
                ],
                dayStartOffset: .seconds(4 * 3_600)   // "today" starts at 04:00, as in your app
            )
        },
        hostConditions: ClosureHostConditionProvider { _, _ in await HabitStore.snapshot() }
    )
}
```

### 3. Show the pause screen

```swift
@State private var inbox = InterventionInbox(handoff: Intervention.coordinator.handoff)

WindowGroup {
    RootView()
        // The pause screen gets its own presenter node.
        .background(Color.clear.fullScreenCover(
            item: Binding(get: { inbox.pending }, set: { if $0 == nil { inbox.dismiss() } })
        ) { context in
            PauseScreen(context: context, presenter: InterventionPresenter(
                coordinator: Intervention.coordinator, inbox: inbox, reopener: SystemAppReopener()))
        })
        .task { await inbox.observe() }
        .onChange(of: scenePhase, initial: true) { _, phase in if phase == .active { inbox.refresh() } }
}
```

```swift
InterventionPauseView(context: context) {
    Text("Opening costs 50 points.")
} actions: {
    InterventionActionButton(Text("Pay 50 and open for 15 min")) {
        Task {
            do {
                let result = try await presenter.proceed(optionID: "pay-50", passDuration: .seconds(900)) { receipt in
                    // Runs before the other app comes forward (this process may be suspended then).
                    ledger.charge(50, idempotencyKey: receipt.contextID)
                }
                if case .reopened = result.reopen {} else { showSwitchBackHint() }
            } catch {
                showError(error)   // .alreadyResolved, .expired, or a storage failure
            }
        }
    }
    InterventionActionButton(Text("Skip and save 50"), prominence: .secondary) {
        do {
            let receipt = try presenter.abandon(optionID: "skip")
            ledger.reward(50, idempotencyKey: receipt.contextID)
        } catch {
            showError(error)
        }
    }
}
```

If the process dies between recording and booking anyway, reconcile the ledger from
`proceeded` / `abandoned` events by `contextID`.

`Examples/InterventionSample` is a complete host app (XcodeGen, iOS 26).

### 4. Guide the automation setup

`AutomationSetupGuideView(hostAppName:actionName:)` lists the steps (App trigger, *Is Opened*,
*Run Immediately*, turn off *Notify When Run*, add your action) and opens `shortcuts://`.
This is where most users drop off; put your best illustration above it.

### 5. Phone-down sessions (optional)

```swift
let controller = PhoneDownSessionController(
    store: FilePhoneDownSessionStore(location: .applicationSupport),
    guardedOpens: CoordinatorGuardedOpenSource(Intervention.coordinator)
)
try controller.start(duration: .seconds(3_600))
// At the app root (not inside a tab), so events keep flowing whichever screen is shown:
// .task { await controller.run(events: UIKitPhoneDownEventSource()) }
// .onChange(of: scenePhase) { if $1 == .active { controller.resume(appIsActive: true) } }
// .task { for await outcome in controller.outcomes() { reward(idempotencyKey: outcome.sessionID) } }
```

A guarded app opening during the session fails it immediately (reliable: your intent runs in
your process). Locking is confirmed through protected-data signals; an absence nothing
confirmed is judged by `unconfirmedAbsence` (`.fail` by default; consider `.tolerate` when
`PhoneDownCapability.current == .lockUndetectable`).

## Localization: declare the languages in your app

The package's own UI text ships in English, Japanese, Simplified and Traditional Chinese, but
**iOS only uses a language that the host app declares.** An app that declares only English
shows the package's screens in English on a Japanese device. Declare all four in the app's
Info.plist (and let Xcode list them as known regions, e.g. by localizing one resource):

```yaml
# XcodeGen
info:
  properties:
    CFBundleLocalizations: [en, ja, zh-Hans, zh-Hant]
```

Every built-in string can also be replaced through the views' parameters.

## Limitations

- **It cannot block.** The user can dismiss the pause, or disable or delete the automation, and
  your app cannot see that. `OpenLogQuery.lastRun` lets you ask after days of silence.
- iOS shows a banner each time the automation runs unless the user turns off *Notify When Run*.
- The guarded app may be visible for a moment before yours comes forward.
- **Pass expiry cannot kick the user out**; only the next open is evaluated.
- Returning to a guarded app from the App Switcher fires the automation again, and that counts
  as an open (device-gate item to confirm).
- Reopening relies on third-party URL schemes, which are undocumented. List a universal link as
  a fallback; if nothing opens, ask the user to switch back.
- Phone-down: lock signals need a passcode and can be late; nothing is observable after the
  app is suspended.
- Things only a real device can verify: confirmation-free foregrounding from an automation,
  latency on cold launch, whether the reopen passes through within the 15 s return window,
  protected-data timing, and the banner with *Notify When Run* off.

For App Review, include the setup steps and a short video in the review notes, and make clear
that "paying" uses in-app points, not money. The package uses public API only.

## Versioning

0.x minors may add cases to public enums (`PassThroughReason`, `InterventionReason`,
`InterventionDecision`, `PhoneDownEvent`, …). Give your `switch`es a `default:` branch.
Error codes and event kinds are open structs and never break a `switch`.

## Documentation

API reference: [no-problem-dev.github.io/swift-app-intervention](https://no-problem-dev.github.io/swift-app-intervention/documentation/).
Design notes and the review they went through: [`docs/DESIGN.md`](docs/DESIGN.md).

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-app-intervention.git", .upToNextMinor(from: "0.1.0"))
]
```

- Composition root and intents → `AppIntervention` + `AppInterventionIntents`
- Screens → `AppInterventionUI` (+ `AppIntervention`)
- Phone-down sessions → `AppInterventionFocus`

## Requirements

| Swift | Platforms |
|---|---|
| 6.2 | iOS 26+ (macOS 26 for building and testing the core) |

## License

MIT License. See [LICENSE](LICENSE) for details.
