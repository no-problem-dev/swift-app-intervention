import AppIntervention
import Foundation

/// The composition root for interventions.
///
/// A lightweight static that depends only on files: the intent may run in a process that iOS
/// launched in the background just for it, before any scene exists. Heavy SDKs (analytics,
/// purchases, databases) belong in scene setup, not here.
enum Intervention {
    static let apps: [GuardedApp] = [
        GuardedApp(id: "instagram", displayName: "Instagram", reopenURLs: [URL(string: "instagram://")!, URL(string: "https://www.instagram.com")!]),
        GuardedApp(id: "youtube", displayName: "YouTube", reopenURLs: [URL(string: "youtube://")!, URL(string: "https://www.youtube.com")!]),
        GuardedApp(id: "x", displayName: "X", reopenURLs: [URL(string: "twitter://")!, URL(string: "https://x.com")!]),
    ]

    static let policy = InterventionPolicy(
        rules: [
            // Mornings and late nights are strict.
            ScheduleRule(id: "morning", window: DailyWindow(start: TimeOfDay(hour: 5), end: TimeOfDay(hour: 9)), effect: .intervene("strict")),
            ScheduleRule(id: "night", window: DailyWindow(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 2)), effect: .intervene("strict")),
        ],
        fallback: .intervene(.standard)
    )

    /// Never throws: an unusable location makes runs pass through instead of crashing the intent.
    /// The wall clock, or a manual one under `-qa-now` (DEBUG).
    static let clock: any InterventionClock = QA.clock

    static let coordinator = InterventionCoordinator.files(
        at: .applicationSupport,
        catalog: StaticGuardedAppCatalog(apps),
        policy: { policy },
        clock: clock
    )

    static func price(for tier: InterventionTier) -> Int {
        tier == "strict" ? 200 : 50
    }
}
