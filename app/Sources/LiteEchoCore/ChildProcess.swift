import Foundation

/// Launches a `Process` and reads its stdout/stderr on dedicated threads until EOF.
///
/// Why not `readabilityHandler` + `terminationHandler`: both are delivered on shared GCD queues.
/// The termination handler can run while a readability handler is still holding a chunk, so the
/// last output (a `done` event, the final stderr line) was sometimes lost or arrived after the
/// result; and when many callers block at once (parallel tests on a small CI runner) the GCD pool
/// can be starved so the handlers run late or not at all. Here every chunk is handed over, in
/// order, before `run` returns, and no shared queue is needed.
public enum ChildProcess {
    /// Runs `process` and returns its exit status once it has exited and both pipes reached EOF.
    ///
    /// - Parameters:
    ///   - stdout / stderr: called with each chunk on that stream's own thread, in order. When
    ///     nil the stream goes to /dev/null. stdin is always /dev/null.
    ///   - afterLaunch: called right after a successful launch (e.g. to honour an early cancel).
    /// - Throws: the launch error; nothing after a successful launch.
    public static func run(_ process: Process,
                           stdout: (@Sendable (Data) -> Void)?,
                           stderr: (@Sendable (Data) -> Void)?,
                           afterLaunch: (@Sendable () -> Void)? = nil) async throws -> Int32 {
        let outPipe = stdout.map { _ in Pipe() }
        let errPipe = stderr.map { _ in Pipe() }
        process.standardOutput = outPipe ?? FileHandle.nullDevice
        process.standardError = errPipe ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        afterLaunch?()

        return await withCheckedContinuation { continuation in
            let readers = DispatchGroup()
            for (pipe, handler) in [(outPipe, stdout), (errPipe, stderr)] {
                guard let pipe, let handler else { continue }
                readers.enter()
                let thread = Thread {
                    drain(pipe.fileHandleForReading, into: handler)
                    readers.leave()
                }
                thread.start()
            }
            let waiter = Thread {
                // Blocking here is fine: this is our own thread, not a shared pool worker.
                readers.wait()
                // Poll instead of relying on terminationHandler (also a shared queue).
                while process.isRunning { Thread.sleep(forTimeInterval: 0.005) }
                continuation.resume(returning: process.terminationStatus)
            }
            waiter.start()
        }
    }

    /// Reads `handle` until EOF (all write ends closed), passing each chunk to `handler`.
    private static func drain(_ handle: FileHandle, into handler: (Data) -> Void) {
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                handler(Data(buffer[0..<count]))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        try? handle.close()
    }
}
