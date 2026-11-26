import Foundation

/// Output of `liteecho engine-info --json [--verify]`.
///
/// ```json
/// {"version":"0.1.0","python":"3.12.13",
///  "packages":{"faster-whisper":"1.2.1","pyannote.audio":"4.0.7"},
///  "models_dir":"/Users/x/Library/Application Support/LiteEcho/models",
///  "models":{"whisper":{"source":"cache","path":"/…","verified":true,"problems":[]},
///            "pyannote":{"source":"missing","path":null,"verified":null,"problems":["…"]}}}
/// ```
/// `source`: "custom" | "cache" | "missing". `verified` is null unless
/// `--verify` was passed (checksumming 1.6 GB takes a few seconds).
public struct EngineInfo: Codable, Equatable, Sendable {
    public struct Model: Codable, Equatable, Sendable {
        public var source: String
        public var path: String?
        public var verified: Bool?
        public var problems: [String]

        /// A custom folder that is incomplete reports problems even before `--verify`.
        public var isAvailable: Bool { source != "missing" && verified != false && problems.isEmpty }
    }

    public var version: String
    public var python: String
    public var packages: [String: String]
    public var modelsDir: String
    public var models: [String: Model]
    /// Languages the engine can transcribe (absent in older engines; see `LanguageCatalog.usable`).
    public var languages: [LanguageInfo]?

    enum CodingKeys: String, CodingKey {
        case version, python, packages, models, languages
        case modelsDir = "models_dir"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        python = try c.decode(String.self, forKey: .python)
        packages = try c.decode([String: String].self, forKey: .packages)
        modelsDir = try c.decode(String.self, forKey: .modelsDir)
        models = try c.decode([String: Model].self, forKey: .models)
        // A malformed list must not break the model checks; the picker falls back to its built-in list.
        languages = try? c.decodeIfPresent([LanguageInfo].self, forKey: .languages)
    }

    public var whisper: Model? { models["whisper"] }
    public var pyannote: Model? { models["pyannote"] }
    public var modelsReady: Bool { (whisper?.isAvailable ?? false) && (pyannote?.isAvailable ?? false) }

    public static func decode(_ data: Data) throws -> EngineInfo {
        try JSONDecoder().decode(EngineInfo.self, from: data)
    }
}
