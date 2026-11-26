import Foundation
import Testing
@testable import LiteEchoShared
import LiteEchoCore

@MainActor @Test func settingsPersistAndBuildJobOptions() {
    let suite = "liteecho.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let s = AppSettings(defaults: defaults)
    #expect(s.newJobOptions == JobOptions())
    s.defaultLanguage = .he
    s.defaultSpeakers = .exactly(3)
    let again = AppSettings(defaults: defaults)
    #expect(again.newJobOptions.language == .he)
    #expect(again.newJobOptions.speakers == .exactly(3))
    defaults.removePersistentDomain(forName: suite)
}

@MainActor @Test func modelFoldersPersistAndDefaultToNil() {
    let suite = "liteecho.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let s = AppSettings(defaults: defaults)
    #expect(s.whisperModelDir == nil && s.pyannoteModelDir == nil)
    s.whisperModelDir = URL(fileURLWithPath: "/Volumes/Big Disk/whisper")
    s.setModelDir(URL(fileURLWithPath: "/models/pyannote"), for: "pyannote")
    let again = AppSettings(defaults: defaults)
    #expect(again.whisperModelDir?.path == "/Volumes/Big Disk/whisper")
    #expect(again.modelDir(for: "pyannote")?.path == "/models/pyannote")
    again.setModelDir(nil, for: "whisper")
    #expect(AppSettings(defaults: defaults).whisperModelDir == nil)
    #expect(AppSettings(defaults: defaults).pyannoteModelDir != nil)
}

@MainActor @Test func languageRecentsAndSpeakerSettingPersist() {
    let suite = "liteecho.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let s = AppSettings(defaults: defaults)
    s.noteLanguagePicked(.he)
    s.noteLanguagePicked(LanguageChoice(code: "fr"))
    s.noteLanguagePicked(.en)
    #expect(s.recentLanguages == [.en, LanguageChoice(code: "fr")])
    s.defaultLanguage = LanguageChoice(code: "fr")
    s.defaultSpeakers = .range(min: 2, max: 4)
    let again = AppSettings(defaults: defaults)
    #expect(again.recentLanguages == [.en, LanguageChoice(code: "fr")])
    #expect(again.newJobOptions.language.code == "fr")
    #expect(again.newJobOptions.speakers == .range(min: 2, max: 4))
}

@MainActor @Test func legacyDefaultsStillLoad() {
    let suite = "liteecho.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("he", forKey: "defaultLanguage")
    defaults.set(3, forKey: "defaultSpeakerCount")
    let s = AppSettings(defaults: defaults)
    #expect(s.defaultLanguage == .he)
    #expect(s.defaultSpeakers == .exactly(3))
    let none = UserDefaults(suiteName: suite + "x")!
    none.set(0, forKey: "defaultSpeakerCount")
    #expect(AppSettings(defaults: none).defaultSpeakers == .auto)
    none.removePersistentDomain(forName: suite + "x")
}

@Test func languagePopoverRowsFollowSectionsAndQuery() {
    let languages = LanguageCatalog.fallback
    let all = LanguageRows.build(languages: languages, recents: [.he], query: "")
    #expect(all.map(\.id) == ["detect-auto", "recent-he", "all-en", "all-he"])
    #expect(LanguageRows.countText(rows: all, query: "") == "3 languages")
    let q = LanguageRows.build(languages: languages, recents: [.he], query: "עבר")
    #expect(q.map(\.id) == ["recent-he", "all-he"])
    #expect(LanguageRows.countText(rows: q, query: "עבר") == "1 match")
    #expect(LanguageRows.build(languages: languages, recents: [], query: "detect").map(\.id) == ["detect-auto"])
    #expect(LanguageRows.build(languages: languages, recents: [], query: "zzz").isEmpty)
}
