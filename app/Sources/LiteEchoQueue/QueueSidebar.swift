import AppKit
import LiteEchoCore
import LiteEchoShared
import SwiftUI

/// "For new files": language, speakers, output location and the models card.
struct QueueSidebar: View {
    @Bindable var settings: AppSettings
    let model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionLabel("For new files", forceUppercase: true)
                languageSection
                speakersSection
                outputSection
                modelsCard
                Text("Transcripts are saved as HTML and open in your default browser.")
                    .font(.caption).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.sidebar)
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Language").font(.subheadline.weight(.semibold))
            LanguagePicker("Language", selection: $settings.defaultLanguage, model: model)
        }
    }

    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speakers").font(.subheadline.weight(.semibold))
            SpeakerPicker(selection: $settings.defaultSpeakers)
        }
    }

    private var outputBinding: Binding<AppSettings.OutputMode> {
        Binding(
            get: { settings.outputMode },
            set: { mode in
                if mode == .customFolder {
                    chooseFolder()
                } else {
                    settings.outputMode = mode
                }
            })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where transcripts are saved"
        if panel.runModal() == .OK, let url = panel.url {
            settings.customOutputFolder = url
            settings.outputMode = .customFolder
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Save transcript").font(.subheadline.weight(.semibold))
            Picker("Save transcript", selection: outputBinding) {
                Text("Next to the audio file").tag(AppSettings.OutputMode.nextToAudio)
                Text("In Documents › Transcripts").tag(AppSettings.OutputMode.documentsTranscripts)
                Text(customLabel).tag(AppSettings.OutputMode.customFolder)
            }
            .labelsHidden()
            if settings.outputMode == .customFolder {
                Button("Change folder…") { chooseFolder() }.controlSize(.small)
                    .buttonStyle(.themedSecondary)
            }
        }
    }

    private var customLabel: String {
        if settings.outputMode == .customFolder, let folder = settings.customOutputFolder {
            return "In \(folder.lastPathComponent)"
        }
        return "Choose a folder…"
    }

    // MARK: Models

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if ready {
                HStack(spacing: 8) {
                    Circle().fill(theme.success).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text("Models ready").font(.subheadline.weight(.semibold))
                }
                ForEach(Self.locationLines(settings: settings), id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if model.engineInfo == nil && model.engineInfoError == nil {
                Text("Checking models…").font(.subheadline.weight(.semibold))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(theme.warning).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text("Models missing — open Preferences to set them up")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .themedCard(padding: 12)
        .accessibilityElement(children: .contain)
    }

    private var ready: Bool { model.engineInfo?.modelsReady ?? false }

    /// "Speech: Whisper large-v3-turbo · custom folder", one line per model.
    static func locationLines(settings: AppSettings) -> [String] {
        func place(_ dir: URL?) -> String { dir == nil ? "LiteEcho's folder" : "custom folder" }
        return ["Speech: Whisper large-v3-turbo · \(place(settings.whisperModelDir))",
                "Speakers: pyannote community-1 · \(place(settings.pyannoteModelDir))"]
    }
}
