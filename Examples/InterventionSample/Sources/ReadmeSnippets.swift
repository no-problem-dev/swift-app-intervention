import AppIntervention
import AppInterventionFocus
import AppInterventionUI
import SwiftUI

// The README's code, compiled with the sample so it cannot drift from the API (review D-S11).
// Keep in sync with README.md / README.ja.md §2, §3 and §5. Not used at run time.
enum ReadmeSnippets {
    enum HabitStore { static func snapshot() async -> HostSnapshot { .empty } }
    enum ledger {
        static func charge(_ amount: Int, idempotencyKey: UUID) {}
        static func reward(_ amount: Int, idempotencyKey: UUID) {}
    }
    static func showSwitchBackHint() {}
    static func showError(_ error: Error) {}

    enum Intervention {
        static let apps = [
            GuardedApp(id: "instagram", displayName: "Instagram",
                       reopenURLs: [URL(string: "instagram://")!, URL(string: "https://www.instagram.com")!]),
        ]
        static let coordinator = InterventionCoordinator.files(
            at: .applicationSupport,
            catalog: StaticGuardedAppCatalog(apps),
            policy: {
                InterventionPolicy(
                    rules: [
                        LockRule(id: "habits") { $0.host.contains("habits-done") ? nil : LockReason(id: "habits") },
                        ScheduleRule(id: "night", window: DailyWindow(start: .init(hour: 22), end: .init(hour: 2)),
                                     effect: .intervene("strict")),
                    ],
                    dayStartOffset: .seconds(4 * 3_600)
                )
            },
            hostConditions: ClosureHostConditionProvider { _, _ in await HabitStore.snapshot() }
        )
    }

    struct PauseScreen: View {
        let context: InterventionContext
        let presenter: InterventionPresenter
        var body: some View {
            InterventionPauseView(context: context) {
                Text("Opening costs 50 points.")
            } actions: {
                InterventionActionButton(Text("Pay 50 and open for 15 min")) {
                    Task {
                        do {
                            let result = try await presenter.proceed(optionID: "pay-50", passDuration: .seconds(900)) { receipt in
                                ledger.charge(50, idempotencyKey: receipt.contextID)
                            }
                            if case .reopened = result.reopen {} else { showSwitchBackHint() }
                        } catch {
                            showError(error)
                        }
                    }
                }
                InterventionActionButton(Text("Skip and save 50"), prominence: .secondary) {
                    do {
                        let receipt = try presenter.abandon(optionID: "skip")
                        ledger.reward(50, idempotencyKey: receipt.contextID)
                    } catch {
                        showError(error)
                    }
                }
            }
        }
    }

    struct Root: View {
        @State private var inbox = InterventionInbox(handoff: Intervention.coordinator.handoff)
        @Environment(\.scenePhase) private var scenePhase
        var body: some View {
            Text("Root")
                .background(Color.clear.fullScreenCover(
                    item: Binding(get: { inbox.pending }, set: { if $0 == nil { inbox.dismiss() } })
                ) { context in
                    PauseScreen(context: context, presenter: InterventionPresenter(
                        coordinator: Intervention.coordinator, inbox: inbox, reopener: SystemAppReopener()))
                })
                .task { await inbox.observe() }
                .onChange(of: scenePhase, initial: true) { _, phase in if phase == .active { inbox.refresh() } }
        }
    }

    @MainActor
    static func phoneDown() throws {
        let controller = PhoneDownSessionController(
            store: FilePhoneDownSessionStore(location: .applicationSupport),
            guardedOpens: CoordinatorGuardedOpenSource(Intervention.coordinator)
        )
        try controller.start(duration: .seconds(3_600))
        _ = PhoneDownCapability.current == .lockUndetectable
    }
}
