import LiteEchoCore
import SwiftUI
import AppKit
import LiteEchoShared

// MARK: - Shell kinds and hints

/// What to tell the user to add to their shell setup, per shell.
public struct PathHint: Equatable, Sendable {
    /// Display name of the startup file (nil for fish, which uses a command).
    public let file: String?
    /// The line (or command) to copy.
    public let line: String
}

public enum ShellKind: Equatable, Sendable {
    case zsh, bash, fish, other

    public init(shellPath: String) {
        switch URL(fileURLWithPath: shellPath).lastPathComponent {
        case "zsh": self = .zsh
        case "bash": self = .bash
        case "fish": self = .fish
        default: self = .other
        }
    }

    public var pathHint: PathHint {
        switch self {
        case .zsh: PathHint(file: "~/.zshrc", line: CommandLineInstaller.pathHint)
        case .bash: PathHint(file: "~/.bash_profile", line: CommandLineInstaller.pathHint)
        case .fish: PathHint(file: nil, line: "fish_add_path ~/.local/bin")
        case .other: PathHint(file: "~/.profile", line: CommandLineInstaller.pathHint)
        }
    }
}

// MARK: - Status (pure)

public enum CommandLineToolStatus: Equatable, Sendable {
    /// Terminal's first `liteecho` is this app's engine.
    case installedOnPath
    /// Our link exists but Terminal does not find it.
    case installedNotOnPath
    /// Terminal's first `liteecho` is something else. `replaceable` is true only when that
    /// something is the file at ~/.local/bin/liteecho; otherwise another PATH folder wins.
    case otherOnPath(command: URL, target: URL, replaceable: Bool)
    /// Nothing of ours. `foreignAtLink`: a different file already sits at ~/.local/bin/liteecho.
    case notInstalled(binDirOnPath: Bool, foreignAtLink: Bool)

    /// Splits a PATH string into normalised directory entries (empty entries dropped).
    public static func parsePath(_ path: String) -> [String] {
        path.split(separator: ":", omittingEmptySubsequences: true).map { entry in
            var s = String(entry)
            while s.count > 1, s.hasSuffix("/") { s.removeLast() }
            return s
        }
    }

    public static func detect(loginPath: [String], resolvedCommand: String?,
                              linkURL: URL, engineBinary: URL) -> CommandLineToolStatus {
        let binDir = linkURL.deletingLastPathComponent().standardizedFileURL.path
        let onPath = loginPath.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == binDir }
        let ours = CommandLineInstaller.linkIsOurs(linkURL: linkURL, engineBinary: engineBinary)
        let engine = engineBinary.resolvingSymlinksInPath().path

        // `command -v` can print an alias or function text; only an absolute path counts.
        if let cmd = resolvedCommand?.trimmingCharacters(in: .whitespacesAndNewlines), cmd.hasPrefix("/") {
            let commandURL = URL(fileURLWithPath: cmd)
            let target = commandURL.resolvingSymlinksInPath()
            if target.path == engine { return .installedOnPath }
            let atLink = commandURL.standardizedFileURL.path == linkURL.standardizedFileURL.path
            return .otherOnPath(command: commandURL, target: target, replaceable: atLink)
        }
        if ours { return .installedNotOnPath }
        let exists = (try? FileManager.default.attributesOfItem(atPath: linkURL.path)) != nil
        return .notInstalled(binDirOnPath: onPath, foreignAtLink: exists)
    }
}

// MARK: - Login shell probe

/// Asks the user's login shell what Terminal would see. Process running is separate from the
/// parsing and the choice of shell, which are pure and tested.
public enum LoginShellProbe {
    public struct Result: Equatable, Sendable {
        public var path: [String]
        public var command: String?
        public var shell: String
        /// True when the login shell could not be asked and the app's own PATH was used.
        public var approximate: Bool
    }

    /// A fixed script: the command name is a constant of this build (liteecho or liteecho-dev),
    /// never user input.
    static var script: String { script(for: AppFlavor.current.commandName) }

