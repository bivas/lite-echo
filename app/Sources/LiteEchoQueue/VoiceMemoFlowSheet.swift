import AppKit
import LiteEchoCore
import LiteEchoShared
import SwiftUI

/// The Voice Memos sheet: lists the library and shows the import table, or the permission /
/// error screen when the library cannot be read. Re-checks whenever the app becomes active
/// (that is how it notices Full Disk Access being granted).
struct VoiceMemoFlowSheet: View {
    let store: QueueStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @StateVar private var listing: VoiceMemoListing?
    @StateVar private var isChecking = false

    var body: some View {
        Group {
            if let listing {
                switch listing.status {
                case .ok:
                    VoiceMemoImportView(store: store, listing: listing, onCancel: { dismiss() },
                                        onDone: { dismiss() })
                default:
                    VoiceMemoAccessView(listing: listing, isChecking: isChecking, onCheckAgain: { Task { await check() } },
                                        onChooseFiles: chooseFiles, onCancel: { dismiss() })
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    Text("Reading Voice Memos…").foregroundStyle(theme.secondaryText)
                    Button("Cancel") { dismiss() }.buttonStyle(.themedSecondary).keyboardShortcut(.cancelAction)
                }
                .frame(width: 540, height: 200)
                .background(theme.window)
            }
        }
        .task { await check() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await check() }
        }
    }

    private func check() async {
        guard !isChecking else { return }
        isChecking = true
        let result = await store.model.listVoiceMemos()
        isChecking = false
        listing = result
    }

    /// The fallback for people who do not want to grant access: pick audio files as usual.
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.message = "Choose audio or video files to transcribe"
        if panel.runModal() == .OK {
            store.add(panel.urls)
            dismiss()
        }
    }
}
