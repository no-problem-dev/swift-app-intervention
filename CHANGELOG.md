# Changelog

All notable changes to this project are recorded in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `AppIntervention`: the core of a "pause before you open it" intervention driven by a
  Shortcuts personal automation. `InterventionPolicy` decides purely, in the order return
  window → lock that overrides passes → valid pass → rules → fallback, with `ScheduleRule`,
  `LockRule` and `OpenCountRule` built in and `HostConditionProvider` feeding host state once
  per run. `InterventionCoordinator.handleAutomationRun(appID:continuation:)` never throws and
  fails open; `resolve(_:_:)` records each intervention exactly once. File stores keep
  versioned JSON envelopes (newer versions are never overwritten, corrupt files are moved aside)
  and an append-only JSONL open log that skips and preserves unknown event kinds.
  `OpenLogQuery` counts by host day (`dayStartOffset`), hour and app. `InterventionInbox` and
  `InterventionPresenter` carry the pending intervention to the UI and reopen the app.
- `AppInterventionIntents`: `AppIntent.runIntervention(appID:coordinator:)` and
  `AppIntentForegroundContinuation`, wrapping iOS 26's `continueInForeground(_:alwaysConfirm:)`
  with `alwaysConfirm: false`. No intents or `IntentModes` constants are shipped: hosts declare
  `supportedModes` as a literal in their app target.
- `AppInterventionUI`: `InterventionPauseView`, `InterventionActionButton`,
  `AutomationSetupGuideView` and `OpenCountSummaryView`, themed through `InterventionTheme`
  and localized in English, Japanese, Simplified and Traditional Chinese.
- `AppInterventionFocus`: `PhoneDownSession`, a persistable state machine that tells locking the
  phone from leaving the app, with `PhoneDownSessionController` and the UIKit event source.
- `Examples/InterventionSample` and `scripts/check-intent-metadata.sh`, which asserts that the
  sample's intent is extracted with `supportedModes == 9`.
