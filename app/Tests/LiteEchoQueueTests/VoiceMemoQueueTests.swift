import Foundation
import Testing
import LiteEchoCore
import LiteEchoShared
@testable import LiteEchoQueue

@MainActor
@Suite struct VoiceMemoQueueTests {
    private func memo(_ id: String, title: String = "Customer call", local: Bool = true) -> VoiceMemo {
        VoiceMemo(id: id, title: title, recorded: Date(timeIntervalSince1970: 1_764_000_000), durationSeconds: 90,
                  folderID: "w", local: local)
    }

    @Test func memoJobRunsTheImportCommandAndRemembersTheId() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let folder = fx.root.appendingPathComponent("out dir")
        let options = JobOptions(language: .he, speakers: .exactly(2), outputFolder: folder)
        let added = fx.store.addVoiceMemos([memo("ID-1")], folderNames: ["w": "Work"], options: options)
        #expect(added == 1)
        #expect(await waitUntil { fx.store.jobs.first.map { $0.state.isFinished } ?? false })
        let job = try #require(fx.store.jobs.first)
        guard case .done(let output, _) = job.state else { Issue.record("not done: \(job.state)"); return }
        #expect(output.lastPathComponent == "memo-out.html")
        #expect(job.voiceMemo?.folder == "Work" && job.displayName == "Customer call")
        #expect(fx.runs() == [["voice-memos", "import", "ID-1", "--language", "he", "--output-folder", folder.path,
                               "--speakers", "2", "--events", "jsonl"]])
        #expect(fx.store.durations[job.id] == 90)
        // Imported ids are remembered, also by a new store (a restart).
        #expect(fx.store.importedMemoIDs == ["ID-1"])
        #expect(fx.makeStore().importedMemoIDs == ["ID-1"])
        #expect(fx.makeStore().jobs.first?.voiceMemo?.id == "ID-1")
        // An imported memo is not added again.
        #expect(fx.store.addVoiceMemos([memo("ID-1")]) == 0)
        #expect(fx.store.jobs.count == 1)
    }

    @Test func failedMemoJobShowsAFriendlyMessageAndIsNotRemembered() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        fx.store.addVoiceMemos([memo("fail-1")])
        #expect(await waitUntil { fx.store.jobs.first.map { $0.state.isFinished } ?? false })
        guard case .failed(let message) = fx.store.jobs[0].state else { Issue.record("not failed"); return }
        #expect(message.contains("Voice Memos once"))
        #expect(fx.store.importedMemoIDs.isEmpty)
        // Failed jobs do not block a manual retry through the sheet, but count for auto-import.
        #expect(fx.store.queuedMemoIDs.isEmpty)
        #expect(fx.store.everQueuedMemoIDs == ["fail-1"])
    }

    @Test func addVoiceMemosSkipsCloudOnlyAndDuplicates() throws {
        let fx = try Fixture(paused: true)
        defer { fx.cleanup() }
        let added = fx.store.addVoiceMemos([memo("a"), memo("b", local: false), memo("a"), memo("c", title: "Other")])
        #expect(added == 2)
        #expect(fx.store.jobs.compactMap(\.voiceMemo?.id) == ["a", "c"])
        #expect(fx.store.queuedMemoIDs == ["a", "c"])
        #expect(fx.store.addVoiceMemos([memo("a")]) == 0)
    }

    @Test func memoRowSubtitleStartsWithTheRecordingDate() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 15))!
        let recorded = cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 10, minute: 42))!
        let job = Job.voiceMemo(VoiceMemoRef(id: "x", title: "T", recorded: recorded), options: JobOptions())
        let text = QueueFormat.subtitle(for: job, duration: 90, finishedIn: nil, now: now, calendar: cal)
        #expect(text == "Today, 10:42 · 1:30 · Auto language · speakers detected automatically · waiting")
        let plain = Job(audio: URL(fileURLWithPath: "/a/b.m4a"), options: JobOptions())
        #expect(QueueFormat.subtitle(for: plain, duration: nil, finishedIn: nil, now: now, calendar: cal)
                == "Auto language · speakers detected automatically · waiting")
        #expect(PendingConfirmation.remove(job).title.contains("“T”"))
    }

    @Test func autoImportEnqueuesOnlyNewMemos() async throws {
        let fx = try Fixture(paused: true)
        defer { fx.cleanup() }
        fx.model.settings.autoImportVoiceMemos = true
        let since = try #require(fx.model.settings.autoImportSince)
        let old = VoiceMemo(id: "old", title: "old", recorded: since.addingTimeInterval(-3600))
        let new = VoiceMemo(id: "new", title: "new", recorded: since.addingTimeInterval(60), folderID: "w")
        fx.model.voiceMemoLister = { VoiceMemoListing(status: .ok, folders: [VoiceMemoFolder(id: "w", name: "Work")],
                                                      memos: [old, new]) }
        fx.model.settings.defaultLanguage = .he
        fx.model.setupDismissed = true
        try Data().write(to: fx.paths.engineCompleteMarker)
        fx.store.startVoiceMemoAutoImport()
        #expect(await waitUntil { !fx.store.jobs.isEmpty })
        #expect(fx.store.jobs.compactMap(\.voiceMemo?.id) == ["new"])
        try #require(!fx.store.jobs.isEmpty)
        #expect(fx.store.jobs[0].voiceMemo?.folder == "Work")
        #expect(fx.store.jobs[0].options.language == .he)
    }
}
