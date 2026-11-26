import Foundation

/// Colours for speakers by order of first appearance (all pass WCAG AA on white).
public enum SpeakerPalette {
    public static let hexColors = ["#1F5FAD", "#A04F00", "#1B7A3A", "#8B3A9E", "#B3261E", "#00707A", "#6B5B00", "#5A5AB8"]

    public static func hex(forIndex index: Int) -> String {
        hexColors[((index % hexColors.count) + hexColors.count) % hexColors.count]
    }
}

public enum TranscriptParseError: Error, Equatable, LocalizedError {
    case unreadable
    case notATranscript
    /// A LiteEcho transcript written before the v1 format (no `liteecho:format` meta tag).
    case olderVersion
    /// A `liteecho:format` this app does not know.
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The file could not be read."
        case .notATranscript: "This file is not a LiteEcho transcript."
        case .olderVersion: "Renaming speakers isn't available for transcripts from older versions of LiteEcho."
        case .unsupportedFormat: "This transcript was made by a newer version of LiteEcho. Update the app to rename its speakers."
        }
    }
}

public struct TranscriptSpeaker: Equatable, Sendable, Identifiable {
    /// Stable ID ("S1", "S2", ...). Never changes; used as the key when renaming.
    public let id: String
    /// The name shown in the transcript (the ID until the speaker is renamed).
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The parts of a v1 transcript the app needs (see docs/transcript-format.md): the
/// `liteecho:*` meta tags and the speakers. The body text is never read.
public struct TranscriptDocument: Equatable, Sendable {
    public static let supportedFormat = "1"

    public let title: String
    public let format: String
    public let audioPath: String?
    /// Detected or chosen language code (`liteecho:language`), falling back to `<html lang>`.
    public let language: String?
    public let languageMode: String?
    public let speakerCount: Int?
    public let speakersMode: String?
    public let durationMs: Int?
    public let created: String?
    public let isRTL: Bool
    /// In order of first appearance.
    public let speakers: [TranscriptSpeaker]

    // MARK: Loading

    public static func load(from url: URL) throws -> TranscriptDocument {
        guard let data = try? Data(contentsOf: url) else { throw TranscriptParseError.unreadable }
        return try parse(data: data, title: url.deletingPathExtension().lastPathComponent)
    }

    public static func parse(html: String, title: String) throws -> TranscriptDocument {
        try parse(data: Data(html.utf8), title: title)
    }

    public static func parse(data: Data, title: String) throws -> TranscriptDocument {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let parsed = parser.parse()
        guard parsed, let format = reader.meta["liteecho:format"] else {
            // Transcripts written before v1 were not well-formed XML and carry no format tag.
            let text = String(decoding: data, as: UTF8.self)
            if !text.contains("liteecho:format"), Self.looksLikeOlderTranscript(text) { throw TranscriptParseError.olderVersion }
            throw TranscriptParseError.notATranscript
        }
        guard format.trimmingCharacters(in: .whitespaces) == supportedFormat else {
            throw TranscriptParseError.unsupportedFormat(format)
        }
        let speakers = reader.speakerOrder.map { TranscriptSpeaker(id: $0, name: reader.speakerNames[$0] ?? $0) }
        return TranscriptDocument(
            title: reader.heading.isEmpty ? title : reader.heading, format: format,
            audioPath: reader.meta["liteecho:audio"],
            language: reader.meta["liteecho:language"] ?? reader.htmlLang,
            languageMode: reader.meta["liteecho:language-mode"],
            speakerCount: reader.meta["liteecho:speakers"].flatMap { Int($0) },
            speakersMode: reader.meta["liteecho:speakers-mode"],
            durationMs: reader.meta["liteecho:duration-ms"].flatMap { Int($0) },
            created: reader.meta["liteecho:created"],
            isRTL: reader.htmlDir == "rtl", speakers: speakers)
    }

    private static func looksLikeOlderTranscript(_ text: String) -> Bool {
        text.contains("WordSection1") || text.contains("audio_source") || text.contains("name=\"ts_")
    }

    // MARK: XML reading

    private final class Reader: NSObject, XMLParserDelegate {
        var meta: [String: String] = [:]
        var htmlLang: String?
        var htmlDir: String?
        var heading = ""
        var speakerOrder: [String] = []
        var speakerNames: [String: String] = [:]

        private var inH1 = false
        private var h1Text = ""
        /// Open `.speaker` elements: (id, collected text, depth at which it opened).
        private var open: [(id: String, text: String, depth: Int)] = []
        private var depth = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attr: [String: String]) {
            depth += 1
            switch name {
            case "html":
                htmlLang = attr["lang"]
                htmlDir = attr["dir"]
            case "meta":
                if let key = attr["name"], let value = attr["content"], meta[key] == nil { meta[key] = value }
            case "h1":
                if heading.isEmpty { inH1 = true; h1Text = "" }
            case "li":
                if let id = attr["data-speaker"] { register(id) }
            default: break
            }
            if let id = attr["data-speaker"], (attr["class"] ?? "").split(separator: " ").contains("speaker") {
                register(id)
                open.append((id, "", depth))
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inH1 { h1Text += string }
            if !open.isEmpty { open[open.count - 1].text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "h1", inH1 {
                inH1 = false
                heading = h1Text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let last = open.last, last.depth == depth {
                open.removeLast()
                let text = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // The first `.speaker` element of an ID (the header list) holds the current name.
                if speakerNames[last.id] == nil, !text.isEmpty { speakerNames[last.id] = text }
            }
            depth -= 1
        }

        private func register(_ id: String) {
            if !speakerOrder.contains(id) { speakerOrder.append(id) }
        }
    }
}
