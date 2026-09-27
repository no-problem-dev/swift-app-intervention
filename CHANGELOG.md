# Changelog

All notable changes to this project are recorded in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-09-27

### Added

- `AppInterventionUI`: `InterventionPauseView(readyIndicator:)` and `PauseReadyIndicator`
  (`.pause`, `.checkmark`, `.hidden`, `.symbol(_:)`) choose what the countdown ring shows once the
  breath is over. Existing call sites compile unchanged.

### Changed

- `InterventionPauseView` now shows a neutral raised hand (`hand.raised.fill`) when the pause is
  over instead of a checkmark, which read as "done" or "opened" even when the host offered no way
  to open. Pass `readyIndicator: .checkmark` for the 0.1.0 look.

## [0.1.0] - 2026-09-27

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
- Hardening from the first code review, before any release:
  - The host's own reopen passes through even when the pass lasts zero or a few seconds (the
    return window no longer depends on the pass being valid, and such passes are not pruned
    while it is open).
  - A pause the app could not bring forward is withdrawn (`InterventionHandoff.withdraw(contextID:)`,
    `HandoffChange`), and pauses older than the inbox's `maxAge` are neither shown nor resolved
    (`InterventionError.Code.expired`).
  - `InterventionPresenter.proceed(optionID:passDuration:onResolved:)` calls `onResolved` before
    the other app is opened, so a ledger write happens while the host is still in front.
  - A failed log write during `resolve` rolls the pass back; concurrent resolutions of one
    context record exactly one.
  - File stores on the same path share one lock and one change stream across instances; the log
    appends with `O_APPEND` and survives a torn last line. `InterventionCoordinator.files(at:…)`
    and the file stores' `init(location:)` no longer throw: the location is resolved on first
    use and failures pass through.
  - `InterventionPolicy.dayStartOffset` reaches the rules' open counts; day boundaries stay on
    the wall clock across daylight-saving changes.
  - Host conditions have a 2-second budget (`hostConditionsTimeout`), after which the run
    passes through (`InterventionError.Code.timeout`).
  - `PhoneDownSessionController.outcomes()` replays the unacknowledged outcome to new subscribers.
  - `DeviceSignal` / `PhoneDownEvent.init(signal:at:)`, `ForegroundModeState` and
    `InterventionIntentDefaults` expose the mappings the adapters use.
  - `Broadcaster` is public and `InterventionHandoff.changes()` has a default implementation.
  - `InterventionCoordinator.inMemory(catalog:policy:)`, public initializers for the result
    types, `AutomationRunOutcome.elapsedMilliseconds`, `InterventionPauseView(subtitle:readyAnnouncement:)`.
  - Renamed `HostConditions` to `ClosureHostConditionProvider`; `AppReopener` no longer
    requires a class.
- The sample declares its four languages, and the README and DocC explain that a host must
  declare them too (`CFBundleLocalizations`), or the package's localized UI stays English.
- Public enums (`PassThroughReason`, `InterventionReason`, `InterventionDecision`,
  `PhoneDownEvent`, …) may gain cases in 0.x minor versions; switch over them with a `default:`.
