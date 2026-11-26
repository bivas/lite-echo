// swift-tools-version:6.0
import PackageDescription

// One module per feature so parallel work never breaks another feature's build:
//   LiteEchoCore    engine protocol, jobs, paths, process runner (no UI)
//   LiteEchoShared  AppModel, AppSettings, WindowID, StateVar (shared UI state)
//   LiteEchoQueue   main window: options sidebar, drop zone, queue, notifications,
//                   speaker renaming sheet
//   LiteEchoSetup   first-run setup and the Settings window
//   LiteEchoApp     the executable: scenes only
//   LiteEchoSnapshots  dev tool: renders the real views offscreen to PNGs for the README
let package = Package(
    name: "LiteEcho",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LiteEcho", targets: ["LiteEchoApp"]),
    ],
    targets: [
        .target(name: "LiteEchoCore"),
        .target(name: "LiteEchoShared", dependencies: ["LiteEchoCore"]),
        .target(name: "LiteEchoQueue", dependencies: ["LiteEchoCore", "LiteEchoShared"]),
        .target(name: "LiteEchoSetup", dependencies: ["LiteEchoCore", "LiteEchoShared"]),
        .executableTarget(
            name: "LiteEchoApp",
            dependencies: ["LiteEchoCore", "LiteEchoShared", "LiteEchoQueue", "LiteEchoSetup"]
        ),
        // Offscreen renderer for the README screenshots (scripts/screenshots.sh). Not shipped.
        .executableTarget(
            name: "LiteEchoSnapshots",
            dependencies: ["LiteEchoCore", "LiteEchoShared", "LiteEchoQueue", "LiteEchoSetup"]
        ),
        .testTarget(name: "LiteEchoCoreTests", dependencies: ["LiteEchoCore"]),
        .testTarget(name: "LiteEchoSharedTests", dependencies: ["LiteEchoShared", "LiteEchoCore"]),
        .testTarget(name: "LiteEchoQueueTests", dependencies: ["LiteEchoQueue", "LiteEchoShared", "LiteEchoCore"]),
        .testTarget(name: "LiteEchoSetupTests", dependencies: ["LiteEchoSetup", "LiteEchoShared", "LiteEchoCore"]),
    ],
    swiftLanguageModes: [.v5]
)
