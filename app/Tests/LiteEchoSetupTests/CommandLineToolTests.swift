import Foundation
import Testing
@testable import LiteEchoSetup

@Suite("CommandLineTool")
struct CommandLineToolTests {
    struct Env {
        let home: URL
        let engine: URL
        let installer: CommandLineInstaller
        var link: URL { installer.linkURL }
    }

    private func env() throws -> Env {
        let home = try makeTempDir("cli")
        let engine = home.appendingPathComponent("engine/bin/liteecho")
        try FileManager.default.createDirectory(at: engine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        return Env(home: home, engine: engine, installer: CommandLineInstaller(home: home, engineBinary: engine))
    }

    private func detect(_ e: Env, path: [String], command: String?) -> CommandLineToolStatus {
        CommandLineToolStatus.detect(loginPath: path, resolvedCommand: command, linkURL: e.link, engineBinary: e.engine)
    }

    @Test func installedOnPath() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.home) }
        _ = try e.installer.install { false }
        let s = detect(e, path: ["/usr/bin", e.installer.binDir.path], command: e.link.path)
        #expect(s == .installedOnPath)
    }

    @Test func installedNotOnPath() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.home) }
        _ = try e.installer.install { false }
        #expect(detect(e, path: ["/usr/bin"], command: nil) == .installedNotOnPath)
    }

    @Test func otherOnPathAtOurLinkLocation() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.home) }
        let uv = e.home.appendingPathComponent("uv/tools/liteecho/bin/liteecho")
        try FileManager.default.createDirectory(at: uv.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: uv, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: e.installer.binDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: e.link, withDestinationURL: uv)
        let s = detect(e, path: [e.installer.binDir.path], command: e.link.path)
        guard case .otherOnPath(let cmd, let target, let replaceable) = s else { Issue.record("got \(s)"); return }
        #expect(cmd.path == e.link.path)
        #expect(target.path == uv.resolvingSymlinksInPath().path)
        #expect(replaceable)
    }

    @Test func otherInEarlierDirIsNotReplaceable() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.home) }
        _ = try e.installer.install { false }
        let s = detect(e, path: ["/opt/homebrew/bin", e.installer.binDir.path], command: "/opt/homebrew/bin/liteecho")
        guard case .otherOnPath(_, _, let replaceable) = s else { Issue.record("got \(s)"); return }
        #expect(!replaceable)
    }

    @Test func notInstalled() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.home) }
        #expect(detect(e, path: ["/usr/bin"], command: nil) == .notInstalled(binDirOnPath: false, foreignAtLink: false))
        #expect(detect(e, path: ["/usr/bin", e.installer.binDir.path + "/"], command: nil)
                == .notInstalled(binDirOnPath: true, foreignAtLink: false))
        try FileManager.default.createDirectory(at: e.installer.binDir, withIntermediateDirectories: true)
        try "mine".write(to: e.link, atomically: true, encoding: .utf8)
        #expect(detect(e, path: [], command: "alias liteecho='x'") == .notInstalled(binDirOnPath: false, foreignAtLink: true))
    }

    @Test func uninstallRemovesOnlyOurLink() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.home) }
        #expect(try e.installer.uninstall() == .notInstalled)
        _ = try e.installer.install { false }
        #expect(try e.installer.uninstall() == .removed)
        #expect((try? FileManager.default.attributesOfItem(atPath: e.link.path)) == nil)
        #expect(FileManager.default.fileExists(atPath: e.engine.path))

        try "mine".write(to: e.link, atomically: true, encoding: .utf8)
        #expect(try e.installer.uninstall() == .notOurs)
        #expect(try String(contentsOf: e.link, encoding: .utf8) == "mine")
        try FileManager.default.removeItem(at: e.link)

        try FileManager.default.createSymbolicLink(atPath: e.link.path, withDestinationPath: "/usr/bin/true")
        #expect(try e.installer.uninstall() == .notOurs)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: e.link.path) == "/usr/bin/true")
        try FileManager.default.removeItem(at: e.link)

        try FileManager.default.createDirectory(at: e.link, withIntermediateDirectories: true)
        #expect(try e.installer.uninstall() == .notOurs)
    }

    @Test func shellChoice() {
        let allowed = ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish"]
        #expect(LoginShellProbe.chooseShell(shellEnv: "/bin/bash", allowedShells: allowed) == "/bin/bash")
        #expect(LoginShellProbe.chooseShell(shellEnv: "/opt/homebrew/bin/fish", allowedShells: allowed) == "/opt/homebrew/bin/fish")
        #expect(LoginShellProbe.chooseShell(shellEnv: "/tmp/evil", allowedShells: allowed) == "/bin/zsh")
        #expect(LoginShellProbe.chooseShell(shellEnv: "bash", allowedShells: ["bash"]) == "/bin/zsh")
        #expect(LoginShellProbe.chooseShell(shellEnv: nil, allowedShells: allowed) == "/bin/zsh")
        #expect(LoginShellProbe.parseShellsFile("# c\n/bin/sh\n\n  /bin/zsh  \nnotabs\n") == ["/bin/sh", "/bin/zsh"])
    }

    @Test func shellHints() {
        #expect(ShellKind(shellPath: "/bin/zsh").pathHint.file == "~/.zshrc")
        #expect(ShellKind(shellPath: "/bin/bash").pathHint.file == "~/.bash_profile")
        #expect(ShellKind(shellPath: "/opt/homebrew/bin/fish").pathHint == PathHint(file: nil, line: "fish_add_path ~/.local/bin"))
        #expect(ShellKind(shellPath: "/bin/zsh").pathHint.line == #"export PATH="$HOME/.local/bin:$PATH""#)
    }

    @Test func pathAndOutputParsing() {
        #expect(CommandLineToolStatus.parsePath("/a/:/b::/c") == ["/a", "/b", "/c"])
        #expect(CommandLineToolStatus.parsePath("") == [])
        let out = "Welcome!\nLITEECHO_PATH=/usr/bin:/x/bin/\n/x/bin/liteecho\n"
        let parsed = LoginShellProbe.parseOutput(out)
        #expect(parsed?.path == ["/usr/bin", "/x/bin"])
        #expect(parsed?.command == "/x/bin/liteecho")
        #expect(LoginShellProbe.parseOutput("LITEECHO_PATH=/a\n")?.command == nil)
        #expect(LoginShellProbe.parseOutput("nothing") == nil)
    }

    @Test func processRunnerAndTimeout() {
        #expect(ProcessRunner.run("/bin/sh", ["-c", "echo hi"], timeout: 3) == "hi\n")
        #expect(ProcessRunner.run("/bin/sh", ["-c", "exit 2"], timeout: 3) == nil)
        #expect(ProcessRunner.run("/nonexistent", [], timeout: 1) == nil)
        let start = Date()
        #expect(ProcessRunner.run("/bin/sleep", ["5"], timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func engineVersionFromFakeEngine() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.home) }
        try "#!/bin/sh\necho '{\"version\": \"0.2.0\"}'\n".write(to: e.engine, atomically: true, encoding: .utf8)
        #expect(LoginShellProbe.engineVersion(of: e.engine) == "0.2.0")
        #expect(LoginShellProbe.engineVersion(of: URL(fileURLWithPath: "/nonexistent")) == nil)
    }

    @Test func realProbeDoesNotCrash() {
        let r = LoginShellProbe.probe(environment: ["SHELL": "/tmp/nope", "PATH": "/usr/bin:/bin"])
        #expect(r.shell == "/bin/zsh")
        #expect(!r.path.isEmpty)
    }
}
