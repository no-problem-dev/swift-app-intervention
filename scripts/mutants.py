#!/usr/bin/env python3
"""Mutation run: does the test suite notice small, plausible bugs?

    usage: scripts/mutants.py [M01 M02 ...]      (make mutants)

Each mutant replaces one exact snippet in a source file. The run happens in a git worktree of
HEAD under .build/mutants-worktree with a fixed --scratch-path, so the working copy is never
touched and builds stay incremental between mutants. Every mutant gets a 60 s budget; a hang
counts as killed (and is reported, because a hang means an unbounded test).

A mutant whose snippet no longer matches is reported STALE: update the list with the code.
Exit status is non-zero when any mutant survives or is stale.
Commit your changes first: the worktree is built from HEAD.
"""
import pathlib, re, subprocess, sys, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKTREE = ROOT / ".build" / "mutants-worktree"
SCRATCH = ROOT / ".build" / "mutants-scratch"
TIMEOUT = 60

C = "Sources/AppIntervention/Coordinator/InterventionCoordinator.swift"
P = "Sources/AppIntervention/Presentation/Presentation.swift"
S = "Sources/AppInterventionFocus/PhoneDownSession.swift"
PC = "Sources/AppInterventionFocus/PhoneDownSessionController.swift"

MUTANTS = [
    ("M01", "return window checked after locks", "Sources/AppIntervention/Policy/InterventionPolicy.swift",
     "if let pass, pass.appID == input.app.id, pass.isInReturnWindow(at: now) {", "if false, let pass, pass.isInReturnWindow(at: now) {"),
    ("M02", "pass expiry end inclusive", "Sources/AppIntervention/Model/Pass.swift",
     "grantedAt <= date && date < expiresAt", "grantedAt <= date && date <= expiresAt"),
    ("M03", "second resolve accepted", C,
     'throw InterventionError(.alreadyResolved, message: "Intervention \\(context.id) was already resolved")', "_ = 0"),
    ("M04", "grace exclusive", S, "absence <= configuration.grace.timeInterval", "absence < configuration.grace.timeInterval"),
    ("M05", "corrupt envelope not quarantined", "Sources/AppIntervention/Files/EnvelopeFile.swift",
     "guard let probe = try? decoder.decode(Probe.self, from: data) else {\n            file.quarantine(at: url)",
     "guard let probe = try? decoder.decode(Probe.self, from: data) else {\n            _ = url"),
    ("M06", "undecodable payload not quarantined", "Sources/AppIntervention/Files/EnvelopeFile.swift",
     "guard let envelope = try? decoder.decode(Envelope.self, from: data) else {\n            file.quarantine(at: url)",
     "guard let envelope = try? decoder.decode(Envelope.self, from: data) else {\n            _ = url"),
    ("M07", "return window not consumed on return", C,
     "                existing.returnWindowEndsAt = nil\n                return existing\n            }\n            record(",
     "                return existing\n            }\n            record("),
    ("M08", "failed foreground keeps the context", C,
     "            try? handoff.withdraw(contextID: context.id)\n            record(", "            record("),
    ("M09", "lock signal window exclusive", S,
     "<= configuration.lockSignalWindow.timeInterval", "< configuration.lockSignalWindow.timeInterval"),
    ("M10", "resolve does not withdraw the handoff", C,
     "        try? handoff.withdraw(contextID: context.id)\n\n        return ResolutionReceipt", "\n        return ResolutionReceipt"),
    ("M11", "return window end inclusive", "Sources/AppIntervention/Model/Pass.swift", "date < end", "date <= end"),
    ("M12", "compaction threshold >=", "Sources/AppIntervention/Files/FileStores.swift",
     "Double(count) > Double(retention.maxCount) * 1.25", "Double(count) >= Double(retention.maxCount) * 1.25"),
    ("M13", "handoff maxAge exclusive", "Sources/AppIntervention/Stores/Stores.swift",
     "age <= maxAge.timeInterval", "age < maxAge.timeInterval"),
    ("M14", "alwaysConfirm default true", "Sources/AppInterventionIntents/AppIntentForegroundContinuation.swift",
     "public static let alwaysConfirm = false", "public static let alwaysConfirm = true"),
    ("M15", "resume ignores guarded opens", PC,
     "handle(.guardedAppOpened(appID: first.appID, at: first.date))", "_ = first"),
    ("M17", "guarded open window end inclusive", S, "if startedAt <= t, t < endsAt {", "if startedAt <= t, t <= endsAt {"),
    ("M18", "newer envelope overwritten", "Sources/AppIntervention/Files/EnvelopeFile.swift",
     "guard probe.formatVersion <= formatVersion else {\n            throw",
     "guard probe.formatVersion <= formatVersion else {\n            file.quarantine(at: url); return nil\n            throw"),
    ("M20", "open count off by one", "Sources/AppIntervention/Policy/InterventionRule.swift",
     "earlier + 1 >= threshold", "earlier >= threshold"),
    ("M21", "call end keeps absence start", S, "current = Away(since: t)\n", "current.duringCall = false\n"),
    ("M22", "expiry not marked undetermined", S, "current.undetermined = true", "current.undetermined = false"),
    ("M23", "continued foreground not logged", C,
     "try await continuation.continueInForeground()\n                    record(intervened(context))",
     "try await continuation.continueInForeground()"),
    ("M24", "resolve not serialized", C, "        resolutionLock.lock()\n        defer { resolutionLock.unlock() }\n", "\n"),
    ("M25", "absence not clipped at end", S, "min(t, endsAt).timeIntervalSince", "t.timeIntervalSince"),
    ("M27", "log read failure ignored", C, "recent = try log.events(in:", "recent = (try? log.events(in:"),
    ("M29", "no-URL proceed keeps the window", P,
     "        guard !urls.isEmpty else {\n            try? coordinator.consumeReturnWindow(appID: context.app.id)",
     "        guard !urls.isEmpty else {\n            _ = 0"),
    ("M30", "tolerate ignored", S, "|| configuration.unconfirmedAbsence == .tolerate", "|| false"),
    ("M31", "already-foreground not logged", C,
     "            if continuation.isForeground {\n                record(intervened(context))",
     "            if continuation.isForeground {\n                _ = 0"),
    ("M32", "controller does not persist", PC, "        try? store.save(updated)\n", "\n"),
    ("M33", "resume skips becameActive", PC, "if appIsActive { handle(.becameActive(clock.now)) }", "_ = appIsActive"),
    ("M35", "lock while active ignored", S,
     "                phase = .running(away: Away(since: t, lockConfirmed: true, duringCall: inCall))", "                break"),
    ("M37", "lookback excludes now", C, "end: now.addingTimeInterval(1)))", "end: now))"),
    ("M38", "proceed pass without return window", C,
     "returnWindowEndsAt: now.adding(returnWindow))", "returnWindowEndsAt: nil)"),
    ("M39", "expired pass purged inside return window", "Sources/AppIntervention/Model/Pass.swift",
     "expiresAt <= date && !isInReturnWindow(at: date)", "expiresAt <= date"),
    ("M40", "failed resolve keeps the pass", C, "_ = try? passes.update(appID: context.app.id) { _ in previous }", "_ = previous"),
    ("M41", "day offset not passed to rules", C,
     "OpenLogQuery(recent, calendar: current.calendar, dayStartOffset: current.dayStartOffset)",
     "OpenLogQuery(recent, calendar: current.calendar)"),
    ("M42", "inbox ignores withdrawals", P, "if pending?.id == id { pending = nil }", "_ = id"),
    ("M43", "outcome not replayed on subscribe", PC,
     "broadcaster.stream(replaying: session?.outcome.map { [$0] } ?? [])", "broadcaster.stream()"),
    ("M44", "torn line not terminated", "Sources/AppIntervention/Files/CoordinatedFile.swift",
     "payload.insert(0x0A, at: 0)", "_ = 0"),
    ("M45", "ledger callback after reopen", P, "        onResolved(receipt)\n        inbox.dismiss()", "        inbox.dismiss()"),
]


