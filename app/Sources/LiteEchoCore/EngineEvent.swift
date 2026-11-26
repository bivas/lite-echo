import Foundation

/// Pipeline stages reported by `liteecho ... --events jsonl` (see docs/macos-app-plan.md).
public enum EngineStage: String, Codable, Sendable, CaseIterable {
    case convert, segmentation, embeddings, transcribe, pauses, download
}

/// A span of the transcript whisper decoded by random sampling ("uncertain passage").
public struct SampledSpan: Codable, Equatable, Sendable, Hashable {
    public var startMs: Int
    public var endMs: Int

    public init(startMs: Int, endMs: Int) {
        self.startMs = startMs
        self.endMs = endMs
    }

    enum CodingKeys: String, CodingKey {
        case startMs = "start_ms"
        case endMs = "end_ms"
    }
}

/// One line of the engine's JSONL event stream on stdout.
///
/// Wire format (one JSON object per line):
/// - `{"type":"stage","stage":"transcribe","completed":590.2,"total":1311.5,"unit":"s"}`
///   (`unit`: "s" for audio seconds, "steps" for pyannote steps, "bytes" for downloads;
///   `kind` is set for downloads: "whisper" | "pyannote")
/// - `{"type":"speakers","count":2}` (right after diarization; the detected number when
///   speakers are on auto, otherwise the requested number)
/// - `{"type":"language","code":"he"}` (after transcription: detected or given)
/// - `{"type":"done","output":"/path/file.html","sampled":[{"start_ms":1,"end_ms":2}]}`
///   (for `fetch-models`: `{"type":"done"}` with no output)
/// - `{"type":"error","message":"...","detail":"traceback or null"}`
public enum EngineEvent: Equatable, Sendable {
    case stage(EngineStage, completed: Double, total: Double, unit: String, kind: String?)
    case speakers(count: Int)
    case language(code: String)
    case done(output: String?, sampled: [SampledSpan])
    case error(message: String, detail: String?)
    /// A well-formed event of a type this app version does not know. Ignore it.
    case unknown(type: String)

    private struct Wire: Decodable {
        var type: String
        var stage: String?
        var completed: Double?
        var total: Double?
        var unit: String?
        var kind: String?
        var code: String?
        var count: Int?
        var output: String?
        var sampled: [SampledSpan]?
        var message: String?
        var detail: String?
    }

    /// Parses one stdout line. Returns nil for blank lines and anything that is not a JSON
    /// event object (the engine may print stray text; it must never crash the app).
    public static func parse(line: String) -> EngineEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        switch wire.type {
        case "stage":
            guard let raw = wire.stage, let stage = EngineStage(rawValue: raw) else {
                return .unknown(type: "stage:\(wire.stage ?? "")")
            }
            return .stage(stage, completed: wire.completed ?? 0, total: wire.total ?? 0,
                          unit: wire.unit ?? "", kind: wire.kind)
        case "speakers":
            return .speakers(count: wire.count ?? 0)
        case "language":
            return .language(code: wire.code ?? "")
        case "done":
            return .done(output: wire.output, sampled: wire.sampled ?? [])
        case "error":
            return .error(message: wire.message ?? "Unknown error", detail: wire.detail)
        default:
            return .unknown(type: wire.type)
        }
    }
}

/// Splits a byte stream into lines for `EngineEvent.parse`, keeping a partial last line.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    /// Appends a chunk and returns the complete lines it finished (without the newline).
    public mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    /// Returns whatever is left once the stream has ended.
    public mutating func flush() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}
