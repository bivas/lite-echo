import Foundation
import LiteEchoCore
import LiteEchoShared
@testable import LiteEchoQueue

/// A temp support dir with a fake `bin/liteecho` shell script standing in for the engine.
/// Behaviour depends on the audio file name: "fail" → error event, "stderr" → stderr only,
/// "slow" → progress then waits (pid written to `slow.pid`), anything else succeeds.
@MainActor
struct Fixture {
    let root: URL
    let paths: AppPaths
    let model: AppModel
    let store: QueueStore
    let audioDir: URL

    var argvLog: URL { paths.engineDir.appendingPathComponent("bin/argv.log") }
    var pidFile: URL { paths.engineDir.appendingPathComponent("bin/slow.pid") }

    init(paused: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("queue-test-\(UUID().uuidString)")
        paths = AppPaths(supportDir: root.appendingPathComponent("support"), bundleResources: nil)
        audioDir = root.appendingPathComponent("audio folder; with spaces")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.engineDir.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        try Self.script.write(to: paths.engineBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.engineBinary.path)
        let defaults = UserDefaults(suiteName: "queue-tests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.notifyWhenDone = false
        settings.keepAwake = false
        model = AppModel(paths: paths, settings: settings)
        store = QueueStore(model: model)
        store.isPaused = paused
    }

    func makeStore() -> QueueStore { QueueStore(model: model) }

    @discardableResult
    func audio(_ name: String) throws -> URL {
        let url = audioDir.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    /// Argument lists of each engine run, in order.
    func runs() -> [[String]] {
        guard let text = try? String(contentsOf: argvLog, encoding: .utf8) else { return [] }
        var runs: [[String]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "RUN" { runs.append([]) } else if !runs.isEmpty, !line.isEmpty { runs[runs.count - 1].append(String(line)) }
        }
        return runs
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    static let script = """
    #!/bin/sh
    dir=$(dirname "$0")
    { echo RUN; for a in "$@"; do printf '%s\\n' "$a"; done; } >> "$dir/argv.log"
    out="${1%.*}.html"
    case "$1" in
    *fail*)
      echo '{"type":"stage","stage":"convert","completed":1,"total":2,"unit":"steps"}'
      echo '{"type":"error","message":"Boom from engine","detail":null}'
      echo "some noise" >&2
      exit 1;;
    *stderr*)
      echo "first line" >&2
      echo "Last stderr line" >&2
      exit 1;;
    *slow*)
      echo $$ > "$dir/slow.pid"
      echo '{"type":"stage","stage":"transcribe","completed":10,"total":100,"unit":"s"}'
      exec sleep 30;;
    esac
    echo '{"type":"stage","stage":"convert","completed":1,"total":1,"unit":"steps"}'
    echo '{"type":"speakers","count":2}'
    echo '{"type":"language","code":"he"}'
    echo '{"type":"stage","stage":"transcribe","completed":50,"total":100,"unit":"s"}'
    echo "progress log" >&2
    printf '{"type":"done","output":"%s","sampled":[{"start_ms":1000,"end_ms":2000}]}\\n' "$out"
    exit 0
    """
}

/// Polls `condition` every 10 ms until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

extension QueueStore {
    func job(named name: String) -> Job? { jobs.first { $0.audio.lastPathComponent == name } }
    func isDone(_ name: String) -> Bool {
        if case .done = job(named: name)?.state { return true }
        return false
    }
    func isRunning(_ name: String) -> Bool {
        if case .running = job(named: name)?.state { return true }
        return false
    }
}
