import Foundation

/// Installs the `liteecho` command as a symlink in ~/.local/bin.
public struct CommandLineInstaller: Sendable {
    public enum Outcome: Equatable, Sendable {
        case created
        case replacedOwnLink
        case replacedAfterConfirmation
        /// Something else is there and the user said no. Nothing was changed.
        case declined
    }

    public enum InstallError: Error, LocalizedError, Equatable {
        case engineMissing
        case isDirectory(String)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .engineMissing: "The engine is not installed yet."
            case .isDirectory(let path): "\(path) is a folder. Remove or rename it, then try again."
            case .io(let message): message
            }
        }
    }

    public static let pathHint = #"export PATH="$HOME/.local/bin:$PATH""#

    public let home: URL
    public let engineBinary: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, engineBinary: URL) {
        self.home = home
        self.engineBinary = engineBinary
    }

    public var binDir: URL { home.appendingPathComponent(".local/bin", isDirectory: true) }
    public var linkURL: URL { binDir.appendingPathComponent("liteecho") }

    private func isOurs(destination: String) -> Bool {
        Self.isOurs(destination: destination, engineBinary: engineBinary)
    }

    static func isOurs(destination: String, engineBinary: URL) -> Bool {
        destination == engineBinary.path || destination.hasSuffix("/LiteEcho/engine/bin/liteecho")
    }

    /// True only when `linkURL` is a symlink that points at this app's engine (directly, by an
    /// older LiteEcho location, or after resolving symlinks). Never true for regular files.
    public static func linkIsOurs(linkURL: URL, engineBinary: URL) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: linkURL.path),
              (attrs[.type] as? FileAttributeType) == .typeSymbolicLink,
              let dest = try? fm.destinationOfSymbolicLink(atPath: linkURL.path) else { return false }
        if isOurs(destination: dest, engineBinary: engineBinary) { return true }
        return linkURL.resolvingSymlinksInPath().path == engineBinary.resolvingSymlinksInPath().path
    }

    public var linkIsOurs: Bool { Self.linkIsOurs(linkURL: linkURL, engineBinary: engineBinary) }

    public enum UninstallOutcome: Equatable, Sendable {
        case removed
        case notInstalled
        /// Something else is at the path (file, folder or another symlink). Left untouched.
        case notOurs
    }

    /// Removes `~/.local/bin/liteecho` only if it is our symlink.
    public func uninstall() throws -> UninstallOutcome {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: linkURL.path)) != nil else { return .notInstalled }
        guard linkIsOurs else { return .notOurs }
        do { try fm.removeItem(at: linkURL) } catch { throw InstallError.io(error.localizedDescription) }
        return .removed
    }

    /// `confirmReplace` is asked only when a file or foreign symlink already sits at the path.
    public func install(confirmReplace: () -> Bool) throws -> Outcome {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: engineBinary.path) else { throw InstallError.engineMissing }
        do {
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            var outcome = Outcome.created
            // attributesOfItem uses lstat: it describes the link itself, not its target.
            if let attrs = try? fm.attributesOfItem(atPath: linkURL.path) {
                let type = attrs[.type] as? FileAttributeType
                if type == .typeDirectory { throw InstallError.isDirectory(linkURL.path) }
                if type == .typeSymbolicLink,
                   let dest = try? fm.destinationOfSymbolicLink(atPath: linkURL.path), isOurs(destination: dest) {
                    outcome = .replacedOwnLink
                } else if confirmReplace() {
                    outcome = .replacedAfterConfirmation
                } else {
                    return .declined
                }
                try fm.removeItem(at: linkURL)
            }
            try fm.createSymbolicLink(at: linkURL, withDestinationURL: engineBinary)
            return outcome
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.io(error.localizedDescription)
        }
    }
}
