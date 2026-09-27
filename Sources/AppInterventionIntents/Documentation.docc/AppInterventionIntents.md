# ``AppInterventionIntents``

Adapters that let the host's own `AppIntent` run an intervention in one line.

## Overview

This module ships **no** intents, entities, enums, App Shortcuts or `IntentModes` constants.
The host declares its intent in its **app target**:

```swift
struct PauseBeforeOpeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Before Opening"
    // Must be a literal in this file.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "App") var app: GuardedAppOption   // the host's AppEnum

    func perform() async throws -> some IntentResult {
        await runIntervention(appID: app.rawValue, coordinator: Intervention.coordinator)
        return .result()
    }
}
```

Why the host target:

- App Intents metadata is extracted per target at build time; from packages it merges
  unreliably (App Shortcut phrases have been observed to vanish silently).
- The extractor reads `supportedModes` from the literal. A constant imported from a package
  compiles but is extracted as background-only (`supportedModes: 1` instead of `9` in
  `extract.actionsdata`), with no warning. `scripts/check-intent-metadata.sh` checks it.
- `.foreground(.dynamic)` needs the intent to run in the app's process, not in an App Intents
  extension.

``AppIntentForegroundContinuation`` wraps `continueInForeground(_:alwaysConfirm:)` and passes
`alwaysConfirm: false` (the system default is `true`).

## Topics

### Running an intervention

- ``AppIntents/AppIntent/runIntervention(appID:coordinator:dialog:alwaysConfirm:)``
- ``AppIntentForegroundContinuation``
- ``ForegroundModeState``
- ``InterventionIntentDefaults``
