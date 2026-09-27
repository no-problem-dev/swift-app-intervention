import SwiftUI

/// Colors and shapes for the package's views. Defaults are system semantic styles; no brand colors.
public struct InterventionTheme {
    public var accent: Color
    public var background: AnyShapeStyle
    public var primaryText: Color
    public var secondaryText: Color
    public var cornerRadius: CGFloat

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
    @Entry public var interventionTheme = InterventionTheme()
}

extension View {
    /// Styles every intervention view below this one.
    public func interventionTheme(_ theme: InterventionTheme) -> some View {
        environment(\.interventionTheme, theme)
    }
}
