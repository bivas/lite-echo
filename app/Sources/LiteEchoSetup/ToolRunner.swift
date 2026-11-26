import Foundation
import LiteEchoCore

/// Runs one helper executable (the bundled `uv`) with an explicit environment and reports
/// stderr lines as they arrive. Arguments are an array; no shell is involved.
final class ToolProcess: @unchecked Sendable {
    struct Result: Sendable, Equatable {
        var exitCode: Int32
        var stderrTail: String
    }

    private let process = Process()
    private let lock = NSLock()
    private var tail = Data()
    private var pending = Data()
    private var cancelled = false
    private let onLine: @Sendable (String) -> Void

    init(executable: URL, arguments: [String], environment: [String: String],
         onStderrLine: @escaping @Sendable (String) -> Void) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        onLine = onStderrLine
    }

    private func consume(_ chunk: Data, flush: Bool = false) {
        lock.lock()
        tail.append(chunk)
        if tail.count > 65_536 { tail.removeFirst(tail.count - 65_536) }
        pending.append(chunk)
        var lines: [String] = []
        while let idx = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            lines.append(String(decoding: pending[pending.startIndex..<idx], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...idx)
        }
        if flush, !pending.isEmpty {
            lines.append(String(decoding: pending, as: UTF8.self))
            pending.removeAll()
        }
        lock.unlock()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { onLine(trimmed) }
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    func run() async throws -> Result {
        if isCancelled { throw CancellationError() }

        let exitCode = try await ChildProcess.run(process, stdout: nil, stderr: { [weak self] chunk in
            self?.consume(chunk)
        }, afterLaunch: { [weak self] in
            // A cancel() that arrived before launch must still stop the process.
            guard let self, self.isCancelled else { return }
            self.process.terminate()
        })
        consume(Data(), flush: true)
        lock.lock()
        let result = Result(exitCode: exitCode, stderrTail: String(decoding: tail, as: UTF8.self))
        lock.unlock()
        if isCancelled { throw CancellationError() }
        return result
    }

    static func run(executable: URL, arguments: [String], environment: [String: String],
                    onStderrLine: @escaping @Sendable (String) -> Void) async throws -> Result {
        let tool = ToolProcess(executable: executable, arguments: arguments,
                               environment: environment, onStderrLine: onStderrLine)
        return try await withTaskCancellationHandler {
            try await tool.run()
        } onCancel: {
            tool.cancel()
        }
    }
}
