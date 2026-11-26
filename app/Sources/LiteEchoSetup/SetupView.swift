import AppKit
import LiteEchoCore
import LiteEchoShared
import SwiftUI

/// First run: build the engine, then get the two models.
public struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @StateVar private var flow = SetupFlow()
    @StateVar private var fetcher = ModelFetcher()
    @StateVar private var token = ""
    @StateVar private var hasSavedToken = KeychainStore().hasToken
    @StateVar private var choices: [String: ModelSource] = [:]
    @StateVar private var folderText: [String: String] = [:]
    @StateVar private var folderResults: [String: ModelFolderValidation] = [:]
    @StateVar private var checking: Set<String> = []

    public init() {}

    private var modelStep: ModelStepState { ModelStepState(info: model.engineInfo) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(flow.phase == .ready ? "Set up the transcription models" : "Set up LiteEcho")
                        .themedHeading(26, weight: .bold)
                    Text("LiteEcho runs entirely on this Mac. It needs two models, about 1.5 GB in all, downloaded once and checked against the exact files the engine expects.")
                        .font(.callout)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                engineSection

                if flow.phase == .ready {
                    modelsSection
                }

                footer
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 640, minHeight: 560)
        .task { await flow.begin(model: model) }
    }

    // MARK: Engine

    @ViewBuilder private var engineSection: some View {
        switch flow.phase {
        case .checking:
            card {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking the engine…").font(.callout)
                }
            }
        case .ready:
            EmptyView()
        case .needsInstall:
            card {
                Text("Install the transcription engine").themedHeading(16)
                Text("LiteEcho runs on a private Python engine with the speech libraries. Installing it downloads about 1 GB once, into Application Support. After that, transcription works offline.")
                    .font(.callout).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Install Engine") { Task { await flow.install(model: model) } }
                        .buttonStyle(.themedPrimary)
                        .keyboardShortcut(.defaultAction)
                    Button("Use existing engine…") { chooseExistingEngine() }
                        .buttonStyle(.themedSecondary)
                }
            }
        case .installing(let step, let lastLine):
            card {
                Text("Installing the engine").themedHeading(16)
                Text("This builds the Python environment LiteEcho runs in. It happens once and needs an internet connection.")
                    .font(.callout).foregroundStyle(theme.secondaryText)
                ForEach(EngineInstaller.Step.allCases, id: \.rawValue) { s in
                    HStack(spacing: 8) {
                        stepIcon(s, current: step)
                        Text(s.title).font(.callout)
                            .foregroundStyle(s.rawValue > step.rawValue ? theme.secondaryText : theme.text)
                    }
                }
                ProgressView().progressViewStyle(.linear)
                Text(lastLine.isEmpty ? " " : lastLine)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
        case .failed(let message, let details):
            card {
                Label("The engine could not be installed", systemImage: "exclamationmark.triangle.fill")
                    .themedHeading(16).foregroundStyle(theme.danger)
                Text(message).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Try again") { Task { await flow.install(model: model) } }
                        .buttonStyle(.themedPrimary)
                    Button(flow.showDetails ? "Hide details" : "Show details") { flow.showDetails.toggle() }
                        .buttonStyle(.themedSecondary)
                    Button("Use existing engine…") { chooseExistingEngine() }
                        .buttonStyle(.themedSecondary)
                }
                if flow.showDetails {
                    ScrollView {
                        Text(details.isEmpty ? "No output." : details)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .padding(8)
                    .background(theme.window, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                }
            }
        case .bundleMissing(let files):
            card {
                Label("The engine files are not part of this build", systemImage: "info.circle.fill")
                    .themedHeading(16)
                Text("The engine is installed from the built LiteEcho.app, which carries the files it needs (missing: \(files.joined(separator: ", "))). If you already have an engine, point to it.")
                    .font(.callout).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Use existing engine…") { chooseExistingEngine() }
                    .buttonStyle(.themedSecondary)
            }
        }
    }

    @ViewBuilder private func stepIcon(_ step: EngineInstaller.Step, current: EngineInstaller.Step) -> some View {
        if step.rawValue < current.rawValue {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
        } else if step == current {
            ProgressView().controlSize(.small).frame(width: 16, height: 16)
        } else {
            Image(systemName: "circle").foregroundStyle(theme.secondaryText)
        }
    }

    private func chooseExistingEngine() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the engine folder (it contains bin/liteecho)."
        panel.prompt = "Use Engine"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await flow.useExistingEngine(at: url, model: model) }
    }

    // MARK: Models

    @ViewBuilder private var modelsSection: some View {
        if let error = model.engineInfoError, model.engineInfo == nil {
            card {
                Label("The engine did not answer", systemImage: "exclamationmark.triangle.fill")
                    .themedHeading(16).foregroundStyle(theme.danger)
                Text(error).font(.callout).textSelection(.enabled)
                Button("Try again") { Task { await model.refreshEngineInfo() } }
                    .buttonStyle(.themedSecondary)
            }
        } else if model.engineInfo == nil {
            card {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for models…").font(.callout)
                }
            }
        } else {
            whisperCard
            pyannoteCard
        }
    }

    /// Where a model comes from: downloaded into LiteEcho's folder, or a folder the user already has.
    enum ModelSource: Hashable { case download, folder }

    private func source(_ kind: String) -> ModelSource {
        choices[kind] ?? (model.settings.modelDir(for: kind) != nil ? .folder : .download)
    }

    private func sourceBinding(_ kind: String) -> Binding<ModelSource> {
        Binding(
            get: { source(kind) },
            set: { choice in
                choices[kind] = choice
                folderResults[kind] = nil
                if choice == .download, model.settings.modelDir(for: kind) != nil {
                    Task { await model.useLiteEchoFolder(kind: kind) }
                }
            })
    }

    private func sourcePicker(kind: String, downloadLabel: String) -> some View {
        Picker("Where the model comes from", selection: sourceBinding(kind)) {
            Text(downloadLabel).tag(ModelSource.download)
            Text("Use a folder I already have").tag(ModelSource.folder)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .disabled(fetcher.isRunning(kind))
    }

    /// Path field + "Choose…" + the outcome of checking the folder.
    @ViewBuilder private func folderChooser(kind: String) -> some View {
        let text = Binding(
            get: { folderText[kind] ?? model.settings.modelDir(for: kind)?.path ?? "" },
            set: { folderText[kind] = $0 })
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Folder with the model files", text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { checkFolder(kind: kind, path: text.wrappedValue) }
                Button("Choose…") {
                    let current = model.settings.modelDir(for: kind)
                    if let url = ModelFolderPicker.choose(kind: kind, current: current) {
                        folderText[kind] = url.path
                        checkFolder(kind: kind, path: url.path)
                    }
                }
                .buttonStyle(.themedSecondary)
            }
            if checking.contains(kind) {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the files…").font(.callout) }
            } else if let result = folderResults[kind] {
                ModelFolderResultView(result: result)
            }
        }
    }

    private func checkFolder(kind: String, path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !checking.contains(kind) else { return }
        checking.insert(kind)
        Task {
            let result = await model.useModelFolder(kind: kind, folder: URL(fileURLWithPath: trimmed, isDirectory: true))
            folderResults[kind] = result
            checking.remove(kind)
        }
    }

    private var whisperCard: some View {
        card {
            modelHeader(title: "Speech recognition", subtitle: "Whisper large-v3-turbo · 1.5 GB",
                        kind: "whisper", availability: modelStep.whisper)
            sourcePicker(kind: "whisper", downloadLabel: "Download into LiteEcho's folder")
            if source("whisper") == .folder {
                folderChooser(kind: "whisper")
            } else {
                progressBlock(kind: "whisper")
                if !fetcher.isRunning("whisper") && !modelStep.whisper.isReady {
                    Button(modelStep.whisper == .missing ? "Download" : "Download again") {
                        Task { await fetcher.download(kind: "whisper", force: modelStep.whisper != .missing, model: model) }
                    }
                    .buttonStyle(.themedPrimary)
                }
            }
        }
    }

    private var pyannoteCard: some View {
        card {
            modelHeader(title: "Speaker detection",
                        subtitle: "pyannote community-1 · 31 MB",
                        kind: "pyannote", availability: modelStep.pyannote)
            sourcePicker(kind: "pyannote",
                         downloadLabel: "Download into LiteEcho's folder (needs a free Hugging Face token)")
            if source("pyannote") == .folder {
                folderChooser(kind: "pyannote")
            } else if !modelStep.pyannote.isReady {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("1.")
                        Text("[Open the model page](https://huggingface.co/pyannote/speaker-diarization-community-1), sign in and accept its terms (CC-BY-4.0).")
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("2.")
                        Text("[Create a read access token](https://huggingface.co/settings/tokens) and paste it below.")
                    }
                }
                .font(.callout)
                .tint(theme.accentText)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hugging Face access token").font(.system(size: 13, weight: .semibold))
                    HStack {
                        SecureField(hasSavedToken ? "Using the token saved in your Keychain" : "hf_…", text: $token)
                            .textFieldStyle(.roundedBorder)
                            .disabled(fetcher.isRunning("pyannote"))
                        Button("Verify and download") {
                            let typed = token
                            Task {
                                await fetcher.download(kind: "pyannote", token: typed, model: model)
                                if fetcher.state(for: "pyannote") == .finished { token = "" }
                                hasSavedToken = fetcher.keychain.hasToken
                            }
                        }
                        .buttonStyle(.themedPrimary)
                        .disabled(fetcher.isRunning("pyannote") || (token.trimmingCharacters(in: .whitespaces).isEmpty && !hasSavedToken))
                    }
                }
                Text("Kept in your macOS Keychain and only sent to huggingface.co to download this model.")
                    .font(.caption).foregroundStyle(theme.secondaryText)
            }
            if source("pyannote") == .download { progressBlock(kind: "pyannote") }
        }
    }

    private func modelHeader(title: String, subtitle: String, kind: String, availability: ModelAvailability) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.callout).foregroundStyle(theme.secondaryText)
            }
            Spacer()
            switch (fetcher.state(for: kind), availability) {
            case (.running(let progress), _):
                Text(progress.map { "Downloading · \($0.percent)%" } ?? "Starting…")
                    .font(.callout.weight(.semibold)).foregroundStyle(theme.accentText)
            case (_, .ready(let source)):
                Label(source == "custom" ? "Custom folder" : "Ready", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(theme.success)
            case (_, .needsRepair):
                Text("Incomplete").font(.callout.weight(.semibold)).foregroundStyle(theme.warning)
            case (_, .missing):
                EmptyView()
            }
        }
    }

    @ViewBuilder private func progressBlock(kind: String) -> some View {
        switch fetcher.state(for: kind) {
        case .running(let progress):
            if let progress, progress.total > 0 {
                ThemedProgressBar(value: progress.fraction)
                Text(progress.summary).font(.caption).foregroundStyle(theme.secondaryText)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Button("Cancel") { fetcher.cancel(kind) }.controlSize(.small)
                .buttonStyle(.themedSecondary)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(theme.danger)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .idle, .finished:
            if case .needsRepair(let problems) = (kind == "whisper" ? modelStep.whisper : modelStep.pyannote),
               !problems.isEmpty {
                Text(problems.joined(separator: "\n")).font(.caption).foregroundStyle(theme.warning)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("Models are stored in ~/Library/Application Support/LiteEcho. You can change this in Settings.")
                    .font(.caption).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Continue") { model.setupDismissed = true }
                    .buttonStyle(.themedPrimary)
                    .disabled(!(flow.phase == .ready && modelStep.canContinue))
                    .keyboardShortcut(.defaultAction)
            }
            Button("Skip for now") { model.setupDismissed = true }
                .buttonStyle(.link).font(.caption).tint(theme.accentText)
        }
        .padding(.top, 4)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .themedCard()
    }
}
