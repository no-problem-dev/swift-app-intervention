import AppIntervention
import AppInterventionFocus
import SwiftUI

struct PhoneDownScreen: View {
    @State private var controller = PhoneDownSessionController(
        store: (try? FilePhoneDownSessionStore(location: .applicationSupport)).map { $0 as any PhoneDownSessionStore } ?? InMemoryPhoneDownSessionStore(),
        guardedOpens: CoordinatorGuardedOpenSource(Intervention.coordinator)
    )
    @State private var source = UIKitPhoneDownEventSource()
    @State private var lastOutcome: PhoneDownOutcome?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if PhoneDownCapability.current == .lockUndetectable {
                    Text("Without a passcode, locking and leaving look the same.").font(.footnote)
                }
                switch controller.session?.phase {
                case .running(let away)?:
                    Text(away == nil ? "Session running" : "Away since \(away!.since.formatted(date: .omitted, time: .standard))")
                    Button("Give up", role: .destructive) { controller.cancel() }
                default:
                    Button("Put the phone down for 1 minute") {
                        try? controller.start(duration: .seconds(60))
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let lastOutcome {
                    Text(lastOutcome.succeeded ? "Done: reward earned" : "Session failed")
                    Button("OK") { controller.acknowledgeOutcome(); self.lastOutcome = nil }
                }
            }
            .padding()
            .navigationTitle("Phone down")
            .task { controller.resume(appIsActive: true) }
            .task { await controller.run(events: source) }
            .task {
                for await outcome in controller.outcomes() {
                    print("[SPIKE] phoneDown session=\(outcome.sessionID) result=\(outcome.result)")
                    lastOutcome = outcome
                }
            }
        }
    }
}
