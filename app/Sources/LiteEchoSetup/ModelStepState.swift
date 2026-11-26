import Foundation
import LiteEchoCore

/// Where one model stands, derived from `engine-info`.
public enum ModelAvailability: Equatable, Sendable {
    case ready(source: String)
    /// Files exist but verification failed (incomplete or corrupt download).
    case needsRepair(problems: [String])
    case missing

    public init(_ model: EngineInfo.Model?) {
        guard let model, model.source != "missing" else { self = .missing; return }
        if model.verified == false { self = .needsRepair(problems: model.problems); return }
        // A chosen folder that no longer holds the files: the model is missing, not "ready".
        if !model.problems.isEmpty && model.verified != true { self = .missing; return }
        self = .ready(source: model.source)
    }

    public var isReady: Bool { if case .ready = self { true } else { false } }
}

/// What the models step shows, as a pure function of the engine info.
public struct ModelStepState: Equatable, Sendable {
    public var whisper: ModelAvailability
    public var pyannote: ModelAvailability
    public var canContinue: Bool

    public init(info: EngineInfo?) {
        whisper = ModelAvailability(info?.whisper)
        pyannote = ModelAvailability(info?.pyannote)
        canContinue = whisper.isReady && pyannote.isReady
    }
}

/// Human labels for the `source` field of a model.
public func modelSourceLabel(_ model: EngineInfo.Model?) -> String {
    guard let model else { return "Missing" }
    switch model.source {
    case "cache": return "Downloaded"
    case "custom": return "Custom folder"
    default: return "Missing"
    }
}

/// Byte progress of a download, with a time estimate.
public struct DownloadProgress: Equatable, Sendable {
    public var completed: Double
    public var total: Double
    public var elapsed: TimeInterval

    public init(completed: Double, total: Double, elapsed: TimeInterval) {
        self.completed = completed
        self.total = total
        self.elapsed = elapsed
    }

    public var fraction: Double { total > 0 ? min(1, max(0, completed / total)) : 0 }
    public var percent: Int { Int((fraction * 100).rounded()) }

    public var remaining: TimeInterval? {
        guard completed > 0, total > completed, elapsed >= 3 else { return nil }
        return elapsed / completed * (total - completed)
    }

    static func bytes(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(value))
    }

    public static func etaText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 90 { return "about \(minutes) min left" }
        return "about \(minutes / 60) h \(minutes % 60) min left"
    }

    /// "1.0 GB of 1.6 GB · about 2 min left"
    public var summary: String {
        var text = "\(Self.bytes(completed)) of \(Self.bytes(total))"
        if let remaining { text += " · \(Self.etaText(remaining))" }
        return text
    }
}

/// Turns raw engine/Hugging Face errors into something a person can act on.
public func friendlyDownloadError(_ message: String, kind: String, token: String? = nil) -> String {
    var text = message
    if let token, !token.isEmpty { text = text.replacingOccurrences(of: token, with: "…") }
    let lower = text.lowercased()
    let authMarkers = ["401", "403", "gated", "unauthorized", "forbidden", "access to model", "restricted", "accept"]
    if kind == "pyannote", authMarkers.contains(where: { lower.contains($0) }) {
        return "Hugging Face refused access. Open the model page, sign in and accept its terms, "
            + "check that the token has read access, then try again.\n\n\(text)"
    }
    return text
}

/// True when an error message means the token (not the network) was the problem.
func isAuthError(_ message: String) -> Bool {
    let lower = message.lowercased()
    return ["401", "403", "gated", "unauthorized", "forbidden"].contains { lower.contains($0) }
}
