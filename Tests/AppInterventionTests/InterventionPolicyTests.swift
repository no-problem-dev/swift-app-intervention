import Foundation
import Testing
@testable import AppIntervention

@Suite("InterventionPolicy", .timeLimit(.minutes(1)))
struct InterventionPolicyTests {
    let now = Fixture.date(2026, 9, 27, 12)

    func pass(returnWindow: Bool = false) -> Pass {
        Pass(
            appID: "instagram", grantedAt: now.addingTimeInterval(-5), expiresAt: now.addingTimeInterval(600),
            returnWindowEndsAt: returnWindow ? now.addingTimeInterval(10) : nil
        )
    }

    let overridingLock = LockRule(id: "lock", tier: "strict", overridesPass: true) { _ in LockReason(id: "habits") }
    let plainLock = LockRule(id: "soft-lock", tier: "strict") { _ in LockReason(id: "habits") }

    // MARK: - Order

    @Test("the return window beats even an overriding lock")
    func returnWindowWins() {
        let policy = InterventionPolicy(rules: [overridingLock], calendar: Fixture.calendar)
        #expect(policy.decide(Fixture.input(at: now), pass: pass(returnWindow: true)) == .passThrough(.returnFromIntervention))
    }

    @Test("an overriding lock beats a valid pass")
    func overridingLockBeatsPass() throws {
        let policy = InterventionPolicy(rules: [ScheduleRule(id: "free", window: .allDay, effect: .allow), overridingLock], calendar: Fixture.calendar)
        let id = UUID()
        let decision = policy.decide(Fixture.input(at: now), pass: pass(), contextID: id)
        guard case .intervene(let context) = decision else { Issue.record("expected intervene, got \(decision)"); return }
        #expect(context.id == id)
        #expect(context.reason == .locked(ruleID: "lock", LockReason(id: "habits")))
        #expect(context.tier == "strict")
        #expect(context.lock == LockReason(id: "habits"))
    }

    @Test("a valid pass beats non-overriding rules")
    func passBeatsRules() {
        let policy = InterventionPolicy(rules: [plainLock], calendar: Fixture.calendar)
        #expect(policy.decide(Fixture.input(at: now), pass: pass()) == .passThrough(.validPass(pass())))
    }

    @Test("an expired pass or another app's pass is ignored")
    func invalidPassIgnored() {
        let policy = InterventionPolicy(rules: [], fallback: .passThrough, calendar: Fixture.calendar)
        let expired = Pass(appID: "instagram", grantedAt: now.addingTimeInterval(-600), expiresAt: now)
        let other = Pass(appID: "youtube", grantedAt: now, expiresAt: now.addingTimeInterval(60), returnWindowEndsAt: now.addingTimeInterval(10))
        #expect(policy.decide(Fixture.input(at: now), pass: expired) == .passThrough(.fallback))
        #expect(policy.decide(Fixture.input(at: now), pass: other) == .passThrough(.fallback))
    }

    @Test("the first rule with a verdict wins, in order")
    func firstRuleWins() {
        let allow = ScheduleRule(id: "free", window: .allDay, effect: .allow)
        let strict = ScheduleRule(id: "strict", window: .allDay, effect: .intervene("strict"))
        let a = InterventionPolicy(rules: [allow, strict], calendar: Fixture.calendar)
        let b = InterventionPolicy(rules: [strict, allow], calendar: Fixture.calendar)
        #expect(a.decide(Fixture.input(at: now), pass: nil) == .passThrough(.rule(id: "free")))
        guard case .intervene(let context) = b.decide(Fixture.input(at: now), pass: nil) else { Issue.record(); return }
        #expect(context.reason == .rule(id: "strict"))
    }

    @Test("a non-overriding lock intervenes as locked when no pass")
    func plainLockIntervenes() {
        let policy = InterventionPolicy(rules: [plainLock], calendar: Fixture.calendar)
        guard case .intervene(let context) = policy.decide(Fixture.input(at: now), pass: nil) else { Issue.record(); return }
        #expect(context.reason == .locked(ruleID: "soft-lock", LockReason(id: "habits")))
    }

    @Test("fallback applies when no rule has an opinion")
    func fallback() {
        let silent = ScheduleRule(id: "night", window: DailyWindow(start: .init(hour: 22), end: .init(hour: 23)), effect: .intervene("strict"))
        let intervene = InterventionPolicy(rules: [silent], fallback: .intervene(.standard), calendar: Fixture.calendar)
        let pass = InterventionPolicy(rules: [silent], fallback: .passThrough, calendar: Fixture.calendar)
        guard case .intervene(let context) = intervene.decide(Fixture.input(at: now), pass: nil) else { Issue.record(); return }
        #expect(context.reason == .fallback)
        #expect(context.tier == .standard)
        #expect(pass.decide(Fixture.input(at: now), pass: nil) == .passThrough(.fallback))
    }

