import Foundation

/// How many speakers the engine should look for.
public enum SpeakerSetting: Codable, Equatable, Sendable, Hashable {
    case auto
    case exactly(Int)
    /// Either bound may be nil (open ended). Bounds are 1...20 with min <= max (see `validated`).
    case range(min: Int?, max: Int?)

    public static let limits = 1...20

    /// A range with both bounds clamped to 1...20 and ordered (min <= max).
    public static func makeRange(min: Int?, max: Int?) -> SpeakerSetting {
        var lo = min.map { Swift.min(Swift.max($0, limits.lowerBound), limits.upperBound) }
        var hi = max.map { Swift.min(Swift.max($0, limits.lowerBound), limits.upperBound) }
        if let a = lo, let b = hi, a > b { swap(&lo, &hi) }
        return .range(min: lo, max: hi)
    }

    /// New bounds after one stepper changed, keeping min <= max: the other bound follows.
    public static func enforcing(min: Int, max: Int, changedMin: Bool) -> (min: Int, max: Int) {
        let lo = Swift.min(Swift.max(min, limits.lowerBound), limits.upperBound)
        let hi = Swift.min(Swift.max(max, limits.lowerBound), limits.upperBound)
        if lo <= hi { return (lo, hi) }
        return changedMin ? (lo, lo) : (hi, hi)
    }

    /// Clamped to the engine's limits; an empty range becomes `.auto`, equal bounds become `.exactly`.
    public var validated: SpeakerSetting {
        switch self {
        case .auto: return .auto
        case .exactly(let n): return .exactly(Swift.min(Swift.max(n, Self.limits.lowerBound), Self.limits.upperBound))
        case .range(let lo, let hi):
            if lo == nil, hi == nil { return .auto }
            guard case .range(let a, let b) = Self.makeRange(min: lo, max: hi) else { return .auto }
            if let a, let b, a == b { return .exactly(a) }
            return .range(min: a, max: b)
        }
    }

    /// Short text for the setting: "Auto", "2 speakers", "Meeting", "Range 2–4", "At least 3", "Up to 6".
    public var label: String {
        switch validated {
        case .auto: return "Auto"
        case .exactly(let n): return n == 1 ? "1 speaker" : "\(n) speakers"
        case .range(let lo, let hi):
            if self.validated == SpeakerPreset.meeting.setting { return SpeakerPreset.meeting.title }
            switch (lo, hi) {
            case let (lo?, hi?): return "Range \(lo)–\(hi)"
            case let (lo?, nil): return "At least \(lo)"
            case let (nil, hi?): return "Up to \(hi)"
            default: return "Auto"
            }
        }
    }

    /// Engine arguments (an array, never a shell string).
    public var cliArguments: [String] {
        switch validated {
        case .auto: return ["--speakers", "auto"]
        case .exactly(let n): return ["--speakers", String(n)]
        case .range(let lo, let hi):
            var args: [String] = []
            if let lo { args += ["--min-speakers", String(lo)] }
            if let hi { args += ["--max-speakers", String(hi)] }
            return args
        }
    }

    // Auto and exactly keep the layout the synthesized coding used before ranges existed
    // (`{"auto":{}}`, `{"exactly":{"_0":3}}`), so saved queues and settings still decode.
    private enum CodingKeys: String, CodingKey { case auto, exactly, range }
    private enum ExactKeys: String, CodingKey { case count = "_0" }
    private enum RangeKeys: String, CodingKey { case min, max }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if let n = try? single.decode(Int.self) { self = n > 0 ? .exactly(n) : .auto; return }
            if let text = try? single.decode(String.self) {
                self = Int(text).map { $0 > 0 ? .exactly($0) : .auto } ?? .auto
                return
            }
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.range) {
            let r = try c.nestedContainer(keyedBy: RangeKeys.self, forKey: .range)
            self = SpeakerSetting.range(min: try r.decodeIfPresent(Int.self, forKey: .min),
                                        max: try r.decodeIfPresent(Int.self, forKey: .max))
        } else if c.contains(.exactly) {
            let e = try c.nestedContainer(keyedBy: ExactKeys.self, forKey: .exactly)
            self = .exactly(try e.decode(Int.self, forKey: .count))
        } else {
            self = .auto
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            _ = c.nestedContainer(keyedBy: ExactKeys.self, forKey: .auto)
        case .exactly(let n):
            var e = c.nestedContainer(keyedBy: ExactKeys.self, forKey: .exactly)
            try e.encode(n, forKey: .count)
        case .range(let lo, let hi):
            var r = c.nestedContainer(keyedBy: RangeKeys.self, forKey: .range)
            try r.encodeIfPresent(lo, forKey: .min)
            try r.encodeIfPresent(hi, forKey: .max)
        }
    }
}

