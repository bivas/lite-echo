import Foundation
import LiteEchoCore

func makeTempDir(_ name: String = "setup") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("liteecho-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A fake app bundle (Resources/engine/...) with a fake `uv` that records argv and env.
struct FakeBundle {
    let root: URL
    let resources: URL
    let paths: AppPaths
    var log: URL { root.appendingPathComponent("uv.log") }
    var failFlag: URL { resources.appendingPathComponent("engine/fail-on") }

    init(includeUV: Bool = true, includeWheelFile: Bool = true) throws {
        root = try makeTempDir("bundle")
        resources = root.appendingPathComponent("Resources", isDirectory: true)
        let engine = resources.appendingPathComponent("engine", isDirectory: true)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        try "requirements".write(to: engine.appendingPathComponent("requirements.txt"), atomically: true, encoding: .utf8)
        try "liteecho-0.1.0-py3-none-any.whl\n".write(to: engine.appendingPathComponent("wheel.txt"), atomically: true, encoding: .utf8)
        try "3.12\n".write(to: engine.appendingPathComponent("python-version.txt"), atomically: true, encoding: .utf8)
        if includeWheelFile {
            try "wheel".write(to: engine.appendingPathComponent("liteecho-0.1.0-py3-none-any.whl"), atomically: true, encoding: .utf8)
        }
        if includeUV {
            let script = """
            #!/bin/sh
            echo "ARGS $*" >> "\(root.path)/uv.log"
            env | sort | sed 's/^/ENV /' >> "\(root.path)/uv.log"
            sub="$1 $2"
            flag="$(dirname "$0")/fail-on"
            if [ -f "$flag" ] && [ "$(cat "$flag")" = "$1" -o "$(cat "$flag")" = "$sub" ]; then
              echo "resolving…" >&2
              echo "error: simulated failure" >&2
              exit 3
            fi
            case "$1" in
              venv)
                for last; do :; done
                mkdir -p "$last/bin"
                echo partial > "$last/pyvenv.cfg"
                ;;
              pip)
                if [ "$2" = "install" ]; then
                  while [ $# -gt 0 ]; do
                    if [ "$1" = "--python" ]; then py="$2"; fi
                    shift
                  done
                  d="$(dirname "$(dirname "$py")")"
                  printf '#!/bin/sh\\nexit 0\\n' > "$d/bin/liteecho"
                  chmod +x "$d/bin/liteecho"
                fi
                ;;
            esac
            exit 0
            """
            let uv = engine.appendingPathComponent("uv")
            try script.write(to: uv, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        }
        paths = AppPaths(supportDir: root.appendingPathComponent("support", isDirectory: true), bundleResources: resources)
    }

    var logText: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
    var argLines: [String] { logText.split(separator: "\n").filter { $0.hasPrefix("ARGS ") }.map { String($0.dropFirst(5)) } }
    var envLines: [String] { logText.split(separator: "\n").filter { $0.hasPrefix("ENV ") }.map { String($0.dropFirst(4)) } }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

func engineInfo(whisper: (String, Bool?)?, pyannote: (String, Bool?)?, problems: [String] = []) -> EngineInfo {
    func model(_ spec: (String, Bool?)?) -> [String: Any] {
        guard let spec else { return ["source": "missing", "path": NSNull(), "verified": NSNull(), "problems": ["missing"]] }
        return ["source": spec.0, "path": "/x", "verified": spec.1 as Any? ?? NSNull(),
                "problems": spec.1 == false ? problems : []]
    }
    let json: [String: Any] = ["version": "0.1.0", "python": "3.12", "packages": [String: String](),
                               "models_dir": "/m",
                               "models": ["whisper": model(whisper), "pyannote": model(pyannote)]]
    return try! EngineInfo.decode(JSONSerialization.data(withJSONObject: json))
}