    // MARK: - Rules

    @Test("a lock rule reads the host snapshot")
    func lockReadsHost() {
        let rule = LockRule(id: "habits") { input in input.host.contains("habits-done") ? nil : LockReason(id: "habits-unfinished") }
        #expect(rule.evaluate(Fixture.input(at: now, host: HostSnapshot(flags: ["habits-done"]))) == nil)
        #expect(rule.evaluate(Fixture.input(at: now)) == .lock(LockReason(id: "habits-unfinished"), tier: .standard, overridesPass: false))
    }

    @Test("open-count rule fires on the Nth open of the day, counting the current one")
    func openCountRule() {
        let rule = OpenCountRule(id: "cap", threshold: 3, tier: "over")
        let earlier = (0..<2).map { OpenEvent(appID: "instagram", kind: .opened, date: now.addingTimeInterval(Double(-60 * ($0 + 1)))) }
        let yesterday = OpenEvent(appID: "instagram", kind: .opened, date: Fixture.date(2026, 9, 26, 12))
        #expect(rule.evaluate(Fixture.input(at: now, events: [earlier[0], yesterday])) == nil)
        #expect(rule.evaluate(Fixture.input(at: now, events: earlier + [yesterday])) == .intervene("over"))
    }

    @Test("open-count rule scoped to apps ignores others")
    func openCountRuleScoped() {
        let rule = OpenCountRule(id: "cap", threshold: 1, tier: "over", appIDs: ["youtube"])
        #expect(rule.evaluate(Fixture.input(Fixture.instagram, at: now)) == nil)
        #expect(rule.evaluate(Fixture.input(Fixture.youtube, at: now)) == .intervene("over"))
    }

    @Test("schedule rule scoped to apps")
    func scheduleScoped() {
        let rule = ScheduleRule(id: "yt", window: .allDay, appIDs: ["youtube"], effect: .intervene("x"))
        #expect(rule.evaluate(Fixture.input(Fixture.instagram, at: now)) == nil)
        #expect(rule.evaluate(Fixture.input(Fixture.youtube, at: now)) == .intervene("x"))
    }
}

@Suite("DailyWindow", .timeLimit(.minutes(1)))
struct DailyWindowTests {
    let cal = Fixture.calendar

    @Test("[start, end) within a day")
    func simple() {
        let window = DailyWindow(start: .init(hour: 6), end: .init(hour: 9, minute: 30))
        #expect(window.contains(Fixture.date(2026, 9, 27, 6, 0), calendar: cal))
        #expect(window.contains(Fixture.date(2026, 9, 27, 9, 29), calendar: cal))
        #expect(!window.contains(Fixture.date(2026, 9, 27, 9, 30), calendar: cal))
        #expect(!window.contains(Fixture.date(2026, 9, 27, 5, 59), calendar: cal))
    }

    @Test("start == end is the whole day")
    func allDay() {
        #expect(DailyWindow.allDay.contains(Fixture.date(2026, 9, 27, 0, 0), calendar: cal))
        #expect(DailyWindow.allDay.contains(Fixture.date(2026, 9, 27, 23, 59), calendar: cal))
    }

    @Test("wraps midnight; weekday of the start day applies after midnight")
    func wrapsMidnight() {
        let window = DailyWindow(start: .init(hour: 23), end: .init(hour: 1))
        let sunday: Set<Locale.Weekday> = [.sunday]
        #expect(window.contains(Fixture.date(2026, 9, 27, 23, 30), weekdays: sunday, calendar: cal))   // Sun 23:30
        #expect(window.contains(Fixture.date(2026, 9, 28, 0, 30), weekdays: sunday, calendar: cal))    // Mon 00:30 → Sun window
        #expect(!window.contains(Fixture.date(2026, 9, 27, 0, 30), weekdays: sunday, calendar: cal))   // Sun 00:30 → Sat window
        #expect(!window.contains(Fixture.date(2026, 9, 27, 1, 0), calendar: cal))
        #expect(!window.contains(Fixture.date(2026, 9, 27, 12, 0), calendar: cal))
    }

    @Test("weekday filter")
    func weekdays() {
        let window = DailyWindow(start: .init(hour: 9), end: .init(hour: 17))
        #expect(window.contains(Fixture.date(2026, 9, 28, 10), weekdays: [.monday], calendar: cal))
        #expect(!window.contains(Fixture.date(2026, 9, 27, 10), weekdays: [.monday], calendar: cal))
    }

    @Test("TimeOfDay clamps")
    func clamps() {
        #expect(TimeOfDay(hour: 25, minute: -3) == TimeOfDay(hour: 23, minute: 0))
    }
}
