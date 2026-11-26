import AppKit
import AVFoundation
import Foundation
import LiteEchoCore
import LiteEchoShared
import Observation
import UniformTypeIdentifiers
import UserNotifications

/// The job queue: persistence, one-at-a-time execution, and the system integrations
/// (notifications, keep-awake, Dock badge).
@MainActor
@Observable
public final class QueueStore {
    public let model: AppModel
    public let storeURL: URL

    public private(set) var jobs: [Job] = []
    /// When true no new job starts; a job already running finishes.
    public var isPaused = false {
        didSet { if oldValue && !isPaused { pump() } }
    }
    /// Audio durations (seconds) read when a file is added. Not persisted.
    public private(set) var durations: [UUID: TimeInterval] = [:]
    /// Wall-clock time jobs took in this session. Not persisted.
    public private(set) var finishedIn: [UUID: TimeInterval] = [:]
    /// Jobs that reached done/failed since the menu bar menu was last opened. Not persisted.
    public private(set) var unseenFinishedCount = 0
    /// The failed subset of `unseenFinishedCount`.
    public private(set) var unseenFailedCount = 0
    /// When jobs finished in this session (for ordering "recently finished"). Not persisted.
    public private(set) var finishedAt: [UUID: Date] = [:]
    /// Called when a finished transcript should be shown ("Open the transcript" setting).
    /// Defaults to the default browser; only existing .html files are ever opened.
    @ObservationIgnored public var openTranscriptHandler: ((URL) -> Void)? = { TranscriptOpener.open($0) }

    private struct RunState {
        var done: (output: String?, sampled: [SampledSpan])?
        var errorMessage: String?
        var transcribeStart: Date?
        var baseline = 0.0
    }

    /// Ids of Voice Memos that were imported successfully (persisted).
    public private(set) var importedMemoIDs: Set<String> = []

    @ObservationIgnored private var currentJobID: UUID?
    @ObservationIgnored private var autoImporter: VoiceMemoAutoImporter?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var currentProcess: EngineProcess?
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var runState = RunState()
    @ObservationIgnored private var activity: NSObjectProtocol?

    public init(model: AppModel, storeURL: URL? = nil) {
        self.model = model
        self.storeURL = storeURL ?? model.paths.queueFile
        restore()
        importedMemoIDs = ImportedVoiceMemoStore(paths: model.paths).load()
        updateSystemState()
    }

    // MARK: Public API

    /// Adds audio/video files (others and duplicates of waiting/running jobs are ignored).
    public func add(_ urls: [URL]) {
        var added = false
        for url in urls {
            let std = url.standardizedFileURL
            guard Self.isMediaFile(std) else { continue }
            let duplicate = jobs.contains { job in
                (job.state == .waiting || isRunning(job.state))
                    && job.audio.standardizedFileURL.path == std.path
            }
            guard !duplicate else { continue }
            let job = Job(audio: std, options: model.settings.newJobOptions)
            jobs.append(job)
            loadDuration(for: job)
            added = true
        }
        guard added else { return }
        persist()
        pump()
    }

    /// Ids of memos with a waiting or running job.
    public var queuedMemoIDs: Set<String> {
        Set(jobs.compactMap { $0.state.isFinished ? nil : $0.voiceMemo?.id })
    }

    /// Ids of memos with a job in any state (also failed or cancelled ones).
    public var everQueuedMemoIDs: Set<String> { Set(jobs.compactMap { $0.voiceMemo?.id }) }

    /// Adds one job per memo (already imported, only-in-iCloud and already waiting ones are skipped).
    /// - Returns: how many jobs were added.
    @discardableResult
    public func addVoiceMemos(_ memos: [VoiceMemo], folderNames: [String: String] = [:],
                              options: JobOptions? = nil) -> Int {
        let options = options ?? model.settings.newVoiceMemoOptions
        var taken = queuedMemoIDs
        var added = 0
        for memo in memos where memo.local && !importedMemoIDs.contains(memo.id) && !taken.contains(memo.id) {
            taken.insert(memo.id)
            let ref = VoiceMemoRef(memo, folder: memo.folderID.flatMap { folderNames[$0] })
            let job = Job.voiceMemo(ref, options: options)
            jobs.append(job)
            loadDuration(for: job)
            added += 1
        }
        guard added > 0 else { return 0 }
        persist()
        pump()
        return added
    }

