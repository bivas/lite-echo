import Foundation
import LiteEchoCore

/// Runs the one-time migration from the former "localScribe" install at launch, before
/// anything reads settings or paths.
public enum LaunchMigration {
    public static let defaultsMarker = "migratedFromLegacyDefaults"

    public struct Outcome: Equatable, Sendable {
        public var support = LegacyMigration.SupportResult()
        public var defaultsCopied = 0
        public var tokenMoved = false
        /// The old engine was deleted: rebuild it without asking.
        public var engineNeedsReinstall: Bool { support.engineNeedsReinstall }
    }

    @discardableResult
    public static func run(paths: AppPaths = .standard,
                           defaults: UserDefaults = .standard,
                           legacyDefaultsDomain: String = LegacyMigration.legacyDefaultsDomain,
                           migrateKeychain: Bool = true) -> Outcome {
        var outcome = Outcome()
        let old = LegacyMigration.legacySupportDir(besides: paths.supportDir)
        do {
            outcome.support = try LegacyMigration.migrateSupportDir(from: old, to: paths.supportDir)
        } catch {
            NSLog("LiteEcho: could not migrate the old support folder: \(error)")
        }
        if !defaults.bool(forKey: defaultsMarker) {
            outcome.defaultsCopied = LegacyMigration.migrateDefaults(
                from: defaults.persistentDomain(forName: legacyDefaultsDomain), to: defaults)
            defaults.set(true, forKey: defaultsMarker)
        }
        if migrateKeychain { outcome.tokenMoved = KeychainStore.migrateLegacyToken() }
        return outcome
    }
}