/// The recording kinds offered as cards (design board 9 · B).
public enum SpeakerPreset: String, CaseIterable, Identifiable, Sendable {
    case auto, solo, conversation, meeting

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .solo: "Solo"
        case .conversation: "Conversation"
        case .meeting: "Meeting"
        }
    }

    /// One line under the title: the count and examples.
    public var detail: String {
        switch self {
        case .auto: "Let LiteEcho decide"
        case .solo: "1 · voice memo, lecture"
        case .conversation: "2 · interview, call"
        case .meeting: "3–8 people"
        }
    }

    public var setting: SpeakerSetting {
        switch self {
        case .auto: .auto
        case .solo: .exactly(1)
        case .conversation: .exactly(2)
        case .meeting: .range(min: 3, max: 8)
        }
    }

    /// The preset whose setting this is; nil for a custom value.
    public init?(matching setting: SpeakerSetting) {
        guard let hit = Self.allCases.first(where: { $0.setting == setting.validated }) else { return nil }
        self = hit
    }
}

public struct JobOptions: Codable, Equatable, Sendable, Hashable {
    public var language: LanguageChoice
    public var speakers: SpeakerSetting
    /// nil = save next to the audio file.
    public var outputFolder: URL?

    public init(language: LanguageChoice = .auto, speakers: SpeakerSetting = .auto,
                outputFolder: URL? = nil) {
        self.language = language
        self.speakers = speakers
        self.outputFolder = outputFolder
    }
}

public enum JobState: Codable, Equatable, Sendable {
    case waiting
    /// `progress` is 0...1 within the current stage; `detail` e.g. "09:50 of 21:51".
    case running(stage: EngineStage, progress: Double, detail: String?)
    case done(output: URL, sampled: [SampledSpan])
    case failed(message: String)
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled: true
        case .waiting, .running: false
        }
    }
}

public struct Job: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var audio: URL
    public var options: JobOptions
    public var state: JobState
    public var addedAt: Date
    /// Language the engine detected (auto mode) or was given.
    public var detectedLanguage: String?
    /// Number of speakers the engine found (auto mode) or was given. nil until diarization ends.
    public var detectedSpeakers: Int?

    public init(id: UUID = UUID(), audio: URL, options: JobOptions, state: JobState = .waiting,
                addedAt: Date = Date(), detectedLanguage: String? = nil, detectedSpeakers: Int? = nil) {
        self.id = id
        self.audio = audio
        self.options = options
        self.state = state
        self.addedAt = addedAt
        self.detectedLanguage = detectedLanguage
        self.detectedSpeakers = detectedSpeakers
    }

    /// Where the engine will write the transcript.
    public var expectedOutput: URL {
        let folder = options.outputFolder ?? audio.deletingLastPathComponent()
        return folder.appendingPathComponent(audio.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("html")
    }
}

/// Builds engine command lines. Arguments only, never a shell string.
public enum EngineCommand {
    /// `whisperDir` / `pyannoteDir`: the model's own folder when the user keeps it outside
    /// LiteEcho's folder; the flags are added only when set.
    public static func transcribe(_ job: Job, whisperDir: URL? = nil, pyannoteDir: URL? = nil) -> [String] {
        var args = [job.audio.path,
                    "--language", job.options.language.code]
        args += job.options.speakers.cliArguments
        args += ["--events", "jsonl"]
        if let folder = job.options.outputFolder {
            args += ["--output-folder", folder.path]
        }
        return args + modelDirArguments(whisperDir: whisperDir, pyannoteDir: pyannoteDir)
    }

    /// `--whisper-dir` / `--pyannote-dir` for the ones that are set (never a shell string).
    public static func modelDirArguments(whisperDir: URL?, pyannoteDir: URL?) -> [String] {
        var args: [String] = []
        if let whisperDir { args += ["--whisper-dir", whisperDir.path] }
        if let pyannoteDir { args += ["--pyannote-dir", pyannoteDir.path] }
        return args
    }

    public static func fetchModels(only kind: String? = nil) -> [String] {
        var args = ["fetch-models", "--events", "jsonl"]
        if let kind { args += ["--only", kind] }
        return args
    }

    public static func engineInfo(verify: Bool = false, whisperDir: URL? = nil, pyannoteDir: URL? = nil) -> [String] {
        ["engine-info", "--json"] + (verify ? ["--verify"] : [])
            + modelDirArguments(whisperDir: whisperDir, pyannoteDir: pyannoteDir)
    }

    public static func renameSpeakers(file: URL, names: [String: String]) -> [String] {
        var args = ["rename-speakers", file.path]
        for key in names.keys.sorted() {
            if let value = names[key] { args += ["--map", "\(key)=\(value)"] }
        }
        return args
    }
}
