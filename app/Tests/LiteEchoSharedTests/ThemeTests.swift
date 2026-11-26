import Foundation
import Testing
@testable import LiteEchoShared

@MainActor private func freshDefaults() -> (UserDefaults, String) {
    let suite = "liteecho.tests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

@MainActor @Test func themeDefaultsToProfessional() {
    let (defaults, suite) = freshDefaults()
    #expect(AppSettings(defaults: defaults).theme == .professional)
    defaults.removePersistentDomain(forName: suite)
}

@MainActor @Test func themeRoundTrips() {
    let (defaults, suite) = freshDefaults()
    for theme in Theme.allCases {
        AppSettings(defaults: defaults).theme = theme
        #expect(AppSettings(defaults: defaults).theme == theme)
    }
    defaults.removePersistentDomain(forName: suite)
}

@MainActor @Test func unknownStoredThemeFallsBackToProfessional() {
    let (defaults, suite) = freshDefaults()
    defaults.set("vaporwave", forKey: "theme")
    #expect(AppSettings(defaults: defaults).theme == .professional)
    defaults.removePersistentDomain(forName: suite)
}

@Test func fiveThemesWithDistinctAccents() {
    #expect(Theme.allCases.count == 5)
    #expect(Set(Theme.allCases.map(\.palette.accent)).count == 5)
    #expect(Set(Theme.allCases.map(\.displayName)).count == 5)
}

@Test func darkFlags() {
    #expect(Set(Theme.allCases.filter(\.isDark)) == [.cyberpunk, .mint])
}

@Test func contrastHelperKnownValues() {
    #expect(abs(Theme.contrastRatio(0x000000, 0xFFFFFF) - 21) < 0.01)
    #expect(abs(Theme.contrastRatio(0xFFFFFF, 0xFFFFFF) - 1) < 0.01)
}

@Test func textContrastMeetsWCAGAA() {
    for theme in Theme.allCases {
        let p = theme.palette
        let name = theme.displayName
        for (bgName, bg) in [("window", p.window), ("bar", p.bar), ("sidebar", p.sidebar),
                             ("control", p.control), ("soft", p.soft)] {
            #expect(Theme.contrastRatio(p.text, bg) >= 4.5, "\(name): text on \(bgName)")
            #expect(Theme.contrastRatio(p.secondaryText, bg) >= 4.5, "\(name): secondary on \(bgName)")
        }
        for (tokenName, fg) in [("accentText", p.accentText), ("success", p.success),
                                ("danger", p.danger), ("warning", p.warning)] {
            #expect(Theme.contrastRatio(fg, p.window) >= 4.5, "\(name): \(tokenName) on window")
        }
        #expect(Theme.contrastRatio(p.onAccent, p.accent) >= 4.5, "\(name): onAccent on accent")
    }
}
