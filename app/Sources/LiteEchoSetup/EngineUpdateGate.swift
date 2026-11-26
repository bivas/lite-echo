import LiteEchoCore
import LiteEchoShared
import SwiftUI

/// Shows `content` once the installed engine matches the engine files bundled in this app.
///
/// - Only the liteecho wheel changed (or an older install without fingerprint): updates
///   silently with a short progress view; it is offline and takes seconds.
/// - The pinned libraries changed: asks first, because that may download.
/// - A failed update keeps the old engine; the user can continue with it or retry.
public struct EngineUpdateGate<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @StateVar private var phase: Phase = .checking
    private let content: () -> Content

    enum Phase: Equatable {
        case checking
        case askToUpdate
        case updating(String)
        case failed(String)
        case ready
    }

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        // The check (and a silent update it may start) is attached to this container, not to the
        // "Checking" view: that view disappears when the phase changes, and SwiftUI would cancel
        // its task midway through the update, leaving the install marker unwritten.
        Group { phaseView }
            .task { await check() }
    }

    @ViewBuilder private var phaseView: some View {
        switch phase {
        case .ready:
            content()
        case .checking:
            ProgressView("Checking the engine…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .updating(let step):
            VStack(spacing: 12) {
                ProgressView()
                Text("Updating the engine").themedHeading(16)
                Text(step).font(.callout).foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .askToUpdate:
            notice(title: "This version of LiteEcho needs updated libraries",
                   message: "Updating may download part of the engine again. Your transcripts, settings and models are kept.",
                   primary: ("Update Engine", { Task { await runUpdate() } }),
                   secondary: ("Not Now", { phase = .ready }))
        case .failed(let message):
            notice(title: "The engine could not be updated",
                   message: "\(message)\nYou can keep using the current engine.",
                   primary: ("Try Again", { Task { await runUpdate() } }),
                   secondary: ("Continue", { phase = .ready }))
        }
    }

    private func notice(title: String, message: String, primary: (String, () -> Void),
                        secondary: (String, () -> Void)) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).themedHeading(16)
            Text(message).font(.callout).foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(primary.0, action: primary.1)
                    .buttonStyle(.themedPrimary)
                    .keyboardShortcut(.defaultAction)
                Button(secondary.0, action: secondary.1)
                    .buttonStyle(.themedSecondary)
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func check() async {
        guard phase == .checking else { return }
        switch EngineInstaller(paths: model.paths).updateNeed {
        case .none: phase = .ready
        case .engineOnly: await runUpdate()
        case .packages: phase = .askToUpdate
        }
    }

    private func runUpdate() async {
        let installer = EngineInstaller(paths: model.paths)
        phase = .updating("Starting…")
        do {
            try await installer.update(onStep: { step in
                Task { @MainActor in phase = .updating(step.title) }
            })
            await model.refreshEngineInfo()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
