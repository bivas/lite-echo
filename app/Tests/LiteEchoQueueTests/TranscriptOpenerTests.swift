import Foundation
import Testing
@testable import LiteEchoQueue

@Suite struct TranscriptOpenerTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("opener-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func opensAnExistingHTMLFile() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("Meeting.html")
        try "<html></html>".write(to: file, atomically: true, encoding: .utf8)
        var opened: [URL] = []
        #expect(TranscriptOpener.open(file) { opened.append($0) })
        #expect(opened == [file])
        let upper = dir.appendingPathComponent("UPPER.HTML")
        try "x".write(to: upper, atomically: true, encoding: .utf8)
        #expect(TranscriptOpener.openableURL(upper) == upper)
    }

    @Test func refusesEverythingElse() throws {
        let dir = try makeDir()
        let text = dir.appendingPathComponent("notes.txt")
        try "x".write(to: text, atomically: true, encoding: .utf8)
        let app = dir.appendingPathComponent("Thing.html", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let refused = [
            text,                                                   // wrong extension
            dir.appendingPathComponent("missing.html"),             // does not exist
            app,                                                    // a directory named *.html
            URL(string: "https://example.com/page.html")!,          // not a file URL
            URL(string: "file:///etc/hosts")!,
        ]
        var opened: [URL] = []
        for url in refused {
            #expect(TranscriptOpener.openableURL(url) == nil)
            #expect(!TranscriptOpener.open(url) { opened.append($0) })
        }
        #expect(opened.isEmpty)
    }
}

@Suite struct SpeakerRenamingTests {
    private func sp(_ id: String, _ name: String? = nil) -> TranscriptSpeaker { TranscriptSpeaker(id: id, name: name ?? id) }

    @Test func unnamedSpeakersStartEmpty() {
        #expect(SpeakerRenaming.defaultFieldText(for: sp("S1")) == "")
        #expect(SpeakerRenaming.defaultFieldText(for: sp("S3", "Dana")) == "Dana")
    }

    @Test func changesAreOnlyEditedNonEmptyFieldsKeyedByID() {
        let changes = SpeakerRenaming.changes(speakers: [sp("S1"), sp("S2"), sp("S3", "Dana")],
                                              fields: ["S1": "  Alex ", "S3": "Dana"])
        #expect(changes == ["S1": "Alex"])
    }

    @Test func validation() {
        #expect(SpeakerRenaming.validationError(speakers: [sp("S1"), sp("S2")], changes: ["S1": "Alex"]) == nil)
        #expect(SpeakerRenaming.validationError(speakers: [sp("S1"), sp("S2", "Alex")], changes: ["S1": "Alex"]) != nil)
        #expect(SpeakerRenaming.validationError(speakers: [sp("S1")], changes: ["S1": "A\nB"]) != nil)
    }
}
