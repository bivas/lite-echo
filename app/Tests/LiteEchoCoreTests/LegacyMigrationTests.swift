import Foundation
import Testing
@testable import LiteEchoCore

private func tempBase() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

@Suite struct SupportMigrationTests {
    @Test func standardPathsAreLiteEcho() {
        #expect(AppPaths.standard.supportDir.lastPathComponent == "LiteEcho")
        #expect(AppPaths.standard.engineBinary.lastPathComponent == "liteecho")
        #expect(LegacyMigration.legacySupportDir(besides: AppPaths.standard.supportDir).lastPathComponent == "localScribe")
    }

    @Test func movesItemsDeletesEngineAndRemovesOldFolder() throws {
        let base = try tempBase()
        let old = base.appendingPathComponent("localScribe"), new = base.appendingPathComponent("LiteEcho")
        try write("q", to: old.appendingPathComponent("queue.json"))
        try write("m", to: old.appendingPathComponent("models/whisper/model.bin"))
        try write("c", to: old.appendingPathComponent("uv-cache/a"))
        try write("py", to: old.appendingPathComponent("python/bin/python"))
        try write("v", to: old.appendingPathComponent("engine/pyvenv.cfg"))
        let result = try LegacyMigration.migrateSupportDir(from: old, to: new)
        #expect(result.moved == ["models", "python", "queue.json", "uv-cache"])
        #expect(result.skipped.isEmpty)
        #expect(result.engineNeedsReinstall)
        #expect(result.removedOldFolder)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: old.path))
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("engine").path))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("models/whisper/model.bin").path))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("queue.json").path))
    }

    @Test func neverOverwritesExistingItems() throws {
        let base = try tempBase()
        let old = base.appendingPathComponent("localScribe"), new = base.appendingPathComponent("LiteEcho")
        try write("old", to: old.appendingPathComponent("queue.json"))
        try write("new", to: new.appendingPathComponent("queue.json"))
        let result = try LegacyMigration.migrateSupportDir(from: old, to: new)
        #expect(result.skipped == ["queue.json"])
        #expect(!result.removedOldFolder)
        #expect(try String(contentsOf: new.appendingPathComponent("queue.json"), encoding: .utf8) == "new")
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("queue.json").path))
        #expect(!result.engineNeedsReinstall)
    }

    @Test func emptyDestinationFolderDoesNotBlockTheMove() throws {
        let base = try tempBase()
        let old = base.appendingPathComponent("localScribe"), new = base.appendingPathComponent("LiteEcho")
        try write("m", to: old.appendingPathComponent("models/whisper/model.bin"))
        try FileManager.default.createDirectory(at: new.appendingPathComponent("models"), withIntermediateDirectories: true)
        let result = try LegacyMigration.migrateSupportDir(from: old, to: new)
        #expect(result.moved == ["models"])
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("models/whisper/model.bin").path))
    }

    @Test func nonEmptyDestinationFolderIsKept() throws {
        let base = try tempBase()
        let old = base.appendingPathComponent("localScribe"), new = base.appendingPathComponent("LiteEcho")
        try write("a", to: old.appendingPathComponent("models/a"))
        try write("b", to: new.appendingPathComponent("models/b"))
        let result = try LegacyMigration.migrateSupportDir(from: old, to: new)
        #expect(result.skipped == ["models"])
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("models/b").path))
        #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent("models/a").path))
    }

    @Test func missingOldFolderIsANoOp() throws {
        let base = try tempBase()
        let new = base.appendingPathComponent("LiteEcho")
        let result = try LegacyMigration.migrateSupportDir(from: base.appendingPathComponent("localScribe"), to: new)
        #expect(result == LegacyMigration.SupportResult())
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }
}

@Suite struct DefaultsMigrationTests {
    @Test func copiesOnlyKeysNotAlreadySet() {
        let suite = "defaults-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("new", forKey: "language")
        let copied = LegacyMigration.migrateDefaults(from: ["language": "old", "keepAwake": true], to: defaults)
        #expect(copied == 1)
        #expect(defaults.string(forKey: "language") == "new")
        #expect(defaults.bool(forKey: "keepAwake"))
        #expect(LegacyMigration.migrateDefaults(from: nil, to: defaults) == 0)
    }
}
