import Foundation

/// One-time move of data from the app's former name ("localScribe") to LiteEcho.
/// Everything takes explicit locations so tests can use temp dirs.
public enum LegacyMigration {
    public static let legacySupportFolderName = "localScribe"
    public static let legacyDefaultsDomain = "dev.localscribe.app"
    public static let legacyKeychainService = "dev.localscribe.app"

    public struct SupportResult: Equatable, Sendable {
        /// Top-level names moved into the new folder.
        public var moved: [String] = []
        /// Names left in the old folder because the new folder already had them.
        public var skipped: [String] = []
        /// The old engine (a Python venv with absolute paths) was deleted and must be rebuilt.
        public var engineNeedsReinstall = false
        public var removedOldFolder = false

        public init() {}
    }

    /// The old folder next to `newSupportDir` (`…/Application Support/localScribe`).
    public static func legacySupportDir(besides newSupportDir: URL) -> URL {
        newSupportDir.deletingLastPathComponent().appendingPathComponent(legacySupportFolderName, isDirectory: true)
    }

    /// Moves each top-level item of `old` into `new` unless `new` already has one with that
    /// name (an empty directory there does not count, so the user's models are not stranded by an
    /// empty `models` folder the engine created). The `engine` folder is deleted instead of moved:
    /// its venv has absolute paths baked in. The old folder is removed when it ends up empty.
    /// Does nothing when `old` does not exist.
    @discardableResult
    public static func migrateSupportDir(from old: URL, to new: URL,
                                         fileManager fm: FileManager = .default) throws -> SupportResult {
        var result = SupportResult()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDirectory), isDirectory.boolValue else { return result }
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(atPath: old.path).sorted()
        for name in items {
            let source = old.appendingPathComponent(name)
            if name == "engine" {
                try fm.removeItem(at: source)
                result.engineNeedsReinstall = true
                continue
            }
            let target = new.appendingPathComponent(name)
            if exists(target, fm), !isEmptyDirectory(target, fm) {
                result.skipped.append(name)
                continue
            }
            if exists(target, fm) { try fm.removeItem(at: target) }
            try fm.moveItem(at: source, to: target)
            result.moved.append(name)
        }
        if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty ?? false {
            try fm.removeItem(at: old)
            result.removedOldFolder = true
        }
        return result
    }

    /// Copies keys from the old defaults domain that `defaults` does not have yet.
    /// Returns the number of keys copied.
    @discardableResult
    public static func migrateDefaults(from oldDomain: [String: Any]?, to defaults: UserDefaults) -> Int {
        guard let oldDomain else { return 0 }
        var copied = 0
        for (key, value) in oldDomain where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }

    private static func exists(_ url: URL, _ fm: FileManager) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    private static func isEmptyDirectory(_ url: URL, _ fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) != .typeSymbolicLink else { return false }
        return (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty ?? false
    }
}
