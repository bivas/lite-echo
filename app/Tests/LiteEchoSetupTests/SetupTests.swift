import Foundation
import Testing
import LiteEchoCore
import LiteEchoShared
@testable import LiteEchoSetup

@Suite("KeychainStore")
struct KeychainStoreTests {
    @Test func saveLoadReplaceDelete() throws {
        let store = KeychainStore(service: "dev.liteecho.tests.\(UUID().uuidString)", account: "token")
        defer { try? store.delete() }
        #expect(store.load() == nil)
        try store.save("hf_first")
        #expect(store.load() == "hf_first")
        try store.save("hf_second")
        #expect(store.load() == "hf_second")
        #expect(store.hasToken)
        try store.delete()
        #expect(store.load() == nil)
        #expect(!store.hasToken)
        try store.delete()  // deleting nothing is fine
    }

    @Test func defaultsMatchSpec() {
        #expect(KeychainStore.defaultService == "dev.liteecho.app")
        #expect(KeychainStore.defaultAccount == "huggingface-token")
    }
}

@Suite("EngineInstaller")
struct EngineInstallerTests {
    @Test func runsTheValidatedRecipe() async throws {
        let bundle = try FakeBundle()
        defer { bundle.cleanup() }
        let paths = bundle.paths
        let installer = EngineInstaller(paths: paths)
        let steps = StepRecorder()
        try await installer.install(onStep: { steps.add($0) })

        let uv = paths.bundledEngineDir!.appendingPathComponent("engine/uv").path
        _ = uv
        let dir = paths.engineDir.path
        let python = "\(dir)/bin/python"
        let args = bundle.argLines
        #expect(args == [
            "venv --python 3.12 --python-preference only-managed \(dir)",
            "pip sync --python \(python) --require-hashes \(paths.bundledRequirements!.path)",
            "pip install --python \(python) --no-deps \(paths.bundledEngineDir!.path)/liteecho-0.1.0-py3-none-any.whl",
        ])
        #expect(steps.values == [.createEnvironment, .installPackages, .installEngine])
        #expect(installer.isComplete)
        #expect(paths.isEngineInstalled)
        #expect(FileManager.default.fileExists(atPath: installer.markerURL.path))
    }

    @Test func environmentIsMinimalAndHasNoToken() async throws {
        let bundle = try FakeBundle()
        defer { bundle.cleanup() }
        try await EngineInstaller(paths: bundle.paths).install()
        let env = Set(bundle.envLines)
        let keys = Set(bundle.envLines.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        #expect(env.contains("UV_PYTHON_INSTALL_DIR=\(bundle.paths.uvPythonDir.path)"))
        #expect(env.contains("UV_CACHE_DIR=\(bundle.paths.uvCacheDir.path)"))
        #expect(!keys.contains("HF_TOKEN"))
        #expect(keys.contains("HOME") && keys.contains("PATH") && keys.contains("TMPDIR"))
        // Only the expected variables, plus the few a shell adds itself.
        let allowed: Set<String> = ["HOME", "PATH", "TMPDIR", "UV_PYTHON_INSTALL_DIR", "UV_CACHE_DIR",
                                    "PWD", "OLDPWD", "SHLVL", "_", "__CF_USER_TEXT_ENCODING"]
        #expect(keys.subtracting(allowed).isEmpty, "unexpected: \(keys.subtracting(allowed))")
    }

    @Test(arguments: ["venv", "pip sync", "pip install"])
    func failureCleansUpAndReportsTheStep(failing: String) async throws {
        let bundle = try FakeBundle()
        defer { bundle.cleanup() }
        try failing.write(to: bundle.failFlag, atomically: true, encoding: .utf8)
        let installer = EngineInstaller(paths: bundle.paths)
        do {
            try await installer.install()
            Issue.record("expected failure")
        } catch let error as EngineInstaller.InstallError {
            guard case .stepFailed(_, let code, let stderr) = error else { Issue.record("wrong error \(error)"); return }
            #expect(code == 3)
            #expect(stderr.contains("simulated failure"))
            #expect(error.localizedDescription.contains("simulated failure"))
        }
        #expect(!installer.isComplete)
        #expect(!bundle.paths.isEngineInstalled)
        #expect(!FileManager.default.fileExists(atPath: bundle.paths.engineDir.path))
    }

    @Test func staleIncompleteDirectoryIsReplaced() async throws {
        let bundle = try FakeBundle()
        defer { bundle.cleanup() }
        let stale = bundle.paths.engineDir.appendingPathComponent("junk")
        try FileManager.default.createDirectory(at: bundle.paths.engineDir, withIntermediateDirectories: true)
        try "x".write(to: stale, atomically: true, encoding: .utf8)
        try await EngineInstaller(paths: bundle.paths).install()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(bundle.paths.isEngineInstalled)
    }

    @Test func binaryWithoutMarkerIsNotComplete() throws {
        let bundle = try FakeBundle()
        defer { bundle.cleanup() }
        let bin = bundle.paths.engineBinary
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let installer = EngineInstaller(paths: bundle.paths)
        #expect(!bundle.paths.isEngineInstalled)  // a binary alone is a half-finished install
        #expect(!installer.isComplete)
        try Data().write(to: installer.markerURL)
        #expect(installer.isComplete)
    }

    @Test func missingBundleFilesAreReported() async throws {
        let bundle = try FakeBundle(includeUV: false)
        defer { bundle.cleanup() }
        let installer = EngineInstaller(paths: bundle.paths)
        #expect(installer.bundleProblems == ["engine/uv"])
        do {
            try await installer.install()
            Issue.record("expected failure")
        } catch let error as EngineInstaller.InstallError {
            #expect(error == .bundleMissing(["engine/uv"]))
        }
        #expect(!FileManager.default.fileExists(atPath: bundle.paths.engineDir.path))
    }

    @Test func missingWheelAndNoBundleAtAll() throws {
        let bundle = try FakeBundle(includeWheelFile: false)
        defer { bundle.cleanup() }
        #expect(EngineInstaller(paths: bundle.paths).bundleProblems == ["engine/liteecho-0.1.0-py3-none-any.whl"])
        let none = AppPaths(supportDir: bundle.root.appendingPathComponent("s"), bundleResources: nil)
        #expect(!EngineInstaller(paths: none).bundleProblems.isEmpty)
    }

    @Test func wheelNameMustNotEscapeTheBundle() throws {
        let bundle = try FakeBundle()
        defer { bundle.cleanup() }
        try "../../evil.whl".write(to: bundle.paths.bundledEngineDir!.appendingPathComponent("wheel.txt"),
                                   atomically: true, encoding: .utf8)
        #expect(EngineInstaller(paths: bundle.paths).bundleProblems == ["engine/wheel.txt"])
    }

    @Test func useExistingEngineLinksAndValidates() throws {
        let bundle = try FakeBundle()
        defer { bundle.cleanup() }
        let installer = EngineInstaller(paths: bundle.paths)
        let empty = bundle.root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: EngineInstaller.InstallError.self) { try installer.useExistingEngine(at: empty) }
        #expect(!FileManager.default.fileExists(atPath: bundle.paths.engineDir.path))

        let engine = bundle.root.appendingPathComponent("myengine")
        try FileManager.default.createDirectory(at: engine.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let bin = engine.appendingPathComponent("bin/liteecho")
        try "#!/bin/sh\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        try installer.useExistingEngine(at: engine)
        #expect(bundle.paths.isEngineInstalled)
        #expect(installer.isComplete)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bundle.paths.engineDir.path) == engine.path)
        try installer.remove()  // removes only the link
        #expect(FileManager.default.fileExists(atPath: bin.path))
        #expect(!bundle.paths.isEngineInstalled)
    }
}

