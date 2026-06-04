import SwiftUI

/// Contents of a per-connection window. Looks up the live ConnectionViewModel by
/// id; on window close it suspends + removes the connection.
struct ConnectionWindowView: View {
    let coordinator: SessionCoordinator
    let id: UUID?

    var body: some View {
        Group {
            if let id, let vm = coordinator.connection(for: id) {
                // Close is handled by ConnectionWindowDelegate (asks suspend vs
                // terminate) and by the dashboard; no onDisappear teardown here,
                // so the chosen action isn't overridden by a default suspend.
                ConnectionView(vm: vm)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle.slash").font(.largeTitle)
                    Text("Connection closed").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }
        }
    }
}
