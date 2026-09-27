import AppIntervention
import AppInterventionFocus
import AppInterventionUI
import SwiftUI

@main
struct SampleApp: App {
    @State private var inbox = InterventionInbox(handoff: Intervention.coordinator.handoff)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Setup", systemImage: "gearshape") { SetupScreen() }
                Tab("Opens", systemImage: "chart.bar") { OpensScreen() }
                Tab("Phone down", systemImage: "iphone.slash") { PhoneDownScreen() }
            }
            // The pause screen gets its own presenter node.
            .background(
                Color.clear.fullScreenCover(item: Binding(get: { inbox.pending }, set: { if $0 == nil { inbox.dismiss() } })) { context in
                    PauseScreen(context: context, inbox: inbox)
                }
            )
            .task { await inbox.observe() }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { inbox.refresh() }
            }
        }
    }
}
