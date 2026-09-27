# Code review — 2026-09-27

Independent fresh-context reviewers. Reviewer C (correctness/concurrency) reproduced every Must/Should with adversarial tests in a temp copy (all 8 failed as predicted). Reviewer D (API/docs) integrated the package into a throwaway host using only the README.

## Must

- **C-M1 Short passes loop.** Return-window check depends on `pass.isValid(at:)` (`Policy/InterventionPolicy.swift:30`) and `removeExpired` drops passes whose `expiresAt <= now` together with their return window (`Stores/Stores.swift:32-38`, `Coordinator/InterventionCoordinator.swift:96`). With `passDuration: .zero` (or 5 s reopened after 6 s) the reopen is intervened again → infinite loop. Fix: return window independent of validity (`grantedAt <= now < returnWindowEndsAt`), don't purge passes still inside their return window.
- **C-M2 Stale context stays in the inbox after a failed foreground.** `post` → in-process `changes()` → `observe()` takes the context → then `continueInForeground` throws → `handoff.clear()` finds nothing; `inbox.pending` is never cleared nor age-checked (`InterventionCoordinator.swift:132,152`, `Presentation/Presentation.swift:50-62`). Next time the host opens it shows an already-finished intervention and proceed charges. Fix: publish a cancellation for that context id; inbox drops matching `pending`; also enforce `maxAge` when reading `presenter.context`.
- **D-M1 Money is recorded only after reopening the other app.** `proceed` grants/logs → dismisses → opens the URL and awaits → only then returns `ProceedResult`, so the host's ledger write happens after the host is backgrounded; suspension/termination loses the charge while the pass exists (free access). Fix: `proceed(optionID:passDuration:onResolved:)` called synchronously right after the receipt and before opening the URL (or split `resolveProceed()` / `reopen(_:)`), and document reconciling the ledger from `proceeded` events by `contextID`.

## Should

- **C-S1 / file locking per instance only.** `resolved.file(name)` creates a new `NSLock` each call; no coordinator when `crossProcess == false`; append = seekToEnd+write (`Files/FileStoreLocation.swift:52-54`, `Files/CoordinatedFile.swift:8,22,75-78`). Two instances on one directory lost 9/1000 log lines and 99/200 passes; two handoffs don't share a broadcaster. Fix: per-URL shared lock (static registry keyed by standardized path), O_APPEND; document one instance per directory at minimum.
- **C-S2 / D-S7 Failed resolve leaves a free pass.** `passes.save` succeeds, `log.append` fails → throws but the pass stays (`InterventionCoordinator.swift:184-188`). Fix: append first or roll back the pass.
- **C-S3 / D-S3 Day boundary not applied to rules.** `OpenLogQuery(recent, calendar:)` built with `.zero` offset (`InterventionCoordinator.swift:109`); `OpenCountRule` disagrees with `OpenCountSummaryView(dayStartOffset:)`. Fix: `InterventionPolicy.dayStartOffset` passed into `RuleInput.opens`.
- **C-S4 Host snapshot can hang the automation.** No timeout on `hostConditions.snapshot` (`InterventionCoordinator.swift:106`). Fix: race with ~2 s timeout → `.empty` / fail open.
- **C-S5 / D-S5 Replayed outcome lost for late subscribers.** `resume()` broadcasts once; `outcomes()` subscribers that start later miss it (`PhoneDownSessionController.swift:61-74`; sample runs them in separate `.task`s). Fix: replay the unacknowledged `session?.outcome` on subscribe.
- **C-S6 Sample drops device events when another tab is shown.** `run(events:)` lives in a tab's `.task` (`Examples/.../PhoneDownScreen.swift:37`). Fix: run at app root; call `resume` on every `.active`.
- **D-S1 README swallows errors** (`Task { try await presenter.proceed(...) }`, README.md:139). Use do/catch like the Example.
- **D-S2 `try!` in README/DocC for `InterventionCoordinator.files(...)`** contradicts fail-open; a missing directory crashes the intent process. Fix: non-throwing `files(...)` resolving lazily (fail open at run time) or `filesOrInMemory(...)`.
- **D-S4 `files(...)` can't set `returnWindow` / `opensLookback`.** Add parameters with the same defaults.
- **D-S6 Custom `InterventionHandoff` must implement `changes()` but `Broadcaster` is `package`.** Give `changes()` a default (finished stream; host relies on `refresh()`) or make `Broadcaster` public.
- **D-S8 DocC built on macOS drops iOS-only types** (`SystemAppReopener`, `UIKitPhoneDownEventSource`, `PhoneDownCapability.current`). Build with `xcodebuild docbuild -destination generic/platform=iOS` or add unavailable stubs.
- **D-S9 DocC output `./docs` collides with `docs/DESIGN.md` and `docs/reviews/`** (could publish internal docs to Pages). Output to `./_site`.
- **D-S10 "every string can be replaced" is false** (`"Take a moment."`, `InterventionPauseView.swift:43`). Add `subtitle: Text?`.
- **D-S11 README.ja sample doesn't compile** (missing `GuardedAppOption`).
- **D-S12 Public enums (`PassThroughReason`, `InterventionReason`, `InterventionDecision`, `PhoneDownEvent`) break host switches when cases are added.** Document in CHANGELOG/README that 0.x minors may add cases, or use open struct codes.
- **D-S13 `scripts/check-intent-metadata.sh` location (`SourcePackages/checkouts/...`) and `jq` requirement undocumented; comments are Japanese only.**

