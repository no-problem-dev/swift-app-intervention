import Foundation
import Testing
@testable import AppIntervention

@Suite("OpenLogQuery")
struct OpenLogQueryTests {
    func opened(_ date: Date, _ app: String = "instagram", kind: OpenEvent.Kind = .opened) -> OpenEvent {
        OpenEvent(appID: app, kind: kind, date: date)
    }

    @Test("dayStartOffset moves the day boundary")
    func dayStartOffset() {
        let events = [
            opened(Fixture.date(2026, 9, 27, 23, 0)),
            opened(Fixture.date(2026, 9, 28, 1, 30)),   // before 04:00 → still the 27th's host day
            opened(Fixture.date(2026, 9, 28, 4, 0)),    // starts the 28th
        ]
        let midnight = OpenLogQuery(events, calendar: Fixture.calendar)
        let fourAM = OpenLogQuery(events, calendar: Fixture.calendar, dayStartOffset: .seconds(4 * 3_600))

        #expect(midnight.count(.opened, onDayContaining: Fixture.date(2026, 9, 27, 12)) == 1)
        #expect(fourAM.count(.opened, onDayContaining: Fixture.date(2026, 9, 27, 12)) == 2)
        #expect(fourAM.count(.opened, onDayContaining: Fixture.date(2026, 9, 28, 2)) == 2)
        #expect(fourAM.count(.opened, onDayContaining: Fixture.date(2026, 9, 28, 12)) == 1)
        #expect(fourAM.day(containing: Fixture.date(2026, 9, 28, 2)) ==
                DateInterval(start: Fixture.date(2026, 9, 27, 4), end: Fixture.date(2026, 9, 28, 4)))
    }

    @Test("countsByDay is zero-filled and honours the offset")
    func byDay() {
        let events = [opened(Fixture.date(2026, 9, 25, 10)), opened(Fixture.date(2026, 9, 27, 3)), opened(Fixture.date(2026, 9, 27, 10))]
        let query = OpenLogQuery(events, calendar: Fixture.calendar, dayStartOffset: .seconds(4 * 3_600))
        let days = query.countsByDay(.opened, from: Fixture.date(2026, 9, 25, 12), days: 3)
        #expect(days.map(\.count) == [1, 1, 1])   // 27th 03:00 belongs to the 26th's host day
        #expect(days.first?.day.start == Fixture.date(2026, 9, 25, 4))
        #expect(query.countsByDay(.opened, from: Fixture.date(2026, 9, 22, 12), days: 3).map(\.count) == [0, 0, 0])
        #expect(query.countsByDay(.opened, from: Fixture.date(), days: 0).isEmpty)
    }

    @Test("hour of day, per app, per kind, lastRun")
    func breakdowns() {
        let events = [
            opened(Fixture.date(2026, 9, 27, 7, 5)),
            opened(Fixture.date(2026, 9, 27, 7, 50), "youtube"),
            opened(Fixture.date(2026, 9, 27, 23, 10)),
            opened(Fixture.date(2026, 9, 27, 23, 11), kind: .abandoned),
            opened(Fixture.date(2026, 9, 27, 23, 12), "youtube", kind: .passedThrough),
        ]
        let query = OpenLogQuery(events.reversed(), calendar: Fixture.calendar)
        let hours = query.countsByHourOfDay(.opened)
        #expect(hours.count == 24)
        #expect(hours[7] == 2)
        #expect(hours[23] == 1)
        #expect(query.countsByHourOfDay(.opened, appID: "youtube")[7] == 1)
        #expect(query.countsByApp(.opened) == ["instagram": 2, "youtube": 1])
        #expect(query.count(.abandoned) == 1)
        #expect(query.count(.opened, appID: "youtube") == 1)
        #expect(query.lastRun() == Fixture.date(2026, 9, 27, 23, 12))
        #expect(query.lastRun(appID: "instagram") == Fixture.date(2026, 9, 27, 23, 10))
        #expect(OpenLogQuery([]).lastRun() == nil)
    }
}
