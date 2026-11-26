import CryptoKit
import Foundation
import LiteEchoCore

/// Builds the engine virtual environment from the files bundled in the app:
///
///     uv venv --python <ver> --python-preference only-managed <engineDir>
///     uv pip sync --python <engineDir>/bin/python --require-hashes <requirements.txt>
///     uv pip install --python <engineDir>/bin/python --no-deps <wheel>
///
/// A venv embeds its own absolute path (script shebangs, pyvenv.cfg), so it is built directly
/// at its final location instead of in a temp dir that is renamed afterwards. Completion is
/// recorded by a marker file written last; a directory without marker (and not a symlink to a
/// user-chosen engine) is a failed install and is removed before the next attempt.
public struct EngineInstaller: Sendable {
    public enum Step: Int, CaseIterable, Sendable, Equatable {
        case createEnvironment, installPackages, installEngine

        public var title: String {
            switch self {
            case .createEnvironment: "Creating the Python environment"
            case .installPackages: "Installing libraries (about 1 GB, once)"
            case .installEngine: "Installing the LiteEcho engine"
            }
        }
    }

    public enum InstallError: Error, LocalizedError, Equatable {
        /// The app bundle lacks the engine ingredients (e.g. running from `swift run`).
        case bundleMissing([String])
        case stepFailed(step: Step, exitCode: Int32, stderr: String)
        case invalidEngine(String)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .bundleMissing(let files):
                return "This copy of LiteEcho does not contain the engine files (\(files.joined(separator: ", "))). "
                    + "Install the engine from the built LiteEcho.app, or point to an existing engine."
            case .stepFailed(let step, let code, let stderr):
                let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                return "\(step.title) failed (exit code \(code))" + (last.isEmpty ? "." : ": \(last)")
            case .invalidEngine(let message), .io(let message):
                return message
            }
        }

        /// Everything the failing tool printed, for "Show details".
        public var details: String {
            if case .stepFailed(_, _, let stderr) = self { return stderr }
            return errorDescription ?? ""
        }
    }

    public static let markerName = ".liteecho-complete"

    public let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    public var markerURL: URL { paths.engineDir.appendingPathComponent(Self.markerName) }

    private var engineIsSymlink: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: paths.engineDir.path)) != nil
    }

    /// Binary present and either our completion marker or a user-chosen (symlinked) engine.
    public var isComplete: Bool {
        // AppPaths.isEngineInstalled applies the same rule (binary + marker, or a symlinked engine).
        paths.isEngineInstalled
    }

    /// Names of the bundle files that are missing; empty when the engine can be built.
    public var bundleProblems: [String] {
        let fm = FileManager.default
        var problems: [String] = []
        guard let uv = paths.bundledUV, let req = paths.bundledRequirements, let dir = paths.bundledEngineDir else {
            return ["engine/uv", "engine/requirements.txt", "engine/wheel.txt"]
        }
        if !fm.isExecutableFile(atPath: uv.path) { problems.append("engine/uv") }
        if !fm.fileExists(atPath: req.path) { problems.append("engine/requirements.txt") }
        if let wheel = wheelURL(in: dir) {
            if !fm.fileExists(atPath: wheel.path) { problems.append("engine/\(wheel.lastPathComponent)") }
        } else {
            problems.append("engine/wheel.txt")
        }
        return problems
    }

    private func wheelURL(in dir: URL) -> URL? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("wheel.txt"), encoding: .utf8) else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a bare file name: never a path that escapes the bundle folder.
        guard !name.isEmpty, name == (name as NSString).lastPathComponent, name.hasSuffix(".whl") else { return nil }
        return dir.appendingPathComponent(name)
    }

    private func pythonVersion(in dir: URL) -> String {
        let text = (try? String(contentsOf: dir.appendingPathComponent("python-version.txt"), encoding: .utf8)) ?? ""
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? "3.12" : version
    }

    /// The whole environment the helper tool gets.
    func toolEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        return [
            "HOME": inherited["HOME"] ?? NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": inherited["TMPDIR"] ?? NSTemporaryDirectory(),
            "UV_PYTHON_INSTALL_DIR": paths.uvPythonDir.path,
            "UV_CACHE_DIR": paths.uvCacheDir.path,
        ]
    }

    /// Builds the engine. `onStep` fires when a step starts, `onOutput` for each stderr line
    /// the tool prints. On failure or cancellation the half-built directory is removed.
    public func install(onStep: @escaping @Sendable (Step) -> Void = { _ in },
                        onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let problems = bundleProblems
        guard problems.isEmpty, let uv = paths.bundledUV, let req = paths.bundledRequirements,
              let bundleDir = paths.bundledEngineDir, let wheel = wheelURL(in: bundleDir) else {
            throw InstallError.bundleMissing(problems)
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: paths.uvPythonDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: paths.uvCacheDir, withIntermediateDirectories: true)
            if !isComplete { try removeEngineDir() }
        } catch {
            throw InstallError.io("Could not prepare the engine folder: \(error.localizedDescription)")
        }
        if isComplete { return }

        let dir = paths.engineDir.path
        let python = paths.engineDir.appendingPathComponent("bin/python").path
        let steps: [(Step, [String])] = [
            (.createEnvironment, ["venv", "--python", pythonVersion(in: bundleDir),
                                  "--python-preference", "only-managed", dir]),
            (.installPackages, ["pip", "sync", "--python", python, "--require-hashes", req.path]),
            (.installEngine, ["pip", "install", "--python", python, "--no-deps", wheel.path]),
        ]
        do {
            for (step, args) in steps {
                onStep(step)
                let result = try await ToolProcess.run(executable: uv, arguments: args,
                                                       environment: toolEnvironment(), onStderrLine: onOutput)
                guard result.exitCode == 0 else {
                    throw InstallError.stepFailed(step: step, exitCode: result.exitCode, stderr: result.stderrTail)
                }
            }
            guard FileManager.default.isExecutableFile(atPath: paths.engineBinary.path) else {
                throw InstallError.invalidEngine("The engine was built but bin/liteecho is missing.")
            }
            try writeMarker()
        } catch {
            try? removeEngineDir()
            throw error
        }
    }

    // MARK: Updates

    /// Identifies the bundle files an engine was built from. Stored as JSON in the marker.
    public struct Fingerprint: Codable, Equatable, Sendable {
        public var requirements: String
        public var wheel: String
    }

    public enum UpdateNeed: Equatable, Sendable {
        /// Up to date, user-managed (symlinked), not installed, or nothing bundled to compare with.
        case none
        /// Only the liteecho wheel changed: offline, a few seconds; no need to ask.
        case engineOnly
        /// The pinned libraries changed: may download, so ask first.
        case packages
    }

    public var bundleFingerprint: Fingerprint? {
        guard let req = paths.bundledRequirements, let dir = paths.bundledEngineDir,
              let wheel = wheelURL(in: dir),
              let reqHash = Self.sha256(of: req), let wheelHash = Self.sha256(of: wheel) else { return nil }
        return Fingerprint(requirements: reqHash, wheel: wheelHash)
    }

    /// nil for markers written before fingerprints existed (empty file).
    public var installedFingerprint: Fingerprint? {
        guard let data = try? Data(contentsOf: markerURL), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(Fingerprint.self, from: data)
    }

    public var updateNeed: UpdateNeed {
        guard isComplete, !engineIsSymlink, let bundle = bundleFingerprint else { return .none }
        guard let installed = installedFingerprint else {
            // Older install without a fingerprint: refresh the engine and re-check the libraries
            // (a no-op from the local cache when they are unchanged).
            return .engineOnly
        }
        if installed.requirements != bundle.requirements { return .packages }
        return installed.wheel == bundle.wheel ? .none : .engineOnly
    }

    /// Brings an installed engine up to the bundled files. Never deletes a working engine:
    /// on failure the old engine stays as it was (and its marker is left untouched).
    public func update(onStep: @escaping @Sendable (Step) -> Void = { _ in },
                       onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let need = updateNeed
        guard need != .none, let uv = paths.bundledUV, let req = paths.bundledRequirements,
              let dir = paths.bundledEngineDir, let wheel = wheelURL(in: dir) else { return }
        let python = paths.engineDir.appendingPathComponent("bin/python").path
        let syncPackages = need == .packages || installedFingerprint == nil
        var steps: [(Step, [String])] = []
        if syncPackages {
            steps.append((.installPackages, ["pip", "sync", "--python", python, "--require-hashes", req.path]))
        }
        steps.append((.installEngine, ["pip", "install", "--python", python, "--no-deps", "--reinstall", wheel.path]))
        for (step, args) in steps {
            onStep(step)
            let result = try await ToolProcess.run(executable: uv, arguments: args,
                                                   environment: toolEnvironment(), onStderrLine: onOutput)
            guard result.exitCode == 0 else {
                throw InstallError.stepFailed(step: step, exitCode: result.exitCode, stderr: result.stderrTail)
            }
        }
        try writeMarker()
    }

    private func writeMarker() throws {
        let data = (try? bundleFingerprint.map { try JSONEncoder().encode($0) }) ?? nil
        try (data ?? Data()).write(to: markerURL, options: .atomic)
    }

    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func removeEngineDir() throws {
        let fm = FileManager.default
        // `fileExists` follows symlinks; a dangling link must go too.
        if (try? fm.attributesOfItem(atPath: paths.engineDir.path)) != nil {
            try fm.removeItem(at: paths.engineDir)
        }
    }

    /// "Use existing engine…": links engineDir to a folder that has `bin/liteecho`.
    public func useExistingEngine(at folder: URL) throws {
        let fm = FileManager.default
        let binary = folder.appendingPathComponent("bin/liteecho")
        guard fm.isExecutableFile(atPath: binary.path) else {
            throw InstallError.invalidEngine("That folder has no bin/liteecho, so it is not a LiteEcho engine.")
        }
        do {
            try fm.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
            try removeEngineDir()
            try fm.createSymbolicLink(at: paths.engineDir, withDestinationURL: folder)
        } catch {
            throw InstallError.io("Could not link the engine: \(error.localizedDescription)")
        }
    }

    /// Removes the engine (Settings > Reinstall). A symlinked engine only loses the link.
    public func remove() throws { try removeEngineDir() }
}
