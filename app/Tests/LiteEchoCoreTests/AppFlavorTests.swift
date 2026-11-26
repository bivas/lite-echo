import Foundation
import Testing
@testable import LiteEchoCore

@Suite struct AppFlavorTests {
    @Test func onlyAnExplicitDevIsDev() {
        #expect(AppFlavor.from(infoValue: "dev") == .dev)
        #expect(AppFlavor.from(infoValue: "release") == .release)
        #expect(AppFlavor.from(infoValue: nil) == .release)
        #expect(AppFlavor.from(infoValue: "DEV") == .release)
    }

    @Test func devGetsItsOwnIdentity() {
        #expect(AppFlavor.dev.displayName == "LiteEcho Dev")
        #expect(AppFlavor.dev.commandName == "liteecho-dev")
        #expect(AppFlavor.dev.keychainService != AppFlavor.release.keychainService)
        #expect(AppFlavor.release.commandName == "liteecho")
    }

    @Test func devKeepsItsOwnDataButSharesModelsAndCaches() {
        let dev = AppPaths.standard(for: .dev)
        let release = AppPaths.standard(for: .release)
        #expect(dev.supportDir.lastPathComponent == "LiteEcho Dev")
        #expect(release.supportDir.lastPathComponent == "LiteEcho")
        // Own: engine, queue, logs.
        #expect(dev.engineDir != release.engineDir)
        #expect(dev.queueFile != release.queueFile)
        #expect(dev.logsDir != release.logsDir)
        // Shared: models and uv's Python and package cache.
        #expect(dev.modelsDir == release.modelsDir)
        #expect(dev.uvCacheDir == release.uvCacheDir)
        #expect(dev.uvPythonDir == release.uvPythonDir)
    }

    @Test func pathsWithoutSharedDirKeepEverythingTogether() {
        let root = URL(fileURLWithPath: "/tmp/liteecho-test", isDirectory: true)
        let paths = AppPaths(supportDir: root, bundleResources: nil)
        #expect(paths.modelsDir.path.hasPrefix(root.path))
        #expect(paths.uvCacheDir.path.hasPrefix(root.path))
    }
}
