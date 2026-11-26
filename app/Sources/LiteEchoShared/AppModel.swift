import Foundation
import LiteEchoCore
import Observation

/// App-wide state shared by every feature (owned by the orchestrator; features read it,
/// and may call its methods, but keep their own state in their own modules).
@MainActor
@Observable
public final class AppModel {
    public let paths: AppPaths
    public let settings: AppSettings
    /// Last `engine-info` result; nil until the engine is installed and has answered.
    public private(set) var engineInfo: EngineInfo?
    public private(set) var engineInfoError: String?
    /// Set by SetupView when the user finishes or skips setup.
    public var setupDismissed = false
    /// Set after migrating from the former "localScribe" install: the old engine was deleted
    /// and setup rebuilds it without asking (the user already consented once).
    public var reinstallEngineWithoutAsking = false

    /// The Settings tab to show; set it before opening the Settings window to pick one.
    public var settingsTab: SettingsTab = .general

    /// Asks the main window to show the Voice Memos import sheet (File menu, menu bar, Preferences).
    public var showVoiceMemoImport = false

    /// Replaces the engine call that lists Voice Memos (tests and previews).
    @ObservationIgnored public var voiceMemoLister: (@MainActor () async -> VoiceMemoListing)?

    /// Snapshot/preview hook only: when set, `refreshEngineInfo` and folder validation never run
    /// the engine and `engineInfo` stays as given to `useFixedEngineInfoForSnapshots`.
    public private(set) var engineInfoIsFixedForSnapshots = false

    /// Used by the LiteEchoSnapshots tool to render screens without an engine process.
    public func useFixedEngineInfoForSnapshots(_ info: EngineInfo?) {
        engineInfo = info
        engineInfoError = nil
        engineInfoIsFixedForSnapshots = true
    }

    public init(paths: AppPaths = .standard, settings: AppSettings? = nil) {
        self.paths = paths
        self.settings = settings ?? AppSettings()
    }

    public var isEngineInstalled: Bool { paths.isEngineInstalled }
    public var modelsReady: Bool { engineInfo?.modelsReady ?? false }
    /// Languages to offer: the engine's list, or a built-in minimal one for older engines.
    public var languages: [LanguageInfo] { LanguageCatalog.usable(engineInfo?.languages) }
    public var needsSetup: Bool { !setupDismissed && !(isEngineInstalled && modelsReady) }

    /// Environment for engine processes: the shared models folder, so the CLI and app agree.
    public var engineEnvironment: [String: String] {
        ["LITEECHO_CACHE": paths.modelsDir.path]
    }

    /// Creates an engine process for `arguments` (the caller runs and cancels it).
    public func makeEngineProcess(_ arguments: [String], extraEnvironment: [String: String] = [:]) -> EngineProcess {
        EngineProcess(executable: paths.engineBinary, arguments: arguments,
                      extraEnvironment: engineEnvironment.merging(extraEnvironment) { $1 })
    }

    /// Runs `liteecho engine-info --json` and stores the result.
    public func refreshEngineInfo(verify: Bool = false) async {
        guard !engineInfoIsFixedForSnapshots else { return }
        guard isEngineInstalled else {
            engineInfo = nil
            engineInfoError = nil
            return
        }
        do {
            let output = try await Self.capture(executable: paths.engineBinary,
                                                arguments: EngineCommand.engineInfo(verify: verify,
                                                                                whisperDir: settings.whisperModelDir,
                                                                                pyannoteDir: settings.pyannoteModelDir),
                                                environment: engineEnvironment)
            engineInfo = try EngineInfo.decode(output)
            engineInfoError = nil
        } catch {
            engineInfoError = String(describing: error)
        }
    }

