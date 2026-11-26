import LiteEchoCore
import LiteEchoQueue
import LiteEchoSetup
import LiteEchoShared
import SwiftUI

/// App shell (owned by the orchestrator). Feature folders own their views:
/// LiteEchoQueue → QueueRootView, LiteEchoSetup → SetupView + SettingsView.
/// Each is a public View. Transcripts open in the default browser, not in a window of this app.
@main
struct LiteEchoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateVar private var model: AppModel
    @StateVar private var queue: QueueStore

    init() {
        let flavor = AppFlavor.current
        KeychainStore.defaultService = flavor.keychainService
        let model = AppModel()
        if flavor == .release {
            // Move data from the former "localScribe" install before anything reads it.
            // Dev builds have their own folder and never touch it.
            let migration = LaunchMigration.run()
            model.reinstallEngineWithoutAsking = migration.engineNeedsReinstall
        }
        let queue = QueueStore(model: model)
        _model = StateVar(initialValue: model)
        _queue = StateVar(initialValue: queue)
        AppDelegate.queue = queue
        // Checks Voice Memos for new recordings when the user turned auto-import on.
        queue.startVoiceMemoAutoImport()
    }

    var body: some Scene {
        Window(AppFlavor.current.displayName, id: WindowID.main) {
            RootView(queue: queue)
                .environment(model)
                .environment(model.settings)
                .frame(minWidth: 820, minHeight: 560)
                .themed(model.settings)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { VoiceMemoCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .environment(model.settings)
                .themed(model.settings)
        }

        // Status item: progress of the running job, recently finished files, quick actions.
        // Ignore same-value writes: MenuBarExtra writes this binding back on every update, which
        // otherwise loops forever through the observed setting (seen in the CI-built release).
        MenuBarExtra(isInserted: Bindable(model.settings).showMenuBarItem.ignoringRepeatedValues()) {
            MenuBarContent(store: queue)
                .environment(model)
                .environment(model.settings)
                .themed(model.settings)
        } label: {
            MenuBarLabel(store: queue)
        }
        .menuBarExtraStyle(.window)
    }
}

/// File › Import from Voice Memos… (⇧⌘I): opens the main window and its Voice Memos sheet.
struct VoiceMemoCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import from Voice Memos…") {
                model.showVoiceMemoImport = true
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(model.needsSetup)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once at launch; receives files opened from Finder ("Open With", Dock drops).
    @MainActor static weak var queue: QueueStore?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        Task { @MainActor in AppDelegate.queue?.add(files) }
    }
}

/// Shows first-run setup until the engine and both models are ready, then the queue.
struct RootView: View {
    let queue: QueueStore
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.needsSetup {
                SetupView()
            } else {
                // The queue only starts once the engine matches this app's bundled engine files.
                EngineUpdateGate {
                    QueueRootView(store: queue)
                        .task {
                            // Resume jobs restored from the last session once the engine is ready.
                            queue.start()
                        }
                }
            }
        }
        .task { await model.refreshEngineInfo() }
    }
}
