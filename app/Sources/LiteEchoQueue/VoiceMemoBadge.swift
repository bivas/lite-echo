import LiteEchoShared
import SwiftUI

/// Small rounded label used for the Voice Memos badges. Colours come from theme tokens only.
struct VoiceMemoBadge: View {
    enum Kind {
        /// "Voice Memo" on a queue row (red-ish).
        case source
        /// "Apple transcript" (green).
        case apple
        /// "Already imported" (grey).
        case imported
        /// "In iCloud only" (amber).
        case iCloud
        /// "In queue" (accent).
        case queued
    }

    let text: String
    let kind: Kind
    @Environment(\.theme) private var theme

    private var tint: Color {
        switch kind {
        case .source: theme.danger
        case .apple: theme.success
        case .imported: theme.secondaryText
        case .iCloud: theme.warning
        case .queued: theme.accentText
        }
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(theme.uppercaseLabels ? .uppercase : nil)
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().stroke(tint.opacity(0.4)))
            .fixedSize()
    }
}
