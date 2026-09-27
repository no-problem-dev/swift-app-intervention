import SwiftUI

/// Colors and shapes for the package's views. Defaults are system semantic styles; no brand colors.
public struct InterventionTheme {
    /// Buttons and the countdown.
    public var accent: Color
    /// The pause screen's background.
    public var background: AnyShapeStyle
    /// Titles and body text.
    public var primaryText: Color
    /// Subtitles and notes.
    public var secondaryText: Color
    /// Button corner radius.
    public var cornerRadius: CGFloat

    /// Creates a theme; every parameter defaults to a system style.
    public init(
        accent: Color = .accentColor,
        background: AnyShapeStyle = AnyShapeStyle(.background),
        primaryText: Color = .primary,
        secondaryText: Color = .secondary,
        cornerRadius: CGFloat = 16
    ) {
        self.accent = accent
        self.background = background
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.cornerRadius = cornerRadius
    }
}

extension EnvironmentValues {
    /// The theme for intervention views. Set it with `.interventionTheme(_:)`.
    @Entry public var interventionTheme = InterventionTheme()
}

extension View {
    /// Styles every intervention view below this one.
    public func interventionTheme(_ theme: InterventionTheme) -> some View {
        environment(\.interventionTheme, theme)
    }
}