    /// Checks `folder` as the folder of one model (`engine-info --verify --whisper-dir X`) without
    /// touching the saved setting.
    public func validateModelFolder(kind: String, folder: URL) async -> ModelFolderValidation {
        guard !engineInfoIsFixedForSnapshots else { return .problems(["Snapshot mode: the engine is not run."]) }
        guard isEngineInstalled else { return .problems(["The engine is not installed yet."]) }
        do {
            let output = try await Self.capture(
                executable: paths.engineBinary,
                arguments: EngineCommand.engineInfo(verify: true,
                                                    whisperDir: kind == "whisper" ? folder : nil,
                                                    pyannoteDir: kind == "pyannote" ? folder : nil),
                environment: engineEnvironment)
            return ModelFolderValidation.outcome(kind: kind, info: try EngineInfo.decode(output))
        } catch {
            return .problems(["The engine could not check this folder."])
        }
    }

    /// Validates `folder` and saves it as the model's folder only when every file checks out.
    /// On problems nothing changes (the previous value stays).
    @discardableResult
    public func useModelFolder(kind: String, folder: URL) async -> ModelFolderValidation {
        let result = await validateModelFolder(kind: kind, folder: folder)
        if case .verified = result {
            settings.setModelDir(folder, for: kind)
            await refreshEngineInfo()
        }
        return result
    }

    /// Goes back to LiteEcho's own folder for this model.
    public func useLiteEchoFolder(kind: String) async {
        settings.setModelDir(nil, for: kind)
        await refreshEngineInfo()
    }

    /// Runs `liteecho voice-memos list --json`. Never throws: any problem becomes an `unreadable` listing.
    public func listVoiceMemos() async -> VoiceMemoListing {
        if let voiceMemoLister { return await voiceMemoLister() }
        guard isEngineInstalled else { return .unreadable("The engine is not installed yet.") }
        do {
            let output = try await Self.capture(executable: paths.engineBinary,
                                                arguments: EngineCommand.voiceMemoList(),
                                                environment: engineEnvironment)
            return try VoiceMemoListing.decode(output)
        } catch let CaptureError.exit(code) {
            return .unreadable("The engine stopped with exit code \(code) while listing Voice Memos.")
        } catch {
            return .unreadable("The engine's answer could not be read: \(error.localizedDescription)")
        }
    }

    /// Runs a short command and returns its stdout.
    public nonisolated static func capture(executable: URL, arguments: [String],
                                    environment: [String: String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var env = ["PATH": "/usr/bin:/bin", "PYTHONUNBUFFERED": "1"]
            for key in ["HOME", "LANG", "TMPDIR", "USER"] {
                if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
            }
            process.environment = env.merging(environment) { $1 }
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            // Read while the process runs: a long answer (a big Voice Memos list) would otherwise
            // fill the pipe and block the engine forever.
            let collected = CaptureBuffer()
            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { collected.append(chunk) }
            }
            process.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                collected.append(out.fileHandleForReading.readDataToEndOfFile())
                let data = collected.data
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CaptureError.exit(proc.terminationStatus))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    public enum CaptureError: Error { case exit(Int32) }

    private final class CaptureBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func append(_ chunk: Data) { lock.lock(); storage.append(chunk); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    }
}

/// Tabs of the Settings window.
public enum SettingsTab: String, Hashable, Sendable {
    case general, models, voiceMemos, advanced
}

/// Result of checking a folder a user picked for one model.
public enum ModelFolderValidation: Equatable, Sendable {
    /// Every expected file is there and matches; `fileCount` files were checked.
    case verified(fileCount: Int)
    case problems([String])

    /// Files each model needs (both pinned to five by the engine).
    public static func expectedFileCount(kind: String) -> Int { 5 }

    /// Reads `models.<kind>` of a `--verify` answer made with that kind's folder.
    public static func outcome(kind: String, info: EngineInfo) -> ModelFolderValidation {
        guard let model = info.models[kind] else { return .problems(["The engine did not report this model."]) }
        if model.source == "custom", model.verified == true, model.problems.isEmpty {
            return .verified(fileCount: expectedFileCount(kind: kind))
        }
        if !model.problems.isEmpty { return .problems(model.problems) }
        return .problems(["This folder does not hold the files this model needs."])
    }
}
