import AppIntervention
import AppInterventionUI
import SwiftUI

struct PauseScreen: View {
    let context: InterventionContext
    let inbox: InterventionInbox
    @State private var presenter: InterventionPresenter?
    @State private var message: String?

    var body: some View {
        InterventionPauseView(context: context) {
            if let message {
                Text(message).font(.callout).multilineTextAlignment(.center)
            } else {
                Text("Opening costs \(Intervention.price(for: context.tier)) points.")
                    .font(.callout)
            }
        } actions: {
            InterventionActionButton(Text("Pay \(Intervention.price(for: context.tier)) and open for 15 min")) {
                Task { await proceed() }
            }
            InterventionActionButton(Text("Skip and save \(Intervention.price(for: context.tier))"), prominence: .secondary) {
                // Book the saving in your ledger keyed by receipt.contextID.
                _ = try? makePresenter().abandon(optionID: "skip")
            }
        }
    }

    private func makePresenter() -> InterventionPresenter {
        if let presenter { return presenter }
        let made = InterventionPresenter(coordinator: Intervention.coordinator, inbox: inbox, reopener: SystemAppReopener())
        presenter = made
        return made
    }

    private func proceed() async {
        do {
            let result = try await makePresenter().proceed(optionID: "pay", passDuration: .seconds(15 * 60))
            // Charge in your ledger keyed by result.receipt.contextID (idempotent).
            if result.reopen == .failed || result.reopen == .noURL {
                message = "Switch back to \(context.app.displayName) yourself."
            }
        } catch {
            message = "\(error)"
        }
    }
}
