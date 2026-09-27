import Foundation

/// The number of events on one (host-defined) day.
public struct DayCount: Sendable, Hashable {
    public let day: DateInterval
    public let count: Int
    public init(day: DateInterval, count: Int) {
        self.day = day
        self.count = count
    }
}

/// Pure queries over open-log events.
///
/// Works on any `[OpenEvent]`, so a host can also run it over events it stored itself.
/// `dayStartOffset` moves the day boundary: with 4 hours, "today" runs from 04:00 to 04:00,
/// so a late-night open still counts toward the evening it belongs to.
public struct OpenLogQuery: Sendable {
    public let events: [OpenEvent]
    public let calendar: Calendar
    public let dayStartOffset: Duration

    public init(_ events: [OpenEvent], calendar: Calendar = .current, dayStartOffset: Duration = .zero) {
        self.events = events.sorted { $0.date < $1.date }
        self.calendar = calendar
        self.dayStartOffset = dayStartOffset
    }

    /// The host day that contains `date`.
    public func day(containing date: Date) -> DateInterval {
        let offset = dayStartOffset.timeInterval
        let shifted = date.addingTimeInterval(-offset)
        let start = calendar.startOfDay(for: shifted)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start.addingTimeInterval(offset), end: next.addingTimeInterval(offset))
    }

    /// Events of `kind`, optionally within `[interval.start, interval.end)` and for one app.
    public func count(_ kind: OpenEvent.Kind, in interval: DateInterval? = nil, appID: GuardedApp.ID? = nil) -> Int {
        events.lazy.filter { event in
            event.kind == kind
                && (appID == nil || event.appID == appID)
                && (interval.map { Self.contains($0, event.date) } ?? true)
        }.count
    }

    /// Events of `kind` on the host day containing `date`.
    public func count(_ kind: OpenEvent.Kind, onDayContaining date: Date, appID: GuardedApp.ID? = nil) -> Int {
        count(kind, in: day(containing: date), appID: appID)
    }

    /// `days` consecutive host days starting with the day containing `start`, zero-filled.
    public func countsByDay(_ kind: OpenEvent.Kind, from start: Date, days: Int, appID: GuardedApp.ID? = nil) -> [DayCount] {
        guard days > 0 else { return [] }
        var result: [DayCount] = []
        var current = day(containing: start)
        for _ in 0..<days {
            result.append(DayCount(day: current, count: count(kind, in: current, appID: appID)))
            current = day(containing: current.end)
        }
        return result
    }

    /// 24 slots by wall-clock hour (the day offset does not apply to hours).
    public func countsByHourOfDay(_ kind: OpenEvent.Kind, in interval: DateInterval? = nil, appID: GuardedApp.ID? = nil) -> [Int] {
        var slots = Array(repeating: 0, count: 24)
        for event in events where event.kind == kind
            && (appID == nil || event.appID == appID)
            && (interval.map { Self.contains($0, event.date) } ?? true) {
            let hour = calendar.component(.hour, from: event.date)
            if slots.indices.contains(hour) { slots[hour] += 1 }
        }
        return slots
    }

    /// Counts per app id.
    public func countsByApp(_ kind: OpenEvent.Kind, in interval: DateInterval? = nil) -> [GuardedApp.ID: Int] {
        var result: [GuardedApp.ID: Int] = [:]
        for event in events where event.kind == kind && (interval.map { Self.contains($0, event.date) } ?? true) {
            result[event.appID, default: 0] += 1
        }
        return result
    }

    /// The last automation run (`opened`, `passedThrough` or `intervened`).
    ///
    /// The host cannot see whether the user disabled the automation; days of silence here are the hint.
    public func lastRun(appID: GuardedApp.ID? = nil) -> Date? {
        let runKinds: Set<OpenEvent.Kind> = [.opened, .passedThrough, .intervened]
        return events.last { runKinds.contains($0.kind) && (appID == nil || $0.appID == appID) }?.date
    }

    private static func contains(_ interval: DateInterval, _ date: Date) -> Bool {
        interval.start <= date && date < interval.end
    }
}