    /// Starts checking Voice Memos for new recordings every two minutes and when the app becomes
    /// active, if the user turned auto-import on. Safe to call more than once.
    public func startVoiceMemoAutoImport() {
        guard autoImporter == nil else { return }
        let importer = VoiceMemoAutoImporter(hooks: .init(
            lister: { [model] in await model.listVoiceMemos() },
            policy: { [model] in model.settings.autoImportPolicy },
            importedIDs: { [weak self] in self?.importedMemoIDs ?? [] },
            queuedIDs: { [weak self] in self?.everQueuedMemoIDs ?? [] },
            canRun: { [model] in model.isEngineInstalled && !model.needsSetup },
            enqueue: { [weak self] memos, listing in
                guard let self else { return }
                self.addVoiceMemos(memos, folderNames: listing.folderNames)
            }))
        autoImporter = importer
        importer.start()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak importer] _ in
            Task { @MainActor in importer?.appBecameActive() }
        }
        importer.appBecameActive()
    }

    /// Removes a job; a running one is cancelled first.
    public func remove(_ id: UUID) {
        if id == currentJobID { requestStop() }
        jobs.removeAll { $0.id == id }
        durations[id] = nil
        finishedIn[id] = nil
        finishedAt[id] = nil
        persist()
        updateSystemState()
    }

    /// Cancels a running (SIGTERM) or waiting job.
    public func cancel(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), !job.state.isFinished else { return }
        if id == currentJobID { requestStop() }
        mutate(id) { $0.state = .cancelled }
        persist()
        updateSystemState()
    }

    /// Puts a finished job back in the queue.
    public func retry(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.state.isFinished else { return }
        mutate(id) { $0.state = .waiting; $0.detectedLanguage = nil; $0.detectedSpeakers = nil }
        finishedIn[id] = nil
        persist()
        pump()
    }

    public func clearFinished() {
        let ids = jobs.filter { $0.state.isFinished }.map(\.id)
        jobs.removeAll { $0.state.isFinished }
        for id in ids { durations[id] = nil; finishedIn[id] = nil; finishedAt[id] = nil }
        persist()
        updateSystemState()
    }

    /// Un-pauses and starts the next waiting job. The app shell calls this once at launch.
    public func start() {
        if isPaused { isPaused = false } else { pump() }
    }

    /// Call when the models became ready again: jobs that were waiting for them start.
    public func modelsMayBeReady() { pump() }

    public func logURL(for id: UUID) -> URL {
        model.paths.logsDir.appendingPathComponent("\(id.uuidString).log")
    }

    /// Call when the menu bar menu is shown.
    public func markMenuSeen() {
        unseenFinishedCount = 0
        unseenFailedCount = 0
    }

    public var runningJob: Job? { jobs.first { isRunning($0.state) } }

    /// Done or failed jobs, newest first, at most `limit`.
    public func recentFinished(limit: Int = 5) -> [Job] {
        let finished = jobs.filter {
            switch $0.state {
            case .done, .failed: true
            default: false
            }
        }
        let sorted = finished.sorted {
            (finishedAt[$0.id] ?? $0.addedAt) > (finishedAt[$1.id] ?? $1.addedAt)
        }
        return Array(sorted.prefix(limit))
    }

    public var recentFinished: [Job] { recentFinished(limit: 5) }

    /// Unfinished jobs (waiting or running).
    public var unfinishedCount: Int { jobs.filter { !$0.state.isFinished }.count }

    // MARK: Media filter

    public nonisolated static func isMediaFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
        if values?.isDirectory == true { return false }
        guard let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }

    // MARK: Running

    private func isRunning(_ state: JobState) -> Bool {
        if case .running = state { return true }
        return false
    }

    private func mutate(_ id: UUID, _ body: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
    }

    private func pump() {
        // Jobs wait while the engine reports a model as missing (never an automatic download).
        // Without an answer yet (engineInfo nil) the engine itself decides.
        guard !isPaused, currentJobID == nil, model.engineInfo == nil || model.modelsReady,
              let job = jobs.first(where: { $0.state == .waiting }) else {
            updateSystemState()
            return
        }
        currentJobID = job.id
        cancelRequested = false
        runState = RunState()
        mutate(job.id) { $0.state = .running(stage: .convert, progress: 0, detail: nil); $0.detectedLanguage = nil; $0.detectedSpeakers = nil }
        persist()
        let process = model.makeEngineProcess(EngineCommand.transcribe(
            job, whisperDir: model.settings.whisperModelDir, pyannoteDir: model.settings.pyannoteModelDir))
        currentProcess = process
        updateSystemState()
        Task { await self.execute(job, process) }
    }

    /// SIGTERMs the running engine. `EngineProcess.cancel()` is a no-op until the process has
    /// actually launched, so a stop requested right after a job starts is repeated until it lands.
    private func requestStop() {
        cancelRequested = true
        guard let process = currentProcess else { return }
        process.cancel()
        Task { @MainActor [weak self] in
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.currentProcess === process else { return }
                process.cancel()
            }
        }
    }

    private func execute(_ job: Job, _ process: EngineProcess) async {
        let started = Date()
        let (stream, continuation) = AsyncStream<EngineEvent>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await event in stream { self?.handle(event, jobID: job.id) }
        }
        var result: EngineProcess.Result?
        var launchError: String?
        do {
            if cancelRequested { throw CancellationError() }
            result = try await process.run { continuation.yield($0) }
        } catch is CancellationError {
            // Stopped before the engine launched.
        } catch {
            launchError = error.localizedDescription
        }
        continuation.finish()
        await consumer.value
        finish(job, result: result, launchError: launchError, took: Date().timeIntervalSince(started))
    }

    private func handle(_ event: EngineEvent, jobID: UUID) {
        guard jobID == currentJobID else { return }
        switch event {
        case .stage(let stage, let completed, let total, let unit, _):
            let fraction = total > 0 ? min(1, max(0, completed / total)) : 0
            var detail: String?
            if stage == .transcribe, unit == "s" {
                let now = Date()
                if runState.transcribeStart == nil {
                    runState.transcribeStart = now
                    runState.baseline = completed
                }
                detail = QueueFormat.transcribeDetail(
                    completed: completed, total: total,
                    elapsed: now.timeIntervalSince(runState.transcribeStart ?? now),
                    baseline: runState.baseline)
            }
            guard !cancelRequested else { return }
            mutate(jobID) { $0.state = .running(stage: stage, progress: fraction, detail: detail) }
        case .speakers(let count):
            mutate(jobID) { $0.detectedSpeakers = count }
            persist()
        case .language(let code):
            mutate(jobID) { $0.detectedLanguage = code }
            persist()
        case .done(let output, let sampled):
            runState.done = (output, sampled)
        case .error(let message, let detail):
            let isMemo = jobs.first { $0.id == jobID }?.voiceMemo != nil
            runState.errorMessage = isMemo ? VoiceMemoImportError.message(forCode: detail, fallback: message) : message
        case .unknown:
            break
        }
    }

    private func finish(_ job: Job, result: EngineProcess.Result?, launchError: String?, took: TimeInterval) {
        let state = runState
        writeLog(for: job.id, text: launchError.map { "Could not start the engine: \($0)\n" } ?? result?.stderrTail ?? "")
        currentProcess = nil
        currentJobID = nil
        defer { pump() }
        guard let current = jobs.first(where: { $0.id == job.id }) else { return }

        var newState: JobState
        var notifyOutcome: Bool?
        if cancelRequested || result?.cancelled == true {
            newState = .cancelled
        } else if let launchError {
            newState = .failed(message: "Could not start the engine: \(launchError)")
            notifyOutcome = false
        } else if let result, result.exitCode == 0, let done = state.done {
            let output = done.output.map { URL(fileURLWithPath: $0) } ?? current.expectedOutput
            newState = .done(output: output, sampled: done.sampled)
            if let memo = current.voiceMemo {
                importedMemoIDs = ImportedVoiceMemoStore(paths: model.paths).insert(memo.id)
            }
            let language = current.detectedLanguage
                ?? (current.options.language.isAuto ? nil : current.options.language.code)
            try? TranscriptMetadataStore(paths: model.paths).save(
                TranscriptMetadata(audio: current.audio, sampled: done.sampled, language: language),
                for: output)
            notifyOutcome = true
        } else {
            let message = state.errorMessage
                ?? Self.lastLine(of: result?.stderrTail ?? "")
                ?? (result.map { $0.exitCode == 0 ? "The engine finished without writing a transcript."
                                                  : "The engine stopped unexpectedly (exit code \($0.exitCode))." }
                    ?? "The engine did not run.")
            newState = .failed(message: message)
            notifyOutcome = false
        }
        mutate(job.id) { $0.state = newState }
        finishedIn[job.id] = took
        finishedAt[job.id] = Date()
        switch newState {
        case .done: unseenFinishedCount += 1
        case .failed: unseenFinishedCount += 1; unseenFailedCount += 1
        default: break
        }
        persist()
        updateSystemState()

        if let ok = notifyOutcome {
            if model.settings.notifyWhenDone { postNotification(for: current, success: ok, state: newState) }
            if ok, model.settings.openWhenDone, case .done(let output, _) = newState {
                openTranscriptHandler?(output)
            }
        }
    }

    nonisolated static func lastLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    private func writeLog(for id: UUID, text: String) {
        let url = logURL(for: id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: Persistence

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: storeURL, options: .atomic)
        } catch {
            NSLog("LiteEcho: could not save the queue: \(error)")
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: storeURL),
              var restored = try? JSONDecoder().decode([Job].self, from: data) else { return }
        for index in restored.indices {
            if case .running = restored[index].state { restored[index].state = .waiting }
        }
        jobs = restored
        for job in restored { loadDuration(for: job) }
    }

    /// Snapshot hook only (LiteEchoSnapshots): shows the saved jobs as they are, including a job
    /// that was running, which `restore()` would put back to waiting. Starts nothing.
    public func showSavedJobsAsIsForSnapshots() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([Job].self, from: data) else { return }
        jobs = saved
        for job in saved { loadDuration(for: job) }
    }

    // MARK: Durations

    private func loadDuration(for job: Job) {
        if let memo = job.voiceMemo {
            if let seconds = memo.duration { durations[job.id] = seconds }
            return
        }
        let id = job.id, url = job.audio
        Task { [weak self] in
            let seconds = await Self.audioDuration(of: url)
            if let seconds { self?.durations[id] = seconds }
        }
    }

    private nonisolated static func audioDuration(of url: URL) async -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    // MARK: Keep awake, Dock badge, notifications

    private func updateSystemState() {
        let running = jobs.contains { isRunning($0.state) }
        if running, model.settings.keepAwake {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .userInitiated],
                    reason: "LiteEcho is transcribing")
            }
        } else if let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
        let count = unfinishedCount
        if let app = NSApp { app.dockTile.badgeLabel = count > 0 ? String(count) : nil }
    }

    /// True while a keep-awake assertion is held (for tests).
    public var isHoldingKeepAwake: Bool { activity != nil }

    private func postNotification(for job: Job, success: Bool, state: JobState) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let name = job.voiceMemo?.title ?? job.audio.deletingPathExtension().lastPathComponent
        var body = name
        if let seconds = durations[job.id] { body += " · \(QueueFormat.duration(seconds))" }
        // e.g. "Hebrew (detected) · 2 speakers (detected)", as in the menu bar mockup.
        let detected = QueueFormat.knownInfoParts(for: job, languages: model.languages).joined(separator: " · ")
        if case .failed(let message) = state { body = "\(name): \(message)" }
        let title = success ? "Transcript ready" : "Transcription failed"
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if success, !detected.isEmpty { content.subtitle = detected }
            let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
