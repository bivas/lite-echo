import AppKit
import LiteEchoCore
import LiteEchoShared
import SwiftUI

/// Sheet C: pick recordings from Voice Memos and add them to the queue.
struct VoiceMemoImportView: View {
    let store: QueueStore
    let listing: VoiceMemoListing
    let onCancel: () -> Void
    let onDone: () -> Void

    @StateVar private var search = ""
    @StateVar private var folderID: String?
    @StateVar private var sort: VoiceMemoSort = .newest
    @StateVar private var showImported = false
    @StateVar private var selected: Set<String> = []
    @StateVar private var language: LanguageChoice = .auto
    @StateVar private var speakers: SpeakerSetting = .auto
    @StateVar private var outputFolder: URL?
    @StateVar private var speakersOpen = false
    @StateVar private var started = false
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedRow: String?
    @Environment(\.theme) private var theme

    private var imported: Set<String> { store.importedMemoIDs }
    private var queued: Set<String> { store.queuedMemoIDs }

    private var query: VoiceMemoQuery {
        VoiceMemoQuery(search: search, folderID: folderID, sort: sort, showAlreadyImported: showImported)
    }

    private var rows: [VoiceMemo] { VoiceMemoCatalog.visible(listing.memos, query: query, imported: imported) }

    private var addable: [VoiceMemo] {
        VoiceMemoCatalog.addable(rows, selected: selected, imported: imported, queued: queued)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            theme.separator.frame(height: 1)
            controls
            columnHeader
            theme.separator.frame(height: 1)
            list
            theme.separator.frame(height: 1)
            footer
        }
        .frame(width: 960, height: 640)
        .background(theme.window)
        .onAppear {
            guard !started else { return }
            started = true
            let settings = store.model.settings
            language = settings.defaultLanguage
            speakers = settings.defaultSpeakers
            outputFolder = settings.voiceMemoOutputFolder
            focusedRow = rows.first?.id
        }
        .onChange(of: outputFolder) { _, new in store.model.settings.voiceMemoOutputFolder = new }
        .onChange(of: rows.map(\.id)) { _, ids in
            // Rows that left the list (filter, search) are no longer selected.
            selected.formIntersection(ids)
        }
        .background {
            // ⌘F focuses the search field.
            Button("Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
    }

    // MARK: Header and controls

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import from Voice Memos").themedHeading(20)
            Text(VoiceMemoFormat.subtitle(count: rows.count, selected: addable.count,
                                          total: rows.reduce(0) { $0 + $1.durationSeconds }))
                .font(.callout).foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryText).accessibilityHidden(true)
                TextField("Search recordings", text: $search)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("Search recordings")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(theme.secondaryText)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: theme.cornerRadius).fill(theme.control))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(theme.separator))
            .frame(maxWidth: 360)

            Menu {
                Button("All Recordings") { folderID = nil }
                if !listing.folders.isEmpty { Divider() }
                ForEach(listing.folders) { folder in
                    Button(folder.name) { folderID = folder.id }
                }
            } label: {
                Text(folderID.flatMap { id in listing.folders.first { $0.id == id }?.name } ?? "All Recordings")
            }
            .menuStyle(.button).buttonStyle(.themedSecondary).fixedSize()
            .accessibilityLabel("Folder")

            Menu {
                ForEach(VoiceMemoSort.allCases) { option in
                    Button(option.label) { sort = option }
                }
            } label: { Text(sort.label) }
            .menuStyle(.button).buttonStyle(.themedSecondary).fixedSize()
            .accessibilityLabel("Sort")

            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 22)
            SectionLabel("Title").frame(maxWidth: .infinity, alignment: .leading)
            SectionLabel("Date").frame(width: 130, alignment: .leading)
            SectionLabel("Length").frame(width: 64, alignment: .trailing)
            SectionLabel("Folder").frame(width: 110, alignment: .leading)
            Color.clear.frame(width: 190)
        }
        .padding(.horizontal, 20).padding(.vertical, 6)
        .background(theme.bar)
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        if rows.isEmpty {
            VStack(spacing: 6) {
                Text(listing.memos.isEmpty ? "No recordings in Voice Memos" : "No recordings match")
                    .font(.headline)
                if !listing.memos.isEmpty {
                    Text(search.isEmpty && folderID == nil && !showImported
                         ? "Everything here was already imported. Turn on “Show already imported” to see it."
                         : "Try another search or folder.")
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { memo in
                        row(memo)
                        theme.separator.frame(height: 1)
                    }
                }
            }
        }
    }

    private func row(_ memo: VoiceMemo) -> some View {
        let availability = VoiceMemoCatalog.availability(of: memo, imported: imported, queued: queued)
        let isOn = selected.contains(memo.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button { toggle(memo) } label: {
                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                        .font(.system(size: 17))
                        .foregroundStyle(isOn ? theme.accentText : theme.secondaryText)
                        .frame(width: 22)
                }
                .buttonStyle(.plain).disabled(!availability.isSelectable)
                .accessibilityLabel(memo.title)
                .accessibilityValue(isOn ? "selected" : "not selected")

                HStack(spacing: 5) {
                    Text(memo.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    if memo.favorite {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(theme.warning)
                            .accessibilityLabel("Favourite")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(VoiceMemoFormat.relativeDate(memo.recorded)).foregroundStyle(theme.secondaryText)
                    .frame(width: 130, alignment: .leading)
                Text(VoiceMemoFormat.length(memo.durationSeconds)).monospacedDigit().foregroundStyle(theme.secondaryText)
                    .frame(width: 64, alignment: .trailing)
                Text(listing.folderName(for: memo) ?? "").foregroundStyle(theme.secondaryText).lineLimit(1)
                    .frame(width: 110, alignment: .leading)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if memo.appleTranscript { VoiceMemoBadge(text: "Apple transcript", kind: .apple) }
                    switch availability {
                    case .alreadyImported: VoiceMemoBadge(text: "Already imported", kind: .imported)
                    case .inQueue: VoiceMemoBadge(text: "In queue", kind: .queued)
                    case .notLocal: VoiceMemoBadge(text: "In iCloud only", kind: .iCloud)
                    case .available: EmptyView()
                    }
                }
                .frame(width: 190)
            }
            if availability == .notLocal, isOn {
                Text("Open the memo in Voice Memos once to download it.")
                    .font(.caption).foregroundStyle(theme.warning)
                    .padding(.leading, 34)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .opacity(availability.isSelectable ? 1 : 0.55)
        .background(focusedRow == memo.id ? theme.soft : (isOn ? theme.soft.opacity(0.6) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { focusedRow = memo.id; toggle(memo) }
        .focusable()
        .focusEffectDisabled()
        .focused($focusedRow, equals: memo.id)
        .onKeyPress(.space) { toggle(memo); return .handled }
        .onKeyPress(phases: .down) { press in
            guard press.key == KeyEquivalent("a"), press.modifiers == .command else { return .ignored }
            selected = VoiceMemoCatalog.selectAll(rows, imported: imported, queued: queued)
            return .handled
        }
        .accessibilityElement(children: .contain)
    }

    private func toggle(_ memo: VoiceMemo) {
        guard VoiceMemoCatalog.availability(of: memo, imported: imported, queued: queued).isSelectable else { return }
        if selected.contains(memo.id) { selected.remove(memo.id) } else { selected.insert(memo.id) }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            LanguagePicker("Language", selection: $language, model: store.model, showsChips: false)
                .frame(width: 190)
            Button { speakersOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Text("Speakers: \(speakers.label)").lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).accessibilityHidden(true)
                }
            }
            .buttonStyle(.themedSecondary)
            .accessibilityLabel("Speakers")
            .accessibilityValue(speakers.label)
            .popover(isPresented: $speakersOpen, arrowEdge: .top) {
                SpeakerPicker(selection: $speakers).padding(14).frame(width: 300)
                    .environment(\.theme, theme)
                    .background(theme.window)
            }
            Menu {
                Button("Transcripts folder") { outputFolder = nil }
                Button("Choose…") { chooseFolder() }
            } label: {
                Text("Save to: \(outputFolder?.lastPathComponent ?? "Transcripts folder")").lineLimit(1)
            }
            .menuStyle(.button).buttonStyle(.themedSecondary).fixedSize()
            .help(outputFolder?.path ?? EngineCommand.defaultVoiceMemoFolder.path)
            .accessibilityLabel("Save to")
            Toggle("Show already imported", isOn: $showImported).toggleStyle(.checkbox)
            Spacer()
            Button("Cancel", action: onCancel).buttonStyle(.themedSecondary).keyboardShortcut(.cancelAction)
            Button(addable.isEmpty ? "Add to Queue" : "Add \(addable.count) to Queue") { add() }
                .buttonStyle(.themedPrimary).keyboardShortcut(.defaultAction).disabled(addable.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(theme.bar)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url }
    }

    private func add() {
        let options = JobOptions(language: language, speakers: speakers, outputFolder: outputFolder)
        store.addVoiceMemos(addable, folderNames: listing.folderNames, options: options)
        onDone()
    }
}
