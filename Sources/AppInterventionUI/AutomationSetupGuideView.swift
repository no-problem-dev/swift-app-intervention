import SwiftUI

/// One step of the automation setup guide.
public struct AutomationSetupStep: Identifiable {
    public let id: Int
    /// What to do.
    public let text: Text
    /// Creates a step; `id` is its number.
    public init(id: Int, text: Text) {
        self.id = id
        self.text = text
    }
}

/// Explains how to create the "When <App> is opened → Run Immediately → <action>" automation,
/// with a button that opens the Shortcuts app.
///
/// This is the step where most users drop off; hosts usually embed it in onboarding with their
/// own illustration above it. Every string can be replaced through `steps` and `footer`.
public struct AutomationSetupGuideView: View {
    @Environment(\.interventionTheme) private var theme
    @Environment(\.openURL) private var openURL

    private let steps: [AutomationSetupStep]
    private let footer: Text?

    /// - Parameters:
    ///   - hostAppName: The host app's name as Shortcuts lists it.
    ///   - actionName: The host intent's title as Shortcuts lists it.
    ///   - steps: Replaces the built-in steps.
    ///   - footer: Replaces the built-in note about the notification banner.
    public init(hostAppName: String, actionName: String, steps: [AutomationSetupStep]? = nil, footer: Text? = nil) {
        self.steps = steps ?? Self.defaultSteps(hostAppName: hostAppName, actionName: actionName)
        self.footer = footer
    }

    /// The built-in, localized steps.
    public static func defaultSteps(hostAppName: String, actionName: String) -> [AutomationSetupStep] {
        [
            Text("Open the Shortcuts app and go to the Automation tab.", bundle: .module),
            Text("Tap + and choose App.", bundle: .module),
            Text("Choose the apps to pause before, select Is Opened, and choose Run Immediately.", bundle: .module),
            Text("Turn off Notify When Run.", bundle: .module),
            Text("Tap Next, then add the “\(actionName)” action from \(hostAppName).", bundle: .module),
        ].enumerated().map { AutomationSetupStep(id: $0.offset + 1, text: $0.element) }
    }

    /// `shortcuts://` opens the Shortcuts app.
    public static let shortcutsURL = URL(string: "shortcuts://")!

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: "\(step.id)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(theme.accent)
                        .frame(minWidth: 20)
                    step.text
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            (footer ?? Text("If Notify When Run stays on, iOS shows a small banner each time the automation runs. That is expected.", bundle: .module))
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
            InterventionActionButton(Text("Open Shortcuts", bundle: .module)) {
                openURL(Self.shortcutsURL)
            }
        }
    }
}

#Preview("Setup guide") {
    ScrollView {
        AutomationSetupGuideView(hostAppName: "Habit Rewards", actionName: "Pause Before Opening")
            .padding()
    }
}
