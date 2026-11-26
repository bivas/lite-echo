import LiteEchoShared
import SwiftUI

extension View {
    /// Shows the confirmation dialog for a destructive queue action. Set `pending` (via
    /// `QueueStore.request`) to present it; the safe button (Return / Esc) leaves the queue untouched.
    func queueConfirmation(_ pending: Binding<PendingConfirmation?>, store: QueueStore) -> some View {
        modifier(QueueConfirmationModifier(pending: pending, store: store))
    }
}

private struct QueueConfirmationModifier: ViewModifier {
    @Binding var pending: PendingConfirmation?
    let store: QueueStore

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible, presenting: pending
            ) { request in
                Button(request.confirmLabel, role: .destructive) { store.perform(request) }
                // The cancel-role button answers Esc; making it the default action makes Return safe too.
                Button(request.cancelLabel, role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: { request in
                Text(request.message)
            }
            .dialogSuppressionToggle(isSuppressed: Binding(
                get: { pending.map { !$0.isEnabled(in: store.model.settings) } ?? false },
                set: { suppressed in pending?.setEnabled(!suppressed, in: store.model.settings) }))
    }
}
