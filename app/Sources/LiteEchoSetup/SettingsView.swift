import AppKit
import LiteEchoCore
import LiteEchoShared
import SwiftUI

/// The Settings window: General, Models, Advanced.
public struct SettingsView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ModelsSettingsTab()
                .tabItem { Label("Models", systemImage: "cube") }
                .tag(SettingsTab.models)
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 580, height: 460)
    }
}

/// Speaker counts offered in the picker: automatic, then 2...10 (plus a stored odd value).
// MARK: General

struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Appearance") {
                ForEach(Theme.allCases) { option in
                    ThemeOptionRow(theme: option, isSelected: settings.theme == option) {
                        settings.theme = option
                    }
                }
            }

            Section {
                LabeledContent("Default language") {
                    LanguagePicker("Default language", selection: $settings.defaultLanguage, model: model)
                        .frame(width: 240)
                }
                LabeledContent("Default speakers") {
                    SpeakerPicker(selection: $settings.defaultSpeakers)
                        .frame(width: 300)
                }
                Picker("Save transcripts", selection: $settings.outputMode) {
                    Text("Next to the audio file").tag(AppSettings.OutputMode.nextToAudio)
                    Text("In Documents › Transcripts").tag(AppSettings.OutputMode.documentsTranscripts)
                    Text("Choose a folder…").tag(AppSettings.OutputMode.customFolder)
                }
                if settings.outputMode == .customFolder {
                    LabeledContent("Folder") {
                        HStack {
                            Text(settings.customOutputFolder?.path ?? "No folder chosen")
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { chooseOutputFolder() }
                        }
                    }
                }
            }

            Section("When a file finishes") {
                Toggle("Show a notification", isOn: $settings.notifyWhenDone)
                Toggle("Open the transcript", isOn: $settings.openWhenDone)
                Toggle("Keep the Mac awake while the queue runs", isOn: $settings.keepAwake)
                Toggle("Show LiteEcho in the menu bar", isOn: $settings.showMenuBarItem)
            }

            Section("Queue") {
                Toggle("Ask before stopping or removing items", isOn: $settings.askBeforeDestructive)
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.window)
        .onChange(of: settings.outputMode) { _, mode in
            if mode == .customFolder, settings.customOutputFolder == nil { chooseOutputFolder() }
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.customOutputFolder = url
        } else if model.settings.customOutputFolder == nil {
            model.settings.outputMode = .nextToAudio
        }
    }

}

// MARK: Models

