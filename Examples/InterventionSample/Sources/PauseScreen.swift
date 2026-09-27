import AppIntervention
import AppInterventionUI
import SwiftUI

struct PauseScreen: View {
    let context: InterventionContext
    @Environment(AppModel.self) private var model
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
                do {
                    let receipt = try makePresenter().abandon(optionID: "skip")
                    // Book the saving in your ledger keyed by receipt.contextID (idempotent).
                    print("[SPIKE] saved contextID=\(receipt.contextID)")
                } catch {
                    message = "\(error)"
                }
            }
        }
    }

    private func makePresenter() -> InterventionPresenter {
        if let presenter { return presenter }
        let made = model.makePresenter()
        presenter = made
        return made
    }

    private func proceed() async {
        do {
            let result = try await makePresenter().proceed(optionID: "pay", passDuration: .seconds(15 * 60)) { receipt in
                // Charge here, before the other app comes forward and this process may be suspended.
                // Key the ledger entry by receipt.contextID so a retry cannot charge twice.
                print("[SPIKE] charged contextID=\(receipt.contextID)")
            }
            if result.reopen == .failed || result.reopen == .noURL {
                message = "Switch back to \(context.app.displayName) yourself."
            }
        } catch {
            message = "\(error)"
        }
    }
}
