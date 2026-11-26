import Foundation
import Testing
@testable import LiteEchoQueue

private func v1Sample(format: String = "1", speakerName2: String = "S2", extraMeta: String = "") -> String {
    """
    <!DOCTYPE html>
    <html lang="he" dir="rtl">
    <head>
    <meta charset="utf-8" />
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'" />
    <meta name="generator" content="LiteEcho 0.2.0" />
    <meta name="liteecho:format" content="\(format)" />
    <meta name="liteecho:audio" content="/audio/Q&amp;A sample.m4a" />
    <meta name="liteecho:language" content="he" />
    <meta name="liteecho:language-mode" content="auto" />
    <meta name="liteecho:speakers" content="2" />
    <meta name="liteecho:speakers-mode" content="range:2-4" />
    <meta name="liteecho:duration-ms" content="125000" />
    <meta name="liteecho:created" content="2026-01-02T03:04:05Z" />\(extraMeta)
    <title>Sample</title>
    <style>[data-speaker="S1"] { color: #1F5FAD; }</style>
    </head>
    <body>
    <header class="doc">
    <h1>Sample talk</h1>
    <p class="info">Sample.m4a · 02:05 · Hebrew · 2 speakers</p>
    <ul class="speakers">
    <li data-speaker="S1"><span class="speaker" data-speaker="S1">Dana</span></li>
    <li data-speaker="S2"><span class="speaker" data-speaker="S2">\(speakerName2)</span></li>
    </ul>
    </header>
    <main>
    <section class="turn" data-speaker="S2" data-start-ms="0" data-end-ms="4210">
    <h2><span class="speaker" data-speaker="S2">\(speakerName2)</span> <time data-ms="0">00:00:00</time></h2>
    <p>Fake text one. <span class="pause" data-ms="3100">(3 s pause)</span> More fake text.</p>
    </section>
    <section class="turn" data-speaker="S1" data-start-ms="5000" data-end-ms="9000">
    <h2><span class="speaker" data-speaker="S1">Dana</span> <time data-ms="5000">00:00:05</time></h2>
    <p>Fake text two.</p>
    </section>
    </main>
    <footer class="doc"><p>Transcribed with LiteEcho 0.2.0</p></footer>
    </body>
    </html>
    """
}

struct TranscriptDocumentTests {
    @Test func parsesV1MetaAndSpeakers() throws {
        let doc = try TranscriptDocument.parse(html: v1Sample(), title: "fallback")
        #expect(doc.format == "1")
        #expect(doc.title == "Sample talk")
        #expect(doc.audioPath == "/audio/Q&A sample.m4a")
        #expect(doc.language == "he" && doc.languageMode == "auto")
        #expect(doc.speakerCount == 2 && doc.speakersMode == "range:2-4")
        #expect(doc.durationMs == 125000)
        #expect(doc.created == "2026-01-02T03:04:05Z")
        #expect(doc.isRTL)
        // IDs in order of first appearance; names from the header list.
        #expect(doc.speakers == [TranscriptSpeaker(id: "S1", name: "Dana"), TranscriptSpeaker(id: "S2", name: "S2")])
    }

    @Test func renamedSpeakerShowsItsName() throws {
        let doc = try TranscriptDocument.parse(html: v1Sample(speakerName2: "Avi &amp; Co"), title: "t")
        #expect(doc.speakers.map(\.name) == ["Dana", "Avi & Co"])
        #expect(doc.speakers.map(\.id) == ["S1", "S2"])
    }

    @Test func rejectsOtherFormats() {
        #expect(throws: TranscriptParseError.unsupportedFormat("2")) {
            try TranscriptDocument.parse(html: v1Sample(format: "2"), title: "t")
        }
    }

    @Test func olderTranscriptsAreNotRenameable() {
        let old = "<html><head><meta name=\"audio_source\" content=\"/a.m4a\"></head><body><div class=WordSection1><p>x<br></p></div></body></html>"
        #expect(throws: TranscriptParseError.olderVersion) { try TranscriptDocument.parse(html: old, title: "t") }
        // Well-formed but without the format tag.
        let wellFormed = "<html><head><meta name=\"audio_source\" content=\"/a.m4a\" /></head><body></body></html>"
        #expect(throws: TranscriptParseError.olderVersion) { try TranscriptDocument.parse(html: wellFormed, title: "t") }
        #expect(TranscriptParseError.olderVersion.errorDescription?.contains("older versions") == true)
    }

    @Test func rejectsUnrelatedFiles() {
        #expect(throws: TranscriptParseError.notATranscript) {
            try TranscriptDocument.parse(html: "<html><body><p>hi</p></body></html>", title: "t")
        }
        #expect(throws: TranscriptParseError.notATranscript) { try TranscriptDocument.parse(html: "", title: "t") }
        // Claims the format but is not well-formed XML.
        #expect(throws: TranscriptParseError.notATranscript) {
            try TranscriptDocument.parse(html: "<html><meta name=\"liteecho:format\" content=\"1\"><p>", title: "t")
        }
    }

    @Test func loadsFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Meeting 1.html")
        try v1Sample().write(to: url, atomically: true, encoding: .utf8)
        #expect(try TranscriptDocument.load(from: url).speakers.count == 2)
        #expect(throws: TranscriptParseError.unreadable) {
            try TranscriptDocument.load(from: dir.appendingPathComponent("missing.html"))
        }
    }

    @Test func renamingLogicKeysByID() throws {
        let speakers = try TranscriptDocument.parse(html: v1Sample(), title: "t").speakers
        #expect(SpeakerRenaming.defaultFieldText(for: speakers[0]) == "Dana")
        #expect(SpeakerRenaming.defaultFieldText(for: speakers[1]) == "")
        #expect(SpeakerRenaming.changes(speakers: speakers, fields: [:]).isEmpty)
        let changes = SpeakerRenaming.changes(speakers: speakers, fields: ["S2": " Avi ", "S1": "Dana"])
        #expect(changes == ["S2": "Avi"])
        #expect(SpeakerRenaming.validationError(speakers: speakers, changes: changes) == nil)
        #expect(SpeakerRenaming.validationError(speakers: speakers, changes: ["S2": "Dana"]) != nil)
        #expect(SpeakerRenaming.validationError(speakers: speakers, changes: ["S2": String(repeating: "x", count: 61)]) != nil)
        #expect(SpeakerRenaming.validationError(speakers: speakers, changes: ["S2": "a\nb"]) != nil)
    }
}
