import Foundation
import Testing
@testable import LiteEchoCore

@Test func parsesStage() {
    let e = EngineEvent.parse(line: #"{"type":"stage","stage":"transcribe","completed":590.5,"total":1311,"unit":"s"}"#)
    #expect(e == .stage(.transcribe, completed: 590.5, total: 1311, unit: "s", kind: nil))
}

@Test func parsesDoneWithSampled() {
    let e = EngineEvent.parse(line: #"{"type":"done","output":"/x/a.html","sampled":[{"start_ms":1,"end_ms":2}]}"#)
    #expect(e == .done(output: "/x/a.html", sampled: [SampledSpan(startMs: 1, endMs: 2)]))
}

@Test func ignoresNoiseAndUnknownTypes() {
    #expect(EngineEvent.parse(line: "") == nil)
    #expect(EngineEvent.parse(line: "Converting audio...") == nil)
    #expect(EngineEvent.parse(line: "{not json") == nil)
    #expect(EngineEvent.parse(line: #"{"type":"future"}"#) == .unknown(type: "future"))
}

@Test func lineBufferKeepsPartialLines() {
    var buffer = LineBuffer()
    #expect(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)) == ["{\"a\":1}"])
    #expect(buffer.append(Data(":2}\n".utf8)) == ["{\"b\":2}"])
    #expect(buffer.append(Data("tail".utf8)) == [])
    #expect(buffer.flush() == "tail")
}

@Test func transcribeCommandUsesArgumentsOnly() {
    let job = Job(audio: URL(fileURLWithPath: "/a b/x;rm -rf ~.m4a"),
                  options: JobOptions(language: .he, speakers: .exactly(2),
                                      outputFolder: URL(fileURLWithPath: "/out")))
    #expect(EngineCommand.transcribe(job) == ["/a b/x;rm -rf ~.m4a", "--language", "he", "--speakers", "2",
                                              "--events", "jsonl", "--output-folder", "/out"])
    #expect(job.expectedOutput.path == "/out/x;rm -rf ~.html")
}

@Test func engineProcessStreamsEventsAndExitCode() async throws {
    let script = #"printf '{"type":"language","code":"he"}\nnoise\n{"type":"done","output":"/o.html"}'; echo err >&2; exit 3"#
    let process = EngineProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    let collected = Collected()
    let result = try await process.run { collected.add($0) }
    #expect(result.exitCode == 3)
    #expect(result.stderrTail.contains("err"))
    #expect(collected.events == [.language(code: "he"), .done(output: "/o.html", sampled: [])])
}

@Test func engineProcessCancel() async throws {
    let process = EngineProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
    Task { try? await Task.sleep(nanoseconds: 200_000_000); process.cancel() }
    let result = try await process.run { _ in }
    #expect(result.cancelled)
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [EngineEvent] = []
    func add(_ e: EngineEvent) { lock.lock(); items.append(e); lock.unlock() }
    var events: [EngineEvent] { lock.lock(); defer { lock.unlock() }; return items }
}

@Test func metadataStoreRoundTripsAndHashesPaths() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = TranscriptMetadataStore(directory: dir)
    let transcript = URL(fileURLWithPath: "/x/../evil/a b.html")
    #expect(store.fileURL(for: transcript).deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path)
    let meta = TranscriptMetadata(audio: URL(fileURLWithPath: "/a.m4a"),
                                  sampled: [SampledSpan(startMs: 5, endMs: 9)], language: "he",
                                  finishedAt: Date(timeIntervalSince1970: 0))
    try store.save(meta, for: transcript)
    #expect(store.load(for: transcript) == meta)
    #expect(store.load(for: URL(fileURLWithPath: "/other.html")) == nil)
    try? FileManager.default.removeItem(at: dir)
}

@Test func engineInstalledNeedsMarkerOrSymlink() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let paths = AppPaths(supportDir: root, bundleResources: nil)
    try fm.createDirectory(at: paths.engineBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\n".write(to: paths.engineBinary, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.engineBinary.path)
    #expect(!paths.isEngineInstalled)               // binary only: half-finished install
    try Data().write(to: paths.engineCompleteMarker)
    #expect(paths.isEngineInstalled)
    // A symlinked existing engine counts without a marker.
    let other = AppPaths(supportDir: root.appendingPathComponent("other"), bundleResources: nil)
    try fm.createDirectory(at: other.supportDir, withIntermediateDirectories: true)
    try fm.removeItem(at: paths.engineCompleteMarker)
    try fm.createSymbolicLink(at: other.engineDir, withDestinationURL: paths.engineDir)
    #expect(other.isEngineInstalled)
    try? fm.removeItem(at: root)
}

@Test func cancelBeforeLaunchStillStopsTheProcess() async throws {
    let process = EngineProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
    process.cancel()
    let started = Date()
    let result = try await process.run { _ in }
    #expect(result.cancelled)
    #expect(Date().timeIntervalSince(started) < 5)
}

@Test func parsesSpeakersAndOldQueuesStillDecode() throws {
    #expect(EngineEvent.parse(line: #"{"type":"speakers","count":2}"#) == .speakers(count: 2))
    // A job saved before detectedSpeakers existed still decodes.
    let job = Job(audio: URL(fileURLWithPath: "/a.m4a"), options: JobOptions())
    var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
    dict.removeValue(forKey: "detectedSpeakers")
    let old = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: dict))
    #expect(old.detectedSpeakers == nil)
}

@Test func modelDirFlagsAreAddedOnlyWhenSet() {
    let job = Job(audio: URL(fileURLWithPath: "/a.m4a"), options: JobOptions())
    let base = EngineCommand.transcribe(job)
    #expect(!base.contains("--whisper-dir") && !base.contains("--pyannote-dir"))
    #expect(EngineCommand.transcribe(job, whisperDir: URL(fileURLWithPath: "/m/My Whisper; rm -rf x")) ==
            base + ["--whisper-dir", "/m/My Whisper; rm -rf x"])
    #expect(EngineCommand.transcribe(job, pyannoteDir: URL(fileURLWithPath: "/p")) == base + ["--pyannote-dir", "/p"])
    #expect(EngineCommand.transcribe(job, whisperDir: URL(fileURLWithPath: "/w"), pyannoteDir: URL(fileURLWithPath: "/p"))
            == base + ["--whisper-dir", "/w", "--pyannote-dir", "/p"])

    #expect(EngineCommand.engineInfo() == ["engine-info", "--json"])
    #expect(EngineCommand.engineInfo(verify: true) == ["engine-info", "--json", "--verify"])
    #expect(EngineCommand.engineInfo(verify: true, whisperDir: URL(fileURLWithPath: "/w"))
            == ["engine-info", "--json", "--verify", "--whisper-dir", "/w"])
    #expect(EngineCommand.engineInfo(pyannoteDir: URL(fileURLWithPath: "/p"))
            == ["engine-info", "--json", "--pyannote-dir", "/p"])
}
