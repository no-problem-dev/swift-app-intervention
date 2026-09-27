import Foundation
@testable import AppIntervention

enum Fixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    /// 2026-09-27 is a Sunday.
    static func date(_ year: Int = 2026, _ month: Int = 9, _ day: Int = 27, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    static let instagram = GuardedApp(
        id: "instagram", displayName: "Instagram",
        reopenURLs: [URL(string: "instagram://")!, URL(string: "https://instagram.com")!]
    )
    static let youtube = GuardedApp(id: "youtube", displayName: "YouTube")

    static func input(_ app: GuardedApp = instagram, at now: Date, events: [OpenEvent] = [], host: HostSnapshot = .empty) -> RuleInput {
        RuleInput(app: app, now: now, calendar: calendar, opens: OpenLogQuery(events, calendar: calendar), host: host)
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "AppInterventionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct FailingPassStore: PassStore {
    func allPasses() throws(InterventionError) -> [Pass] { throw InterventionError(.read, file: "passes.json") }
    func update(appID: GuardedApp.ID, _ transform: (Pass?) -> Pass?) throws(InterventionError) -> Pass? {
        throw InterventionError(.write, file: "passes.json")
    }
}

struct FailingHandoff: InterventionHandoff {
    func post(_ context: InterventionContext) throws(InterventionError) { throw InterventionError(.write, file: "pending") }
    func take(now: Date, maxAge: Duration) throws(InterventionError) -> InterventionContext? { nil }
    func withdraw(contextID: UUID) throws(InterventionError) {}
}

final class CountingHostConditions: HostConditionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    let snapshot: HostSnapshot
    init(_ snapshot: HostSnapshot) { self.snapshot = snapshot }
    var calls: Int { lock.withLock { _calls } }
    func snapshot(for app: GuardedApp, at date: Date) async -> HostSnapshot {
        lock.withLock { _calls += 1 }
        return snapshot
    }
}
