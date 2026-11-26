import LiteEchoCore
import SwiftUI

/// Language dropdown: a field showing the current choice, a searchable popover (Detect, Recent,
/// All languages) and the two most recent languages as one-click chips underneath.
public struct LanguagePicker: View {
    @Binding private var selection: LanguageChoice
    private let languages: [LanguageInfo]
    private let recents: [LanguageChoice]
    private let showsChips: Bool
    private let onPick: (LanguageChoice) -> Void
    private let label: String
    @StateVar private var isOpen = false
    @Environment(\.theme) private var theme

    public init(_ label: String = "Language", selection: Binding<LanguageChoice>, languages: [LanguageInfo],
                recents: [LanguageChoice], showsChips: Bool = true,
                onPick: @escaping (LanguageChoice) -> Void = { _ in }) {
        self.label = label
        self._selection = selection
        self.languages = languages
        self.recents = recents
        self.showsChips = showsChips
        self.onPick = onPick
    }

    /// Uses the engine's language list and the remembered recents; picking updates the recents.
    @MainActor
    public init(_ label: String = "Language", selection: Binding<LanguageChoice>, model: AppModel,
                showsChips: Bool = true) {
        let settings = model.settings
        self.init(label, selection: selection, languages: model.languages, recents: settings.recentLanguages,
                  showsChips: showsChips, onPick: { settings.noteLanguagePicked($0) })
    }

