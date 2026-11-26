import Foundation

/// Every location the app reads or writes. Injected (not global) so tests can use a temp dir.
public struct AppPaths: Sendable, Equatable {
    /// ~/Library/Application Support/LiteEcho
    public var supportDir: URL
    /// Directory holding the app bundle's Resources (uv binary, engine requirements, wheel).
    public var bundleResources: URL?

    public init(supportDir: URL, bundleResources: URL? = Bundle.main.resourceURL) {
        self.supportDir = supportDir
        self.bundleResources = bundleResources
    }

    public static var standard: AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(supportDir: base.appendingPathComponent("LiteEcho", isDirectory: true))
    }

    /// Shared with the CLI (`liteecho.resources.cache_dir()` on macOS).
    public var modelsDir: URL { supportDir.appendingPathComponent("models", isDirectory: true) }
    /// The engine's virtual environment.
    public var engineDir: URL { supportDir.appendingPathComponent("engine", isDirectory: true) }
    public var engineBinary: URL { engineDir.appendingPathComponent("bin/liteecho") }
    /// uv keeps its downloaded Python and package cache here, not in the user's global dirs.
    public var uvPythonDir: URL { supportDir.appendingPathComponent("python", isDirectory: true) }
    public var uvCacheDir: URL { supportDir.appendingPathComponent("uv-cache", isDirectory: true) }
    public var queueFile: URL { supportDir.appendingPathComponent("queue.json") }
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