final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [EngineInstaller.Step] = []
    func add(_ s: EngineInstaller.Step) { lock.lock(); items.append(s); lock.unlock() }
    var values: [EngineInstaller.Step] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite("CommandLineInstaller")
struct CommandLineInstallerTests {
    private func setup() throws -> (home: URL, binary: URL, installer: CommandLineInstaller) {
        let home = try makeTempDir("home")
        let binary = home.appendingPathComponent("engine/bin/liteecho")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return (home, binary, CommandLineInstaller(home: home, engineBinary: binary))
    }

    @Test func createsLinkAndDirectory() throws {
        let (home, binary, installer) = try setup()
        defer { try? FileManager.default.removeItem(at: home) }
        let outcome = try installer.install { Issue.record("must not ask"); return false }
        #expect(outcome == .created)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: installer.linkURL.path) == binary.path)
        #expect(installer.linkURL.path == home.appendingPathComponent(".local/bin/liteecho").path)
    }

    @Test func replacesItsOwnLinkSilently() throws {
        let (home, binary, installer) = try setup()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: installer.binDir, withIntermediateDirectories: true)
        // A link to an older location of our engine.
        try FileManager.default.createSymbolicLink(
            atPath: installer.linkURL.path, withDestinationPath: "/Users/x/Library/Application Support/LiteEcho/engine/bin/liteecho")
        #expect(try installer.install { Issue.record("must not ask"); return false } == .replacedOwnLink)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: installer.linkURL.path) == binary.path)
        #expect(try installer.install { false } == .replacedOwnLink)
    }

    @Test func foreignFileNeedsConfirmation() throws {
        let (home, binary, installer) = try setup()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: installer.binDir, withIntermediateDirectories: true)
        try "mine".write(to: installer.linkURL, atomically: true, encoding: .utf8)

        let asked = Counter()
        #expect(try installer.install { asked.bump(); return false } == .declined)
        #expect(asked.value == 1)
        #expect(try String(contentsOf: installer.linkURL, encoding: .utf8) == "mine")

        #expect(try installer.install { true } == .replacedAfterConfirmation)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: installer.linkURL.path) == binary.path)
    }

    @Test func foreignSymlinkAndDirectory() throws {
        let (home, _, installer) = try setup()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: installer.binDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: installer.linkURL.path, withDestinationPath: "/usr/bin/true")
        #expect(try installer.install { false } == .declined)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: installer.linkURL.path) == "/usr/bin/true")

        try FileManager.default.removeItem(at: installer.linkURL)
        try FileManager.default.createDirectory(at: installer.linkURL, withIntermediateDirectories: true)
        #expect(throws: CommandLineInstaller.InstallError.self) { try installer.install { true } }
    }

    @Test func needsAnInstalledEngine() throws {
        let home = try makeTempDir("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = CommandLineInstaller(home: home, engineBinary: home.appendingPathComponent("nope"))
        #expect(throws: CommandLineInstaller.InstallError.engineMissing) { try installer.install { true } }
        #expect(!FileManager.default.fileExists(atPath: installer.binDir.path))
    }
}

