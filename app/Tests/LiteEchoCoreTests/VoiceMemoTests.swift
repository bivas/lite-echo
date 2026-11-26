import Foundation
import Testing
@testable import LiteEchoCore

private let listJSON = #"""
{"status":"ok","detail":"","folders":[{"id":"f1","name":"Work"},{"id":"f2","name":"Ideas"}],
 "memos":[
  {"id":"A1","title":"Customer call","recorded":"2026-11-26T08:42:00Z","duration_s":1311.4,"folder_id":"f1",
   "favorite":true,"local":true,"apple_transcript":true,"format":"m4a"},
  {"id":"B2","title":"Idea","recorded":"2026-11-25T10:00:00.250Z","duration_s":20,"folder_id":null,
   "favorite":false,"local":false,"apple_transcript":false,"format":"qta"},
  {"id":"C3"},
  {"title":"no id"},
  {"id":"D4","title":"  ","recorded":"garbage","duration_s":-5}
 ]}
"""#

private func memo(_ id: String, _ title: String = "T", at hour: Int = 10, day: Int = 20, duration: TimeInterval = 60,
                  folder: String? = nil, local: Bool = true) -> VoiceMemo {
    var c = DateComponents(); c.year = 2026; c.month = 11; c.day = day; c.hour = hour
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    return VoiceMemo(id: id, title: title, recorded: cal.date(from: c)!, durationSeconds: duration,
                     folderID: folder, local: local)
}

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

// MARK: Decoding

@Test func listingDecodesAllFieldsAndToleratesMissingOnes() throws {
    let listing = try VoiceMemoListing.decode(Data(listJSON.utf8))
    #expect(listing.status == .ok)
    #expect(listing.folders.map(\.name) == ["Work", "Ideas"])
    // The entry without an id is dropped; the rest decode.
    #expect(listing.memos.map(\.id) == ["A1", "B2", "C3", "D4"])
    let a = listing.memos[0]
    #expect(a.title == "Customer call" && a.favorite && a.local && a.appleTranscript && a.format == "m4a")
    #expect(a.durationSeconds == 1311.4 && a.folderID == "f1")
    #expect(listing.folderName(for: a) == "Work")
    #expect(listing.memos[1].local == false && listing.memos[1].folderID == nil)
    #expect(listing.memos[1].recorded.timeIntervalSince1970 == 1_795_600_800.25)
    let bare = listing.memos[2]
    #expect(bare.title == "Voice Memo" && bare.local && !bare.favorite && !bare.appleTranscript)
    #expect(bare.durationSeconds == 0 && bare.recorded == .distantPast && bare.format == nil)
    let odd = listing.memos[3]
    #expect(odd.title == "Voice Memo" && odd.durationSeconds == 0 && odd.recorded == .distantPast)
}

@Test func listingDecodesEveryStatus() throws {
    for (raw, expected) in [("ok", VoiceMemoAccess.ok), ("no-access", .noAccess), ("no-library", .noLibrary),
                            ("unreadable", .unreadable), ("something-new", .unreadable)] {
        let listing = try VoiceMemoListing.decode(Data(#"{"status":"\#(raw)","detail":"why"}"#.utf8))
        #expect(listing.status == expected)
        #expect(listing.detail == "why" && listing.memos.isEmpty && listing.folders.isEmpty)
    }
    #expect(try VoiceMemoListing.decode(Data("{}".utf8)).status == .unreadable)
    #expect(throws: Error.self) { try VoiceMemoListing.decode(Data("not json".utf8)) }
}

// MARK: Search, filter, sort

@Test func visibleFiltersSearchesAndSorts() {
    let memos = [memo("1", "Customer call", day: 20, duration: 300, folder: "w"),
                 memo("2", "Élan idea", day: 22, duration: 30, folder: "i"),
                 memo("3", "Customer notes", day: 21, duration: 900, folder: "w"),
                 memo("4", "Zebra", day: 19, duration: 100),
                 memo("5", "Alpha 10", day: 18, duration: 5), memo("6", "Alpha 2", day: 17, duration: 5)]
    func ids(_ q: VoiceMemoQuery, imported: Set<String> = []) -> [String] {
        VoiceMemoCatalog.visible(memos, query: q, imported: imported).map(\.id)
    }
    #expect(ids(VoiceMemoQuery()) == ["2", "3", "1", "4", "5", "6"])
    #expect(ids(VoiceMemoQuery(sort: .oldest)) == ["6", "5", "4", "1", "3", "2"])
    #expect(ids(VoiceMemoQuery(sort: .longest)).prefix(3) == ["3", "1", "4"])
    #expect(ids(VoiceMemoQuery(sort: .title)) == ["6", "5", "1", "3", "2", "4"])
    #expect(ids(VoiceMemoQuery(search: "CUSTOMER")) == ["3", "1"])
    #expect(ids(VoiceMemoQuery(search: "elan")) == ["2"])
    #expect(ids(VoiceMemoQuery(search: "  zeb  ")) == ["4"])
    #expect(ids(VoiceMemoQuery(search: "nothing")).isEmpty)
    #expect(ids(VoiceMemoQuery(folderID: "w")) == ["3", "1"])
    #expect(ids(VoiceMemoQuery(search: "notes", folderID: "w")) == ["3"])
    // Already imported ones are hidden unless asked for.
    #expect(ids(VoiceMemoQuery(), imported: ["2", "4"]) == ["3", "1", "5", "6"])
    #expect(ids(VoiceMemoQuery(showAlreadyImported: true), imported: ["2"]).count == 6)
}

// MARK: Selection

@Test func selectionRules() {
    let local = memo("L"), cloud = memo("C", local: false), done = memo("I"), queued = memo("Q")
    let all = [local, cloud, done, queued]
    let imported: Set = ["I"], inQueue: Set = ["Q"]
    func a(_ m: VoiceMemo) -> VoiceMemoAvailability {
        VoiceMemoCatalog.availability(of: m, imported: imported, queued: inQueue)
    }
    #expect(a(local) == .available && a(cloud) == .notLocal && a(done) == .alreadyImported && a(queued) == .inQueue)
    #expect(a(local).isSelectable && a(local).isAddable)
    #expect(a(cloud).isSelectable && !a(cloud).isAddable)
    #expect(!a(done).isSelectable && !a(queued).isSelectable)
    // Imported wins over not local.
    #expect(VoiceMemoCatalog.availability(of: memo("X", local: false), imported: ["X"], queued: []) == .alreadyImported)
    let all4 = Set(all.map(\.id))
    #expect(VoiceMemoCatalog.addable(all, selected: all4, imported: imported, queued: inQueue).map(\.id) == ["L"])
    #expect(VoiceMemoCatalog.selectAll(all, imported: imported, queued: inQueue) == ["L"])
}

// MARK: Dates and text

@Test func relativeDates() {
    let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 15, minute: 0))!
    func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 10, _ min: Int = 42) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    func text(_ date: Date) -> String { VoiceMemoFormat.relativeDate(date, now: now, calendar: utc) }
    #expect(text(at(2026, 11, 26)) == "Today, 10:42")
    #expect(text(at(2026, 11, 26, 0, 5)) == "Today, 00:05")
    #expect(text(at(2026, 11, 25, 23, 59)) == "Yesterday")
    #expect(text(at(2026, 11, 24)) == "Tue 24 Nov")
    #expect(text(at(2025, 11, 24)) == "Mon 24 Nov 2025")
    // Midnight boundary: 00:10 today is today, 23:50 the day before is yesterday.
    let early = utc.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 0, minute: 10))!
    #expect(VoiceMemoFormat.relativeDate(utc.date(byAdding: .minute, value: -20, to: early)!, now: early, calendar: utc) == "Yesterday")
}

@Test func lengthsAndSubtitle() {
    #expect(VoiceMemoFormat.length(1311.4) == "21:51")
    #expect(VoiceMemoFormat.length(3725) == "1:02:05")
    #expect(VoiceMemoFormat.totalLength(45) == "45 s")
    #expect(VoiceMemoFormat.totalLength(720) == "12 min")
    #expect(VoiceMemoFormat.totalLength(3 * 3600 + 300) == "3 h 05 min")
    #expect(VoiceMemoFormat.subtitle(count: 1, selected: 0, total: 30) == "1 recording · 0 selected · 30 s")
    #expect(VoiceMemoFormat.subtitle(count: 12, selected: 3, total: 600) == "12 recordings · 3 selected · 10 min")
}

@Test func importErrorMessages() {
    #expect(VoiceMemoImportError.message(forCode: "no-access", fallback: "x").contains("Full Disk Access"))
    #expect(VoiceMemoImportError.message(forCode: "not-local", fallback: "x").contains("Voice Memos once"))
    #expect(VoiceMemoImportError.message(forCode: "not-found", fallback: "x").contains("no longer"))
    #expect(VoiceMemoImportError.message(forCode: "unreadable", fallback: "x") == "Couldn't read the Voice Memos library.")
    #expect(VoiceMemoImportError.message(forCode: "unsupported-format", fallback: "x").contains("format"))
    #expect(VoiceMemoImportError.message(forCode: nil, fallback: "raw") == "raw")
    #expect(VoiceMemoImportError.message(forCode: "weird", fallback: "raw") == "raw")
}

// MARK: Jobs

@Test func jobCodableIsBackwardCompatibleAndRoundTripsMemos() throws {
    // A queue entry saved before voice memos existed.
    let old = #"{"id":"6A1C4F2E-1111-4222-8333-444455556666","audio":"file:///a/b.m4a","options":{"language":{"code":"auto"},"speakers":{"auto":{}}},"state":{"waiting":{}},"addedAt":0}"#
    // The language shape may differ; build the legacy JSON from a current job without the key instead.
    let plain = Job(audio: URL(fileURLWithPath: "/a/b.m4a"), options: JobOptions())
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
    #expect(object["voiceMemo"] == nil)
    object["voiceMemo"] = nil
    let legacy = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy == plain && legacy.voiceMemo == nil && legacy.displayName == "b.m4a")
    _ = old

    let ref = VoiceMemoRef(id: "A1", title: "Customer call", recorded: Date(timeIntervalSince1970: 1_700_000_000),
                           folder: "Work", duration: 90)
    let job = Job.voiceMemo(ref, options: JobOptions(language: .he, speakers: .exactly(2)))
    let back = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job))
    #expect(back == job && back.voiceMemo == ref && back.displayName == "Customer call")
}

@Test func engineArgumentsForAMemoJob() {
    let ref = VoiceMemoRef(id: "A1-B2", title: "Customer call", recorded: Date(), folder: "Work")
    let folder = URL(fileURLWithPath: "/Users/me/My Transcripts")
    var job = Job.voiceMemo(ref, options: JobOptions(language: .he, speakers: .exactly(2), outputFolder: folder))
    let expected = ["voice-memos", "import", "A1-B2", "--language", "he", "--output-folder", "/Users/me/My Transcripts",
                    "--speakers", "2", "--events", "jsonl"]
    #expect(EngineCommand.transcribe(job) == expected)
    #expect(EngineCommand.voiceMemoImport(job) == expected)
    // Default folder: no flag; ranges and model folders follow the normal options.
    job.options = JobOptions(language: .auto, speakers: .range(min: 3, max: 8), outputFolder: nil)
    #expect(EngineCommand.transcribe(job, whisperDir: URL(fileURLWithPath: "/m/w")) ==
            ["voice-memos", "import", "A1-B2", "--language", "auto", "--min-speakers", "3", "--max-speakers", "8",
             "--events", "jsonl", "--whisper-dir", "/m/w"])
    #expect(EngineCommand.voiceMemoList() == ["voice-memos", "list", "--json"])
    // A normal job is unchanged.
    let plain = Job(audio: URL(fileURLWithPath: "/a/b.m4a"), options: JobOptions())
    #expect(EngineCommand.transcribe(plain).first == "/a/b.m4a")
}

// MARK: Imported ids

@Test func importedIDsPersist() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("memo-ids-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ImportedVoiceMemoStore(url: dir.appendingPathComponent("sub/imported.json"))
    #expect(store.load().isEmpty)
    store.insert("A")
    store.insert("B")
    store.insert("A")
    #expect(ImportedVoiceMemoStore(url: store.url).load() == ["A", "B"])
    // A damaged file counts as empty and does not crash.
    try Data("{{".utf8).write(to: store.url)
    #expect(store.load().isEmpty)
}

// MARK: Auto-import decisions and poller

private func listing(_ memos: [VoiceMemo], status: VoiceMemoAccess = .ok) -> VoiceMemoListing {
    VoiceMemoListing(status: status, folders: [VoiceMemoFolder(id: "w", name: "Work")], memos: memos)
}

@Test func autoImportDecisions() {
    let since = memo("S", day: 20, duration: 0).recorded
    let before = memo("before", at: 9, day: 20), after = memo("after", at: 11, day: 20, duration: 120, folder: "w")
    let exact = VoiceMemo(id: "exact", title: "t", recorded: since)
    let cloud = memo("cloud", day: 21, local: false)
    let imported = memo("imp", day: 21), queued = memo("que", day: 21), short = memo("short", day: 22, duration: 20)
    let all = listing([short, queued, imported, cloud, after, exact, before])
    func ids(_ policy: AutoImportPolicy) -> [String] {
        AutoImportDecision.memos(in: all, policy: policy, imported: ["imp"], queued: ["que"]).map(\.id)
    }
    let base = AutoImportPolicy(enabled: true, since: since)
    // Only after the moment, local, not imported, not queued; oldest first.
    #expect(ids(base) == ["after", "short"])
    #expect(ids(AutoImportPolicy(enabled: false, since: since)).isEmpty)
    #expect(ids(AutoImportPolicy(enabled: true, since: nil)).isEmpty)
    #expect(ids(AutoImportPolicy(enabled: true, since: since, folderID: "w")) == ["after"])
    #expect(ids(AutoImportPolicy(enabled: true, since: since, minimumLength: .thirtySeconds)) == ["after"])
    #expect(ids(AutoImportPolicy(enabled: true, since: since, minimumLength: .fiveMinutes)).isEmpty)
    // Nothing when the library is not readable.
    for status in [VoiceMemoAccess.noAccess, .noLibrary, .unreadable] {
        #expect(AutoImportDecision.memos(in: listing([after], status: status), policy: base, imported: [], queued: []).isEmpty)
    }
}

@MainActor
private final class PollerRig {
    var now = Date(timeIntervalSince1970: 1_000_000)
    var policy = AutoImportPolicy(enabled: true, since: Date(timeIntervalSince1970: 0))
    var imported: Set<String> = []
    var queued: Set<String> = []
    var canRun = true
    var answer = VoiceMemoListing(status: .ok)
    var listCalls = 0
    var enqueued: [[String]] = []
    lazy var importer = VoiceMemoAutoImporter(hooks: .init(
        lister: { [unowned self] in self.listCalls += 1; return self.answer },
        clock: { [unowned self] in self.now },
        policy: { [unowned self] in self.policy },
        importedIDs: { [unowned self] in self.imported },
        queuedIDs: { [unowned self] in self.queued },
        canRun: { [unowned self] in self.canRun },
        enqueue: { [unowned self] memos, _ in self.enqueued.append(memos.map(\.id)) }))
}

@MainActor @Test func pollerEnqueuesNewMemosOnce() async {
    let rig = PollerRig()
    let new = VoiceMemo(id: "new", title: "n", recorded: rig.now)
    rig.answer = listing([new])
    #expect(await rig.importer.poll().map(\.id) == ["new"])
    #expect(rig.enqueued == [["new"]])
    #expect(rig.importer.lastStatus == .ok)
    // Once it is queued (the store would have added it) it is not enqueued again.
    rig.queued = ["new"]
    rig.now.addTimeInterval(120)
    #expect(await rig.importer.poll().isEmpty)
    #expect(rig.enqueued.count == 1 && rig.listCalls == 2)
}

@MainActor @Test func pollerRespectsPolicyReadinessAndGap() async {
    let rig = PollerRig()
    rig.answer = listing([VoiceMemo(id: "m", title: "t", recorded: rig.now)])
    rig.policy.enabled = false
    #expect(await rig.importer.poll().isEmpty && rig.listCalls == 0)
    rig.policy.enabled = true
    rig.policy.since = nil
    #expect(await rig.importer.poll().isEmpty && rig.listCalls == 0)
    rig.policy.since = Date(timeIntervalSince1970: 0)
    rig.canRun = false
    #expect(await rig.importer.poll().isEmpty && rig.listCalls == 0)
    rig.canRun = true
    rig.imported = ["m"]
    #expect(await rig.importer.poll().isEmpty && rig.listCalls == 1)
    // Within the minimum gap a second poll is skipped unless forced; later ones run.
    rig.now.addTimeInterval(3)
    #expect(await rig.importer.poll().isEmpty && rig.listCalls == 1)
    rig.imported = []
    #expect(await rig.importer.poll(force: true).map(\.id) == ["m"] && rig.listCalls == 2)
    rig.imported = ["m"]
    rig.now.addTimeInterval(VoiceMemoAutoImporter.minimumGap + 1)
    _ = await rig.importer.poll()
    #expect(rig.listCalls == 3)
}

@MainActor @Test func pollerDoesNothingWhenAccessIsLost() async {
    let rig = PollerRig()
    rig.answer = VoiceMemoListing(status: .noAccess, detail: "denied", memos: [VoiceMemo(id: "m", title: "t", recorded: rig.now)])
    #expect(await rig.importer.poll().isEmpty)
    #expect(rig.importer.lastStatus == .noAccess && rig.enqueued.isEmpty)
}
