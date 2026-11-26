import Foundation
import Testing
import LiteEchoCore
import LiteEchoShared
@testable import LiteEchoQueue

@MainActor
@Suite struct QueueStoreTests {
    @Test func addFiltersAndDeduplicates() async throws {
        let fx = try Fixture(paused: true)
        defer { fx.cleanup() }
        let a = try fx.audio("a.m4a")
        let notes = try fx.audio("notes.txt")
        let video = try fx.audio("clip.mov")
        fx.model.settings.defaultLanguage = .he
        fx.model.settings.defaultSpeakers = .exactly(3)

        fx.store.add([a, notes, video, a, fx.audioDir])
        #expect(fx.store.jobs.map { $0.audio.lastPathComponent } == ["a.m4a", "clip.mov"])
        #expect(fx.store.jobs[0].options.language == .he)
        #expect(fx.store.jobs[0].options.speakers == .exactly(3))
        fx.store.add([a])
        #expect(fx.store.jobs.count == 2)
        #expect(fx.store.jobs.allSatisfy { $0.state == .waiting })
        #expect(QueueStore.isMediaFile(URL(fileURLWithPath: "/x/y.mp3")))
        #expect(!QueueStore.isMediaFile(URL(fileURLWithPath: "/x/y.pdf")))
    }

