import AppIntervention
import SwiftUI

/// What the pause view's ring shows once the breath is over.
///
/// The default is a neutral raised hand: a checkmark read as "done" or "opened", even when the host
/// offers no way to open (a lock, an empty balance).
public struct PauseReadyIndicator: Sendable, Hashable {
    /// The SF Symbol to show, or `nil` to show nothing.
    public let systemName: String?

    /// A custom SF Symbol.
    public static func symbol(_ systemName: String) -> PauseReadyIndicator {
        PauseReadyIndicator(systemName: systemName)
    }

    /// A raised hand (`hand.raised.fill`). The default.
    public static let pause = PauseReadyIndicator(systemName: "hand.raised.fill")
    /// A checkmark (`checkmark`), the only indicator before 0.2.0.
    public static let checkmark = PauseReadyIndicator(systemName: "checkmark")
    /// Nothing inside the ring.
    public static let hidden = PauseReadyIndicator(systemName: nil)
}

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
    private let subtitle: Text?
    private let readyAnnouncement: String?
    private let readyIndicator: PauseReadyIndicator
    private let content: Content
    private let actions: Actions

    /// - Parameters:
    ///   - context: The intervention to show.
    ///   - pause: How long the actions stay disabled. Default three seconds.
    ///   - title: Replaces "Before you open <App>".
    ///   - subtitle: Replaces "Take a moment."
    ///   - readyAnnouncement: What VoiceOver announces when the actions become available.
    ///     `nil` uses the built-in localized text.
    ///   - readyIndicator: What the ring shows once the pause is over. Default ``PauseReadyIndicator/pause``.
    ///   - content: The host's body: price, balance, streak.
    ///   - actions: The host's options, usually ``InterventionActionButton``s.
    public init(
        context: InterventionContext,
        pause: Duration = .seconds(3),
        title: Text? = nil,
        subtitle: Text? = nil,
        readyAnnouncement: String? = nil,
        readyIndicator: PauseReadyIndicator = .pause,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.context = context
        self.title = title
        self.subtitle = subtitle
        self.readyAnnouncement = readyAnnouncement
        self.readyIndicator = readyIndicator
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
                    (subtitle ?? Text("Take a moment.", bundle: .module))
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
            guard remaining > 0 else { return }
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining -= 1
            }
            AccessibilityNotification.Announcement(
                readyAnnouncement ?? String(localized: "You can choose now.", bundle: .module)
            ).post()
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
            if remaining > 0 {
                Text(verbatim: "\(remaining)")
                    .font(.title.monospacedDigit())
                    .foregroundStyle(theme.primaryText)
            } else if let symbol = readyIndicator.systemName {
                Image(systemName: symbol)
                    .font(.title2.bold())
                    .foregroundStyle(theme.accent)
            }
        }
        .frame(width: 88, height: 88)
        .accessibilityHidden(true)
    }
}

/// A full-width button for the pause screen's actions.
public struct InterventionActionButton: View {
    /// How strongly the button is drawn.
    public enum Prominence: Sendable, Hashable { case primary, secondary }

    @Environment(\.interventionTheme) private var theme
    private let title: Text
    private let prominence: Prominence
    private let action: () -> Void

    /// - Parameters:
    ///   - title: The label.
    ///   - prominence: `.primary` is filled with the theme's accent; `.secondary` is bordered.
    ///   - action: Runs on tap.
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
