import CryptoKit
import Foundation

/// Per-transcript facts the app learns while transcribing, kept in Application Support
/// (never next to the user's files). Written by the queue when a job finishes.
public struct TranscriptMetadata: Codable, Equatable, Sendable {
    public var audio: URL
    /// Spans whisper decoded by random sampling ("uncertain passages").
    public var sampled: [SampledSpan]
    public var language: String?
    public var finishedAt: Date

    public init(audio: URL, sampled: [SampledSpan], language: String?, finishedAt: Date = Date()) {
        self.audio = audio
        self.sampled = sampled
        self.language = language
        self.finishedAt = finishedAt
    }
}

public struct TranscriptMetadataStore: Sendable {
    public let directory: URL

    public init(paths: AppPaths) {
        directory = paths.supportDir.appendingPathComponent("transcripts", isDirectory: true)
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// File name derived from the transcript's absolute path (SHA-256), so any path is safe.
    public func fileURL(for transcript: URL) -> URL {
        let digest = SHA256.hash(data: Data(transcript.standardizedFileURL.path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    public func save(_ metadata: TranscriptMetadata, for transcript: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: fileURL(for: transcript), options: .atomic)
    }

    public func load(for transcript: URL) -> TranscriptMetadata? {
        guard let data = try? Data(contentsOf: fileURL(for: transcript)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TranscriptMetadata.self, from: data)
    }
}
