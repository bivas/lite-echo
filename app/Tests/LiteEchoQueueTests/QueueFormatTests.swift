import Foundation
import Testing
import LiteEchoCore
@testable import LiteEchoQueue

@Suite struct QueueFormatTests {
    @Test func durations() {
        #expect(QueueFormat.duration(48 * 60 + 12) == "48:12")
        #expect(QueueFormat.duration(3600 + 125) == "1:02:05")
        #expect(QueueFormat.clock(590) == "09:50")
        #expect(QueueFormat.clock(1311) == "21:51")
    }

    @Test func etaIsHiddenBelowFivePercent() {
        #expect(QueueFormat.transcribeDetail(completed: 40, total: 1311, elapsed: 20) == "00:40 of 21:51")
        #expect(QueueFormat.transcribeDetail(completed: 0, total: 0, elapsed: 0) == nil)
    }

    @Test func etaAppearsFromFivePercent() {
        // 590 s of 1311 s done in 150 s of wall time: 721 s left at 3.93x realtime = 183 s.
        #expect(QueueFormat.transcribeDetail(completed: 590, total: 1311, elapsed: 150)
                == "09:50 of 21:51 · about 3 min left")
        #expect(QueueFormat.transcribeDetail(completed: 100, total: 1000, elapsed: 10)
                == "01:40 of 16:40 · about 2 min left")
        #expect(QueueFormat.eta(remaining: 10) == "less than a minute left")
        #expect(QueueFormat.eta(remaining: 7200) == "about 2 h left")
        #expect(QueueFormat.eta(remaining: 5400 + 600) == "about 1 h 40 min left")
    }

    @Test func baselineIsSubtractedFromRate() {
        // Started at 500 s: 100 s advanced in 10 s, 800 s left → 80 s.
        #expect(QueueFormat.transcribeDetail(completed: 600, total: 1400, elapsed: 10, baseline: 500)?
            .hasSuffix("about 1 min left") == true)
    }

    @Test func subtitles() {
        let waiting = Job(audio: URL(fileURLWithPath: "/a/b.mp3"), options: JobOptions())
        #expect(QueueFormat.subtitle(for: waiting, duration: 3725, finishedIn: nil)
                == "1:02:05 · Auto language · speakers detected automatically · waiting")
        var done = Job(audio: URL(fileURLWithPath: "/a/b.mp3"),
                       options: JobOptions(language: .auto, speakers: .exactly(2)),
                       state: .done(output: URL(fileURLWithPath: "/a/b.html"), sampled: []),
                       detectedLanguage: "he")
        #expect(QueueFormat.subtitle(for: done, duration: 2892, finishedIn: 14 * 60)
                == "48:12 · Hebrew (detected) · 2 speakers · finished in 14 min")
        done.options.language = .en
        done.state = .cancelled
        #expect(QueueFormat.subtitle(for: done, duration: nil, finishedIn: nil)
                == "English · 2 speakers · cancelled")
    }

    @Test func columns() {
        let t = QueueFormat.columns(stage: .transcribe, progress: 0.45, detail: "x")
        #expect(t.map(\.status) == [.done, .done, .active(0.45)])
        #expect(t[2].detail == "x")
        let s = QueueFormat.columns(stage: .embeddings, progress: 0.5, detail: nil)
        #expect(s.map(\.status) == [.done, .active(0.75), .pending])
        let c = QueueFormat.columns(stage: .segmentation, progress: 1, detail: nil)
        #expect(c[1].status == .active(0.5))
        #expect(QueueFormat.columns(stage: .convert, progress: 0.2, detail: nil)[0].status == .active(0.2))
    }

    private func running(_ job: Job = Job(audio: URL(fileURLWithPath: "/a/Customer call.m4a"), options: JobOptions())) -> Job {
        var j = job
        j.state = .running(stage: .transcribe, progress: 0.5, detail: nil)
        return j
    }

    @Test func runningSubtitleShowsDetection() {
        var job = running()
        #expect(QueueFormat.subtitle(for: job, duration: 1311, finishedIn: nil)
                == "21:51 · Detecting language… · Detecting speakers…")
        job.detectedSpeakers = 2
        #expect(QueueFormat.subtitle(for: job, duration: 1311, finishedIn: nil)
                == "21:51 · Detecting language… · 2 speakers (detected)")
        job.detectedLanguage = "he"
        #expect(QueueFormat.subtitle(for: job, duration: 1311, finishedIn: nil)
                == "21:51 · Hebrew (detected) · 2 speakers (detected)")
        job.detectedSpeakers = 1
        #expect(QueueFormat.speakersPart(for: job) == "1 speaker (detected)")
    }

    @Test func explicitOptionsHaveNoDetectedMark() {
        let job = running(Job(audio: URL(fileURLWithPath: "/a/b.m4a"),
                              options: JobOptions(language: .en, speakers: .exactly(3)),
                              detectedLanguage: "en", detectedSpeakers: 3))
        #expect(QueueFormat.subtitle(for: job, duration: nil, finishedIn: nil) == "English · 3 speakers")
    }

    @Test func doneRowKeepsDetectedValues() {
        let job = Job(audio: URL(fileURLWithPath: "/a/b.m4a"), options: JobOptions(),
                      state: .done(output: URL(fileURLWithPath: "/a/b.html"), sampled: []),
                      detectedLanguage: "he", detectedSpeakers: 2)
        #expect(QueueFormat.subtitle(for: job, duration: 2892, finishedIn: 14 * 60)
                == "48:12 · Hebrew (detected) · 2 speakers (detected) · finished in 14 min")
    }

    @Test func languageNames() {
        #expect(QueueFormat.languageName(code: "he") == "Hebrew")
        #expect(QueueFormat.languageName(code: "en") == "English")
        #expect(!QueueFormat.languageName(code: "fr").isEmpty)
        #expect(QueueFormat.languageName(code: "zzzz-qq") .isEmpty == false)
    }

    @Test func statusBar() {
        var a = running()
        let b = Job(audio: URL(fileURLWithPath: "/a/b.m4a"), options: JobOptions())
        #expect(QueueFormat.statusBar(jobs: [a, b, b], isPaused: false)
                == "Transcribing “Customer call.m4a” · Detecting language… · Detecting speakers… · 1 of 3")
        a.detectedLanguage = "he"; a.detectedSpeakers = 2
        #expect(QueueFormat.statusBar(jobs: [a, b, b], isPaused: false)
                == "Transcribing “Customer call.m4a” · Hebrew (detected) · 2 speakers (detected) · 1 of 3")
        #expect(QueueFormat.statusBar(jobs: [], isPaused: false) == "Idle")
        #expect(QueueFormat.statusBar(jobs: [b], isPaused: true) == "Paused · 1 waiting")
        var done = b
        done.state = .done(output: URL(fileURLWithPath: "/a/b.html"), sampled: [])
        #expect(QueueFormat.statusBar(jobs: [done, done, done], isPaused: false) == "3 files finished")
    }

    @Test func overallProgressMapping() {
        #expect(QueueFormat.overallProgress(stage: .convert, progress: 1) == 0.10)
        #expect(abs(QueueFormat.overallProgress(stage: .segmentation, progress: 1) - 0.20) < 1e-9)
        #expect(abs(QueueFormat.overallProgress(stage: .embeddings, progress: 1) - 0.30) < 1e-9)
        #expect(QueueFormat.overallProgress(stage: .transcribe, progress: 0) == 0.30)
        #expect(QueueFormat.overallProgress(stage: .transcribe, progress: 1) == 1.0)
        #expect(QueueFormat.overallProgress(stage: .transcribe, progress: 5) == 1.0)
        #expect(QueueFormat.overallProgress(of: .waiting) == nil)
    }

    @Test func menuBarStatePrecedence() {
        typealias S = QueueFormat.MenuBarState
        #expect(QueueFormat.menuBarState(isRunning: false, unseenFailed: 0, unseenFinished: 0) == S.idle)
        #expect(QueueFormat.menuBarState(isRunning: true, unseenFailed: 0, unseenFinished: 2) == S.running)
        #expect(QueueFormat.menuBarState(isRunning: false, unseenFailed: 0, unseenFinished: 2) == S.unseenDone)
        #expect(QueueFormat.menuBarState(isRunning: true, unseenFailed: 1, unseenFinished: 1) == S.failed)
    }

    @Test func menuSubtitle() {
        let job = Job(audio: URL(fileURLWithPath: "/a/b.m4a"), options: JobOptions(),
                      state: .done(output: URL(fileURLWithPath: "/a/b.html"), sampled: []),
                      detectedLanguage: "he", detectedSpeakers: 2)
        #expect(QueueFormat.menuSubtitle(for: job, ago: "2 min ago")
                == "Hebrew (detected) · 2 speakers (detected) · 2 min ago")
    }

    @Test func rangeAndPresetDisplay() {
        var job = Job(audio: URL(fileURLWithPath: "/a/b.m4a"),
                      options: JobOptions(language: LanguageChoice(code: "fr"), speakers: .range(min: 2, max: 4)))
        let languages = [LanguageInfo(code: "fr", name: "French", native: "Français")]
        #expect(QueueFormat.speakersPart(for: job) == "Range 2–4")
        #expect(QueueFormat.subtitle(for: job, duration: nil, finishedIn: nil, languages: languages)
                == "French · Range 2–4 · waiting")
        job.detectedSpeakers = 3
        #expect(QueueFormat.speakersPart(for: job) == "Range 2–4 → 3 speakers (detected)")
        job.options.speakers = SpeakerPreset.meeting.setting
        job.detectedSpeakers = 5
        #expect(QueueFormat.speakersPart(for: job) == "Meeting → 5 speakers (detected)")
        job.detectedSpeakers = nil
        job.state = .running(stage: .embeddings, progress: 0.5, detail: nil)
        #expect(QueueFormat.speakersPart(for: job) == "Meeting → detecting…")
        #expect(QueueFormat.knownInfoParts(for: job, languages: languages) == ["French", "Meeting → detecting…"])
        #expect(QueueFormat.statusBar(jobs: [job], isPaused: false, languages: languages)
                == "Transcribing “b.m4a” · French · Meeting → detecting… · 1 of 1")
    }

    @Test func detectedLanguageUsesTheEngineName() {
        var job = Job(audio: URL(fileURLWithPath: "/a/b.m4a"), options: JobOptions(), detectedLanguage: "tr")
        let languages = [LanguageInfo(code: "tr", name: "Turkish", native: "Türkçe")]
        #expect(QueueFormat.languagePart(for: job, languages: languages) == "Turkish (detected)")
        job.options.language = LanguageChoice(code: "tr")
        #expect(QueueFormat.languagePart(for: job, languages: languages) == "Turkish")
    }
}
