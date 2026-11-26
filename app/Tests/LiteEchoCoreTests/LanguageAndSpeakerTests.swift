import Foundation
import Testing
@testable import LiteEchoCore

private let sampleLanguages: [LanguageInfo] = [
    LanguageInfo(code: "he", name: "Hebrew", native: "עברית", tuned: true),
    LanguageInfo(code: "fr", name: "French", native: "Français"),
    LanguageInfo(code: "es", name: "Spanish", native: "Español"),
    LanguageInfo(code: "pt", name: "Portuguese", native: "Português"),
    LanguageInfo(code: "tr", name: "Turkish", native: "Türkçe"),
    LanguageInfo(code: "en", name: "English", native: "English", tuned: true),
].sorted { $0.name < $1.name }

// MARK: Language list

@Test func engineInfoDecodesLanguagesAndToleratesOlderEngines() throws {
    func decode(_ extra: String) throws -> EngineInfo {
        let json = #"{"version":"1","python":"3","packages":{},"models_dir":"/m","models":{}\#(extra)}"#
        return try EngineInfo.decode(Data(json.utf8))
    }
    let with = try decode(#","languages":[{"code":"he","name":"Hebrew","native":"עברית","tuned":true},{"code":"fr","name":"French","native":"Français"}]"#)
    #expect(with.languages?.count == 2)
    #expect(with.languages?[0].tuned == true && with.languages?[1].tuned == false)
    #expect(LanguageCatalog.usable(with.languages).map(\.code) == ["fr", "he"])
    let old = try decode("")
    #expect(old.languages == nil)
    #expect(LanguageCatalog.usable(old.languages) == LanguageCatalog.fallback)
    // A malformed list does not break engine-info.
    let broken = try decode(#","languages":"nope""#)
    #expect(broken.languages == nil)
    #expect(LanguageCatalog.usable([]) == LanguageCatalog.fallback)
    #expect(LanguageCatalog.usable([LanguageInfo(code: "auto", name: "Auto")]) == LanguageCatalog.fallback)
}

@Test func searchMatchesNameNativeCodeAndDiacritics() {
    func codes(_ q: String) -> [String] { LanguageCatalog.filter(sampleLanguages, query: q).map(\.code) }
    #expect(codes("") == sampleLanguages.map(\.code))
    #expect(codes("HEBR") == ["he"])
    #expect(codes("עבר") == ["he"])            // native name
    #expect(codes("he") == ["he"])             // exact code first
    #expect(codes("francais") == ["fr"])       // diacritics ignored
    #expect(codes("Français") == ["fr"])
    #expect(codes("turkce") == ["tr"])
    #expect(codes("portugues") == ["pt"])
    #expect(codes("ESPAÑOL") == ["es"])
    #expect(codes("zzz").isEmpty)
    // Exact code ranks above name matches; name prefix above containment.
    #expect(codes("en").first == "en")
    #expect(LanguageCatalog.autoMatches(query: "Detect") && LanguageCatalog.autoMatches(query: ""))
    #expect(!LanguageCatalog.autoMatches(query: "hebrew"))
}

@Test func recentsKeepTheLastTwoDistinctPicks() {
    var recents: [LanguageChoice] = []
    recents = LanguageCatalog.updatedRecents(recents, picking: .he)
    recents = LanguageCatalog.updatedRecents(recents, picking: .en)
    #expect(recents == [.en, .he])
    recents = LanguageCatalog.updatedRecents(recents, picking: .he)      // moves to front
    #expect(recents == [.he, .en])
    recents = LanguageCatalog.updatedRecents(recents, picking: LanguageChoice(code: "fr"))
    #expect(recents == [LanguageChoice(code: "fr"), .he])               // oldest dropped
    #expect(LanguageCatalog.updatedRecents(recents, picking: .auto) == recents)   // auto is never a recent
}

@Test func legacyLanguageValuesStillDecode() throws {
    let decoder = JSONDecoder()
    #expect(try decoder.decode(LanguageChoice.self, from: Data(#""auto""#.utf8)) == .auto)
    #expect(try decoder.decode(LanguageChoice.self, from: Data(#""he""#.utf8)) == .he)
    #expect(try decoder.decode(LanguageChoice.self, from: Data(#""en""#.utf8)) == .en)
    #expect(try decoder.decode(LanguageChoice.self, from: Data(#""FR""#.utf8)).code == "fr")
    #expect(String(decoding: try JSONEncoder().encode(LanguageChoice(code: "fr")), as: UTF8.self) == #""fr""#)
    // A queue.json entry written before this change.
    let old = #"{"language":"he","speakers":{"exactly":{"_0":3}}}"#
    let options = try decoder.decode(JobOptions.self, from: Data(old.utf8))
    #expect(options.language == .he && options.speakers == .exactly(3))
}

@Test func languageNamesComeFromTheEngineListFirst() {
    #expect(LanguageCatalog.name(forCode: "fr", in: sampleLanguages) == "French")
    #expect(LanguageCatalog.name(forCode: "he") == "Hebrew")
    #expect(LanguageCatalog.name(forCode: "xx-nonsense").isEmpty == false)
    #expect(LanguageCatalog.displayName(of: .auto, in: sampleLanguages) == "Auto-detect")
    #expect(LanguageCatalog.displayName(of: LanguageChoice(code: "tr"), in: sampleLanguages) == "Turkish")
}

// MARK: Speakers

@Test func legacySpeakerSettingsStillDecode() throws {
    let decoder = JSONDecoder()
    #expect(try decoder.decode(SpeakerSetting.self, from: Data(#"{"auto":{}}"#.utf8)) == .auto)
    #expect(try decoder.decode(SpeakerSetting.self, from: Data(#"{"exactly":{"_0":4}}"#.utf8)) == .exactly(4))
    #expect(try decoder.decode(SpeakerSetting.self, from: Data(#"{"range":{"min":2,"max":4}}"#.utf8)) == .range(min: 2, max: 4))
    #expect(try decoder.decode(SpeakerSetting.self, from: Data(#"{"range":{"max":4}}"#.utf8)) == .range(min: nil, max: 4))
    for value: SpeakerSetting in [.auto, .exactly(2), .range(min: 3, max: 8), .range(min: nil, max: 5)] {
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(SpeakerSetting.self, from: data) == value)
    }
    // The old encoding is unchanged, so an older app can still read what this one writes.
    #expect(String(decoding: try JSONEncoder().encode(SpeakerSetting.exactly(3)), as: UTF8.self) == #"{"exactly":{"_0":3}}"#)
}

@Test func presetsMapToEngineArguments() {
    #expect(SpeakerPreset.auto.setting.cliArguments == ["--speakers", "auto"])
    #expect(SpeakerPreset.solo.setting.cliArguments == ["--speakers", "1"])
    #expect(SpeakerPreset.conversation.setting.cliArguments == ["--speakers", "2"])
    #expect(SpeakerPreset.meeting.setting.cliArguments == ["--min-speakers", "3", "--max-speakers", "8"])
    #expect(SpeakerSetting.range(min: 2, max: nil).cliArguments == ["--min-speakers", "2"])
    #expect(SpeakerSetting.range(min: nil, max: 6).cliArguments == ["--max-speakers", "6"])
    #expect(SpeakerSetting.exactly(99).cliArguments == ["--speakers", "20"])
    #expect(SpeakerSetting.exactly(0).cliArguments == ["--speakers", "1"])
    for preset in SpeakerPreset.allCases { #expect(SpeakerPreset(matching: preset.setting) == preset) }
    #expect(SpeakerPreset(matching: .exactly(5)) == nil)
    #expect(SpeakerPreset(matching: .range(min: 2, max: 4)) == nil)
}

@Test func transcribeCommandCarriesLanguageAndSpeakerArguments() {
    let job = Job(audio: URL(fileURLWithPath: "/a/b.m4a"),
                  options: JobOptions(language: LanguageChoice(code: "fr"), speakers: .range(min: 3, max: 8)))
    #expect(EngineCommand.transcribe(job) == ["/a/b.m4a", "--language", "fr", "--min-speakers", "3",
                                              "--max-speakers", "8", "--events", "jsonl"])
}

