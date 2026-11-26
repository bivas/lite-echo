import LiteEchoCore
import SwiftUI

/// "Pick the kind of recording": a 2x2 grid of preset cards plus a "Custom number…" section
/// (exactly N, or a range). Used by the sidebar, Preferences and per-file options.
public struct SpeakerPicker: View {
    @Binding private var selection: SpeakerSetting
    @StateVar private var customOpen = false
    @StateVar private var mode: CustomMode = .exactly
    @StateVar private var exactCount = 3
    @StateVar private var rangeMin = 2
    @StateVar private var rangeMax = 4
    @StateVar private var synced = false
    @Environment(\.theme) private var theme

    enum CustomMode: Hashable { case exactly, range }

    public init(selection: Binding<SpeakerSetting>) {
        self._selection = selection
    }

    private var isCustom: Bool { SpeakerPreset(matching: selection) == nil }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    card(.auto)
                    card(.solo)
                }
                GridRow {
                    card(.conversation)
                    card(.meeting)
                }
            }
            Button {
                if !customOpen { syncDraft() }
                customOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: customOpen ? "chevron.down" : "chevron.right").font(.caption2)
                        .accessibilityHidden(true)
                    Text(isCustom && !customOpen ? "Custom: \(selection.label)" : "Custom number…")
                }
                .font(.callout)
                .foregroundStyle(theme.accentText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Custom number of speakers")
            .accessibilityValue(customOpen ? "expanded" : "collapsed")
            if customOpen { customEditor }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speakers")
        .onAppear {
            guard !synced else { return }
            synced = true
            syncDraft()
            if isCustom { customOpen = true }
        }
    }

    // MARK: Cards

    private func card(_ preset: SpeakerPreset) -> some View {
        let selected = SpeakerPreset(matching: selection) == preset
        return Button {
            selection = preset.setting
            syncDraft()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.title).font(.callout.weight(.semibold))
                Text(preset.detail).font(.caption).foregroundStyle(theme.secondaryText)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: theme.cornerRadius).fill(selected ? theme.soft : theme.control))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                .stroke(selected ? theme.accent : theme.separator, lineWidth: selected ? 2 : 1))
            .themedGlow(selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.title), \(preset.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Custom

    private var customEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemedSegmentedPicker("Custom speaker count", selection: Binding(
                get: { mode },
                set: { mode = $0; commit() }),
                options: [(CustomMode.exactly, "Exactly"), (CustomMode.range, "Range")])
            if mode == .exactly {
                Stepper(value: Binding(get: { exactCount }, set: { exactCount = $0; commit() }),
                        in: SpeakerSetting.limits) {
                    Text(exactCount == 1 ? "1 speaker" : "\(exactCount) speakers")
                }
                .accessibilityLabel("Number of speakers")
            } else {
                Stepper(value: Binding(get: { rangeMin }, set: { setRange(min: $0, changedMin: true) }),
                        in: SpeakerSetting.limits) {
                    Text("Between \(rangeMin)")
                }
                .accessibilityLabel("Fewest speakers")
                Stepper(value: Binding(get: { rangeMax }, set: { setRange(max: $0, changedMin: false) }),
                        in: SpeakerSetting.limits) {
                    Text("and \(rangeMax)")
                }
                .accessibilityLabel("Most speakers")
            }
        }
        .padding(.leading, 4)
    }

    private func setRange(min: Int? = nil, max: Int? = nil, changedMin: Bool) {
        let bounds = SpeakerSetting.enforcing(min: min ?? rangeMin, max: max ?? rangeMax, changedMin: changedMin)
        rangeMin = bounds.min
        rangeMax = bounds.max
        commit()
    }

    private func commit() {
        switch mode {
        case .exactly: selection = .exactly(exactCount)
        case .range: selection = .range(min: rangeMin, max: rangeMax)
        }
    }

    /// Loads the editor's values from the current setting.
    private func syncDraft() {
        switch selection.validated {
        case .auto: break
        case .exactly(let n): mode = .exactly; exactCount = n
        case .range(let lo, let hi):
            mode = .range
            rangeMin = lo ?? hi ?? 2
            rangeMax = hi ?? Swift.max(lo ?? 2, 4)
            let fixed = SpeakerSetting.enforcing(min: rangeMin, max: rangeMax, changedMin: true)
            rangeMin = fixed.min; rangeMax = fixed.max
        }
    }
}
