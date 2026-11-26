import AppKit
import LiteEchoShared
import SwiftUI

/// The folder picker for "Use a folder I already have" (one model per pick).
enum ModelFolderPicker {
    @MainActor static func choose(kind: String, current: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = current
        panel.message = kind == "whisper"
            ? "Choose the folder that holds the speech recognition model (it contains model.bin)."
            : "Choose the folder that holds the speaker detection model (it contains config.yaml)."
        panel.prompt = "Use This Folder"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// What checking a picked folder came to: all files match, or the problems.
struct ModelFolderResultView: View {
    let result: ModelFolderValidation
    @Environment(\.theme) private var theme

    var body: some View {
        switch result {
        case .verified(let count):
            Label("All \(count) files match", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(theme.success)
        case .problems(let problems):
            VStack(alignment: .leading, spacing: 3) {
                Label("This folder cannot be used", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(theme.warning)
                ForEach(problems, id: \.self) {
                    Text($0).font(.caption).foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