@Test func rangeValidation() {
    #expect(SpeakerSetting.makeRange(min: 5, max: 2) == .range(min: 2, max: 5))
    #expect(SpeakerSetting.makeRange(min: 0, max: 40) == .range(min: 1, max: 20))
    #expect(SpeakerSetting.range(min: nil, max: nil).validated == .auto)
    #expect(SpeakerSetting.range(min: 3, max: 3).validated == .exactly(3))
    #expect(SpeakerSetting.range(min: 9, max: 4).validated == .range(min: 4, max: 9))
    // Steppers: raising the minimum drags the maximum along, lowering the maximum drags the minimum.
    #expect(SpeakerSetting.enforcing(min: 6, max: 4, changedMin: true) == (min: 6, max: 6))
    #expect(SpeakerSetting.enforcing(min: 3, max: 2, changedMin: false) == (min: 2, max: 2))
    #expect(SpeakerSetting.enforcing(min: 2, max: 4, changedMin: true) == (min: 2, max: 4))
    #expect(SpeakerSetting.enforcing(min: 0, max: 99, changedMin: true) == (min: 1, max: 20))
}

@Test func speakerLabels() {
    #expect(SpeakerSetting.auto.label == "Auto")
    #expect(SpeakerSetting.exactly(1).label == "1 speaker")
    #expect(SpeakerSetting.exactly(2).label == "2 speakers")
    #expect(SpeakerSetting.range(min: 3, max: 8).label == "Meeting")
    #expect(SpeakerSetting.range(min: 2, max: 4).label == "Range 2–4")
    #expect(SpeakerSetting.range(min: 3, max: nil).label == "At least 3")
    #expect(SpeakerSetting.range(min: nil, max: 6).label == "Up to 6")
}
