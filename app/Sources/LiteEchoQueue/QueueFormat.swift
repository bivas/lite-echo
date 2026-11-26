import Foundation
import LiteEchoCore

/// Pure formatting helpers for the queue UI (kept free of UI so they are unit-testable).
public enum QueueFormat {
    /// "48:12", "1:02:05" (minutes not padded below an hour).
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Position inside the audio: "09:50", "1:02:05".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// "about 3 min left".
    public static func eta(remaining seconds: TimeInterval) -> String {
        if seconds < 30 { return "less than a minute left" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "about \(minutes) min left" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "about \(h) h left" : "about \(h) h \(m) min left"
    }

    /// "09:50 of 21:51 · about 3 min left". The estimate appears once 5% is done.
    /// - Parameters:
    ///   - elapsed: wall-clock seconds since the first transcribe event.
    ///   - baseline: `completed` at that first event.
    public static func transcribeDetail(completed: Double, total: Double, elapsed: TimeInterval,
                                        baseline: Double = 0) -> String? {
        guard total > 0 else { return nil }
        var text = "\(clock(min(completed, total))) of \(clock(total))"
        let advanced = completed - baseline
        if completed / total >= 0.05, elapsed > 0, advanced > 0 {
            let remaining = max(0, total - completed) * elapsed / advanced
            text += " · " + eta(remaining: remaining)
        }
        return text
    }

    /// English name of a language code, from the engine's list when given.
    public static func languageName(code: String, languages: [LanguageInfo] = []) -> String {
        LanguageCatalog.name(forCode: code, in: languages)
    }

    public static func speakersText(_ setting: SpeakerSetting) -> String {
        switch setting {
        case .auto: "speakers detected automatically"
        case .exactly, .range: setting.label
        }
    }

    public static func speakerCount(_ n: Int) -> String { n == 1 ? "1 speaker" : "\(n) speakers" }

    public static func finishedIn(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "finished in under a minute" : "finished in \(Int((seconds / 60).rounded())) min"
    }

    static func isRunning(_ job: Job) -> Bool {
        if case .running = job.state { return true }
        return false
    }

    /// "Hebrew (detected)", "Detecting language…", "Auto language" or the explicit language.
    public static func languagePart(for job: Job, languages: [LanguageInfo] = []) -> String {
        guard job.options.language.isAuto else { return languageName(code: job.options.language.code, languages: languages) }
        if let code = job.detectedLanguage, !code.isEmpty { return languageName(code: code, languages: languages) + " (detected)" }
        return isRunning(job) ? "Detecting language…" : "Auto language"
    }

    /// "2 speakers (detected)", "Detecting speakers…", "speakers detected automatically", "3 speakers",
    /// "Meeting → 5 speakers (detected)" or "Range 2–4 → 3 speakers (detected)".
    public static func speakersPart(for job: Job) -> String {
        switch job.options.speakers {
        case .auto:
            if let n = job.detectedSpeakers { return speakerCount(n) + " (detected)" }
            return isRunning(job) ? "Detecting speakers…" : speakersText(.auto)
        case .exactly:
            return speakersText(job.options.speakers)
        case .range:
            let label = job.options.speakers.label
            if let n = job.detectedSpeakers { return "\(label) → \(speakerCount(n)) (detected)" }
            return isRunning(job) ? "\(label) → detecting…" : label
        }
    }

    /// "48:12 · Hebrew (detected) · 2 speakers (detected) · finished in 14 min"
    public static func subtitle(for job: Job, duration: TimeInterval?, finishedIn took: TimeInterval?,
                                languages: [LanguageInfo] = []) -> String {
        var parts: [String] = []
        if let duration { parts.append(self.duration(duration)) }
        parts.append(languagePart(for: job, languages: languages))
        parts.append(speakersPart(for: job))
        switch job.state {
        case .waiting: parts.append("waiting")
        case .cancelled: parts.append("cancelled")
        case .done: if let took { parts.append(finishedIn(took)) }
        case .running, .failed: break
        }
        return parts.joined(separator: " · ")
    }

    /// Only the parts that are known (explicit or detected), or "Detecting…" notes while running.
    public static func knownInfoParts(for job: Job, languages: [LanguageInfo] = []) -> [String] {
        var parts: [String] = []
        if !job.options.language.isAuto || job.detectedLanguage != nil || isRunning(job) {
            parts.append(languagePart(for: job, languages: languages))
        }
        if job.options.speakers != .auto || job.detectedSpeakers != nil || isRunning(job) {
            parts.append(speakersPart(for: job))
        }
        return parts
    }

    /// Bottom status bar text.
    public static func statusBar(jobs: [Job], isPaused: Bool, languages: [LanguageInfo] = []) -> String {
        if let index = jobs.firstIndex(where: isRunning) {
            let job = jobs[index]
            let parts = ["Transcribing “\(job.audio.lastPathComponent)”", languagePart(for: job, languages: languages),
                         speakersPart(for: job), "\(index + 1) of \(jobs.count)"]
            return parts.joined(separator: " · ")
        }
        let waiting = jobs.filter { $0.state == .waiting }.count
        if isPaused { return waiting > 0 ? "Paused · \(waiting) waiting" : "Paused" }
        let done = jobs.filter { if case .done = $0.state { return true }; return false }.count
        if done > 0 { return done == 1 ? "1 file finished" : "\(done) files finished" }
        return "Idle"
    }

    /// Menu row subtitle: known info plus a relative time ("2 min ago"), if given.
    public static func menuSubtitle(for job: Job, ago: String?, languages: [LanguageInfo] = []) -> String {
        (knownInfoParts(for: job, languages: languages) + (ago.map { [$0] } ?? [])).joined(separator: " · ")
    }

    /// Overall progress of a running job, 0...1: convert 0-10%, speakers 10-30%, transcribe 30-100%.
    public static func overallProgress(stage: EngineStage, progress: Double) -> Double {
        let p = min(1, max(0, progress))
        switch stage {
        case .convert, .download: return 0.10 * p
        case .segmentation: return 0.10 + 0.20 * (p * 0.5)
        case .embeddings: return 0.10 + 0.20 * (0.5 + p * 0.5)
        case .transcribe: return 0.30 + 0.70 * p
        case .pauses: return 1
        }
    }

    public static func overallProgress(of state: JobState) -> Double? {
        if case .running(let stage, let progress, _) = state { return overallProgress(stage: stage, progress: progress) }
        return nil
    }

    public static func stageName(_ stage: EngineStage) -> String {
        switch stage {
        case .convert: "Converting audio"
        case .download: "Downloading models"
        case .segmentation, .embeddings: "Finding speakers"
        case .transcribe: "Transcribing"
        case .pauses: "Finishing"
        }
    }

    public enum MenuBarState: Equatable { case idle, running, unseenDone, failed }

    /// Failed beats running beats unseen finished beats idle.
    public static func menuBarState(isRunning: Bool, unseenFailed: Int, unseenFinished: Int) -> MenuBarState {
        if unseenFailed > 0 { return .failed }
        if isRunning { return .running }
        if unseenFinished > 0 { return .unseenDone }
        return .idle
    }

    public enum ColumnStatus: Equatable {
        case pending
        case active(Double)
        case done
    }

    public struct Column: Equatable {
        public var title: String
        public var status: ColumnStatus
        public var detail: String?
    }

    /// The three progress columns of a running row.
    public static func columns(stage: EngineStage, progress: Double, detail: String?) -> [Column] {
        let p = min(1, max(0, progress))
        var convert = ColumnStatus.pending, speakers = ColumnStatus.pending, transcribe = ColumnStatus.pending
        switch stage {
        case .convert, .download:
            convert = .active(p)
        case .segmentation:
            convert = .done; speakers = .active(p * 0.5)
        case .embeddings:
            convert = .done; speakers = .active(0.5 + p * 0.5)
        case .transcribe:
            convert = .done; speakers = .done; transcribe = .active(p)
        case .pauses:
            convert = .done; speakers = .done; transcribe = .done
        }
        return [
            Column(title: "Converting audio", status: convert, detail: nil),
            Column(title: "Finding speakers", status: speakers, detail: nil),
            Column(title: "Transcribing", status: transcribe, detail: stage == .transcribe ? detail : nil),
        ]
    }
}
