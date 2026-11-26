import AppKit
import LiteEchoCore
import LiteEchoQueue
import LiteEchoSetup
import LiteEchoShared
import SwiftUI

// Renders the real LiteEcho views offscreen into PNGs for the README.
//
//   LiteEchoSnapshots <output-dir> [screen-name ...]
//
// Everything is isolated: a temp support folder with a do-nothing fake engine, a throwaway
// UserDefaults suite, a Keychain service that does not exist, and a fixed `engineInfo`
// (AppModel.useFixedEngineInfoForSnapshots) so the engine is never started. Sample data only.

// MARK: - Sample environment

/// Looks like an app-support folder in the screenshots; lives in /tmp and is deleted afterwards.
let sandboxRoot = URL(fileURLWithPath: "/tmp/liteecho-demo", isDirectory: true)
let supportDir = sandboxRoot.appendingPathComponent("Library/Application Support/LiteEcho", isDirectory: true)
let customWhisperFolder = URL(fileURLWithPath: "/Users/demo/Models/faster-whisper-large-v3-turbo", isDirectory: true)

enum ModelsState {
    case bothReady          // whisper on a custom folder, pyannote in LiteEcho's folder
    case bothMissing        // first-run setup
}

@MainActor
struct Sample {
    let model: AppModel
    let queue: QueueStore
    let defaultsName: String

    init(theme: Theme, models: ModelsState, withQueue: Bool) throws {
        let fm = FileManager.default
        let paths = AppPaths(supportDir: supportDir, bundleResources: nil)
        // A harmless stand-in so the app treats the engine as installed. It is never run.
        try fm.createDirectory(at: paths.engineBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 1\n".write(to: paths.engineBinary, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.engineBinary.path)
        fm.createFile(atPath: paths.engineCompleteMarker.path, contents: Data())

        defaultsName = "liteecho-snapshots-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let settings = AppSettings(defaults: defaults)
        settings.theme = theme
        settings.notifyWhenDone = true
        settings.keepAwake = false   // no power assertion while rendering
        if models == .bothReady { settings.whisperModelDir = customWhisperFolder }

        model = AppModel(paths: paths, settings: settings)
        model.useFixedEngineInfoForSnapshots(Self.engineInfo(models, paths: paths))
        model.setupDismissed = false

        let queueFile = sandboxRoot.appendingPathComponent("queue.json")
        if withQueue { try Self.writeQueue(to: queueFile) }
        queue = QueueStore(model: model, storeURL: queueFile)
        // Nothing here calls pump(), so no job can start (and the engine is a stub anyway).
        queue.showSavedJobsAsIsForSnapshots()
    }

    /// Audio durations load asynchronously; wait until every queued file has one.
    func waitForDurations() {
        let deadline = Date().addingTimeInterval(10)
        while queue.durations.count < queue.jobs.count, Date() < deadline { pump(0.1) }
        pump(0.2)
    }

    func cleanup() { UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName) }

    static func engineInfo(_ state: ModelsState, paths: AppPaths) -> EngineInfo {
        func model(source: String, path: String?, verified: Bool?) -> [String: Any] {
            ["source": source, "path": path as Any? ?? NSNull(), "verified": verified as Any? ?? NSNull(),
             "problems": source == "missing" ? ["The model files are not on this Mac yet."] : [String]()]
        }
        let whisper: [String: Any], pyannote: [String: Any]
        switch state {
        case .bothReady:
            whisper = model(source: "custom", path: customWhisperFolder.path, verified: true)
            pyannote = model(source: "cache",
                             path: paths.modelsDir.appendingPathComponent("pyannote-community-1").path, verified: true)
        case .bothMissing:
            whisper = model(source: "missing", path: nil, verified: nil)
            pyannote = model(source: "missing", path: nil, verified: nil)
        }
        let json: [String: Any] = [
            "version": "0.5.0", "python": "3.12.13",
            "packages": ["faster-whisper": "1.2.1", "pyannote.audio": "4.0.7", "torch": "2.8.0",
                         "ctranslate2": "4.6.0", "numpy": "2.2.6"],
            "models_dir": paths.modelsDir.path,
            "models": ["whisper": whisper, "pyannote": pyannote],
        ]
        return try! EngineInfo.decode(JSONSerialization.data(withJSONObject: json))
    }

