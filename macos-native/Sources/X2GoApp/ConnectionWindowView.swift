import SwiftUI

/// Contents of a per-connection window. Looks up the live ConnectionViewModel by
/// id; on window close it suspends + removes the connection.
struct ConnectionWindowView: View {
    let coordinator: SessionCoordinator
    let id: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let id, let vm = coordinator.connection(for: id) {
                // Close is handled by ConnectionWindowDelegate (asks suspend vs
                // terminate) and by the dashboard; no onDisappear teardown here,
                // so the chosen action isn't overridden by a default suspend.
                ConnectionView(vm: vm)
            } else {
                // No live connection (e.g. a window restored from a previous run):
                // close it so we never show a stale, empty connection window.
                Color.clear.onAppear { dismiss() }
            }
        }
    }
}
