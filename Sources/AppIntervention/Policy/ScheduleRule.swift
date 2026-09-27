import Foundation

/// A local time of day.
public struct TimeOfDay: Sendable, Hashable, Codable, Comparable {
    public let hour: Int
    public let minute: Int

    /// `hour` is clamped to 0...23 and `minute` to 0...59.
    public init(hour: Int, minute: Int = 0) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    var minutesSinceMidnight: Int { hour * 60 + minute }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }
}

/// A daily window `[start, end)` in local time.
///
/// - `start == end` covers the whole day.
/// - `start > end` wraps past midnight; the weekday filter then applies to the day the window
///   *started* (a Sunday 23:00–01:00 window matches Monday 00:30).
public struct DailyWindow: Sendable, Hashable, Codable {
    /// Inclusive start.
    public var start: TimeOfDay
    /// Exclusive end.
    public var end: TimeOfDay

    /// Creates a window.
    public init(start: TimeOfDay, end: TimeOfDay) {
        self.start = start
        self.end = end
    }

    public static let allDay = DailyWindow(start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 0))

    /// Whether `date` falls in the window, on one of `weekdays` (of the day the window started).
    public func contains(_ date: Date, weekdays: Set<Locale.Weekday>? = nil, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let s = start.minutesSinceMidnight
        let e = end.minutesSinceMidnight

        let windowDay: Date
        if s == e {
            windowDay = date
        } else if s < e {
            guard s <= minute, minute < e else { return false }
            windowDay = date
        } else if minute >= s {
            windowDay = date
        } else if minute < e {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { return false }
            windowDay = previous
        } else {
            return false
        }

        guard let weekdays else { return true }
        return weekdays.contains(Locale.Weekday(calendarWeekday: calendar.component(.weekday, from: windowDay)))
    }
}

extension Locale.Weekday {
    /// Maps `Calendar`'s 1 (Sunday) ... 7 (Saturday).
    init(calendarWeekday: Int) {
        switch calendarWeekday {
        case 1: self = .sunday
        case 2: self = .monday
        case 3: self = .tuesday
        case 4: self = .wednesday
        case 5: self = .thursday
        case 6: self = .friday
        default: self = .saturday
        }
    }
}

/// Intervene (or explicitly allow) inside a daily window, optionally on some weekdays and for some apps.
public struct ScheduleRule: InterventionRule, Hashable, Codable {
    /// What the window does. A schedule never locks; use ``LockRule`` for that.
    public enum Effect: Sendable, Hashable, Codable {
        case intervene(InterventionTier)
        case allow
    }

    public let id: String
    /// When the rule applies.
    public var window: DailyWindow
    /// `nil` = every day.
    public var weekdays: Set<Locale.Weekday>?
    /// `nil` = every guarded app.
    public var appIDs: Set<GuardedApp.ID>?
    /// What the rule does inside the window.
    public var effect: Effect

    /// Creates a schedule rule.
    public init(id: String, window: DailyWindow, weekdays: Set<Locale.Weekday>? = nil, appIDs: Set<GuardedApp.ID>? = nil, effect: Effect) {
        self.id = id
        self.window = window
        self.weekdays = weekdays
        self.appIDs = appIDs
        self.effect = effect
    }

    /// Applies the effect inside the window.
    public func evaluate(_ input: RuleInput) -> RuleVerdict? {
        if let appIDs, !appIDs.contains(input.app.id) { return nil }
        guard window.contains(input.now, weekdays: weekdays, calendar: input.calendar) else { return nil }
        switch effect {
        case .intervene(let tier): return .intervene(tier)
        case .allow: return .allow
        }
    }
}