    /// A silent mono WAV of `seconds` (sparse file: the header says how long it is), so the queue
    /// can show real durations without keeping real recordings around.
    static func writeAudio(_ name: String, seconds: Int, in dir: URL) throws -> URL {
        let rate = 8000
        let dataSize = rate * seconds
        var header = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; header.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; header.append(Data(bytes: &x, count: 2)) }
        header.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        header.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate); u16(1); u16(8)
        header.append("data".data(using: .ascii)!); u32(dataSize)
        let url = dir.appendingPathComponent(name)
        try header.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(header.count + dataSize))
        try handle.close()
        return url
    }

    static func writeQueue(to file: URL) throws {
        let dir = sandboxRoot.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        let auto = JobOptions()
        func job(_ name: String, seconds: Int, age: TimeInterval, state: JobState,
                 language: String? = nil, speakers: Int? = nil) throws -> Job {
            let audio = try writeAudio(name, seconds: seconds, in: dir)
            return Job(audio: audio, options: auto, state: state, addedAt: now.addingTimeInterval(-age),
                       detectedLanguage: language, detectedSpeakers: speakers)
        }
        func done(_ name: String) -> JobState {
            .done(output: dir.appendingPathComponent((name as NSString).deletingPathExtension + ".html"), sampled: [])
        }
        let jobs = [
            try job("Interview draft.mp3", seconds: 33 * 60 + 8, age: 3600, state: done("Interview draft.mp3"),
                    language: "he", speakers: 2),
            try job("Team sync.m4a", seconds: 47 * 60 + 12, age: 2400, state: done("Team sync.m4a"),
                    language: "en", speakers: 3),
            // 30% + 70% * 0.214 = 45% overall.
            try job("Customer call.m4a", seconds: 21 * 60 + 51, age: 600,
                    state: .running(stage: .transcribe, progress: 0.214, detail: "04:41 of 21:51 · about 14 min left"),
                    language: "he", speakers: 2),
            try job("Product demo.m4a", seconds: 8 * 60 + 5, age: 60, state: .waiting),
        ]
        try JSONEncoder().encode(jobs).write(to: file)
    }
}

// MARK: - Rendering

/// A window that may sit at any position, including off every screen.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// Draws `view` into a 2x bitmap of `frameView` (the whole window incl. title bar when given).
@MainActor
func bitmap(of target: NSView, scale: CGFloat = 2) -> NSBitmapImageRep {
    target.layoutSubtreeIfNeeded()
    let bounds = target.bounds
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = bounds.size   // pixels/points = 2: cacheDisplay renders at 2x
    target.cacheDisplay(in: bounds, to: rep)
    return rep
}

/// Rounded window shape with a soft drop shadow on a transparent canvas.
@MainActor
func framed(_ rep: NSBitmapImageRep, cornerRadius: CGFloat, margin: CGFloat = 40) -> NSBitmapImageRep {
    let scale = CGFloat(rep.pixelsWide) / rep.size.width
    let size = NSSize(width: rep.size.width + 2 * margin, height: rep.size.height + 2 * margin)
    let out = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = size
    let ctx = NSGraphicsContext(bitmapImageRep: out)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let rect = NSRect(x: margin, y: margin, width: rep.size.width, height: rep.size.height)
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    path.addClip()
    rep.draw(in: rect)
    NSColor.black.withAlphaComponent(0.18).setStroke()
    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: cornerRadius, yRadius: cornerRadius)
    border.lineWidth = 0.5
    border.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return out
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "snapshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try data.write(to: url)
}

/// Hosts `content` in a titled window (real title bar and SwiftUI toolbar) kept off every screen.
@MainActor
func renderWindow<V: View>(_ content: V, size: NSSize, title: String, dark: Bool,
                           settle: TimeInterval = 1.2) -> NSBitmapImageRep {
    let controller = NSHostingController(rootView: content)
    controller.sizingOptions = []
    let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentViewController = controller
    window.setContentSize(size)
    // On a screen's coordinate space but far away from every display, so nothing shows up.
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFrontRegardless()
    window.makeKey()
    pump(settle)
    controller.view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    pump(0.2)
    let frameView = window.contentView!.superview!
    let rep = bitmap(of: frameView)
    window.orderOut(nil)
    window.close()
    return rep
}

/// Hosts `content` at its natural size in a borderless window (menu bar panel).
@MainActor
func renderPanel<V: View>(_ content: V, width: CGFloat, dark: Bool, settle: TimeInterval = 0.8) -> NSBitmapImageRep {
    let host = NSHostingView(rootView: content)
    host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
    host.layoutSubtreeIfNeeded()
    let height = ceil(host.fittingSize.height)
    let window = OffscreenWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFrontRegardless()
    pump(settle)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let rep = bitmap(of: host)
    window.orderOut(nil)
    window.close()
    return rep
}

// MARK: - Screens

struct Screen {
    let name: String
    let render: @MainActor () throws -> NSBitmapImageRep
}

let mainSize = NSSize(width: 1200, height: 780)

@MainActor
func mainWindow(theme: Theme) throws -> NSBitmapImageRep {
    let sample = try Sample(theme: theme, models: .bothReady, withQueue: true)
    defer { sample.cleanup() }
    sample.waitForDurations()
    let view = QueueRootView(store: sample.queue)
        .environment(sample.model)
        .environment(sample.model.settings)
        .themed(sample.model.settings)
    return renderWindow(view, size: mainSize, title: "LiteEcho", dark: theme.isDark)
}

@MainActor
func preferences(tab: SettingsTab, size: NSSize,
                 cli: CommandLineToolPreview? = nil) throws -> NSBitmapImageRep {
    let sample = try Sample(theme: .professional, models: .bothReady, withQueue: false)
    defer { sample.cleanup() }
    sample.model.settingsTab = tab
    let view = SettingsView()
        .environment(sample.model)
        .environment(sample.model.settings)
        .environment(\.commandLineToolPreview, cli)
        .themed(sample.model.settings)
    return renderWindow(view, size: size, title: "Settings", dark: false)
}

