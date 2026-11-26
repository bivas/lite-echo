import AppKit
import LiteEchoCore
import LiteEchoShared
import SwiftUI
import UniformTypeIdentifiers

/// The main window: options sidebar, drop zone, queue and status bar.
public struct QueueRootView: View {
    private let store: QueueStore
    @StateVar private var isTargeted = false
    @StateVar private var isHovering = false
    @StateVar private var pendingConfirmation: PendingConfirmation?
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings

    public init(store: QueueStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                QueueSidebar(settings: store.model.settings, model: store.model)
                    .frame(width: 280)
                theme.separator.frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        dropZone
                        queueHeader
                        queueList
                    }
                    .padding(24)
                }
                .frame(maxWidth: .infinity)
                .background(theme.window)
            }
            theme.separator.frame(height: 1)
            statusBar
        }
        .toolbar {
            ToolbarItemGroup {
                Button { addFilesWithPanel() } label: { Label("Add Files…", systemImage: "plus") }
                    .keyboardShortcut("o", modifiers: .command)
                    .help("Add audio or video files")
                Button { store.isPaused.toggle() } label: {
                    Text(store.isPaused ? "Start" : "Pause").fontWeight(.semibold)
                }
                .help(store.isPaused ? "Start the queue" : "Pause the queue after the current file")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openPreferences() } label: { Label("Preferences", systemImage: "gearshape") }
                    .help("Open Preferences")
            }
        }
        .onChange(of: store.model.modelsReady) { _, ready in
            if ready { store.modelsMayBeReady() }
        }
    }

    /// Opens Settings on Models when a model is missing, else on General.
    private func openPreferences() {
        store.model.settingsTab = store.model.modelsReady ? .general : .models
        openSettings()
    }

    // MARK: Drop zone

    private var dropZone: some View {
        Button { addFilesWithPanel() } label: {
            VStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 30)).foregroundStyle(theme.accentText)
                    .accessibilityHidden(true)
                Text("Drop audio or video files here, or click to choose").themedHeading(15)
                Text("m4a, mp3, wav, mp4, mov and anything else FFmpeg reads. Files are processed on this Mac only.")
                    .font(.callout).foregroundStyle(theme.secondaryText).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .padding(20)
            .background(RoundedRectangle(cornerRadius: theme.cornerRadius + 4)
                .fill(isTargeted ? theme.soft : theme.control))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 4)
                .strokeBorder(theme.hasGlow || isTargeted ? theme.accent : theme.secondaryText.opacity(0.55),
                              style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
            .themedGlow(isTargeted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside, !isHovering { NSCursor.pointingHand.push(); isHovering = true }
            else if !inside, isHovering { NSCursor.pop(); isHovering = false }
        }
        .onDisappear { if isHovering { NSCursor.pop(); isHovering = false } }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .accessibilityLabel("Add audio files")
        .accessibilityHint("Opens a file picker; you can also drop files here")
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in store.add([url]) }
            }
        }
        return accepted
    }

    private func addFilesWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.message = "Choose audio or video files to transcribe"
        if panel.runModal() == .OK { store.add(panel.urls) }
    }

    // MARK: Queue

    private var queueHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Queue").themedHeading(18)
            Text(store.jobs.count == 1 ? "1 file" : "\(store.jobs.count) files")
                .font(.callout).foregroundStyle(theme.secondaryText)
            Spacer()
            Button("Clear finished") { pendingConfirmation = store.request(.clearFinished(in: store.jobs)) }
                .buttonStyle(.themedSecondary)
                .disabled(!store.jobs.contains { $0.state.isFinished })
                .queueConfirmation($pendingConfirmation, store: store)
        }
    }

    @ViewBuilder private var queueList: some View {
        if store.jobs.isEmpty {
            Text("No files yet. Drop some above or choose Add Files….")
                .font(.callout).foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity).padding(24)
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(theme.separator))
        } else {
            VStack(spacing: 0) {
                ForEach(store.jobs) { job in
                    QueueRow(job: job, store: store)
                    if job.id != store.jobs.last?.id { theme.separator.frame(height: 1) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(theme.separator))
        }
    }

    // MARK: Status bar

    private var statusText: String {
        QueueFormat.statusBar(jobs: store.jobs, isPaused: store.isPaused, languages: store.model.languages)
    }

    private var statusBar: some View {
        HStack {
            Text(statusText).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(store.model.engineInfo.map { "Runs offline · engine liteecho \($0.version)" } ?? "Runs offline")
        }
        .font(.caption).foregroundStyle(theme.secondaryText)
        .padding(.horizontal, 16).frame(height: 28)
        .background(theme.bar)
    }
}
