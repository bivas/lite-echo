import Foundation

/// The language to transcribe in: `auto` (detect per file) or a Whisper language code ("he", "fr", ...).
/// Persisted as a plain string, so values saved by older versions ("auto", "en", "he") still decode.
public struct LanguageChoice: Codable, Hashable, Sendable {
    public var code: String

    public init(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.code = trimmed.isEmpty ? "auto" : trimmed
    }

    public static let auto = LanguageChoice(code: "auto")
    public static let en = LanguageChoice(code: "en")
    public static let he = LanguageChoice(code: "he")

    public var isAuto: Bool { code == "auto" }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self.init(code: value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}

/// One entry of `engine-info`'s `languages` list.
public struct LanguageInfo: Codable, Hashable, Sendable, Identifiable {
    public var code: String
    public var name: String
    public var native: String
    /// LiteEcho ships a tuned prompt for this language.
    public var tuned: Bool

    public var id: String { code }

    public init(code: String, name: String, native: String? = nil, tuned: Bool = false) {
        self.code = code
        self.name = name
        self.native = native ?? name
        self.tuned = tuned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let code = try c.decode(String.self, forKey: .code)
        self.init(code: code,
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? code,
                  native: try c.decodeIfPresent(String.self, forKey: .native),
                  tuned: try c.decodeIfPresent(Bool.self, forKey: .tuned) ?? false)
    }

    enum CodingKeys: String, CodingKey { case code, name, native, tuned }
}

/// Pure logic behind the language picker: the built-in fallback list, search and recents.
public enum LanguageCatalog {
    /// Used when the engine is older and reports no `languages`. `auto` is always offered
    /// separately by the picker, so the list holds concrete languages only.
    public static let fallback: [LanguageInfo] = [
        LanguageInfo(code: "en", name: "English", native: "English", tuned: true),
        LanguageInfo(code: "he", name: "Hebrew", native: "עברית", tuned: true),
    ]

    public static let maxRecents = 2

    /// Case- and diacritic-insensitive form used for matching.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The list to show: the engine's, minus any "auto" entry, sorted by English name; the fallback when empty.
    public static func usable(_ languages: [LanguageInfo]?) -> [LanguageInfo] {
        let real = (languages ?? []).filter { $0.code.lowercased() != "auto" }
        let list = real.isEmpty ? fallback : real
        return list.sorted { fold($0.name) < fold($1.name) }
    }

    /// Languages matching `query` (English name, native name or code). Empty query = all.
    /// Order: exact code, then names starting with the query, then code prefix, then the rest (each A to Z).
    public static func filter(_ languages: [LanguageInfo], query: String) -> [LanguageInfo] {
        let q = fold(query)
        guard !q.isEmpty else { return languages }
        func rank(_ l: LanguageInfo) -> Int? {
            let name = fold(l.name), native = fold(l.native), code = fold(l.code)
            if code == q { return 0 }
            if name.hasPrefix(q) || native.hasPrefix(q) { return 1 }
            if code.hasPrefix(q) { return 2 }
            if name.contains(q) || native.contains(q) { return 3 }
            return nil
        }
        return languages.enumerated().compactMap { index, l in rank(l).map { (index, $0, l) } }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            .map(\.2)
    }

    /// Whether the "Auto-detect" row matches the query.
    public static func autoMatches(query: String) -> Bool {
        let q = fold(query)
        return q.isEmpty || "auto-detect".contains(q) || "detect".contains(q) || "auto".contains(q)
    }

    /// Recents after picking `choice`: newest first, no duplicates, at most 2. Auto is never a recent.
    public static func updatedRecents(_ recents: [LanguageChoice], picking choice: LanguageChoice) -> [LanguageChoice] {
        guard !choice.isAuto else { return Array(recents.filter { !$0.isAuto }.prefix(maxRecents)) }
        var result = [choice] + recents.filter { $0 != choice && !$0.isAuto }
        if result.count > maxRecents { result = Array(result.prefix(maxRecents)) }
        return result
    }

    /// "Auto-detect" or the language's English name (the code when unknown).
    public static func displayName(of choice: LanguageChoice, in languages: [LanguageInfo]) -> String {
        choice.isAuto ? "Auto-detect" : name(forCode: choice.code, in: languages)
    }

    /// English name of a code: the engine's list, then the built-in one, then the system's, then the code.
    public static func name(forCode code: String, in languages: [LanguageInfo] = []) -> String {
        let lower = code.lowercased()
        if let hit = languages.first(where: { $0.code.lowercased() == lower }) { return hit.name }
        if let hit = fallback.first(where: { $0.code == lower }) { return hit.name }
        return Locale(identifier: "en").localizedString(forLanguageCode: lower) ?? code
    }
}
