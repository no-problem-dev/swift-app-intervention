import AppIntervention
import AppInterventionFocus
import AppInterventionUI
import SwiftUI

/// App-lifetime state. Lives at the root so device events keep flowing whichever tab is shown.
@MainActor @Observable
final class AppModel {
    enum TabID: Hashable { case setup, opens, phoneDown, state }

    let inbox = InterventionInbox(handoff: Intervention.coordinator.handoff, clock: Intervention.clock)
    let phoneDown = PhoneDownSessionController(
        store: FilePhoneDownSessionStore(location: .applicationSupport),
        guardedOpens: CoordinatorGuardedOpenSource(Intervention.coordinator),
        clock: Intervention.clock
    )
    let phoneDownEvents = UIKitPhoneDownEventSource(clock: Intervention.clock)
    var lastOutcome: PhoneDownOutcome?
    var selectedTab: TabID = .setup
    /// Bumped by QA actions so the State tab re-reads the stores.
    var revision = 0

    func makePresenter() -> InterventionPresenter {
        InterventionPresenter(coordinator: Intervention.coordinator, inbox: inbox, reopener: QA.reopener ?? SystemAppReopener())
    }
}

@main
struct SampleApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        QA.prepareBeforeLaunch()          // -qa-reset (DEBUG); must run before the stores are touched
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            @Bindable var model = model
            TabView(selection: $model.selectedTab) {
                Tab("Setup", systemImage: "gearshape", value: AppModel.TabID.setup) { SetupScreen() }
                Tab("Opens", systemImage: "chart.bar", value: AppModel.TabID.opens) { OpensScreen() }
                Tab("Phone down", systemImage: "iphone.slash", value: AppModel.TabID.phoneDown) { PhoneDownScreen() }
                if QA.isEnabled {
                    Tab("State", systemImage: "ladybug", value: AppModel.TabID.state) { StateScreen() }
                }
            }
            .environment(model)
            // The pause screen gets its own presenter node.
            .background(
                Color.clear.fullScreenCover(item: Binding(get: { model.inbox.pending }, set: { if $0 == nil { model.inbox.dismiss() } })) { context in
                    PauseScreen(context: context)
                        .environment(model)
                }
            )
            .task { await model.inbox.observe() }
            .task { await model.phoneDown.run(events: model.phoneDownEvents) }
            .task {
                for await outcome in model.phoneDown.outcomes() {
                    // Grant rewards idempotently by outcome.sessionID.
                    print("[SPIKE] phoneDown session=\(outcome.sessionID) result=\(outcome.result)")
                    model.lastOutcome = outcome
                }
            }
            .task { await QA.startIfRequested(model) }
            .onOpenURL { url in Task { await QA.handle(url, model: model) } }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active {
                    model.inbox.refresh()
                    model.phoneDown.resume(appIsActive: true)
                }
            }
        }
    }
}
