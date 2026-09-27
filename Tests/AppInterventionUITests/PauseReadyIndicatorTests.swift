import AppIntervention
import AppInterventionUI
import SwiftUI
import Testing

@MainActor
struct PauseReadyIndicatorTests {
    @Test("The default is a neutral raised hand, not a checkmark")
    func defaultIsNeutral() {
        #expect(PauseReadyIndicator.pause.systemName == "hand.raised.fill")
        #expect(PauseReadyIndicator.checkmark.systemName == "checkmark")
        #expect(PauseReadyIndicator.hidden.systemName == nil)
        #expect(PauseReadyIndicator.symbol("pause.fill").systemName == "pause.fill")
    }

    @Test("The pause view accepts every indicator (source compatible with 0.1.0 call sites)")
    func viewAcceptsIndicators() {
        let context = InterventionContext(
            app: GuardedApp(id: "instagram", displayName: "Instagram"),
            requestedAt: .now, tier: .standard, reason: .fallback
        )
        _ = InterventionPauseView(context: context) { EmptyView() } actions: { EmptyView() }
        for indicator in [PauseReadyIndicator.pause, .checkmark, .hidden, .symbol("pause.fill")] {
            _ = InterventionPauseView(context: context, readyIndicator: indicator) { EmptyView() } actions: { EmptyView() }
        }
    }
}