    static func script(for command: String) -> String {
        precondition(command.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }, "unsafe command name")
        return #"printf 'LITEECHO_PATH=%s\n' "$PATH"; command -v "# + command + " || true"
    }
    static let pathMarker = "LITEECHO_PATH="

    /// `$SHELL` if it is an absolute path listed in /etc/shells, else /bin/zsh.
    public static func chooseShell(shellEnv: String?, allowedShells: [String]) -> String {
        if let shell = shellEnv, shell.hasPrefix("/"), allowedShells.contains(shell) { return shell }
        return "/bin/zsh"
    }

    /// Absolute paths from the contents of /etc/shells (comments and blanks ignored).
    public static func parseShellsFile(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") }
    }

    /// Reads the marker line for PATH, then the first absolute path after it. Anything else a
    /// profile prints (banners, noise) is ignored.
    public static func parseOutput(_ output: String) -> (path: [String], command: String?)? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let idx = lines.firstIndex(where: { $0.hasPrefix(pathMarker) }) else { return nil }
        let path = CommandLineToolStatus.parsePath(String(lines[idx].dropFirst(pathMarker.count)))
        let command = lines[(idx + 1)...].first { $0.hasPrefix("/") }
        return (path, command)
    }

    public static func probe(environment: [String: String] = ProcessInfo.processInfo.environment,
                             timeout: TimeInterval = 3) -> Result {
        let shellsText = (try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) ?? ""
        let shell = chooseShell(shellEnv: environment["SHELL"], allowedShells: parseShellsFile(shellsText))
        if let out = ProcessRunner.run(shell, ["-i", "-l", "-c", script], timeout: timeout, environment: environment),
           let parsed = parseOutput(out) {
            return Result(path: parsed.path, command: parsed.command, shell: shell, approximate: false)
        }
        return Result(path: CommandLineToolStatus.parsePath(environment["PATH"] ?? ""),
                      command: nil, shell: shell, approximate: true)
    }

    /// `<binary> engine-info --json` → "version", or nil on any failure or timeout.
    public static func engineVersion(of binary: URL, timeout: TimeInterval = 3) -> String? {
        guard let out = ProcessRunner.run(binary.path, ["engine-info", "--json"], timeout: timeout),
              let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? String, !version.isEmpty else { return nil }
        return version
    }
}

/// Runs a program with an arguments array (no shell), a timeout, and no stdin. Returns stdout
/// on a zero exit, nil otherwise (including timeout, where the process is terminated).
enum ProcessRunner {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                    environment: [String: String]? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Read on a dedicated thread, not a GCD worker: when many callers block at once (tests run
        // in parallel on a small CI runner) the GCD pool can be exhausted and the read never starts.
        let box = Box()
        let reader = DispatchSemaphore(value: 0)
        let thread = Thread {
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            box.lock.lock(); box.data = d; box.lock.unlock()
            reader.signal()
        }
        thread.start()

        // One deadline for the process and its output. Poll for exit instead of relying on
        // terminationHandler, which is also delivered on a shared queue.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // A child that outlives the program can hold the pipe open; give up at the deadline then.
        let remaining = max(0, deadline.timeIntervalSinceNow)
        guard reader.wait(timeout: .now() + remaining) == .success else { return nil }
        guard process.terminationStatus == 0 else { return nil }
        box.lock.lock(); defer { box.lock.unlock() }
        return String(data: box.data, encoding: .utf8)
    }
}

// MARK: - View

/// Snapshot/preview hook: when set in the environment, the section shows this state instead of
/// probing the login shell. The app itself never sets it.
public struct CommandLineToolPreview: Sendable {
    public var status: CommandLineToolStatus
    public var shellPath: String
    public var engineVersion: String?
    public init(status: CommandLineToolStatus, shellPath: String = "/bin/zsh", engineVersion: String? = nil) {
        self.status = status
        self.shellPath = shellPath
        self.engineVersion = engineVersion
    }
}

private struct CommandLineToolPreviewKey: EnvironmentKey {
    static let defaultValue: CommandLineToolPreview? = nil
}

extension EnvironmentValues {
    public var commandLineToolPreview: CommandLineToolPreview? {
        get { self[CommandLineToolPreviewKey.self] }
        set { self[CommandLineToolPreviewKey.self] = newValue }
    }
}

