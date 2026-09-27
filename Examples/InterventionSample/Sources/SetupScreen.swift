import AppInterventionUI
import SwiftUI

struct SetupScreen: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                AutomationSetupGuideView(hostAppName: "Intervention Sample", actionName: "Pause Before Opening")
                    .padding()
            }
            .navigationTitle("Set up")
        }
    }
}

struct OpensScreen: View {
    @State private var events: [OpenEvent] = []

    var body: some View {
        NavigationStack {
            List {
                OpenCountSummaryView(events: events)
                Section("Recent") {
                    ForEach(events.suffix(20).reversed()) { event in
                        LabeledContent(event.appID, value: "\(event.kind) \(event.date.formatted(date: .omitted, time: .shortened))")
                    }
                }
            }
            .navigationTitle("Opens")
            .task { events = (try? Intervention.coordinator.events(in: nil)) ?? [] }
            .refreshable { events = (try? Intervention.coordinator.events(in: nil)) ?? [] }
        }
    }
}

import AppIntervention
