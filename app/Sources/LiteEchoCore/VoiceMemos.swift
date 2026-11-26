import Foundation

// Voice Memos (contract v1, docs/transcript-format.md). The app only ever talks to the engine's
// `voice-memos list --json` and `voice-memos import ID …`; nothing here reads Apple's files.

/// Whether the engine could read the Voice Memos library.
public enum VoiceMemoAccess: String, Codable, Sendable, Equatable {
    case ok
    /// The library exists but reading it is denied: Full Disk Access is needed.
    case noAccess = "no-access"
    case noLibrary = "no-library"
    case unreadable
}

public struct VoiceMemoFolder: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One recording of the library, as `voice-memos list --json` reports it.
public struct VoiceMemo: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var recorded: Date
    public var durationSeconds: TimeInterval
    public var folderID: String?
    public var favorite: Bool
    /// The audio file is on this Mac (false: only in iCloud).
    public var local: Bool
    public var appleTranscript: Bool
    public var format: String?

    public init(id: String, title: String, recorded: Date, durationSeconds: TimeInterval = 0,
                folderID: String? = nil, favorite: Bool = false, local: Bool = true,
                appleTranscript: Bool = false, format: String? = nil) {
        self.id = id
        self.title = title
        self.recorded = recorded
        self.durationSeconds = durationSeconds
        self.folderID = folderID
        self.favorite = favorite
        self.local = local
        self.appleTranscript = appleTranscript
        self.format = format
    }

    enum CodingKeys: String, CodingKey {
        case id, title, recorded, favorite, local, format
        case durationSeconds = "duration_s"
        case folderID = "folder_id"
        case appleTranscript = "apple_transcript"
    }

    /// Lenient: only `id` is required. A missing title becomes "Voice Memo", a missing or
    /// unreadable date `.distantPast`, `local` defaults to true, the other flags to false.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let rawTitle = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        let trimmed = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = trimmed.isEmpty ? "Voice Memo" : trimmed
        let raw = (try? c.decodeIfPresent(String.self, forKey: .recorded)) ?? nil
        recorded = raw.flatMap(VoiceMemoDates.parse) ?? .distantPast
        durationSeconds = max(0, (try? c.decodeIfPresent(Double.self, forKey: .durationSeconds)) ?? 0)
        folderID = (try? c.decodeIfPresent(String.self, forKey: .folderID)) ?? nil
        favorite = (try? c.decodeIfPresent(Bool.self, forKey: .favorite)) ?? false
        local = (try? c.decodeIfPresent(Bool.self, forKey: .local)) ?? true
        appleTranscript = (try? c.decodeIfPresent(Bool.self, forKey: .appleTranscript)) ?? false
        format = (try? c.decodeIfPresent(String.self, forKey: .format)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(VoiceMemoDates.format(recorded), forKey: .recorded)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(folderID, forKey: .folderID)
        try c.encode(favorite, forKey: .favorite)
        try c.encode(local, forKey: .local)
        try c.encode(appleTranscript, forKey: .appleTranscript)
        try c.encodeIfPresent(format, forKey: .format)
    }
}

enum VoiceMemoDates {
    static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

/// The answer of `voice-memos list --json`.
public struct VoiceMemoListing: Equatable, Sendable {
    public var status: VoiceMemoAccess
    /// Human-readable reason from the engine (never recording data).
    public var detail: String
    public var folders: [VoiceMemoFolder]
    public var memos: [VoiceMemo]

    public init(status: VoiceMemoAccess, detail: String = "", folders: [VoiceMemoFolder] = [],
                memos: [VoiceMemo] = []) {
        self.status = status
        self.detail = detail
        self.folders = folders
        self.memos = memos
    }

    /// A listing that stands for "could not ask the engine".
    public static func unreadable(_ detail: String) -> VoiceMemoListing {
        VoiceMemoListing(status: .unreadable, detail: detail)
    }

    private struct Wire: Decodable {
        var status: String?
        var detail: String?
        var folders: [Lossy<VoiceMemoFolder>]?
        var memos: [Lossy<VoiceMemo>]?
    }

    /// An element that decodes to nil instead of failing the whole array.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    /// Decodes the engine's JSON. An unknown or missing status counts as `unreadable`; broken
    /// memo or folder entries are skipped. Throws only when the data is not a JSON object.
    public static func decode(_ data: Data) throws -> VoiceMemoListing {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        let status = wire.status.flatMap(VoiceMemoAccess.init(rawValue:)) ?? .unreadable
        return VoiceMemoListing(
            status: status, detail: wire.detail ?? "",
            folders: (wire.folders ?? []).compactMap(\.value),
            memos: (wire.memos ?? []).compactMap(\.value))
    }

    public func folderName(for memo: VoiceMemo) -> String? {
        guard let id = memo.folderID else { return nil }
        return folders.first { $0.id == id }?.name
    }

    public var folderNames: [String: String] {
        Dictionary(folders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

/// What a queue row remembers about the recording it was made from.
public struct VoiceMemoRef: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var recorded: Date
    public var folder: String?
    /// Length in seconds, when known (the queue shows it without reading audio).
    public var duration: TimeInterval?

    public init(id: String, title: String, recorded: Date, folder: String? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.title = title
        self.recorded = recorded
        self.folder = folder
        self.duration = duration
    }

    public init(_ memo: VoiceMemo, folder: String?) {
        self.init(id: memo.id, title: memo.title, recorded: memo.recorded, folder: folder,
                  duration: memo.durationSeconds > 0 ? memo.durationSeconds : nil)
    }
}

// MARK: Rows, search, sort, selection

public enum VoiceMemoSort: String, CaseIterable, Identifiable, Sendable {
    case newest, oldest, longest, title

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .longest: "Longest"
        case .title: "Title"
        }
    }
}

/// Why a memo can or cannot be added.
public enum VoiceMemoAvailability: Equatable, Sendable {
    case available
    case alreadyImported
    /// Waiting or running in the queue.
    case inQueue
    /// Only in iCloud: it can be ticked (to show the hint) but never added.
    case notLocal

