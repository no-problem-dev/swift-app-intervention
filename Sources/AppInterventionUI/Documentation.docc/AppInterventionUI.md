# ``AppInterventionUI``

Themeable SwiftUI for interventions: the pause screen, the automation setup guide, and a
small open-count summary.

## Overview

Nothing here carries a brand: colors come from ``InterventionTheme`` in the environment
(system semantic styles by default), and every string can be replaced. Built-in strings are
localized in English, Japanese, Simplified and Traditional Chinese.

```swift
InterventionPauseView(context: context) {
    Text("Opening costs 50 points.")
} actions: {
    InterventionActionButton(Text("Pay 50 and open for 15 min")) { proceed() }
    InterventionActionButton(Text("Skip and save 50"), prominence: .secondary) { skip() }
}
.interventionTheme(InterventionTheme(accent: .green))
```

Present it from its own node (for example `.background(Color.clear.fullScreenCover(...))`)
rather than chaining it with other presenters on one view.

## Topics

### Views

- ``InterventionPauseView``
- ``InterventionActionButton``
- ``AutomationSetupGuideView``
- ``AutomationSetupStep``
- ``OpenCountSummaryView``

### Styling

- ``InterventionTheme``

### Returning to the app

- ``SystemAppReopener``
