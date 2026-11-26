import SwiftUI

// Reusable themed building blocks. Everything reads `@Environment(\.theme)`.

// MARK: Scene root

/// Injects the selected theme into a scene root: environment value, colour scheme, tint, font
/// design, default text colour and (optionally) the window-coloured background.
/// Reads `settings.theme`, so changing it re-renders live.
public struct ThemeHost<Content: View>: View {
    let settings: AppSettings
    let fillsBackground: Bool
    let content: Content

    public init(settings: AppSettings, fillsBackground: Bool = true, @ViewBuilder content: () -> Content) {
        self.settings = settings
        self.fillsBackground = fillsBackground
        self.content = content()
    }

    public var body: some View {
        let theme = settings.theme
        content
            .environment(\.theme, theme)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
            .preferredColorScheme(theme.isDark ? .dark : .light)
            .tint(theme.accent)
            .fontDesign(theme.bodyDesign)
            .foregroundStyle(theme.text)
            .background(fillsBackground ? theme.window : Color.clear)
    }
}

extension View {
    /// Applies the app theme to a scene's root view (next to the `.environment(model)` calls).
    public func themed(_ settings: AppSettings, fillsBackground: Bool = true) -> some View {
        ThemeHost(settings: settings, fillsBackground: fillsBackground) { self }
    }

    /// Neon glow in the accent colour; no-op in themes without glow.
    public func themedGlow(_ active: Bool = true) -> some View { modifier(ThemedGlow(active: active)) }

    /// A bordered card on the control background.
    public func themedCard(padding: CGFloat = 18) -> some View {
        modifier(ThemedCard(padding: padding))
    }

    /// Heading font in the theme's heading design.
    public func themedHeading(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        modifier(ThemedHeading(size: size, weight: weight))
    }
}

private struct ThemedGlow: ViewModifier {
    let active: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        if theme.hasGlow, active {
            content.shadow(color: theme.accent.opacity(0.75), radius: 6)
        } else {
            content
        }
    }
}

private struct ThemedCard: ViewModifier {
    let padding: CGFloat
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: theme.cornerRadius).fill(theme.control))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(theme.separator))
    }
}

private struct ThemedHeading: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.font(theme.heading(size, weight: weight))
    }
}

// MARK: Labels

/// Small caption-style section label ("FOR NEW FILES"). Uppercased in themes that ask for it,
/// or always with `forceUppercase`.
public struct SectionLabel: View {
    private let title: String
    private let forceUppercase: Bool
    @Environment(\.theme) private var theme

    public init(_ title: String, forceUppercase: Bool = false) {
        self.title = title
        self.forceUppercase = forceUppercase
    }

    public var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .kerning(0.5)
            .textCase(forceUppercase || theme.uppercaseLabels ? .uppercase : nil)
            .foregroundStyle(theme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Buttons

/// Filled accent button (text on accent), with glow in Cyberpunk.
public struct ThemedPrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .textCase(theme.uppercaseLabels ? .uppercase : nil)
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, controlSize == .small ? 10 : 14)
                .padding(.vertical, controlSize == .small ? 3 : 6)
                .background(RoundedRectangle(cornerRadius: theme.cornerRadius).fill(theme.accent))
                .themedGlow(isEnabled)
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
    }
}

/// Outlined button on the control background.
public struct ThemedSecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize

        var body: some View {
            configuration.label
                .textCase(theme.uppercaseLabels ? .uppercase : nil)
                .foregroundStyle(theme.text)
                .padding(.horizontal, controlSize == .small ? 8 : 12)
                .padding(.vertical, controlSize == .small ? 2 : 5)
                .background(RoundedRectangle(cornerRadius: theme.cornerRadius).fill(theme.control))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(theme.secondaryText.opacity(0.45)))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
    }
}

extension ButtonStyle where Self == ThemedPrimaryButtonStyle {
    public static var themedPrimary: ThemedPrimaryButtonStyle { ThemedPrimaryButtonStyle() }
}

extension ButtonStyle where Self == ThemedSecondaryButtonStyle {
    public static var themedSecondary: ThemedSecondaryButtonStyle { ThemedSecondaryButtonStyle() }
}

// MARK: Progress

/// Determinate progress bar: accent fill on the theme track (with glow in Cyberpunk).
public struct ThemedProgressBar: View {
    private let value: Double
    private let tint: Color?
    @Environment(\.theme) private var theme

    public init(value: Double, tint: Color? = nil) {
        self.value = min(1, max(0, value))
        self.tint = tint
    }

    public var body: some View {
        let fill = tint ?? theme.accent
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track)
                Capsule().fill(fill)
                    .frame(width: proxy.size.width * value)
                    .themedGlow(value > 0)
            }
            .overlay(Capsule().stroke(theme.accentText.opacity(0.35), lineWidth: 0.5))
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

// MARK: Segmented control

/// Single-choice segmented control; the selected segment is accent-filled (glowing in Cyberpunk).
public struct ThemedSegmentedPicker<Value: Hashable>: View {
    private let options: [(value: Value, title: String)]
    @Binding private var selection: Value
    private let label: String
    @Environment(\.theme) private var theme

    public init(_ label: String, selection: Binding<Value>, options: [(value: Value, title: String)]) {
        self.label = label
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .textCase(theme.uppercaseLabels ? .uppercase : nil)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? theme.onAccent : theme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: max(2, theme.cornerRadius - 2))
                            .fill(selected ? theme.accent : Color.clear))
                        .themedGlow(selected)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: theme.cornerRadius).fill(theme.control))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(theme.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: Swatches

/// A row of small colour dots previewing a theme.
public struct ThemeSwatchRow: View {
    let theme: Theme

    public init(theme: Theme) { self.theme = theme }

    public var body: some View {
        HStack(spacing: -4) {
            ForEach(Array([theme.window, theme.sidebar, theme.accent, theme.text, theme.success].enumerated()),
                    id: \.offset) { _, color in
                Circle().fill(color).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.gray.opacity(0.55), lineWidth: 0.75))
            }
        }
        .accessibilityHidden(true)
    }
}