    private var currentName: String { LanguageCatalog.displayName(of: selection, in: languages) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 8) {
                    Text(currentName).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        .foregroundStyle(theme.secondaryText).accessibilityHidden(true)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: theme.cornerRadius).fill(theme.control))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(theme.separator))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(currentName)
            .accessibilityHint("Opens a searchable list of languages")
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                LanguageListPopover(selection: selection, languages: languages, recents: recents) { choice in
                    selection = choice
                    onPick(choice)
                    isOpen = false
                }
                .environment(\.theme, theme)
            }
            if showsChips, !recents.isEmpty {
                HStack(spacing: 6) {
                    ForEach(recents, id: \.self) { choice in
                        chip(choice)
                    }
                }
            }
        }
    }

    private func chip(_ choice: LanguageChoice) -> some View {
        let selected = choice == selection
        return Button {
            selection = choice
            onPick(choice)
        } label: {
            Text(LanguageCatalog.name(forCode: choice.code, in: languages))
                .font(.caption.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(selected ? theme.accentText : theme.text)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(selected ? theme.soft : theme.control))
                .overlay(Capsule().stroke(selected ? theme.accent : theme.separator))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LanguageCatalog.name(forCode: choice.code, in: languages))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One row of the popover. `id` is unique across sections (a language can be Recent and in All).
struct LanguageRow: Identifiable, Equatable {
    enum Section { case detect, recent, all }
    let section: Section
    let choice: LanguageChoice
    let info: LanguageInfo?
    var id: String { "\(section)-\(choice.code)" }
}

/// Rows of the popover for a query, in display order. Pure, so it is unit-tested.
enum LanguageRows {
    static func build(languages: [LanguageInfo], recents: [LanguageChoice], query: String) -> [LanguageRow] {
        var rows: [LanguageRow] = []
        if LanguageCatalog.autoMatches(query: query) {
            rows.append(LanguageRow(section: .detect, choice: .auto, info: nil))
        }
        let known = Dictionary(languages.map { ($0.code.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let recentInfos = recents.filter { !$0.isAuto }.map {
            known[$0.code] ?? LanguageInfo(code: $0.code, name: LanguageCatalog.name(forCode: $0.code, in: languages))
        }
        for info in LanguageCatalog.filter(recentInfos, query: query) {
            rows.append(LanguageRow(section: .recent, choice: LanguageChoice(code: info.code), info: info))
        }
        for info in LanguageCatalog.filter(languages, query: query) {
            rows.append(LanguageRow(section: .all, choice: LanguageChoice(code: info.code), info: info))
        }
        return rows
    }

    /// "N matches" for a query, "N languages" without one.
    static func countText(rows: [LanguageRow], query: String) -> String {
        let n = rows.filter { $0.section != .recent }.count
        if LanguageCatalog.fold(query).isEmpty { return n == 1 ? "1 language" : "\(n) languages" }
        return n == 1 ? "1 match" : "\(n) matches"
    }
}

private struct LanguageListPopover: View {
    let selection: LanguageChoice
    let languages: [LanguageInfo]
    let recents: [LanguageChoice]
    let onPick: (LanguageChoice) -> Void
    @StateVar private var query = ""
    @StateVar private var highlighted = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.theme) private var theme

    private var rows: [LanguageRow] { LanguageRows.build(languages: languages, recents: recents, query: query) }

    var body: some View {
        let rows = self.rows
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryText).accessibilityHidden(true)
                TextField("Search by name, native name or code", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Search languages")
                    .onSubmit { pickHighlighted(rows) }
                    .onKeyPress(.upArrow) { move(-1, rows); return .handled }
                    .onKeyPress(.downArrow) { move(1, rows); return .handled }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: theme.cornerRadius).fill(theme.control))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(theme.separator))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index == 0 || rows[index - 1].section != row.section {
                                header(for: row.section).padding(.top, index == 0 ? 0 : 10).padding(.bottom, 2)
                            }
                            rowView(row, highlighted: index == highlighted).id(row.id)
                        }
                        if rows.isEmpty {
                            Text("No languages match “\(query)”").font(.callout)
                                .foregroundStyle(theme.secondaryText).padding(.vertical, 12)
                        }
                    }
                }
                .frame(height: 300)
                .onChange(of: highlighted) { _, new in
                    if rows.indices.contains(new) { proxy.scrollTo(rows[new].id) }
                }
            }
            Text(LanguageRows.countText(rows: rows, query: query))
                .font(.caption).foregroundStyle(theme.secondaryText)
                .accessibilityLabel(LanguageRows.countText(rows: rows, query: query))
        }
        .padding(12)
        .frame(width: 320)
        .background(theme.window)
        .foregroundStyle(theme.text)
        .tint(theme.accent)
        .fontDesign(theme.bodyDesign)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onAppear {
            highlighted = rows.firstIndex(where: { $0.section == .all && $0.choice == selection })
                ?? rows.firstIndex(where: { $0.choice == selection }) ?? 0
            searchFocused = true
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func move(_ delta: Int, _ rows: [LanguageRow]) {
        guard !rows.isEmpty else { return }
        highlighted = min(rows.count - 1, max(0, highlighted + delta))
    }

    private func pickHighlighted(_ rows: [LanguageRow]) {
        guard rows.indices.contains(highlighted) else { return }
        onPick(rows[highlighted].choice)
    }

    private func header(for section: LanguageRow.Section) -> some View {
        switch section {
        case .detect: SectionLabel("Detect")
        case .recent: SectionLabel("Recent")
        case .all: SectionLabel("All languages")
        }
    }

    private func rowView(_ row: LanguageRow, highlighted: Bool) -> some View {
        let selected = row.choice == selection
        return Button { onPick(row.choice) } label: {
            HStack(spacing: 6) {
                if let info = row.info {
                    Text(info.name).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                    if info.native != info.name {
                        Text("· \(info.native)").foregroundStyle(theme.secondaryText).lineLimit(1)
                    }
                    Text("· \(info.code)").foregroundStyle(theme.secondaryText).font(.callout.monospaced())
                    if info.tuned {
                        Text("Tuned").font(.caption2.weight(.semibold)).foregroundStyle(theme.accentText)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().stroke(theme.accent))
                    }
                } else {
                    Text("Auto-detect").fontWeight(selected ? .semibold : .regular)
                    Text("· picks per file").foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark").font(.caption.weight(.semibold))
                        .foregroundStyle(theme.accentText).accessibilityHidden(true)
                }
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: max(2, theme.cornerRadius - 3))
                .fill(highlighted ? theme.soft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.info.map { "\($0.name), \($0.native), \($0.code)" + ($0.tuned ? ", tuned" : "") }
                            ?? "Auto-detect, picks per file")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
