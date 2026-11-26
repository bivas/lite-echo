import SwiftUI

/// The app's colour themes. Each one is a fixed set of tokens (see `Palette`); views read them
/// through `@Environment(\.theme)` and never hard-code colours.
public enum Theme: String, CaseIterable, Identifiable, Sendable {
    case professional, cyberpunk, lime, mint, paper

    public var id: String { rawValue }
    public static let `default`: Theme = .professional

    /// Colour tokens as 0xRRGGBB.
    public struct Palette: Equatable, Sendable {
        public let window, bar, sidebar, separator: UInt32
        public let text, secondaryText: UInt32
        public let accent, onAccent: UInt32
        /// Accent used for text and icons on `window`/`bar` (differs from `accent` only when the
        /// accent is too light to read as text).
        public let accentText: UInt32
        public let soft, track, success, control, danger, warning: UInt32
    }

    public var displayName: String {
        switch self {
        case .professional: "Professional"
        case .cyberpunk: "Cyberpunk"
        case .lime: "Lite Lime"
        case .mint: "Echo Mint"
        case .paper: "Paper Studio"
        }
    }

    public var subtitle: String {
        switch self {
        case .professional: "Graphite · light"
        case .cyberpunk: "Neon Grid · dark"
        case .lime: "Fresh and light"
        case .mint: "Logo colours · dark"
        case .paper: "Warm and editorial"
        }
    }

    public var isDark: Bool { self == .cyberpunk || self == .mint }

    public var cornerRadius: CGFloat {
        switch self {
        case .professional: 8
        case .cyberpunk: 3
        case .lime: 14
        case .mint: 10
        case .paper: 6
        }
    }

    /// Design of all text.
    public var bodyDesign: Font.Design { self == .cyberpunk ? .monospaced : .default }
    /// Design of headings and titles.
    public var headingDesign: Font.Design {
        switch self {
        case .cyberpunk: .monospaced
        case .paper: .serif
        default: .default
        }
    }
    /// Section labels and button titles are uppercased.
    public var uppercaseLabels: Bool { self == .cyberpunk }
    /// Neon glow on the primary button, progress fill and selected segments.
    public var hasGlow: Bool { self == .cyberpunk }

    public var palette: Palette {
        switch self {
        case .professional:
            Palette(window: 0xFFFFFF, bar: 0xF6F7F9, sidebar: 0xF3F4F7, separator: 0xDADDE3,
                    text: 0x17191E, secondaryText: 0x5B6170, accent: 0x2F5BD3, onAccent: 0xFFFFFF,
                    accentText: 0x2F5BD3, soft: 0xEAF0FC, track: 0xD9E2F7, success: 0x1E7B34,
                    control: 0xFFFFFF, danger: 0xB42318, warning: 0x8A5300)
        case .cyberpunk:
            Palette(window: 0x0D0B17, bar: 0x120F20, sidebar: 0x0F0C1C, separator: 0x2A2342,
                    text: 0xEDE9FF, secondaryText: 0x9A92BF, accent: 0xFF2EA6, onAccent: 0x14000B,
                    accentText: 0xFF2EA6, soft: 0x1E1030, track: 0x33204A, success: 0x00E5FF,
                    control: 0x17132A, danger: 0xFF6B6B, warning: 0xFFB454)
        case .lime:
            Palette(window: 0xFFFFFF, bar: 0xFBFDF7, sidebar: 0xF6FAEE, separator: 0xE1EAD2,
                    text: 0x1B2410, secondaryText: 0x5C6B4A, accent: 0xA3E635, onAccent: 0x1A2E05,
                    accentText: 0x3F7A0C, soft: 0xF1FADF, track: 0xE2F1C4, success: 0x3F7A0C,
                    control: 0xFFFFFF, danger: 0xB42318, warning: 0x8A5300)
        case .mint:
            Palette(window: 0x0F172A, bar: 0x121C33, sidebar: 0x111A2F, separator: 0x22304D,
                    text: 0xE6EDF7, secondaryText: 0x93A3BD, accent: 0x5EEAD4, onAccent: 0x062A26,
                    accentText: 0x5EEAD4, soft: 0x14263A, track: 0x1F3A4A, success: 0x5EEAD4,
                    control: 0x16213A, danger: 0xFB7185, warning: 0xFBBF24)
        case .paper:
            Palette(window: 0xFBF7EF, bar: 0xF5EFE3, sidebar: 0xF4EDDF, separator: 0xE2D7C3,
                    text: 0x2A2622, secondaryText: 0x6E6457, accent: 0xB4532A, onAccent: 0xFFFFFF,
                    accentText: 0xB4532A, soft: 0xF6E7DA, track: 0xEBD3C2, success: 0x4D7A3A,
                    control: 0xFFFDF8, danger: 0xB42318, warning: 0x8A5300)
        }
    }

    // MARK: Colour tokens

    public var window: Color { Color(rgb: palette.window) }
    public var bar: Color { Color(rgb: palette.bar) }
    public var sidebar: Color { Color(rgb: palette.sidebar) }
    public var separator: Color { Color(rgb: palette.separator) }
    public var text: Color { Color(rgb: palette.text) }
    public var secondaryText: Color { Color(rgb: palette.secondaryText) }
    public var accent: Color { Color(rgb: palette.accent) }
    public var onAccent: Color { Color(rgb: palette.onAccent) }
    public var accentText: Color { Color(rgb: palette.accentText) }
    public var soft: Color { Color(rgb: palette.soft) }
    public var track: Color { Color(rgb: palette.track) }
    public var success: Color { Color(rgb: palette.success) }
    public var control: Color { Color(rgb: palette.control) }
    public var danger: Color { Color(rgb: palette.danger) }
    public var warning: Color { Color(rgb: palette.warning) }

    // MARK: Fonts

    /// A heading/title font in this theme's heading design.
    public func heading(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: headingDesign)
    }

    // MARK: Contrast

    /// WCAG relative luminance of 0xRRGGBB.
    public static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((rgb >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    /// WCAG contrast ratio (1...21) between two 0xRRGGBB colours.
    public static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

extension Color {
    /// 0xRRGGBB in sRGB.
    public init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, opacity: 1)
    }
}

// MARK: Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .professional
}

extension EnvironmentValues {
    public var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