## Could

- C-C1 A torn last line swallows the next append (`CoordinatedFile.swift:75-78`); ensure trailing `\n` before appending.
- C-C2 DST day boundary shifts by an hour (`Query/OpenLogQuery.swift:30-36`); compute boundaries with calendar arithmetic.
- C-C3 Non-atomic take-and-put-back in `resolve` (`InterventionCoordinator.swift:194-196`); add "remove if id matches".
- C-C4 Negative `opensLookback` crashes `DateInterval` (`InterventionCoordinator.swift:98`); clamp in init.
- D-C1 ~40 undocumented public members (functions/inits).
- D-C2 No public inits for `ResolutionReceipt`, `AutomationRunOutcome`, `PhoneDownOutcome`, `ProceedResult` (hosts can't build values in tests).
- D-C3 Naming: `HostConditions` → `ClosureHostConditionProvider`; drop `AppReopener: AnyObject`.
- D-C4 `InterventionCoordinator.inMemory(catalog:policy:)` convenience.
- D-C5 `Duration.milliseconds` is `package`; expose or add `elapsedMilliseconds`.
- D-C6 VoiceOver gets no announcement during the pause countdown.
- D-C7 Limitations: App Switcher returns re-fire the automation and count as opens.

Verified OK: policy order matches spec; PhoneDownSession transitions idempotent incl. persistence/resume; broadcasters clean up; UIKit event source only `assumeIsolated` on main; no force unwraps/fatalError in core; newer envelopes not rewritten, corrupt files quarantined; org conventions match swift-authentication.

## Reviewer E — test quality (mutation testing on HEAD 01efd1e)

- 27/35 mutants killed. Survivors: M04 grace `<=`→`<`; M09 lockSignalWindow `<=`→`<`; M11 return-window end inclusive; M13 handoff maxAge `<=`→`<`; M14 `runIntervention` `alwaysConfirm` default → true; M17 `guardedAppOpened` end inclusive; M24 `resolve` lock removed; M37 lookback end → `now`.
- E-M1 (= C-M2) stale pause after failed foreground; the existing `continuationThrows` test doesn't run the inbox. Add an inbox-inclusive test.
- E-M2 Intents defaults/paths untested (`alwaysConfirm` default, `isForeground`/`canContinueInForeground` mapping); extract the mode→action mapping into a testable function.
- E-M3 Hanging tests: `for await` without limits in `PhoneDownSessionControllerTests.swift:30,76` hung >240 s under a mutant. Add `.timeLimit` / timeout-bounded receive helpers everywhere.
- E-S4 Exact-boundary tests for each survivor above.
- E-S5 Concurrent `resolve`: 20 parallel resolves → 1 success, 19 `.alreadyResolved`.
- E-S6 `FailingOpenLogStore`; assert log contents on handoff failure.
- E-S7 File-backed coordinator E2E across instance re-creation (process restart); `FilePhoneDownSessionStore` quarantine / newer envelope.
- E-S8 Missing phone-down transitions (listed in the reviewer report: background after end, lockConfirmed when not away, tick past end while unconfirmed away, backgroundTimeExpired when not away, resume(appIsActive:false), start replacing a running session).
- E-S9 (= C-S5/C-S6) sample outcome replay.
- E-S10 `.inactive` handling untestable: extract notification → `PhoneDownEvent` mapping into a pure function tested on macOS.
- E-C11..13 dayStartOffset (= C-S3), inbox pending never expires, no UI/localization snapshot tests.
- Stability: 5/5 runs and 200 repetitions passed; ManualClock used; polling loops theoretically load-sensitive.

## QA harness and speed strategy (decided 2026-09-27)

Measured on a clean copy: cold `swift build --build-tests` 17 s, incremental 2 s, `swift test --skip-build` 3 s, filtered 1 s. Slowness in review came from a hanging test (E-M3), 35 mutants, and cold copies — not from the package size.
1. Every awaiting test is bounded (`.timeLimit(.minutes(1))` or a timeout helper); add a check script that fails if a test file awaits without a bound.
2. Makefile targets print elapsed time and a budget (like gamification_app's `timed`); exceeding the budget is a defect.
3. Reviewers never copy the package: use `git worktree` under the package and a fixed `--scratch-path`; `make mutants` runs a scripted mutant list with a 60 s per-mutant timeout.
4. iOS builds only in the QA stage; macOS `swift test` for everyday loops. `.mobilebuildmcp/config.yaml` + one DerivedData path for the sample (no `generic` destination flip-flop).
5. Sample QA entry points (DEBUG only): launch args `-qa-reset`, `-qa-now <ISO8601>`, `-qa-reopen accept|reject|none`, `-qa-pd-seconds N`; URL scheme `interventionsample://qa/run?app=…&fg=succeed|fail|unavailable|already`, `qa/pass?app=…&sec=…`, `qa/pd?event=bg|active|lock|unlock|expire|call1|call0|guarded&dt=+N`; after each action print one `[QA] decision=… passes=… pending=… logTail=… pd=… buildUUID=…` line; a State tab showing passes / pending / log tail / session JSON. `make qa` drives the simulator pass and saves screenshots.