struct ModelsSettingsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @StateVar private var fetcher = ModelFetcher()
    @StateVar private var verifying = false
    @StateVar private var hasToken = KeychainStore().hasToken
    @StateVar private var replacingToken = false
    @StateVar private var newToken = ""
    @StateVar private var tokenError: String?

    @StateVar private var folderResults: [String: ModelFolderValidation] = [:]
    @StateVar private var checking: Set<String> = []

    private let rows: [(kind: String, title: String, detail: String)] = [
        ("whisper", "Speech recognition", "Whisper large-v3-turbo · 1.5 GB"),
        ("pyannote", "Speaker detection", "pyannote community-1 · 31 MB"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let info = model.engineInfo {
                    ForEach(rows, id: \.kind) { row in
                        modelCard(row, model: info.models[row.kind])
                    }
                } else {
                    Text(model.isEngineInstalled ? "Checking the engine…" : "The engine is not installed yet.")
                        .foregroundStyle(theme.secondaryText)
                        .themedCard()
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Hugging Face token")
                    tokenRow
                }
                .themedCard()
                HStack {
                    Text("LiteEcho's folder: \(model.paths.modelsDir.path)").font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    if verifying { ProgressView().controlSize(.small) }
                    Button("Verify now") {
                        verifying = true
                        Task {
                            await model.refreshEngineInfo(verify: true)
                            verifying = false
                        }
                    }
                    .buttonStyle(.themedSecondary)
                    .disabled(verifying || !model.isEngineInstalled)
                }
            }
            .padding(20)
        }
        .background(theme.window)
        .task { if model.engineInfo == nil { await model.refreshEngineInfo() } }
    }

    private func isCustom(_ kind: String) -> Bool { model.settings.modelDir(for: kind) != nil }

    private func locationBinding(_ kind: String) -> Binding<Bool> {
        Binding(
            get: { isCustom(kind) },
            set: { custom in
                folderResults[kind] = nil
                if custom { chooseFolder(kind) } else if isCustom(kind) {
                    Task { await model.useLiteEchoFolder(kind: kind) }
                }
            })
    }

    /// Picks a folder, checks it, and keeps the previous setting unless every file matches.
    private func chooseFolder(_ kind: String) {
        guard let url = ModelFolderPicker.choose(kind: kind, current: model.settings.modelDir(for: kind)),
              !checking.contains(kind) else { return }
        checking.insert(kind)
        Task {
            folderResults[kind] = await model.useModelFolder(kind: kind, folder: url)
            checking.remove(kind)
        }
    }

    @ViewBuilder private func modelCard(_ row: (kind: String, title: String, detail: String),
                                        model info: EngineInfo.Model?) -> some View {
        let kind = row.kind
        let custom = isCustom(kind)
        let availability = ModelAvailability(info)
        let folder = custom ? model.settings.modelDir(for: kind)?.path : (info?.path ?? model.paths.modelsDir.path)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).themedHeading(15)
                    Text(row.detail).font(.caption).foregroundStyle(theme.secondaryText)
                }
                Spacer()
                if availability.isReady {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(theme.success)
                } else {
                    Label("Missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(theme.warning)
                }
            }
            LabeledContent("Location") {
                ThemedSegmentedPicker("Location", selection: locationBinding(kind),
                                      options: [(false, "LiteEcho's folder"), (true, "Custom folder")])
                    .disabled(fetcher.isRunning(kind))
            }
            LabeledContent("Folder") {
                Text(folder ?? "Not found")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.secondaryText)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            verifyStatus(info)
            if checking.contains(kind) {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the files…").font(.callout) }
            } else if let result = folderResults[kind] {
                ModelFolderResultView(result: result)
            }
            downloadProgress(kind)
            HStack {
                if custom {
                    Button("Change…") { chooseFolder(kind) }.buttonStyle(.themedSecondary)
                } else if availability == .missing, !fetcher.isRunning(kind) {
                    Button("Choose a folder…") { chooseFolder(kind) }.buttonStyle(.themedSecondary)
                }
                if let folder {
                    Button("Show in Finder") { reveal(URL(fileURLWithPath: folder, isDirectory: true)) }
                        .buttonStyle(.themedSecondary)
                }
                if custom {
                    Button("Use LiteEcho's folder") {
                        folderResults[kind] = nil
                        Task { await model.useLiteEchoFolder(kind: kind) }
                    }
                    .buttonStyle(.themedSecondary)
                } else {
                    Button("Download again") { redownload(kind) }
                        .buttonStyle(.themedSecondary)
                        .disabled(fetcher.isRunning(kind) || !model.isEngineInstalled)
                }
            }
        }
        .themedCard()
    }

    @ViewBuilder private func downloadProgress(_ kind: String) -> some View {
        switch fetcher.state(for: kind) {
        case .running(let progress):
            if let progress, progress.total > 0 {
                ThemedProgressBar(value: progress.fraction)
                Text("\(progress.percent)% · \(progress.summary)").font(.caption).foregroundStyle(theme.secondaryText)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Button("Cancel") { fetcher.cancel(kind) }.controlSize(.small).buttonStyle(.themedSecondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(theme.danger).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func verifyStatus(_ info: EngineInfo.Model?) -> some View {
        if verifying {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Verifying…").font(.caption) }
        } else if let info, info.source != "missing" {
            switch info.verified {
            case .some(true):
                Label("Verified", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(theme.success)
            case .some(false):
                VStack(alignment: .leading, spacing: 2) {
                    Label("Verification failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(theme.warning)
                    ForEach(info.problems, id: \.self) { Text($0).font(.caption2).foregroundStyle(theme.secondaryText) }
                }
            case .none:
                if info.problems.isEmpty {
                    Text("Not verified yet").font(.caption).foregroundStyle(theme.secondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(info.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(theme.warning) }
                    }
                }
            }
        } else if let problem = info?.problems.first {
            Text(problem).font(.caption).foregroundStyle(theme.secondaryText)
        }
    }

    private func redownload(_ kind: String) {
        if kind == "pyannote", !fetcher.keychain.hasToken {
            fetcher.reset(kind)
            replacingToken = true
            tokenError = "Add your Hugging Face token first, then download the speaker model again."
            return
        }
        Task { await fetcher.download(kind: kind, force: true, model: model) }
    }

    @ViewBuilder private var tokenRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if replacingToken {
                SecureField("hf_…", text: $newToken).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") { saveToken() }
                        .disabled(newToken.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { replacingToken = false; newToken = ""; tokenError = nil }
                }
            } else {
                HStack {
                    Label(hasToken ? "Saved in Keychain" : "No token saved",
                          systemImage: hasToken ? "key.fill" : "key")
                    Spacer()
                    Button(hasToken ? "Replace…" : "Add…") { replacingToken = true }
                    if hasToken { Button("Remove") { removeToken() } }
                }
            }
            if let tokenError { Text(tokenError).font(.caption).foregroundStyle(theme.danger) }
            Text("Used only to download the speaker detection model from huggingface.co.")
                .font(.caption).foregroundStyle(theme.secondaryText)
        }
    }

    private func saveToken() {
        do {
            try fetcher.keychain.save(newToken.trimmingCharacters(in: .whitespacesAndNewlines))
            newToken = ""; replacingToken = false; tokenError = nil
            hasToken = fetcher.keychain.hasToken
        } catch { tokenError = error.localizedDescription }
    }

    private func removeToken() {
        do { try fetcher.keychain.delete(); hasToken = fetcher.keychain.hasToken; tokenError = nil } catch {
            tokenError = error.localizedDescription
        }
    }

    private func reveal(_ url: URL) {
        // Only LiteEcho's own folder is created on demand; a custom folder is never made for the user.
        if url.path.hasPrefix(model.paths.modelsDir.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }
}

// MARK: Advanced

struct AdvancedSettingsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @StateVar private var confirmReinstall = false
    @StateVar private var errorText: String?

    var body: some View {
        Form {
            CommandLineToolSection(engineBinary: model.paths.engineBinary)
            Section("Engine") {
                if let info = model.engineInfo {
                    LabeledContent("Version", value: info.version)
                    LabeledContent("Python", value: info.python)
                    DisclosureGroup("Packages (\(info.packages.count))") {
                        ForEach(info.packages.keys.sorted(), id: \.self) { name in
                            LabeledContent(name, value: info.packages[name] ?? "")
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                } else {
                    Text(model.isEngineInstalled ? "The engine did not report its version." : "The engine is not installed.")
                        .foregroundStyle(theme.secondaryText)
                }
                LabeledContent("Location") {
                    Text(model.paths.engineDir.path).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(theme.secondaryText).textSelection(.enabled)
                }
            }
            Section {
                Button("Open engine logs") {
                    try? FileManager.default.createDirectory(at: model.paths.logsDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.paths.logsDir)
                }
                Button("Reinstall engine…") { confirmReinstall = true }
                if let errorText { Text(errorText).font(.caption).foregroundStyle(theme.danger) }
            } footer: {
                Text("Reinstalling rebuilds the Python environment. Your models and transcripts are not touched.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.window)
        .task { if model.engineInfo == nil { await model.refreshEngineInfo() } }
        .confirmationDialog("Reinstall the engine?", isPresented: $confirmReinstall) {
            Button("Reinstall", role: .destructive) { reinstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The engine is removed and setup runs again. Downloading its libraries takes a few minutes.")
        }
    }

    private func reinstall() {
        do {
            try EngineInstaller(paths: model.paths).remove()
            errorText = nil
            model.setupDismissed = false
            Task { await model.refreshEngineInfo() }
        } catch {
            errorText = "Could not remove the engine: \(error.localizedDescription)"
        }
    }
}

// MARK: Appearance

/// One selectable theme: swatch row, name and a check mark.
struct ThemeOptionRow: View {
    let theme: Theme
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                ThemeSwatchRow(theme: theme)
                VStack(alignment: .leading, spacing: 1) {
                    Text(theme.displayName)
                    Text(theme.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.displayName), \(theme.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
