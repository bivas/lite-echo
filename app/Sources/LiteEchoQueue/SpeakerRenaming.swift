import Foundation
import LiteEchoCore
import LiteEchoShared
import SwiftUI

/// Pure logic behind the "Rename Speakers…" sheet. Speakers are keyed by their stable ID
/// ("S1"); only the display name changes.
public enum SpeakerRenaming {
    public static let maxNameLength = 60

    /// Unnamed speakers (name equals the ID) start with an empty field; renamed ones show their name.
    public static func defaultFieldText(for speaker: TranscriptSpeaker) -> String {
        speaker.name == speaker.id ? "" : speaker.name
    }

    /// Speakers of a v1 transcript file, in order of first appearance.
    public static func speakers(in transcript: URL) throws -> [TranscriptSpeaker] {
        try TranscriptDocument.load(from: transcript).speakers
    }

    /// New names by speaker ID, for the fields that differ from the current name.
    public static func changes(speakers: [TranscriptSpeaker], fields: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for speaker in speakers {
            let value = (fields[speaker.id] ?? defaultFieldText(for: speaker)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, value != speaker.name { result[speaker.id] = value }
        }
        return result
    }

    /// A message when the changes cannot be applied, else nil.
    public static func validationError(speakers: [TranscriptSpeaker], changes: [String: String]) -> String? {
        let finalNames = speakers.map { changes[$0.id] ?? $0.name }
        if Set(finalNames).count != finalNames.count { return "Each speaker needs a different name." }
        if changes.values.contains(where: { $0.count > maxNameLength }) {
            return "Names can be at most \(maxNameLength) characters."
        }
        let badName = changes.values.contains { value in
            value.contains(where: \.isNewline) || value.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
        return badName ? "Names can't contain line breaks." : nil
    }
}

/// Sheet listing the speakers of a finished transcript with a text field for each.
/// Applies the names through the engine (`rename-speakers FILE --map OLD=NEW`).
struct RenameSpeakersSheet: View {
    let transcript: URL
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @StateVar private var speakers: [TranscriptSpeaker] = []
    @StateVar private var loadError: String?
    @StateVar private var names: [String: String] = [:]
    @StateVar private var error: String?
    @StateVar private var isApplying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Speakers").themedHeading(16)
            Text(transcript.deletingPathExtension().lastPathComponent)
                .font(.caption).foregroundStyle(theme.secondaryText).lineLimit(1).truncationMode(.middle)
            if let loadError {
                Text(loadError).font(.callout).foregroundStyle(loadIsInformational ? theme.secondaryText : theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if speakers.isEmpty {
                Text("No speakers were detected in this transcript.").font(.callout).foregroundStyle(theme.secondaryText)
            } else {
                ForEach(Array(speakers.enumerated()), id: \.element.id) { index, speaker in
                    HStack(spacing: 10) {
                        Circle().fill(Color(hex: SpeakerPalette.hex(forIndex: index))).frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text(speaker.id).font(.callout).foregroundStyle(theme.secondaryText).frame(width: 60, alignment: .leading)
                        TextField("Name this speaker", text: Binding(
                            get: { names[speaker.id] ?? SpeakerRenaming.defaultFieldText(for: speaker) },
                            set: { names[speaker.id] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await apply() } }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(theme.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if isApplying { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.themedSecondary)
                Button("Rename") { Task { await apply() } }
                    .buttonStyle(.themedPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isApplying || SpeakerRenaming.changes(speakers: speakers, fields: names).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { load() }
    }

    /// Older transcripts are not an error, they just can't be renamed.
    private var loadIsInformational: Bool { loadErrorIsOlderVersion }
    @StateVar private var loadErrorIsOlderVersion = false

    private func load() {
        do { speakers = try SpeakerRenaming.speakers(in: transcript) } catch {
            loadError = error.localizedDescription
            loadErrorIsOlderVersion = (error as? TranscriptParseError) == .olderVersion
        }
    }

    private func apply() async {
        let changes = SpeakerRenaming.changes(speakers: speakers, fields: names)
        guard !changes.isEmpty, !isApplying else { return }
        if let problem = SpeakerRenaming.validationError(speakers: speakers, changes: changes) {
            error = problem
            return
        }
        guard model.isEngineInstalled else {
            error = "The engine is not installed yet. Finish setup first."
            return
        }
        isApplying = true
        error = nil
        defer { isApplying = false }
        let process = model.makeEngineProcess(EngineCommand.renameSpeakers(file: transcript, names: changes))
        do {
            let result = try await process.run { _ in }
            if result.exitCode != 0 {
                let tail = result.stderrTail.split(separator: "\n").suffix(3).joined(separator: "\n")
                error = tail.isEmpty ? "Renaming failed (exit code \(result.exitCode))." : tail
                return
            }
            dismiss()
        } catch {
            self.error = "Could not start the engine: \(error.localizedDescription)"
        }
    }
}

private extension Color {
    /// "#RRGGBB"
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
