import AppIntervention
import SwiftUI

/// The pause screen scaffold: the app's name, a short breathing countdown, then the host's actions.
///
/// The actions are disabled until the pause elapses — the pause itself is the intervention.
/// The body (`content`) and the actions are the host's: prices, balances, streaks and option
/// ids belong to the host, not to this package.
public struct InterventionPauseView<Content: View, Actions: View>: View {
    @Environment(\.interventionTheme) private var theme
    @State private var remaining: Int

    private let context: InterventionContext
    private let title: Text?
    private let content: Content
    private let actions: Actions

    public init(
        context: InterventionContext,
        pause: Duration = .seconds(3),
        title: Text? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.context = context
        self.title = title
        self.content = content()
        self.actions = actions()
        _remaining = State(initialValue: max(0, Int(pause.timeInterval.rounded(.up))))
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(theme.background).ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer(minLength: 24)
                countdown
                VStack(spacing: 8) {
                    (title ?? Text("Before you open \(context.app.displayName)", bundle: .module))
                        .font(.title2.bold())
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.center)
                    Text("Take a moment.", bundle: .module)
                        .font(.body)
                        .foregroundStyle(theme.secondaryText)
                }
                content
                Spacer(minLength: 24)
                VStack(spacing: 12) { actions }
                    .disabled(remaining > 0)
                    .opacity(remaining > 0 ? 0.5 : 1)
                    .animation(.default, value: remaining)
            }
            .padding(24)
        }
        .task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                remaining -= 1
            }
        }
    }

    private var countdown: some View {
        ZStack {
            Circle().stroke(theme.secondaryText.opacity(0.2), lineWidth: 6)
            Circle()
                .trim(from: 0, to: remaining > 0 ? 1 : 0)
                .stroke(theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: remaining)
            Text(remaining > 0 ? "\(remaining)" : "")
                .font(.title.monospacedDigit())
                .foregroundStyle(theme.primaryText)
        }
        .frame(width: 88, height: 88)
        .accessibilityHidden(true)
    }
}

/// A full-width button for the pause screen's actions.
public struct InterventionActionButton: View {
    public enum Prominence: Sendable, Hashable { case primary, secondary }

    @Environment(\.interventionTheme) private var theme
    private let title: Text
    private let prominence: Prominence
    private let action: () -> Void

    public init(_ title: Text, prominence: Prominence = .primary, action: @escaping () -> Void) {
        self.title = title
        self.prominence = prominence
        self.action = action
    }

    public var body: some View {
        let button = Button(action: action) {
            title.frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .tint(theme.accent)
        .buttonBorderShape(.roundedRectangle(radius: theme.cornerRadius))
        .controlSize(.large)

        switch prominence {
        case .primary: button.buttonStyle(.borderedProminent)
        case .secondary: button.buttonStyle(.bordered)
        }
    }
}

#Preview("Pause") {
    InterventionPauseView(
        context: InterventionContext(
            app: GuardedApp(id: "instagram", displayName: "Instagram"),
            requestedAt: .now, tier: .standard, reason: .fallback
        )
    ) {
        Text(verbatim: "Opening costs 50 points. Balance: 320.")
    } actions: {
        InterventionActionButton(Text(verbatim: "Pay 50 and open for 15 min")) {}
        InterventionActionButton(Text(verbatim: "Skip and save 50"), prominence: .secondary) {}
    }
}
