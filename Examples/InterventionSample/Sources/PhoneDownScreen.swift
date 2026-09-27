import AppIntervention
import AppInterventionFocus
import SwiftUI

struct PhoneDownScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let controller = model.phoneDown
        NavigationStack {
            VStack(spacing: 24) {
                if PhoneDownCapability.current == .lockUndetectable {
                    Text("Without a passcode, locking and leaving look the same.").font(.footnote)
                }
                switch controller.session?.phase {
                case .running(let away)?:
                    if let away {
                        Text("Away since \(away.since.formatted(date: .omitted, time: .standard))")
                    } else {
                        Text("Session running")
                    }
                    Button("Give up", role: .destructive) { controller.cancel() }
                default:
                    Button("Put the phone down for 1 minute") {
                        try? controller.start(duration: .seconds(60))
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let outcome = model.lastOutcome {
                    Label(outcome.succeeded ? "Done: reward earned" : "Session failed: \(failureText(outcome))",
                          systemImage: outcome.succeeded ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .font(.title3.bold())
                        .foregroundStyle(outcome.succeeded ? .green : .red)
                    Button("OK") {
                        controller.acknowledgeOutcome()
                        model.lastOutcome = nil
                    }
                }
            }
            .padding()
            .navigationTitle("Phone down")
        }
    }

    private func failureText(_ outcome: PhoneDownOutcome) -> String {
        guard case .failed(let reason) = outcome.result else { return "" }
        switch reason {
        case .leftApp: return "left the app"
        case .openedGuardedApp(let appID, _): return "opened \(appID)"
        case .cancelled: return "gave up"
        }
    }
}