def run(cmd, cwd, timeout=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def test(cwd):
    start = time.time()
    try:
        r = run(["swift", "test", "--scratch-path", str(SCRATCH)], cwd, TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HANG", time.time() - start, []
    out = r.stdout + r.stderr
    fails = sorted(set(re.findall(r'✘ Test "([^"]+)"', out)))
    if r.returncode != 0 and not fails and "error:" in out:
        return "COMPILE-ERROR", time.time() - start, [l for l in out.splitlines() if "error:" in l][:2]
    return ("KILLED" if r.returncode != 0 else "SURVIVED"), time.time() - start, fails


def main():
    only = set(sys.argv[1:])
    run(["git", "worktree", "remove", "--force", str(WORKTREE)], ROOT)
    r = run(["git", "worktree", "add", "--detach", str(WORKTREE), "HEAD"], ROOT)
    if r.returncode != 0:
        print(r.stderr); return 2
    try:
        status, took, _ = test(WORKTREE)
        print(f"baseline: {status} ({took:.0f}s)", flush=True)
        if status != "SURVIVED":
            print("baseline must pass"); return 2
        survived = stale = 0
        for key, name, rel, old, new in MUTANTS:
            if only and key not in only:
                continue
            path = WORKTREE / rel
            original = path.read_text()
            if original.count(old) != 1:
                print(f"{key} STALE        {name} (snippet found {original.count(old)}×)", flush=True)
                stale += 1
                continue
            path.write_text(original.replace(old, new, 1))
            try:
                status, took, detail = test(WORKTREE)
            finally:
                path.write_text(original)
            if status == "SURVIVED":
                survived += 1
            label = "KILLED" if status == "HANG" else status
            note = " (by hang: find the unbounded test)" if status == "HANG" else ""
            print(f"{key} {label:<13}{name} {took:.0f}s{note} {detail[:2] if detail else ''}", flush=True)
        total = len([m for m in MUTANTS if not only or m[0] in only])
        print(f"\n{total - survived - stale}/{total} killed, {survived} survived, {stale} stale")
        return 1 if survived or stale else 0
    finally:
        run(["git", "worktree", "remove", "--force", str(WORKTREE)], ROOT)


if __name__ == "__main__":
    sys.exit(main())
