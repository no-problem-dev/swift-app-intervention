# ``AppIntervention``

The core of a "pause before you open it" intervention: models, the pure policy, stores, the
coordinator, and the handoff to the host's UI. Foundation only.

## Overview

The host app asks the user to create a Shortcuts personal automation — *When <App> is opened →
Run Immediately → <Host>: Pause Before Opening*. Each run calls the host's own `AppIntent`,
which hands the work to ``InterventionCoordinator/handleAutomationRun(appID:continuation:)``:

1. Read the pass, recent opens and host conditions once.
2. Ask the pure ``InterventionPolicy`` — return window, overriding lock, pass, rules, fallback.
3. Pass through in the background, or post an ``InterventionContext`` to the
   ``InterventionHandoff`` and continue in the foreground.

The host shows the pause screen for ``InterventionInbox/pending`` and resolves it through
``InterventionPresenter``, which records the choice exactly once, grants a ``Pass`` and reopens
the app. The pass is what keeps the automation — which fires again on that reopen — from
looping.

```swift
enum Intervention {
    static let coordinator = try! InterventionCoordinator.files(
        at: .applicationSupport,
        catalog: StaticGuardedAppCatalog(apps),
        policy: { InterventionPolicy(rules: [nightRule], fallback: .intervene(.standard)) }
    )
}
```

The automation path never throws and never traps the user: storage failures pass through as
``PassThroughReason/failOpen(_:)``.

## Topics

### Coordinating

- ``InterventionCoordinator``
- ``AutomationRunOutcome``
- ``ForegroundContinuation``
- ``StubForegroundContinuation``

### Deciding

- ``InterventionPolicy``
- ``InterventionRule``
- ``RuleInput``
- ``RuleVerdict``
- ``ScheduleRule``
- ``DailyWindow``
- ``TimeOfDay``
- ``LockRule``
- ``OpenCountRule``
- ``InterventionDecision``
- ``PassThroughReason``

### Models

- ``GuardedApp``
- ``Pass``
- ``InterventionContext``
- ``InterventionReason``
- ``InterventionTier``
- ``LockReason``

### Resolving

- ``InterventionInbox``
- ``InterventionPresenter``
- ``InterventionResolution``
- ``ResolutionReceipt``
- ``AppReopener``
- ``RecordingAppReopener``

### Host state

- ``GuardedAppCatalog``
- ``StaticGuardedAppCatalog``
- ``ClosureGuardedAppCatalog``
- ``HostConditionProvider``
- ``HostConditions``
- ``NoHostConditions``
- ``HostSnapshot``

### The open log

- ``OpenEvent``
- ``OpenLogQuery``
- ``DayCount``

### Storage

- ``PassStore``
- ``OpenLogStore``
- ``InterventionHandoff``
- ``FileStoreLocation``
- ``ResolvedFileStoreLocation``
- ``FilePassStore``
- ``FileOpenLogStore``
- ``OpenLogRetention``
- ``FileInterventionHandoff``
- ``InMemoryPassStore``
- ``InMemoryOpenLogStore``
- ``InMemoryInterventionHandoff``

### Time and errors

- ``InterventionClock``
- ``SystemClock``
- ``ManualClock``
- ``InterventionError``