final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func bump() { value += 1 }
}

@Suite("Launch migration")
struct LaunchMigrationTests {
    @Test func movesTheLegacyFolderAndFlagsEngineReinstall() throws {
        let base = try makeTempDir("migrate")
        let old = base.appendingPathComponent("localScribe")
        let fm = FileManager.default
        try fm.createDirectory(at: old.appendingPathComponent("engine/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: old.appendingPathComponent("python"), withIntermediateDirectories: true)
        try "x".write(to: old.appendingPathComponent("queue.json"), atomically: true, encoding: .utf8)
        let paths = AppPaths(supportDir: base.appendingPathComponent("LiteEcho"), bundleResources: nil)
        let suite = "launch-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let outcome = LaunchMigration.run(paths: paths, defaults: defaults, legacyDefaultsDomain: "no.such.domain.\(UUID().uuidString)",
                                          migrateKeychain: false)
        #expect(outcome.engineNeedsReinstall)
        #expect(fm.fileExists(atPath: paths.queueFile.path))
        #expect(!fm.fileExists(atPath: paths.engineDir.path))
        #expect(!fm.fileExists(atPath: old.path))
        // Second launch: nothing left to do.
        #expect(!LaunchMigration.run(paths: paths, defaults: defaults, migrateKeychain: false).engineNeedsReinstall)
    }

    @Test func legacyTokenMovesToTheNewService() throws {
        let account = "token-\(UUID().uuidString)"
        let old = KeychainStore(service: "dev.liteecho.tests.old.\(UUID().uuidString)", account: account)
        let new = KeychainStore(service: "dev.liteecho.tests.new.\(UUID().uuidString)", account: account)
        defer { try? old.delete(); try? new.delete() }
        try old.save("hf_test_value")
        #expect(KeychainStore.migrateLegacyToken(to: new, from: old))
        #expect(new.load() == "hf_test_value")
        #expect(old.load() == nil)
        #expect(!KeychainStore.migrateLegacyToken(to: new, from: old))
    }
}

@Suite("Model step")
struct ModelStepTests {
    @Test func importedFromCustomFolder() {
        let state = ModelStepState(info: engineInfo(whisper: ("custom", nil), pyannote: ("custom", nil)))
        #expect(state.whisper == .ready(source: "custom"))
        #expect(state.canContinue)
    }

    @Test func nothingDownloaded() {
        let state = ModelStepState(info: engineInfo(whisper: nil, pyannote: nil))
        #expect(state.whisper == .missing && state.pyannote == .missing)
        #expect(!state.canContinue)
        #expect(!ModelStepState(info: nil).canContinue)
    }

