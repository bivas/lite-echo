import Foundation

/// Runs one engine command as a child process and streams its JSONL events.
///
/// - stdout: parsed line by line into `EngineEvent`s (non-JSON lines are ignored).
/// - stderr: collected (last 64 KB) for error reports and the engine log.
/// - `cancel()` sends SIGTERM; the engine stops its workers and removes temp files.
///
/// Arguments are passed as an array (never through a shell). Secrets such as the Hugging Face
/// token go in `environment`, never in arguments, because argv is visible to other processes.
public final class EngineProcess: @unchecked Sendable {
    public struct Result: Sendable, Equatable {
        public var exitCode: Int32
        public var cancelled: Bool
        public var stderrTail: String
    }

    private let process = Process()
    private let lock = NSLock()
    private var stderrData = Data()
    private var lineBuffer = LineBuffer()
    private var wasCancelled = false

    public let executable: URL
    public let arguments: [String]

    /// - Parameters:
    ///   - extraEnvironment: merged over a minimal environment (HOME, PATH, LANG, TMPDIR).
    public init(executable: URL, arguments: [String], extraEnvironment: [String: String] = [:],
                currentDirectory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        process.executableURL = executable
        process.arguments = arguments
        var env: [String: String] = [:]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["HOME", "LANG", "TMPDIR", "USER", "LOGNAME"] {
            if let value = inherited[key] { env[key] = value }
        }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PYTHONUNBUFFERED"] = "1"
        env["NO_COLOR"] = "1"
        for (key, value) in extraEnvironment { env[key] = value }
        process.environment = env
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
    }

    /// Starts the process. `onEvent` is called on a background thread for each event, in order;
    /// every event has been delivered when this returns. Returns when the process exits.
    public func run(onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws -> Result {
        let exitCode = try await ChildProcess.run(process, stdout: { [weak self] chunk in
            guard let self else { return }
            self.lock.lock()
            let lines = self.lineBuffer.append(chunk)
            self.lock.unlock()
            for line in lines {
                if let event = EngineEvent.parse(line: line) { onEvent(event) }
            }
        }, stderr: { [weak self] chunk in
            guard let self else { return }
            self.lock.lock()
            self.stderrData.append(chunk)
            if self.stderrData.count > 65_536 {
                self.stderrData.removeFirst(self.stderrData.count - 65_536)
            }
            self.lock.unlock()
        }, afterLaunch: { [weak self] in
            // A cancel() that arrived before launch must still stop the process.
            guard let self else { return }
            self.lock.lock()
            let cancelledEarly = self.wasCancelled
            self.lock.unlock()
            if cancelledEarly { self.process.terminate() }
        })

        lock.lock()
        let last = lineBuffer.flush()
        let tail = String(decoding: stderrData.suffix(65_536), as: UTF8.self)
        let cancelled = wasCancelled
        lock.unlock()
        if let last, let event = EngineEvent.parse(line: last) { onEvent(event) }
        return Result(exitCode: exitCode, cancelled: cancelled, stderrTail: tail)
    }

    /// Asks the engine to stop (SIGTERM). Safe to call more than once or before exit.
    public func cancel() {
        lock.lock()
        wasCancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    public var isRunning: Bool { process.isRunning }
}
