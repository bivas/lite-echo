import AppKit
import LiteEchoCore
import LiteEchoShared
import SwiftUI

/// Deep link to Privacy & Security › Full Disk Access (it may land on the general page).
enum VoiceMemoSettingsLink {
    static let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func open() { NSWorkspace.shared.open(fullDiskAccess) }
}

/// Sheet B: LiteEcho cannot read the Voice Memos library (Full Disk Access is off), plus the
/// other states in which the library cannot be listed.
struct VoiceMemoAccessView: View {
    let listing: VoiceMemoListing
    let isChecking: Bool
    let onCheckAgain: () -> Void
    let onChooseFiles: () -> Void
    let onCancel: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch listing.status {
            case .noAccess, .ok: accessContent
            case .noLibrary: noLibraryContent
            case .unreadable: unreadableContent
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(theme.window)
    }

    // MARK: No access

    @ViewBuilder private var accessContent: some View {
        Text("Allow LiteEcho to read your Voice Memos").themedHeading(20)
        Text("LiteEcho only reads your recordings. It never changes or deletes them, and nothing leaves this Mac.")
            .foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 12) {
            step(1, "Open System Settings › Privacy & Security › Full Disk Access.")
            step(2, "Turn on LiteEcho in the list, or add it with the + button.")
            step(3, "Come back here. LiteEcho checks again when it becomes active, or press Check Again.")
        }
        .themedCard(padding: 14)
        Text("macOS may ask you to quit and reopen LiteEcho after you change this.")
            .font(.caption).foregroundStyle(theme.secondaryText)
        HStack(spacing: 10) {
            Button("Choose Files Instead…", action: onChooseFiles).buttonStyle(.themedSecondary)
            Spacer()
            Button("Cancel", action: onCancel).buttonStyle(.themedSecondary)
                .keyboardShortcut(.cancelAction)
            Button("Check Again", action: onCheckAgain).buttonStyle(.themedSecondary).disabled(isChecking)
            Button("Open System Settings") { VoiceMemoSettingsLink.open() }
                .buttonStyle(.themedPrimary).keyboardShortcut(.defaultAction)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.callout.weight(.bold)).foregroundStyle(theme.onAccent)
                .frame(width: 22, height: 22).background(Circle().fill(theme.accent))
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
    }

    // MARK: Other states

    @ViewBuilder private var noLibraryContent: some View {
        Text("No Voice Memos library found").themedHeading(20)
        Text("No Voice Memos library was found on this Mac. Record something in the Voice Memos app first, or choose audio files instead.")
            .foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
            Button("Choose Files Instead…", action: onChooseFiles).buttonStyle(.themedSecondary)
            Spacer()
            Button("Cancel", action: onCancel).buttonStyle(.themedSecondary).keyboardShortcut(.cancelAction)
            Button("Check Again", action: onCheckAgain).buttonStyle(.themedPrimary)
                .keyboardShortcut(.defaultAction).disabled(isChecking)
        }
    }

    @ViewBuilder private var unreadableContent: some View {
        Text("Couldn't read the library").themedHeading(20)
        Text("The Voice Memos library could not be read. Your recordings are untouched.")
            .foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        if !listing.detail.isEmpty {
            Text(listing.detail).font(.caption).textSelection(.enabled)
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .themedCard(padding: 10)
        }
        HStack(spacing: 10) {
            Button("Copy Details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(listing.detail, forType: .string)
            }
            .buttonStyle(.themedSecondary).disabled(listing.detail.isEmpty)
            Button("Choose Files Instead…", action: onChooseFiles).buttonStyle(.themedSecondary)
            Spacer()
            Button("Cancel", action: onCancel).buttonStyle(.themedSecondary).keyboardShortcut(.cancelAction)
            Button("Check Again", action: onCheckAgain).buttonStyle(.themedPrimary)
                .keyboardShortcut(.defaultAction).disabled(isChecking)
        }
    }
}
