import Foundation
import LiteEchoCore
import LiteEchoShared
import Observation

/// Runs `fetch-models` for one model at a time per kind and tracks its progress.
/// Shared by the setup flow and the Settings > Models tab.
@MainActor
@Observable
public final class ModelFetcher {
    public enum State: Equatable {
        case idle
        case running(DownloadProgress?)
        case failed(String)
        case finished
    }

    public private(set) var states: [String: State] = [:]
    private var processes: [String: EngineProcess] = [:]
    public let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    public func state(for kind: String) -> State { states[kind] ?? .idle }
    public func isRunning(_ kind: String) -> Bool { if case .running = state(for: kind) { true } else { false } }

    /// Arguments for a download. The token is never part of them.
    public static func arguments(kind: String, force: Bool) -> [String] {
        EngineCommand.fetchModels(only: kind) + (force ? ["--force"] : [])
    }

    /// The process for one download. The token travels only in the environment.
    public static func makeProcess(model: AppModel, kind: String, token: String?, force: Bool) -> EngineProcess {
        var extra: [String: String] = [:]
        if let token, !token.isEmpty { extra["HF_TOKEN"] = token }
        return model.makeEngineProcess(arguments(kind: kind, force: force), extraEnvironment: extra)
    }

    public func cancel(_ kind: String) { processes[kind]?.cancel() }

    public func reset(_ kind: String) { states[kind] = .idle }

    /// Downloads one model. For pyannote the token is saved to the Keychain first
    /// (and rolled back if Hugging Face rejects it).
    public func download(kind: String, token: String? = nil, force: Bool = false, model: AppModel) async {
        guard !isRunning(kind) else { return }
        states[kind] = .running(nil)

        var effectiveToken: String?
        var previousToken: String?
        var savedNewToken = false
        if kind == "pyannote" {
            previousToken = keychain.load()
            let typed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            effectiveToken = typed.isEmpty ? previousToken : typed
            guard let effective = effectiveToken, !effective.isEmpty else {
                states[kind] = .failed("Paste your Hugging Face access token first.")
                return
            }
            if effective != previousToken {
                do { try keychain.save(effective); savedNewToken = true } catch {
                    states[kind] = .failed("Could not save the token to the Keychain: \(error.localizedDescription)")
                    return
                }
            }
        }

        let process = Self.makeProcess(model: model, kind: kind, token: effectiveToken, force: force)
        processes[kind] = process
        let started = Date()
        let box = EventBox()
        do {
            let result = try await process.run { [weak self] event in
                switch event {
                case .stage(.download, let completed, let total, _, let eventKind) where eventKind == nil || eventKind == kind:
                    let progress = DownloadProgress(completed: completed, total: total,
                                                    elapsed: Date().timeIntervalSince(started))
                    Task { @MainActor in
                        guard let self, case .running = self.state(for: kind) else { return }
                        self.states[kind] = .running(progress)
                    }
                case .error(let message, _):
                    box.setError(message)
                default:
                    break
                }
            }
            processes[kind] = nil
            if result.cancelled {
                states[kind] = .idle
                return
            }
            if result.exitCode == 0, box.error == nil {
                await model.refreshEngineInfo(verify: false)
                if ModelAvailability(model.engineInfo?.models[kind]) .isReady {
                    states[kind] = .finished
                } else {
                    states[kind] = .failed("The download finished, but the files did not check out. Try again.")
                }
                return
            }
            let raw = box.error
                ?? result.stderrTail.split(whereSeparator: \.isNewline).last.map(String.init)
                ?? "The download failed (exit code \(result.exitCode))."
            fail(kind: kind, raw: raw, token: effectiveToken, rollback: savedNewToken, previous: previousToken)
        } catch {
            processes[kind] = nil
            fail(kind: kind, raw: error.localizedDescription, token: effectiveToken,
                 rollback: savedNewToken, previous: previousToken)
        }
    }

    private func fail(kind: String, raw: String, token: String?, rollback: Bool, previous: String?) {
        if rollback, isAuthError(raw) {
            if let previous { try? keychain.save(previous) } else { try? keychain.delete() }
        }
        states[kind] = .failed(friendlyDownloadError(raw, kind: kind, token: token))
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: String?
    var error: String? { lock.lock(); defer { lock.unlock() }; return _error }
    func setError(_ message: String) { lock.lock(); _error = message; lock.unlock() }
}
