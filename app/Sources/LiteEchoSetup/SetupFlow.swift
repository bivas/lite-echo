import Foundation
import LiteEchoCore
import LiteEchoShared
import Observation

/// State of the first setup step: getting the engine onto this Mac.
@MainActor
@Observable
public final class SetupFlow {
    public enum EnginePhase: Equatable {
        case checking
        /// The engine is missing and can be installed: wait for the user to start the download.
        case needsInstall
        case bundleMissing([String])
        case installing(step: EngineInstaller.Step, lastLine: String)
        case failed(message: String, details: String)
        case ready
    }

    public private(set) var phase: EnginePhase = .checking
    public var showDetails = false

    public init() {}

    /// Decides what to show on first appearance: nothing if the engine exists, else ask before
    /// installing (it downloads about 1 GB, so it never starts without a click), except when
    /// migrating from the former install, which the user already agreed to.
    public func begin(model: AppModel) async {
        guard phase == .checking || isFailed else { return }
        let installer = EngineInstaller(paths: model.paths)
        if model.paths.isEngineInstalled {
            phase = .ready
            await model.refreshEngineInfo()
            return
        }
        let problems = installer.bundleProblems
        if !problems.isEmpty {
            phase = .bundleMissing(problems)
            return
        }
        if model.reinstallEngineWithoutAsking {
            model.reinstallEngineWithoutAsking = false
            await install(model: model)
            return
        }
        phase = .needsInstall
    }

    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    public func install(model: AppModel) async {
        let installer = EngineInstaller(paths: model.paths)
        showDetails = false
        phase = .installing(step: .createEnvironment, lastLine: "")
        let current = StepBox()
        do {
            try await installer.install(
                onStep: { step in
                    current.step = step
                    Task { @MainActor [weak self] in self?.phase = .installing(step: step, lastLine: "") }
                },
                onOutput: { line in
                    let step = current.step
                    Task { @MainActor [weak self] in
                        guard let self, case .installing = self.phase else { return }
                        self.phase = .installing(step: step, lastLine: line)
                    }
                })
            phase = .ready
            await model.refreshEngineInfo()
        } catch is CancellationError {
            phase = .checking
        } catch let error as EngineInstaller.InstallError {
            if case .bundleMissing(let files) = error { phase = .bundleMissing(files) } else {
                phase = .failed(message: error.localizedDescription, details: error.details)
            }
        } catch {
            phase = .failed(message: error.localizedDescription, details: error.localizedDescription)
        }
    }

    public func useExistingEngine(at folder: URL, model: AppModel) async {
        do {
            try EngineInstaller(paths: model.paths).useExistingEngine(at: folder)
            phase = .ready
            await model.refreshEngineInfo()
        } catch {
            phase = .failed(message: error.localizedDescription, details: error.localizedDescription)
        }
    }
}

private final class StepBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _step = EngineInstaller.Step.createEnvironment
    var step: EngineInstaller.Step {
        get { lock.lock(); defer { lock.unlock() }; return _step }
        set { lock.lock(); _step = newValue; lock.unlock() }
    }
}
