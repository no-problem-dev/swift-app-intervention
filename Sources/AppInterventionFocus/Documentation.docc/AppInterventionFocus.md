# ``AppInterventionFocus``

"Put the phone down" sessions that tell locking the phone from leaving the app, using public
API only.

## Overview

``PhoneDownSession`` is a pure, `Codable` state machine fed with ``PhoneDownEvent``s;
``PhoneDownSessionController`` persists every transition, feeds it device events and guarded
opens, and publishes ``PhoneDownOutcome``s keyed by session id.

What the session can see, and how it decides:

- Only `didEnterBackground` starts an absence; `.inactive` (Control Center, Notification
  Center, Siri, call banners) does not.
- A lock signal (`protectedDataWillBecomeUnavailable` or `isProtectedDataAvailable == false`
  while polling during a background task) confirms the absence. It needs a passcode and
  usually arrives about ten seconds after locking.
- **A guarded app's automation running during the session fails it immediately.** The host's
  intent runs in the host's process, so this signal is reliable, and it is replayed from the
  open log when a session resumes after the process died.
- An absence nothing confirmed is judged when the app becomes active, by
  ``PhoneDownSession/Configuration/unconfirmedAbsence`` (short absences within
  ``PhoneDownSession/Configuration/grace`` are forgiven). Calls do not count as leaving.

```swift
let controller = PhoneDownSessionController(
    store: try FilePhoneDownSessionStore(location: .applicationSupport),
    guardedOpens: CoordinatorGuardedOpenSource(Intervention.coordinator)
)
try controller.start(duration: .seconds(3_600))
// .task { controller.resume(appIsActive: true) }
// .task { await controller.run(events: UIKitPhoneDownEventSource()) }
```

## Topics

### Sessions

- ``PhoneDownSession``
- ``PhoneDownEvent``
- ``PhoneDownOutcome``
- ``PhoneDownCapability``
- ``PhoneDownSessionController``

### Sources and storage

- ``PhoneDownEventSource``
- ``ManualPhoneDownEventSource``
- ``GuardedOpenSource``
- ``CoordinatorGuardedOpenSource``
- ``ManualGuardedOpenSource``
- ``PhoneDownSessionStore``
- ``FilePhoneDownSessionStore``
- ``InMemoryPhoneDownSessionStore``
