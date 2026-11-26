import Foundation

/// Every location the app reads or writes. Injected (not global) so tests can use a temp dir.
public struct AppPaths: Sendable, Equatable {
    /// This build's own data: ~/Library/Application Support/LiteEcho (or "LiteEcho Dev").
    public var supportDir: URL
    /// Data every flavor shares (models, uv's Python and package cache): the release folder.
    /// Equal to `supportDir` unless a dev build sets it.
    public var sharedDir: URL
    /// Directory holding the app bundle's Resources (uv binary, engine requirements, wheel).
    public var bundleResources: URL?

    public init(supportDir: URL, sharedDir: URL? = nil, bundleResources: URL? = Bundle.main.resourceURL) {
        self.supportDir = supportDir
        self.sharedDir = sharedDir ?? supportDir
        self.bundleResources = bundleResources
    }

    public static var standard: AppPaths { standard(for: .current) }

    public static func standard(for flavor: AppFlavor) -> AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(supportDir: base.appendingPathComponent(flavor.supportFolderName, isDirectory: true),
                        sharedDir: base.appendingPathComponent(AppFlavor.sharedFolderName, isDirectory: true))
    }

    /// Shared with the CLI (`liteecho.resources.cache_dir()` on macOS) and with every flavor.
    public var modelsDir: URL { sharedDir.appendingPathComponent("models", isDirectory: true) }
    /// The engine's virtual environment.
    public var engineDir: URL { supportDir.appendingPathComponent("engine", isDirectory: true) }
    public var engineBinary: URL { engineDir.appendingPathComponent("bin/liteecho") }
    /// uv keeps its downloaded Python and package cache here, not in the user's global dirs.
    public var uvPythonDir: URL { sharedDir.appendingPathComponent("python", isDirectory: true) }
    public var uvCacheDir: URL { sharedDir.appendingPathComponent("uv-cache", isDirectory: true) }
    public var queueFile: URL { supportDir.appendingPathComponent("queue.json") }
    /// Ids of Voice Memos that were imported successfully.
    public var importedVoiceMemosFile: URL { supportDir.appendingPathComponent("imported-voice-memos.json") }
    public var logsDir: URL { supportDir.appendingPathComponent("logs", isDirectory: true) }

    // Files shipped inside the app bundle by scripts/build-app.sh.
    public var bundledUV: URL? { bundleResources?.appendingPathComponent("engine/uv") }
    public var bundledRequirements: URL? { bundleResources?.appendingPathComponent("engine/requirements.txt") }
    /// The liteecho wheel; its exact file name is listed in engine/wheel.txt.
    public var bundledEngineDir: URL? { bundleResources?.appendingPathComponent("engine", isDirectory: true) }

    /// Written by the installer after the last install step succeeds.
    public var engineCompleteMarker: URL { engineDir.appendingPathComponent(".liteecho-complete") }

    /// The engine is usable when its binary exists and it is either a finished install
    /// (marker present) or a user-chosen existing engine (engineDir is a symlink to it).
    /// A half-finished install never counts.
    public var isEngineInstalled: Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: engineBinary.path) else { return false }
        if fm.fileExists(atPath: engineCompleteMarker.path) { return true }
        let attrs = try? fm.attributesOfItem(atPath: engineDir.path)
        return (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