    @Test func successfulRunMapsToDoneAndSavesMetadata() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let a = try fx.audio("good.m4a")
        fx.store.add([a])
        #expect(await waitUntil { fx.store.isDone("good.m4a") })
        let job = try #require(fx.store.job(named: "good.m4a"))
        guard case .done(let output, let sampled) = job.state else { Issue.record("not done"); return }
        #expect(output.lastPathComponent == "good.html")
        #expect(sampled == [SampledSpan(startMs: 1000, endMs: 2000)])
        #expect(job.detectedLanguage == "he")
        #expect(job.detectedSpeakers == 2)
        // Persisted and restored.
        #expect(fx.makeStore().job(named: "good.m4a")?.detectedSpeakers == 2)
        let meta = try #require(TranscriptMetadataStore(paths: fx.paths).load(for: output))
        #expect(meta.sampled == sampled)
        #expect(meta.language == "he")
        #expect(meta.audio.path == a.standardizedFileURL.path)
        // The engine's stderr is kept in the job log.
        let log = try String(contentsOf: fx.store.logURL(for: job.id), encoding: .utf8)
        #expect(log.contains("progress log"))
        #expect(fx.store.finishedIn[job.id] != nil)
    }

    @Test func argvPassesPathsVerbatim() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        fx.model.settings.defaultLanguage = .en
        fx.model.settings.defaultSpeakers = .exactly(2)
        let out = fx.root.appendingPathComponent("out dir; rm -rf")
        fx.model.settings.outputMode = .customFolder
        fx.model.settings.customOutputFolder = out
        let a = try fx.audio("my file; echo hi $(x).m4a")
        fx.store.add([a])
        #expect(await waitUntil { fx.store.isDone("my file; echo hi $(x).m4a") })
        let args = try #require(fx.runs().first)
        #expect(args == [a.standardizedFileURL.path, "--language", "en", "--speakers", "2",
                         "--events", "jsonl", "--output-folder", out.path])
    }

    @Test func jobsRunOneAtATimeInOrder() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let urls = try ["one.m4a", "two.m4a", "three.m4a"].map { try fx.audio($0) }
        fx.store.add(urls)
        var maxRunning = 0
        let finished = await waitUntil {
            maxRunning = max(maxRunning, fx.store.jobs.filter { if case .running = $0.state { return true }; return false }.count)
            return fx.store.jobs.allSatisfy { $0.state.isFinished }
        }
        #expect(finished)
        #expect(maxRunning <= 1)
        let order = fx.runs().map { URL(fileURLWithPath: $0[0]).lastPathComponent }
        #expect(order == ["one.m4a", "two.m4a", "three.m4a"])
    }

    @Test func failureUsesErrorEventMessage() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        fx.store.add([try fx.audio("fail.m4a")])
        #expect(await waitUntil { fx.store.job(named: "fail.m4a")?.state.isFinished == true })
        #expect(fx.store.job(named: "fail.m4a")?.state == .failed(message: "Boom from engine"))
    }

    @Test func failureFallsBackToLastStderrLine() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        fx.store.add([try fx.audio("stderr.m4a")])
        #expect(await waitUntil { fx.store.job(named: "stderr.m4a")?.state.isFinished == true })
        #expect(fx.store.job(named: "stderr.m4a")?.state == .failed(message: "Last stderr line"))
        let id = try #require(fx.store.job(named: "stderr.m4a")?.id)
        let log = try String(contentsOf: fx.store.logURL(for: id), encoding: .utf8)
        #expect(log.contains("first line"))
    }

    @Test func cancelStopsProcessAndMarksCancelled() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        fx.store.add([try fx.audio("slow.m4a"), try fx.audio("next.m4a")])
        #expect(await waitUntil {
            if case .running(.transcribe, _, _) = fx.store.job(named: "slow.m4a")?.state { return true }
            return false
        })
        let pid = try #require(Int32(String(contentsOf: fx.pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let id = try #require(fx.store.job(named: "slow.m4a")?.id)
        fx.store.cancel(id)
        #expect(fx.store.job(named: "slow.m4a")?.state == .cancelled)
        #expect(await waitUntil { kill(pid, 0) != 0 })
        // The queue moves on to the next job.
        #expect(await waitUntil { fx.store.isDone("next.m4a") })
        #expect(fx.store.job(named: "slow.m4a")?.state == .cancelled)
    }

    @Test func removeRunningJobCancelsIt() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        fx.store.add([try fx.audio("slow.m4a")])
        #expect(await waitUntil { fx.store.isRunning("slow.m4a") })
        let id = try #require(fx.store.jobs.first?.id)
        fx.store.remove(id)
        #expect(fx.store.jobs.isEmpty)
        // A new job can run afterwards, so the slot was released.
        fx.store.add([try fx.audio("after.m4a")])
        #expect(await waitUntil { fx.store.isDone("after.m4a") })
    }

    @Test func pauseHoldsJobsAndStartResumes() async throws {
        let fx = try Fixture(paused: true)
        defer { fx.cleanup() }
        fx.store.add([try fx.audio("p1.m4a")])
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(fx.store.job(named: "p1.m4a")?.state == .waiting)
        #expect(fx.runs().isEmpty)
        fx.store.start()
        #expect(!fx.store.isPaused)
        #expect(await waitUntil { fx.store.isDone("p1.m4a") })
        // Toggling isPaused back off also resumes.
        fx.store.isPaused = true
        fx.store.add([try fx.audio("p2.m4a")])
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(fx.store.job(named: "p2.m4a")?.state == .waiting)
        fx.store.isPaused = false
        #expect(await waitUntil { fx.store.isDone("p2.m4a") })
    }

    @Test func persistenceRestoresAndTurnsRunningIntoWaiting() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        fx.store.add([try fx.audio("good.m4a")])
        #expect(await waitUntil { fx.store.isDone("good.m4a") })
        fx.store.add([try fx.audio("slow.m4a"), try fx.audio("later.m4a")])
        #expect(await waitUntil { fx.store.isRunning("slow.m4a") })

        let restored = fx.makeStore()   // simulates a relaunch while "slow" was running
        #expect(restored.jobs.map { $0.audio.lastPathComponent } == ["good.m4a", "slow.m4a", "later.m4a"])
        #expect(restored.isDone("good.m4a"))
        #expect(restored.job(named: "slow.m4a")?.state == .waiting)
        #expect(restored.job(named: "later.m4a")?.state == .waiting)
        #expect(restored.job(named: "good.m4a")?.detectedLanguage == "he")
        #expect(FileManager.default.fileExists(atPath: fx.paths.queueFile.path))

        fx.store.cancel(try #require(fx.store.job(named: "slow.m4a")?.id))
        #expect(await waitUntil { fx.store.isDone("later.m4a") })
    }

    @Test func retryRequeuesFailedAndCancelled() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        fx.store.add([try fx.audio("fail.m4a")])
        #expect(await waitUntil { fx.store.job(named: "fail.m4a")?.state.isFinished == true })
        fx.store.isPaused = true
        let id = try #require(fx.store.jobs.first?.id)
        fx.store.retry(id)
        #expect(fx.store.jobs.first?.state == .waiting)
        fx.store.retry(id)   // not finished any more: no-op
        #expect(fx.store.jobs.first?.state == .waiting)
        fx.store.isPaused = false
        #expect(await waitUntil { fx.store.jobs.first?.state == .failed(message: "Boom from engine") })
        #expect(fx.runs().count == 2)

        fx.store.add([try fx.audio("w.m4a")])
        #expect(await waitUntil { fx.store.isDone("w.m4a") })
        let wid = try #require(fx.store.job(named: "w.m4a")?.id)
        fx.store.isPaused = true
        fx.store.add([try fx.audio("c.m4a")])
        let cid = try #require(fx.store.job(named: "c.m4a")?.id)
        fx.store.cancel(cid)
        #expect(fx.store.job(named: "c.m4a")?.state == .cancelled)
        fx.store.retry(cid)
        #expect(fx.store.job(named: "c.m4a")?.state == .waiting)
        _ = wid
    }

    @Test func clearFinishedKeepsWaiting() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        fx.store.add([try fx.audio("good.m4a"), try fx.audio("fail.m4a")])
        #expect(await waitUntil { fx.store.jobs.allSatisfy { $0.state.isFinished } })
        fx.store.isPaused = true
        fx.store.add([try fx.audio("waiting.m4a")])
        fx.store.clearFinished()
        #expect(fx.store.jobs.map { $0.audio.lastPathComponent } == ["waiting.m4a"])
        #expect(fx.store.unfinishedCount == 1)
        let reloaded = fx.makeStore()
        #expect(reloaded.jobs.count == 1)
    }

    @Test func keepAwakeIsHeldOnlyWhileRunning() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        fx.model.settings.keepAwake = true
        fx.store.add([try fx.audio("slow.m4a")])
        #expect(await waitUntil { fx.store.isRunning("slow.m4a") })
        #expect(fx.store.isHoldingKeepAwake)
        fx.store.cancel(try #require(fx.store.jobs.first?.id))
        #expect(await waitUntil { !fx.store.isHoldingKeepAwake })
    }

    @Test func unseenCountersTrackDoneAndFailedNotCancel() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        fx.store.add([try fx.audio("good.m4a"), try fx.audio("fail.m4a")])
        #expect(await waitUntil { fx.store.jobs.allSatisfy { $0.state.isFinished } })
        #expect(fx.store.unseenFinishedCount == 2)
        #expect(fx.store.unseenFailedCount == 1)
        #expect(fx.store.recentFinished.count == 2)
        fx.store.markMenuSeen()
        #expect(fx.store.unseenFinishedCount == 0 && fx.store.unseenFailedCount == 0)

        fx.store.isPaused = true
        fx.store.add([try fx.audio("later.m4a")])
        let id = try #require(fx.store.job(named: "later.m4a")?.id)
        fx.store.cancel(id)
        #expect(fx.store.unseenFinishedCount == 0)
        #expect(fx.store.runningJob == nil)
    }
}