    /// The checkbox reacts.
    public var isSelectable: Bool { self == .available || self == .notLocal }
    /// Counts for "Add K to Queue".
    public var isAddable: Bool { self == .available }
}

public struct VoiceMemoQuery: Equatable, Sendable {
    public var search = ""
    /// nil = All Recordings.
    public var folderID: String?
    public var sort: VoiceMemoSort = .newest
    public var showAlreadyImported = false

    public init(search: String = "", folderID: String? = nil, sort: VoiceMemoSort = .newest,
                showAlreadyImported: Bool = false) {
        self.search = search
        self.folderID = folderID
        self.sort = sort
        self.showAlreadyImported = showAlreadyImported
    }
}

public enum VoiceMemoCatalog {
    public static func availability(of memo: VoiceMemo, imported: Set<String>, queued: Set<String>) -> VoiceMemoAvailability {
        if imported.contains(memo.id) { return .alreadyImported }
        if queued.contains(memo.id) { return .inQueue }
        if !memo.local { return .notLocal }
        return .available
    }

    /// The rows to show: filtered by folder and search (title, case and accent insensitive),
    /// without already imported ones unless asked, then sorted.
    public static func visible(_ memos: [VoiceMemo], query: VoiceMemoQuery, imported: Set<String>) -> [VoiceMemo] {
        let needle = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = memos.filter { memo in
            if let folder = query.folderID, memo.folderID != folder { return false }
            if !query.showAlreadyImported, imported.contains(memo.id) { return false }
            if !needle.isEmpty,
               memo.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
            return true
        }
        return sorted(filtered, by: query.sort)
    }

    public static func sorted(_ memos: [VoiceMemo], by sort: VoiceMemoSort) -> [VoiceMemo] {
        switch sort {
        case .newest: memos.sorted { $0.recorded > $1.recorded }
        case .oldest: memos.sorted { $0.recorded < $1.recorded }
        case .longest: memos.sorted { $0.durationSeconds > $1.durationSeconds }
        case .title: memos.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    /// The selected memos that can really be added, in list order.
    public static func addable(_ memos: [VoiceMemo], selected: Set<String>, imported: Set<String>,
                               queued: Set<String>) -> [VoiceMemo] {
        memos.filter {
            selected.contains($0.id) && availability(of: $0, imported: imported, queued: queued).isAddable
        }
    }

    /// "Select all": every row that can be added (iCloud-only and imported rows stay unticked).
    public static func selectAll(_ memos: [VoiceMemo], imported: Set<String>, queued: Set<String>) -> Set<String> {
        Set(memos.filter { availability(of: $0, imported: imported, queued: queued).isAddable }.map(\.id))
    }
}

// MARK: Text

public enum VoiceMemoFormat {
    /// "Today, 10:42", "Yesterday", "Mon 24 Nov" (with the year when it is not this year).
    public static func relativeDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                                    locale: Locale = Locale(identifier: "en_GB")) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today, " + formatted(date, "HH:mm", calendar, locale)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatted(date, sameYear ? "EEE d MMM" : "EEE d MMM yyyy", calendar, locale)
    }

    private static func formatted(_ date: Date, _ format: String, _ calendar: Calendar, _ locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.dateFormat = format
        return f.string(from: date)
    }

    /// "48:12", "1:02:05".
    public static func length(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Sum of lengths for the subtitle: "45 s", "12 min", "3 h 05 min".
    public static func totalLength(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        let minutes = Int((Double(total) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// "12 recordings · 3 selected · 4 h 10 min".
    public static func subtitle(count: Int, selected: Int, total: TimeInterval) -> String {
        let noun = count == 1 ? "1 recording" : "\(count) recordings"
        return "\(noun) · \(selected) selected · \(totalLength(total))"
    }
}

/// Friendly texts for the engine's import errors (`detail` is the code).
public enum VoiceMemoImportError {
    /// The failed-row text for `no-access`; a row showing it offers "Set up access…".
    public static let accessMessage = "LiteEcho can no longer read your Voice Memos. Allow Full Disk Access, then retry."

    public static func message(forCode code: String?, fallback: String) -> String {
        switch code {
        case "no-access": accessMessage
        case "not-found": "This recording is no longer in Voice Memos."
        case "not-local": "Open the memo in Voice Memos once to download it, then retry."
        case "unreadable": "Couldn't read the Voice Memos library."
        case "unsupported-format": "This recording's audio format isn't supported."
        default: fallback
        }
    }
}

// MARK: Imported ids

/// The ids of memos that were imported successfully, kept in Application Support.
public struct ImportedVoiceMemoStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public init(paths: AppPaths) { self.init(url: paths.importedVoiceMemosFile) }

    private struct File: Codable { var ids: [String] }

    public func load() -> Set<String> {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else {
            return []
        }
        return Set(file.ids)
    }

    public func save(_ ids: Set<String>) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(File(ids: ids.sorted())).write(to: url, options: .atomic)
        } catch {
            NSLog("LiteEcho: could not save the imported Voice Memos: \(error)")
        }
    }

    /// Adds `id` and saves; returns the new set.
    @discardableResult
    public func insert(_ id: String) -> Set<String> {
        var ids = load()
        ids.insert(id)
        save(ids)
        return ids
    }
}
