import LiteEchoCore
import LiteEchoShared
import SwiftUI

/// Preferences › Voice Memos: access status and automatic import.
struct VoiceMemosSettingsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow
    @StateVar private var listing: VoiceMemoListing?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Access") {
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 9, height: 9).accessibilityHidden(true)
                    Text(statusText).accessibilityLabel("Voice Memos access: \(statusText)")
                    Spacer()
                    if let listing, listing.status != .ok {
                        Button("Set up access…") {
                            model.showVoiceMemoImport = true
                            openWindow(id: WindowID.main)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                }
            }

            Section("Saving transcripts") {
                LabeledContent("Save to") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(displayPath(saveFolder))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        if settings.voiceMemoOutputFolder == nil {
                            Text("Default").font(.caption).foregroundStyle(theme.secondaryText)
                        }
                    }
                }
                HStack {
                    Button("Choose…") { chooseSaveFolder() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saveFolder]) }
                        .disabled(!FileManager.default.fileExists(atPath: saveFolder.path))
                    Spacer()
                    if settings.voiceMemoOutputFolder != nil {
                        Button("Use Default") { settings.voiceMemoOutputFolder = nil }
                    }
                }
                Text("Voice Memos' own folder can't be written to, so transcripts of imported memos are saved here, named after the memo title. The folder is created on the first import. The import sheet can still pick another folder for one batch.")
                    .font(.caption).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Automatic import") {
                Toggle("Add new Voice Memos to the queue automatically", isOn: $settings.autoImportVoiceMemos)
                Picker("From folder", selection: $settings.autoImportFolderID) {
                    Text("All recordings").tag(String?.none)
                    ForEach(listing?.folders ?? []) { folder in
                        Text(folder.name).tag(Optional(folder.id))
                    }
                    // A folder that no longer exists (or the list is not loaded) stays selectable.
                    if let id = settings.autoImportFolderID, !(listing?.folders.contains { $0.id == id } ?? false) {
                        Text("Unknown folder").tag(Optional(id))
                    }
                }
                .disabled(!settings.autoImportVoiceMemos)
                Picker("Only if longer than", selection: $settings.autoImportMinimumLength) {
                    ForEach(VoiceMemoMinimumLength.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.autoImportVoiceMemos)
                Text("Only recordings made after you turn this on are added, using your default language and speakers. LiteEcho checks every two minutes while it is running, and reads Voice Memos without ever changing it.")
                    .font(.caption).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.window)
        .task { listing = await model.listVoiceMemos() }
    }

    private var saveFolder: URL {
        model.settings.voiceMemoOutputFolder ?? EngineCommand.defaultVoiceMemoFolder
    }

    /// The path with the home folder shown as `~`.
    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where transcripts of imported Voice Memos are saved"
        panel.directoryURL = saveFolder.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.voiceMemoOutputFolder = url
        }
    }

    private var statusColor: Color {
        guard let listing else { return theme.secondaryText }
        return listing.status == .ok ? theme.success : theme.warning
    }

    private var statusText: String {
        guard let listing else { return "Checking…" }
        switch listing.status {
        case .ok:
            let n = listing.memos.count
            return "Access granted · \(n) \(n == 1 ? "recording" : "recordings") found"
        case .noAccess: return "Access not granted"
        case .noLibrary: return "No Voice Memos library found"
        case .unreadable: return "The library could not be read"
        }
    }
}
