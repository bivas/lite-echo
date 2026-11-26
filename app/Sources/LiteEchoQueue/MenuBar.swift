import AppKit
import LiteEchoCore
import LiteEchoShared
import SwiftUI

/// Menu bar icon reflecting the queue state.
public struct MenuBarLabel: View {
    private let store: QueueStore

    public init(store: QueueStore) {
        self.store = store
    }

    private var state: QueueFormat.MenuBarState {
        QueueFormat.menuBarState(isRunning: store.runningJob != nil,
                                 unseenFailed: store.unseenFailedCount,
                                 unseenFinished: store.unseenFinishedCount)
    }

    private var progress: Double {
        store.runningJob.flatMap { QueueFormat.overallProgress(of: $0.state) } ?? 0
    }

    private var doneSymbol: String {
        NSImage(systemSymbolName: "waveform.badge.checkmark", accessibilityDescription: nil) != nil
            ? "waveform.badge.checkmark" : "checkmark.circle.fill"
    }

    public var body: some View {
        switch state {
        case .idle:
            Image(nsImage: BrandGlyph.image(progress: nil)).accessibilityLabel("LiteEcho, idle")
        case .running:
            HStack(spacing: 3) {
                Image(nsImage: BrandGlyph.image(progress: progress))
                Text("\(Int((progress * 100).rounded()))%").monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("LiteEcho, transcribing, \(Int((progress * 100).rounded())) percent")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityLabel("LiteEcho, a transcription failed")
        case .unseenDone:
            Image(systemName: doneSymbol)
                .accessibilityLabel("LiteEcho, \(store.unseenFinishedCount) new transcripts ready")
        }
    }
}

/// The app's "Wave face" mark as a one-colour menu bar template image: five bars with an
/// antenna dot on the tallest. With `progress`, bars left of it are solid and the rest faint.
enum BrandGlyph {
    // Bar x positions and vertical spans in the design's 24-unit grid.
    static let bars: [(x: CGFloat, top: CGFloat, bottom: CGFloat)] =
        [(5, 10, 14), (8.5, 8, 16), (12, 4.5, 19.5), (15.5, 8, 16), (19, 10, 14)]

    static func image(progress: Double?) -> NSImage {
        // Quantise so the label is not redrawn for every tiny progress tick.
        let filled = progress.map { (min(max($0, 0), 1) * 20).rounded() / 20 }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let k = rect.width / 24
            for (i, bar) in bars.enumerated() {
                let solid = filled.map { Double(i) + 0.5 <= $0 * Double(bars.count) } ?? true
                NSColor.black.withAlphaComponent(solid ? 1 : 0.35).setStroke()
                let path = NSBezierPath()
                path.lineWidth = 2 * k
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: bar.x * k, y: bar.top * k))
                path.line(to: NSPoint(x: bar.x * k, y: bar.bottom * k))
                path.stroke()
            }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: (12 - 1.1) * k, y: (2.4 - 1.1) * k, width: 2.2 * k, height: 2.2 * k)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The menu bar window content (use with `.menuBarExtraStyle(.window)`).
public struct MenuBarContent: View {
    private let store: QueueStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.theme) private var theme

    public init(store: QueueStore) {
        self.store = store
    }

    private var stateLine: String {
        if let job = store.runningJob { return "Transcribing “\(job.audio.lastPathComponent)”" }
        if store.isPaused { return "Paused" }
        let waiting = store.jobs.filter { $0.state == .waiting }.count
        return waiting > 0 ? "\(waiting) waiting" : "Idle"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LiteEcho").themedHeading(15)
                Text(stateLine).font(.caption).foregroundStyle(theme.secondaryText).lineLimit(1).truncationMode(.middle)
            }
            if let job = store.runningJob { runningSection(job) }
            theme.separator.frame(height: 1)
            recentSection
            theme.separator.frame(height: 1)
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { store.markMenuSeen() }
    }

    @ViewBuilder private func runningSection(_ job: Job) -> some View {
        if case .running(let stage, _, let detail) = job.state {
            VStack(alignment: .leading, spacing: 6) {
                Text(job.audio.lastPathComponent).font(.subheadline.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(QueueFormat.stageName(stage)).font(.caption).foregroundStyle(theme.secondaryText)
                ThemedProgressBar(value: QueueFormat.overallProgress(of: job.state) ?? 0)
                    .accessibilityLabel("Progress for \(job.audio.lastPathComponent)")
                if let detail { Text(detail).font(.caption).foregroundStyle(theme.secondaryText) }
                Text(QueueFormat.knownInfoParts(for: job, languages: store.model.languages).joined(separator: " · "))
                    .font(.caption).foregroundStyle(theme.secondaryText)
            }
        }
    }

    @ViewBuilder private var recentSection: some View {
        let recent = store.recentFinished
        VStack(alignment: .leading, spacing: 8) {
            if recent.isEmpty {
                Text("No transcriptions yet. Drop files on the main window or use Add Files…")
                    .font(.callout).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Recently finished").font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
                ForEach(recent) { job in row(job) }
            }
        }
    }

    private func ago(_ job: Job) -> String? {
        guard let date = store.finishedAt[job.id] else { return nil }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder private func row(_ job: Job) -> some View {
        switch job.state {
        case .done(let output, _):
            Button {
                TranscriptOpener.open(output)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.audio.lastPathComponent).font(.subheadline).lineLimit(1).truncationMode(.middle)
                    Text(QueueFormat.menuSubtitle(for: job, ago: ago(job), languages: store.model.languages)).font(.caption)
                        .foregroundStyle(theme.secondaryText).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the transcript")
        case .failed(let message):
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.audio.lastPathComponent).font(.subheadline).lineLimit(1).truncationMode(.middle)
                    Text(message).font(.caption).foregroundStyle(theme.danger).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Retry") { store.retry(job.id) }
                    .buttonStyle(.themedSecondary).controlSize(.small)
                    .accessibilityLabel("Retry \(job.audio.lastPathComponent)")
            }
        default:
            EmptyView()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Open LiteEcho") {
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Add Files…") { addFiles() }
            Button(store.isPaused ? "Resume queue" : "Pause queue") { store.isPaused.toggle() }
            Button("Quit LiteEcho") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
    }

    private func addFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.message = "Choose audio or video files to transcribe"
        if panel.runModal() == .OK { store.add(panel.urls) }
    }
}