/// "Command-line tool" settings section. Drop it into a `Form` (it is a `Section`).
///
///     CommandLineToolSection(engineBinary: model.paths.engineBinary)
public struct CommandLineToolSection: View {
    private struct Snapshot {
        var status: CommandLineToolStatus
        var approximate: Bool
        var hint: PathHint
        var engineVersion: String?
        var otherVersion: String?
    }

    private let engineBinary: URL
    private let home: URL
    @Environment(\.theme) private var theme
    @Environment(\.commandLineToolPreview) private var preview
    @StateVar private var snapshot: Snapshot?
    @StateVar private var busy = false
    @StateVar private var message: String?
    @StateVar private var messageIsError = false
    @StateVar private var confirmReplace = false
    @StateVar private var copied = false

    public init(engineBinary: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.engineBinary = engineBinary
        self.home = home
    }

    private var installer: CommandLineInstaller { CommandLineInstaller(home: home, engineBinary: engineBinary) }

    public var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                if let snapshot {
                    content(snapshot)
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking Terminal…") }
                        .foregroundStyle(theme.secondaryText)
                }
                if let message {
                    Text(message).font(.callout)
                        .foregroundStyle(messageIsError ? theme.danger : theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            SectionLabel("Command-line tool")
        }
        .task { await refresh() }
        .alert("Replace the existing “\(AppFlavor.current.commandName)”?", isPresented: $confirmReplace) {
            Button("Replace", role: .destructive) { replace() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(installer.linkURL.path) will be replaced with a link to this app's engine. The other copy is not deleted if it lives elsewhere, but Terminal will no longer use this path for it.")
        }
    }

    @ViewBuilder private func content(_ s: Snapshot) -> some View {
        switch s.status {
        case .installedOnPath:
            header(theme.success, "Installed and on your PATH",
                   "Typing \(AppFlavor.current.commandName) in Terminal runs this app's engine\(s.engineVersion.map { " (\($0))" } ?? "").")
            Text("~/.local/bin/\(AppFlavor.current.commandName) → \(AppFlavor.current.displayName) engine").font(.callout.monospaced()).foregroundStyle(theme.secondaryText)
            actions {
                Button("Reinstall") { install() }
                Button("Uninstall") { uninstall() }
            }
        case .installedNotOnPath:
            header(theme.warning, "Installed, but not on your PATH",
                   "Terminal doesn't search ~/.local/bin, so typing \(AppFlavor.current.commandName) won't find it yet.")
            pathHint(s.hint)
            actions {
                Button("Check again") { Task { await refresh() } }
                Button("Uninstall") { uninstall() }
            }
        case .otherOnPath(let command, let target, let replaceable):
            header(theme.accent, "A different \(AppFlavor.current.commandName) is on your PATH",
                   "Terminal's first \(AppFlavor.current.commandName) is not this app's engine.")
            VStack(alignment: .leading, spacing: 2) {
                Text(command.path).font(.callout.monospaced())
                if target.path != command.path { Text("→ \(target.path)").font(.callout.monospaced()) }
                if let v = s.otherVersion { Text("Version \(v)").font(.callout) }
            }
            .foregroundStyle(theme.secondaryText).textSelection(.enabled)
            if replaceable {
                actions {
                    Button("Keep it") { message = "Nothing was changed."; messageIsError = false }
                    Button("Replace with the app's…") { confirmReplace = true }
                }
            } else {
                Text("It lives in a folder that comes before ~/.local/bin on your PATH, so a link there would not win. LiteEcho won't touch it; remove or rename it yourself if you'd rather use the app's engine.")
                    .font(.callout).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                actions { Button("Check again") { Task { await refresh() } } }
            }
        case .notInstalled(let binDirOnPath, let foreignAtLink):
            header(theme.secondaryText, "Not installed",
                   "Adds a \(AppFlavor.current.commandName) command to Terminal that runs this app's engine.")
            if foreignAtLink {
                Text("A different file already exists at ~/.local/bin/\(AppFlavor.current.commandName); you'll be asked before it is replaced.")
                    .font(.callout).foregroundStyle(theme.secondaryText)
            }
            if binDirOnPath {
                Text("~/.local/bin is already on your PATH.").font(.callout).foregroundStyle(theme.secondaryText)
            } else {
                Text("~/.local/bin is not on your PATH yet, so you'll need one more step after installing:")
                    .font(.callout).foregroundStyle(theme.secondaryText)
                pathHint(s.hint)
            }
            actions { Button("Install") { install() } }
        }
        if s.approximate {
            Text("Couldn't ask your login shell, so this check is approximate.")
                .font(.caption).foregroundStyle(theme.secondaryText)
        }
    }

    private func header(_ color: Color, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(title).font(.body.weight(.semibold))
            }
            Text(detail).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func pathHint(_ hint: PathHint) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hint.file.map { "Add this line to \($0), then open a new Terminal window:" }
                 ?? "Run this once in Terminal:")
                .font(.callout).foregroundStyle(theme.secondaryText)
            HStack {
                Text(hint.line).font(.callout.monospaced()).textSelection(.enabled)
                Spacer(minLength: 8)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hint.line, forType: .string)
                    copied = true
                }
                .buttonStyle(.themedSecondary).controlSize(.small)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: theme.cornerRadius).fill(theme.control))
        }
    }

    private func actions<C: View>(@ViewBuilder _ buttons: () -> C) -> some View {
        HStack { buttons() }.buttonStyle(.themedSecondary).disabled(busy)
    }

    // MARK: Actions

    private func refresh() async {
        let engine = engineBinary, home = home
        if let preview {
            snapshot = Snapshot(status: preview.status, approximate: false,
                                hint: ShellKind(shellPath: preview.shellPath).pathHint,
                                engineVersion: preview.engineVersion, otherVersion: nil)
            return
        }
        busy = true
        let snap: Snapshot = await Task.detached {
            let probe = LoginShellProbe.probe()
            let linkURL = CommandLineInstaller(home: home, engineBinary: engine).linkURL
            let status = CommandLineToolStatus.detect(loginPath: probe.path, resolvedCommand: probe.command,
                                                      linkURL: linkURL, engineBinary: engine)
            var engineVersion: String?
            var otherVersion: String?
            switch status {
            case .installedOnPath: engineVersion = LoginShellProbe.engineVersion(of: engine)
            case .otherOnPath(let command, _, _): otherVersion = LoginShellProbe.engineVersion(of: command)
            default: break
            }
            return Snapshot(status: status, approximate: probe.approximate,
                            hint: ShellKind(shellPath: probe.shell).pathHint,
                            engineVersion: engineVersion, otherVersion: otherVersion)
        }.value
        snapshot = snap
        busy = false
    }

    private func install() {
        message = nil
        do {
            let outcome = try installer.install {
                let alert = NSAlert()
                alert.messageText = "Replace the existing “\(AppFlavor.current.commandName)”?"
                alert.informativeText = "\(installer.linkURL.path) already exists and was not created by LiteEcho. Replace it with a link to the app's engine?"
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                alert.alertStyle = .warning
                return alert.runModal() == .alertFirstButtonReturn
            }
            messageIsError = false
            if outcome == .declined { message = "Nothing was changed." }
        } catch {
            messageIsError = true
            message = error.localizedDescription
        }
        Task { await refresh() }
    }

    private func replace() {
        message = nil
        do {
            _ = try installer.install { true }
            messageIsError = false
        } catch {
            messageIsError = true
            message = error.localizedDescription
        }
        Task { await refresh() }
    }

    private func uninstall() {
        message = nil
        do {
            switch try installer.uninstall() {
            case .removed: messageIsError = false
            case .notInstalled: messageIsError = false; message = "It was already removed."
            case .notOurs:
                messageIsError = true
                message = "~/.local/bin/\(AppFlavor.current.commandName) isn't a link to this app's engine, so it was left alone."
            }
        } catch {
            messageIsError = true
            message = error.localizedDescription
        }
        Task { await refresh() }
    }
}
