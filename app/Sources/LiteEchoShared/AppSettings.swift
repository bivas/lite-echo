import Foundation
import LiteEchoCore
import Observation

/// User preferences, persisted in UserDefaults. Shared by Queue (defaults for new files),
/// Settings (edits them).
@MainActor
@Observable
public final class AppSettings {
    public enum OutputMode: String, CaseIterable, Identifiable, Sendable {
        case nextToAudio, documentsTranscripts, customFolder
        public var id: String { rawValue }
    }

    private let defaults: UserDefaults

    public var defaultLanguage: LanguageChoice { didSet { defaults.set(defaultLanguage.code, forKey: Keys.language) } }
    /// The last two languages picked (newest first); shown as one-click chips.
    public private(set) var recentLanguages: [LanguageChoice] {
        didSet { defaults.set(recentLanguages.map(\.code), forKey: Keys.recentLanguages) }
    }
    public var defaultSpeakers: SpeakerSetting {
        didSet { defaults.set(try? JSONEncoder().encode(defaultSpeakers), forKey: Keys.speakers) }
    }
    public var outputMode: OutputMode { didSet { defaults.set(outputMode.rawValue, forKey: Keys.outputMode) } }
    public var customOutputFolder: URL? { didSet { defaults.set(customOutputFolder?.path, forKey: Keys.customFolder) } }
    public var notifyWhenDone: Bool { didSet { defaults.set(notifyWhenDone, forKey: Keys.notify) } }
    public var openWhenDone: Bool { didSet { defaults.set(openWhenDone, forKey: Keys.openWhenDone) } }
    public var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: Keys.keepAwake) } }
    public var showTimestamps: Bool { didSet { defaults.set(showTimestamps, forKey: Keys.showTimestamps) } }
    public var showPauses: Bool { didSet { defaults.set(showPauses, forKey: Keys.showPauses) } }
    public var highlightUncertain: Bool { didSet { defaults.set(highlightUncertain, forKey: Keys.highlightUncertain) } }
    /// Show the LiteEcho status item in the menu bar (progress and finished files).
    public var showMenuBarItem: Bool { didSet { defaults.set(showMenuBarItem, forKey: Keys.showMenuBarItem) } }

    /// Ask before stopping the running job / removing a queued or finished row / clearing finished rows.
    public var confirmCancel: Bool { didSet { defaults.set(confirmCancel, forKey: Keys.confirmCancel) } }
    public var confirmRemove: Bool { didSet { defaults.set(confirmRemove, forKey: Keys.confirmRemove) } }
    public var confirmClearFinished: Bool {
        didSet { defaults.set(confirmClearFinished, forKey: Keys.confirmClearFinished) }
    }

    /// One switch for the three confirmations above: on only when all are on; setting it sets all three.
    public var askBeforeDestructive: Bool {
        get { confirmCancel && confirmRemove && confirmClearFinished }
        set { confirmCancel = newValue; confirmRemove = newValue; confirmClearFinished = newValue }
    }

    /// The speech model's own folder when kept outside LiteEcho's folder (nil = LiteEcho's folder).
    public var whisperModelDir: URL? { didSet { defaults.set(whisperModelDir?.path, forKey: Keys.whisperDir) } }
    /// Same for the speaker detection model.
    public var pyannoteModelDir: URL? { didSet { defaults.set(pyannoteModelDir?.path, forKey: Keys.pyannoteDir) } }

    /// Colour theme of every window; unknown stored values fall back to Professional.
    public var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: Keys.theme) } }

    // MARK: Voice Memos

    /// Add new Voice Memos to the queue automatically. Turning it on remembers the moment:
    /// only memos recorded after it are added.
    public var autoImportVoiceMemos: Bool {
        didSet {
            defaults.set(autoImportVoiceMemos, forKey: Keys.autoImport)
            if autoImportVoiceMemos, !oldValue { autoImportSince = Date() }
        }
    }
    /// When auto-import was last turned on.
    public private(set) var autoImportSince: Date? {
        didSet { defaults.set(autoImportSince?.timeIntervalSince1970, forKey: Keys.autoImportSince) }
    }
    /// nil = all folders.
    public var autoImportFolderID: String? { didSet { defaults.set(autoImportFolderID, forKey: Keys.autoImportFolder) } }
    public var autoImportMinimumLength: VoiceMemoMinimumLength {
        didSet { defaults.set(autoImportMinimumLength.rawValue, forKey: Keys.autoImportMinimum) }
    }
    /// Where imported memos are saved; nil = `~/Documents/LiteEcho Transcripts`.
    public var voiceMemoOutputFolder: URL? {
        didSet { defaults.set(voiceMemoOutputFolder?.path, forKey: Keys.voiceMemoFolder) }
    }

    public var autoImportPolicy: AutoImportPolicy {
        AutoImportPolicy(enabled: autoImportVoiceMemos, since: autoImportSince, folderID: autoImportFolderID,
                         minimumLength: autoImportMinimumLength)
    }

    /// Options for a Voice Memo added now (saved in the Voice Memos folder, not "next to the audio").
    public var newVoiceMemoOptions: JobOptions {
        JobOptions(language: defaultLanguage, speakers: defaultSpeakers, outputFolder: voiceMemoOutputFolder)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultLanguage = defaults.string(forKey: Keys.language).map(LanguageChoice.init(code:)) ?? .auto
        recentLanguages = (defaults.stringArray(forKey: Keys.recentLanguages) ?? [])
            .map(LanguageChoice.init(code:))
            .filter { !$0.isAuto }
            .reduce(into: [LanguageChoice]()) { if !$0.contains($1) { $0.append($1) } }
            .prefix(LanguageCatalog.maxRecents).map { $0 }
        if let data = defaults.data(forKey: Keys.speakers), let saved = try? JSONDecoder().decode(SpeakerSetting.self, from: data) {
            defaultSpeakers = saved.validated
        } else {
            // Older versions stored 0 (automatic) or an exact count under another key.
            let legacy = defaults.integer(forKey: Keys.legacySpeakerCount)
            defaultSpeakers = legacy > 0 ? SpeakerSetting.exactly(legacy).validated : .auto
        }
        outputMode = OutputMode(rawValue: defaults.string(forKey: Keys.outputMode) ?? "") ?? .nextToAudio
        customOutputFolder = defaults.string(forKey: Keys.customFolder).map { URL(fileURLWithPath: $0) }
        notifyWhenDone = defaults.object(forKey: Keys.notify) as? Bool ?? true
        openWhenDone = defaults.object(forKey: Keys.openWhenDone) as? Bool ?? false
        keepAwake = defaults.object(forKey: Keys.keepAwake) as? Bool ?? true
        showTimestamps = defaults.object(forKey: Keys.showTimestamps) as? Bool ?? true
        showPauses = defaults.object(forKey: Keys.showPauses) as? Bool ?? true
        highlightUncertain = defaults.object(forKey: Keys.highlightUncertain) as? Bool ?? false
        showMenuBarItem = defaults.object(forKey: Keys.showMenuBarItem) as? Bool ?? true
        confirmCancel = defaults.object(forKey: Keys.confirmCancel) as? Bool ?? true
        confirmRemove = defaults.object(forKey: Keys.confirmRemove) as? Bool ?? true
        confirmClearFinished = defaults.object(forKey: Keys.confirmClearFinished) as? Bool ?? true
        whisperModelDir = defaults.string(forKey: Keys.whisperDir).map { URL(fileURLWithPath: $0, isDirectory: true) }
        pyannoteModelDir = defaults.string(forKey: Keys.pyannoteDir).map { URL(fileURLWithPath: $0, isDirectory: true) }
        theme = Theme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .default
        autoImportVoiceMemos = defaults.object(forKey: Keys.autoImport) as? Bool ?? false
        autoImportSince = (defaults.object(forKey: Keys.autoImportSince) as? Double).map { Date(timeIntervalSince1970: $0) }
        autoImportFolderID = defaults.string(forKey: Keys.autoImportFolder)
        autoImportMinimumLength = VoiceMemoMinimumLength(rawValue: defaults.integer(forKey: Keys.autoImportMinimum)) ?? .any
        voiceMemoOutputFolder = defaults.string(forKey: Keys.voiceMemoFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The custom folder of a model kind ("whisper" or "pyannote"); nil = LiteEcho's folder.
    public func modelDir(for kind: String) -> URL? {
        switch kind {
        case "whisper": whisperModelDir
        case "pyannote": pyannoteModelDir
        default: nil
        }
    }

    public func setModelDir(_ url: URL?, for kind: String) {
        switch kind {
        case "whisper": whisperModelDir = url
        case "pyannote": pyannoteModelDir = url
        default: break
        }
    }

    /// Options for a file added now.
    public var newJobOptions: JobOptions {
        JobOptions(language: defaultLanguage, speakers: defaultSpeakers, outputFolder: resolvedOutputFolder)
    }

    /// Remembers a language the user picked (newest first, at most two).
    public func noteLanguagePicked(_ choice: LanguageChoice) {
        recentLanguages = LanguageCatalog.updatedRecents(recentLanguages, picking: choice)
    }

    /// nil = next to the audio file.
    public var resolvedOutputFolder: URL? {
        switch outputMode {
        case .nextToAudio:
            return nil
        case .documentsTranscripts:
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return docs.appendingPathComponent("Transcripts", isDirectory: true)
        case .customFolder:
            return customOutputFolder
        }
    }

    private enum Keys {
        static let language = "defaultLanguage"
        static let recentLanguages = "recentLanguages"
        static let speakers = "defaultSpeakers"
        static let legacySpeakerCount = "defaultSpeakerCount"
        static let outputMode = "outputMode"
        static let customFolder = "customOutputFolder"
        static let notify = "notifyWhenDone"
        static let openWhenDone = "openWhenDone"
        static let keepAwake = "keepAwake"
        static let showTimestamps = "showTimestamps"
        static let showPauses = "showPauses"
        static let highlightUncertain = "highlightUncertain"
        static let showMenuBarItem = "showMenuBarItem"
        static let confirmCancel = "confirmCancel"
        static let confirmRemove = "confirmRemove"
        static let confirmClearFinished = "confirmClearFinished"
        static let theme = "theme"
        static let whisperDir = "whisperModelDir"
        static let pyannoteDir = "pyannoteModelDir"
        static let autoImport = "autoImportVoiceMemos"
        static let autoImportSince = "autoImportVoiceMemosSince"
        static let autoImportFolder = "autoImportVoiceMemosFolder"
        static let autoImportMinimum = "autoImportVoiceMemosMinimum"
        static let voiceMemoFolder = "voiceMemoOutputFolder"
    }
}