let screens: [Screen] = [
    Screen(name: "main-professional") { try mainWindow(theme: .professional) },
    Screen(name: "main-cyberpunk") { try mainWindow(theme: .cyberpunk) },
    Screen(name: "main-lime") { try mainWindow(theme: .lime) },
    Screen(name: "main-mint") { try mainWindow(theme: .mint) },
    Screen(name: "main-paper") { try mainWindow(theme: .paper) },
    Screen(name: "preferences-appearance") {
        try preferences(tab: .general, size: NSSize(width: 580, height: 460))
    },
    Screen(name: "preferences-models") {
        try preferences(tab: .models, size: NSSize(width: 580, height: 460))
    },
    Screen(name: "preferences-cli") {
        try preferences(tab: .advanced, size: NSSize(width: 580, height: 460),
                        cli: CommandLineToolPreview(status: .installedOnPath, shellPath: "/bin/zsh",
                                                    engineVersion: "0.5.0"))
    },
    Screen(name: "menubar-panel") {
        let sample = try Sample(theme: .professional, models: .bothReady, withQueue: true)
        defer { sample.cleanup() }
        sample.waitForDurations()
        let view = MenuBarContent(store: sample.queue)
            .environment(sample.model)
            .environment(sample.model.settings)
            .themed(sample.model.settings)
        return renderPanel(view, width: 320, dark: false)
    },
    Screen(name: "voice-memos-import") {
        let sample = try Sample(theme: .professional, models: .bothReady, withQueue: false)
        defer { sample.cleanup() }
        let now = Date()
        func ago(_ days: Double, _ hours: Double = 0) -> Date { now.addingTimeInterval(-(days * 86_400 + hours * 3_600)) }
        let listing = VoiceMemoListing(status: .ok, folders: [
            VoiceMemoFolder(id: "f-work", name: "Work"), VoiceMemoFolder(id: "f-study", name: "Study"),
        ], memos: [
            VoiceMemo(id: "m1", title: "Customer call", recorded: ago(0, 2), durationSeconds: 1311,
                      folderID: "f-work", favorite: true, appleTranscript: true, format: "m4a"),
            VoiceMemo(id: "m2", title: "Team sync", recorded: ago(1, 3), durationSeconds: 2892,
                      folderID: "f-work", format: "m4a"),
            VoiceMemo(id: "m3", title: "Idea for the product demo", recorded: ago(3), durationSeconds: 123,
                      format: "m4a"),
            VoiceMemo(id: "m4", title: "Lecture notes", recorded: ago(6), durationSeconds: 3870,
                      folderID: "f-study", local: false, format: "m4a"),
            VoiceMemo(id: "m5", title: "Interview draft", recorded: ago(8), durationSeconds: 1988,
                      folderID: "f-work", appleTranscript: true, format: "m4a"),
            VoiceMemo(id: "m6", title: "New Recording 14", recorded: ago(10), durationSeconds: 41,
                      format: "qta"),
        ])
        let view = VoiceMemoImportView(store: sample.queue, listing: listing, onCancel: {}, onDone: {})
            .environment(sample.model)
            .environment(sample.model.settings)
            .themed(sample.model.settings)
        return renderWindow(view, size: NSSize(width: 960, height: 640), title: "Import from Voice Memos",
                            dark: false)
    },
    Screen(name: "setup-models") {
        let sample = try Sample(theme: .professional, models: .bothMissing, withQueue: false)
        defer { sample.cleanup() }
        let view = SetupView()
            .environment(sample.model)
            .environment(sample.model.settings)
            .themed(sample.model.settings)
        return renderWindow(view, size: mainSize, title: "LiteEcho", dark: false, settle: 1.5)
    },
]

// MARK: - Main

@MainActor
func run() throws -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let outPath = arguments.first else {
        FileHandle.standardError.write(Data("usage: LiteEchoSnapshots <output-dir> [screen ...]\n".utf8))
        exit(2)
    }
    let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
    let wanted = Set(arguments.dropFirst())

    // The real Keychain item must never be read: point the default at a service that does not exist.
    KeychainStore.defaultService = "dev.liteecho.snapshots.unused"

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    try? FileManager.default.removeItem(at: sandboxRoot)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var failures = 0
    for screen in screens where wanted.isEmpty || wanted.contains(screen.name) {
        do {
            let raw = try screen.render()
            let isPanel = screen.name.hasPrefix("menubar")
            let image = framed(raw, cornerRadius: isPanel ? 12 : 10)
            try writePNG(image, to: outDir.appendingPathComponent("\(screen.name).png"))
            print("wrote \(screen.name).png (\(image.pixelsWide)x\(image.pixelsHigh))")
        } catch {
            failures += 1
            FileHandle.standardError.write(Data("\(screen.name): \(error)\n".utf8))
        }
    }
    try? FileManager.default.removeItem(at: sandboxRoot)
    return failures == 0 ? 0 : 1

}

exit(MainActor.assumeIsolated { (try? run()) ?? 1 })