    @Test func partiallyDownloaded() {
        let state = ModelStepState(info: engineInfo(whisper: ("cache", true), pyannote: ("cache", false), problems: ["model.bin: checksum"]))
        #expect(state.whisper == .ready(source: "cache"))
        #expect(state.pyannote == .needsRepair(problems: ["model.bin: checksum"]))
        #expect(!state.canContinue)
        let mixed = ModelStepState(info: engineInfo(whisper: ("custom", nil), pyannote: ("cache", nil)))
        #expect(mixed.canContinue)
    }

    @Test func sourceLabels() throws {
        func m(_ source: String) throws -> EngineInfo.Model {
            try JSONDecoder().decode(EngineInfo.Model.self,
                                     from: Data(#"{"source":"\#(source)","path":null,"verified":null,"problems":[]}"#.utf8))
        }
        #expect(modelSourceLabel(try m("cache")) == "Downloaded")
        #expect(modelSourceLabel(try m("custom")) == "Custom folder")
        #expect(modelSourceLabel(try m("missing")) == "Missing")
        #expect(modelSourceLabel(nil) == "Missing")
    }

    @Test func progressSummary() {
        let gb = 1_000_000_000.0
        let p = DownloadProgress(completed: 1.0 * gb, total: 1.6 * gb, elapsed: 200)
        #expect(p.percent == 63)
        #expect(p.summary.hasPrefix("1 GB of 1.6 GB") || p.summary.hasPrefix("1.0 GB of 1.6 GB"))
        #expect(p.summary.contains("about 2 min left"))
        #expect(DownloadProgress(completed: 10, total: 100, elapsed: 0).remaining == nil)
        #expect(DownloadProgress.etaText(20) == "less than a minute left")
        #expect(DownloadProgress.etaText(7200) == "about 2 h 0 min left")
        #expect(DownloadProgress(completed: 5, total: 0, elapsed: 1).fraction == 0)
    }

    @Test func errorsAreFriendlyAndRedactTheToken() {
        let raw = "401 Client Error: gated repo for token hf_secret123"
        let text = friendlyDownloadError(raw, kind: "pyannote", token: "hf_secret123")
        #expect(text.contains("accept its terms"))
        #expect(!text.contains("hf_secret123"))
        #expect(friendlyDownloadError("disk full", kind: "whisper") == "disk full")
        #expect(friendlyDownloadError("disk full", kind: "pyannote") == "disk full")
    }
}

@Suite("Token handling")
struct TokenTests {
    @MainActor @Test func tokenIsNeverInArguments() {
        let model = AppModel(paths: AppPaths(supportDir: URL(fileURLWithPath: "/tmp/ls-nonexistent"), bundleResources: nil),
                             settings: AppSettings(defaults: UserDefaults(suiteName: "ls-test-\(UUID().uuidString)")!))
        let token = "hf_supersecret"
        let process = ModelFetcher.makeProcess(model: model, kind: "pyannote", token: token, force: false)
        #expect(process.arguments == ["fetch-models", "--events", "jsonl", "--only", "pyannote"])
        #expect(!process.arguments.contains { $0.contains(token) })
        #expect(process.executable == model.paths.engineBinary)

        let forced = ModelFetcher.makeProcess(model: model, kind: "whisper", token: nil, force: true)
        #expect(forced.arguments == ["fetch-models", "--events", "jsonl", "--only", "whisper", "--force"])
    }
}

@MainActor @Test func missingEngineWaitsForConsentInsteadOfInstalling() async throws {
    let bundle = try FakeBundle()
    defer { bundle.cleanup() }
    let defaults = UserDefaults(suiteName: "liteecho.tests.\(UUID().uuidString)")!
    let model = AppModel(paths: bundle.paths, settings: AppSettings(defaults: defaults))
    let flow = SetupFlow()
    await flow.begin(model: model)
    #expect(flow.phase == .needsInstall)
    // Nothing was run: the fake uv never wrote its log and no engine folder exists.
    #expect(!FileManager.default.fileExists(atPath: bundle.log.path))
    #expect(!FileManager.default.fileExists(atPath: bundle.paths.engineDir.path))
}

@Suite struct EngineUpdateTests {
    /// A finished install from `bundle`, with the given marker content.
    func installed(_ bundle: FakeBundle, marker: Data) throws {
        let bin = bundle.paths.engineBinary
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        try marker.write(to: EngineInstaller(paths: bundle.paths).markerURL)
    }

    @Test func upToDateEngineNeedsNothing() throws {
        let bundle = try FakeBundle(); defer { bundle.cleanup() }
        let installer = EngineInstaller(paths: bundle.paths)
        try installed(bundle, marker: JSONEncoder().encode(installer.bundleFingerprint!))
        #expect(installer.updateNeed == .none)
    }

    @Test func legacyMarkerGetsSilentRefresh() throws {
        let bundle = try FakeBundle(); defer { bundle.cleanup() }
        try installed(bundle, marker: Data())
        #expect(EngineInstaller(paths: bundle.paths).updateNeed == .engineOnly)
    }

    @Test func changedWheelIsEngineOnlyChangedRequirementsAsks() throws {
        let bundle = try FakeBundle(); defer { bundle.cleanup() }
        let installer = EngineInstaller(paths: bundle.paths)
        var fp = installer.bundleFingerprint!
        fp.wheel = "old"
        try installed(bundle, marker: JSONEncoder().encode(fp))
        #expect(installer.updateNeed == .engineOnly)
        fp.requirements = "old"
        try JSONEncoder().encode(fp).write(to: installer.markerURL)
        #expect(installer.updateNeed == .packages)
    }

    @Test func engineOnlyUpdateReinstallsWheelAndWritesFingerprint() async throws {
        let bundle = try FakeBundle(); defer { bundle.cleanup() }
        let installer = EngineInstaller(paths: bundle.paths)
        var fp = installer.bundleFingerprint!
        fp.wheel = "old"
        try installed(bundle, marker: JSONEncoder().encode(fp))
        try await installer.update()
        let log = try String(contentsOf: bundle.log, encoding: .utf8)
        #expect(log.contains("--reinstall"))
        #expect(!log.contains("pip sync"))      // libraries unchanged: no sync, nothing downloaded
        #expect(installer.installedFingerprint == installer.bundleFingerprint)
        #expect(installer.updateNeed == .none)
    }

    @Test func failedUpdateKeepsWorkingEngine() async throws {
        let bundle = try FakeBundle(); defer { bundle.cleanup() }
        let installer = EngineInstaller(paths: bundle.paths)
        try installed(bundle, marker: Data())
        try "pip sync".write(to: bundle.failFlag, atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) { try await installer.update() }
        #expect(bundle.paths.isEngineInstalled)          // old engine still usable
        #expect(installer.installedFingerprint == nil)    // marker untouched
    }

    @Test func symlinkedEngineIsNeverUpdated() throws {
        let bundle = try FakeBundle(); defer { bundle.cleanup() }
        let other = try makeTempDir("other-engine")
        let bin = other.appendingPathComponent("bin/liteecho")
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let installer = EngineInstaller(paths: bundle.paths)
        try installer.useExistingEngine(at: other)
        #expect(installer.updateNeed == .none)
    }
}

/// A temp support dir whose `bin/liteecho` answers `engine-info` like the real engine: a folder
/// given with `--whisper-dir` / `--pyannote-dir` is "verified" when it holds a file named `ok`.
@MainActor
struct FakeInfoEngine {
    let root: URL
    let paths: AppPaths
    let model: AppModel
    var argvLog: URL { paths.engineDir.appendingPathComponent("bin/argv.log") }

    init() throws {
        root = try makeTempDir("info-engine")
        paths = AppPaths(supportDir: root.appendingPathComponent("support"), bundleResources: nil)
        let bin = paths.engineDir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "marker".write(to: paths.engineCompleteMarker, atomically: true, encoding: .utf8)
        let script = #"""
        #!/bin/sh
        dir=$(dirname "$0")
        echo "$*" >> "$dir/argv.log"
        w=""; p=""
        while [ $# -gt 0 ]; do
          case "$1" in --whisper-dir) w="$2";; --pyannote-dir) p="$2";; esac
          shift
        done
        model() { # kind dir
          if [ -z "$2" ]; then
            printf '{"source":"cache","path":"/cache/%s","verified":true,"problems":[]}' "$1"
          elif [ -f "$2/ok" ]; then
            printf '{"source":"custom","path":"%s","verified":true,"problems":[]}' "$2"
          else
            printf '{"source":"custom","path":"%s","verified":false,"problems":["%s: model.bin is missing"]}' "$2" "$1"
          fi
        }
        printf '{"version":"1","python":"3","packages":{},"models_dir":"/m","models":{"whisper":%s,"pyannote":%s}}\n' "$(model whisper "$w")" "$(model pyannote "$p")"
        """#
        try script.write(to: paths.engineBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.engineBinary.path)
        let defaults = UserDefaults(suiteName: "info-engine-\(UUID().uuidString)")!
        model = AppModel(paths: paths, settings: AppSettings(defaults: defaults))
    }

    func folder(valid: Bool) throws -> URL {
        let dir = root.appendingPathComponent("models \(valid ? "good" : "bad"); x", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if valid { try "x".write(to: dir.appendingPathComponent("ok"), atomically: true, encoding: .utf8) }
        return dir
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
@Suite("Custom model folders")
struct CustomModelFolderTests {
    @Test func outcomeMapping() {
        func info(_ model: [String: Any]) -> EngineInfo {
            let json: [String: Any] = ["version": "1", "python": "3", "packages": [String: String](), "models_dir": "/m",
                                       "models": ["whisper": model]]
            return try! EngineInfo.decode(JSONSerialization.data(withJSONObject: json))
        }
        #expect(ModelFolderValidation.outcome(kind: "whisper",
            info: info(["source": "custom", "path": "/x", "verified": true, "problems": [String]()])) == .verified(fileCount: 5))
        #expect(ModelFolderValidation.outcome(kind: "whisper",
            info: info(["source": "custom", "path": "/x", "verified": false, "problems": ["a", "b"]])) == .problems(["a", "b"]))
        // Not custom (the engine ignored the folder) or no explanation: still a failure with a message.
        guard case .problems(let generic) = ModelFolderValidation.outcome(kind: "whisper",
            info: info(["source": "cache", "path": "/c", "verified": true, "problems": [String]()])) else {
            Issue.record("a cache result must not count as a verified custom folder"); return
        }
        #expect(!generic.isEmpty)
        guard case .problems = ModelFolderValidation.outcome(kind: "pyannote",
            info: info(["source": "custom", "path": "/x", "verified": true, "problems": [String]()])) else {
            Issue.record("a model the engine did not report is a problem"); return
        }
    }

    @Test func verifiedFolderIsSavedAndPassedToTheEngine() async throws {
        let fx = try FakeInfoEngine()
        defer { fx.cleanup() }
        let good = try fx.folder(valid: true)
        let result = await fx.model.useModelFolder(kind: "whisper", folder: good)
        #expect(result == .verified(fileCount: 5))
        #expect(fx.model.settings.whisperModelDir == good)
        #expect(fx.model.settings.pyannoteModelDir == nil)
        #expect(fx.model.engineInfo?.whisper?.source == "custom")
        // The validation run used the folder as one argument; the refresh used the saved setting.
        let log = try String(contentsOf: fx.argvLog, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(log.first == "engine-info --json --verify --whisper-dir \(good.path)")
        #expect(log.last == "engine-info --json --whisper-dir \(good.path)")
    }

    @Test func folderWithProblemsIsShownAndNotSaved() async throws {
        let fx = try FakeInfoEngine()
        defer { fx.cleanup() }
        let good = try fx.folder(valid: true)
        _ = await fx.model.useModelFolder(kind: "pyannote", folder: good)
        let bad = try fx.folder(valid: false)
        let result = await fx.model.useModelFolder(kind: "pyannote", folder: bad)
        #expect(result == .problems(["pyannote: model.bin is missing"]))
        #expect(fx.model.settings.pyannoteModelDir == good)  // the old value stays
    }

    @Test func goingBackToLiteEchoFolderClearsTheSetting() async throws {
        let fx = try FakeInfoEngine()
        defer { fx.cleanup() }
        _ = await fx.model.useModelFolder(kind: "whisper", folder: try fx.folder(valid: true))
        await fx.model.useLiteEchoFolder(kind: "whisper")
        #expect(fx.model.settings.whisperModelDir == nil)
        #expect(fx.model.engineInfo?.whisper?.source == "cache")
    }

    @Test func aSavedFolderThatWentBadShowsAsMissingAndBlocksNothingElse() {
        let state = ModelStepState(info: engineInfo(whisper: ("custom", nil), pyannote: ("cache", true),
                                                    problems: []))
        #expect(state.canContinue)
        let info = try! EngineInfo.decode(Data(#"{"version":"1","python":"3","packages":{},"models_dir":"/m","models":{"whisper":{"source":"custom","path":"/gone","verified":null,"problems":["whisper model /gone (missing: model.bin)"]},"pyannote":{"source":"cache","path":"/c","verified":true,"problems":[]}}}"#.utf8))
        let broken = ModelStepState(info: info)
        #expect(broken.whisper == .missing)
        #expect(!broken.canContinue)
        #expect(!info.modelsReady)
    }
}
