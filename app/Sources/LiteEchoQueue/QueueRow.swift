import AppKit
import LiteEchoCore
import LiteEchoShared
import SwiftUI

struct QueueRow: View {
    let job: Job
    let store: QueueStore
    @StateVar private var renamingTranscript: URL?
    @StateVar private var pendingConfirmation: PendingConfirmation?
    @StateVar private var hovering = false
    @FocusState private var rowFocused: Bool
    @FocusState private var removeFocused: Bool
    @Environment(\.theme) private var theme

    private var subtitle: String {
        QueueFormat.subtitle(for: job, duration: store.durations[job.id], finishedIn: store.finishedIn[job.id],
                             languages: store.model.languages)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                icon.frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(job.displayName).font(.system(size: 14, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                        if job.voiceMemo != nil { VoiceMemoBadge(text: "Voice Memo", kind: .source) }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(theme.secondaryText)
                    if case .failed(let message) = job.state {
                        Text(message).font(.caption).foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            if case .running(let stage, let progress, let detail) = job.state {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(QueueFormat.columns(stage: stage, progress: progress, detail: detail), id: \.title) {
                        ProgressColumn(column: $0)
                    }
                }
                .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(isRunning ? theme.soft : Color.clear)
        .onHover { hovering = $0 }
        .focusable(QueueFormat.offersRemoveButton(for: job.state))
        .focusEffectDisabled()
        .focused($rowFocused)
        .onKeyPress(.delete) {
            guard QueueFormat.offersRemoveButton(for: job.state) else { return .ignored }
            pendingConfirmation = store.request(.remove(job))
            return .handled
        }
        .accessibilityElement(children: .contain)
        .contextMenu {
            if case .done(let output, _) = job.state {
                Button("Open Transcript") { TranscriptOpener.open(output) }
                Button("Rename Speakers…") { renamingTranscript = output }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
            }
        }
        .queueConfirmation($pendingConfirmation, store: store)
        .sheet(isPresented: Binding(get: { renamingTranscript != nil },
                                    set: { if !$0 { renamingTranscript = nil } })) {
            if let url = renamingTranscript {
                RenameSpeakersSheet(transcript: url, model: store.model).themed(store.model.settings)
            }
        }
    }

    private var isRunning: Bool {
        if case .running = job.state { return true }
        return false
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .done:
            Image(systemName: "checkmark.circle").font(.system(size: 22)).foregroundStyle(theme.success)
                .accessibilityLabel("Done")
        case .running:
            ProgressView().controlSize(.small).accessibilityLabel("Running")
        case .waiting:
            Image(systemName: "clock").font(.system(size: 22)).foregroundStyle(theme.secondaryText)
                .accessibilityLabel("Waiting")
        case .failed:
            Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(theme.danger)
                .accessibilityLabel("Failed")
        case .cancelled:
            Image(systemName: "slash.circle").font(.system(size: 22)).foregroundStyle(theme.secondaryText)
                .accessibilityLabel("Cancelled")
        }
    }

    @ViewBuilder private var actions: some View {
        switch job.state {
        case .done(let output, _):
            Button("Open transcript") { TranscriptOpener.open(output) }
                .buttonStyle(.themedPrimary)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                .buttonStyle(.themedSecondary)
            removeFromListButton
        case .running:
            Button("Cancel") { pendingConfirmation = store.request(.stop(job)) }
                .buttonStyle(.themedSecondary)
        case .waiting:
            Button("Remove") { pendingConfirmation = store.request(.remove(job)) }
                .buttonStyle(.themedSecondary)
                .accessibilityLabel("Remove \(job.displayName) from the queue")
        case .failed(let message):
            if job.voiceMemo != nil, message == VoiceMemoImportError.accessMessage {
                Button("Set up access…") { store.model.showVoiceMemoImport = true }
                    .buttonStyle(.themedSecondary)
            }
            Button("Show log") { NSWorkspace.shared.open(store.logURL(for: job.id)) }
                .buttonStyle(.themedSecondary)
            Button("Retry") { store.retry(job.id) }
                .buttonStyle(.themedSecondary)
            removeFromListButton
        case .cancelled:
            Button("Retry") { store.retry(job.id) }
                .buttonStyle(.themedSecondary)
            removeFromListButton
        }
    }

    /// Small circular ✕ for finished rows. Faded out (not removed) until hover/focus so layout is stable
    /// and it stays in the accessibility tree and Tab order.
    private var removeFromListButton: some View {
        let visible = hovering || rowFocused || removeFocused
        return Button { pendingConfirmation = store.request(.remove(job)) } label: {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 22, height: 22)
                .background(Circle().fill(theme.control))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focused($removeFocused)
        .opacity(visible ? 1 : 0)
        .help("Remove from the list")
        .accessibilityLabel("Remove “\(job.displayName)” from the list")
    }
}

private struct ProgressColumn: View {
    let column: QueueFormat.Column
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(column.title).font(.caption.weight(.semibold))
                Spacer()
                switch column.status {
                case .done: Text("Done").font(.caption).foregroundStyle(theme.success)
                case .active(let p): Text("\(Int((p * 100).rounded()))%").font(.caption.weight(.semibold))
                        .foregroundStyle(theme.accentText)
                case .pending: EmptyView()
                }
            }
            switch column.status {
            case .done: ThemedProgressBar(value: 1, tint: theme.success)
            case .active(let p): ThemedProgressBar(value: p)
            case .pending: ThemedProgressBar(value: 0)
            }
            if let detail = column.detail {
                Text(detail).font(.caption).foregroundStyle(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
