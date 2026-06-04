import SwiftUI
import X2GoProtocol
import X2GoSSH

/// Modern session manager: a grid of profile cards (each with edit / open /
/// close actions and a live status), plus create/delete/import. At most one live
/// connection per profile; opening an active one brings its window to the front.
struct SessionManagerView: View {
    @Bindable var store: ProfileStore
    let coordinator: SessionCoordinator

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var selection: UUID?
    @State private var editing: SessionProfile?
    @State private var isNew = false
    @State private var passwordFor: SessionProfile?
    @State private var disconnecting: SessionProfile?
    @State private var search = ""
    @State private var importNote: String?

    private var filtered: [SessionProfile] {
        let items = store.profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !search.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(search)
            || $0.host.localizedCaseInsensitiveContains(search)
            || $0.user.localizedCaseInsensitiveContains(search)
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 16)]

    var body: some View {
        Group {
            if store.profiles.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filtered) { profile in
                            ProfileCard(
                                profile: profile,
                                vm: coordinator.connection(for: profile.id),
                                selected: selection == profile.id,
                                onEdit: { edit(profile) },
                                onOpen: { activate(profile) },
                                onClose: { disconnecting = profile })
                            .onTapGesture { selection = profile.id }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { activate(profile) })
                            .contextMenu {
                                Button("Connect / Show") { activate(profile) }
                                Button("Edit…") { edit(profile) }
                                if coordinator.isActive(profile.id) {
                                    Button("Disconnect") { disconnecting = profile }
                                }
                                Divider()
                                Button("Delete", role: .destructive) { store.delete(profile) }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .searchable(text: $search, placement: .toolbar, prompt: "Search sessions")
        .toolbar {
            ToolbarItemGroup {
                Button { newProfile() } label: { Label("New", systemImage: "plus") }
                Button { if let p = selected { store.delete(p); selection = nil } } label: {
                    Label("Delete", systemImage: "trash")
                }.disabled(selected == nil)
            }
            ToolbarItem(placement: .automatic) {
                Menu { Button("Import from old X2Go client…") { runImport() } }
                    label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        .navigationTitle("X2Go Sessions")
        .sheet(item: $editing) { profile in
            ProfileEditor(profile: profile, isNew: isNew) { saved in
                if isNew { store.add(saved) } else { store.update(saved) }
            }
        }
        .sheet(item: $passwordFor) { profile in
            PasswordPrompt(profileName: profile.name) { password in
                coordinator.connectIfNeeded(profile: profile, credentials: [.password(password)])
            }
        }
        .onChange(of: coordinator.windowToOpen) { _, newID in
            if let id = newID {
                openWindow(id: "connection", value: id)
                coordinator.windowToOpen = nil
            }
        }
        .confirmationDialog("Disconnect \(disconnecting?.name ?? "session")?",
                            isPresented: Binding(get: { disconnecting != nil },
                                                 set: { if !$0 { disconnecting = nil } }),
                            presenting: disconnecting) { p in
            Button("Suspend") {
                Task { await coordinator.close(p.id, terminate: false) }
                dismissWindow(id: "connection", value: p.id)
            }
            Button("Terminate", role: .destructive) {
                Task { await coordinator.close(p.id, terminate: true) }
                dismissWindow(id: "connection", value: p.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Suspend keeps your apps running on the server (resume later). Terminate ends the session.")
        }
        .alert("Import", isPresented: .constant(importNote != nil)) {
            Button("OK") { importNote = nil }
        } message: { Text(importNote ?? "") }
    }

    private var selected: SessionProfile? { store.profiles.first { $0.id == selection } }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "display").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No sessions yet").font(.title2)
            Text("Create a session or import from the old X2Go client.").foregroundStyle(.secondary)
            HStack {
                Button("New Session") { newProfile() }.buttonStyle(.borderedProminent)
                Button("Import…") { runImport() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func newProfile() { isNew = true; editing = SessionProfile() }
    private func edit(_ p: SessionProfile) { isNew = false; editing = p }

    private func runImport() {
        let n = store.importLegacy()
        importNote = n > 0 ? "Imported \(n) session\(n == 1 ? "" : "s")." : "No new sessions found to import."
    }

    /// Connect (or, if already live, just bring the window to the front).
    private func activate(_ p: SessionProfile) {
        if coordinator.isActive(p.id) {
            openWindow(id: "connection", value: p.id)   // already live -> bring to front
            return
        }
        // Start connecting; the window opens via coordinator.windowToOpen once the
        // session is established (or a reconnect chooser is needed).
        if let key = p.keyPath, !key.isEmpty {
            let path = (key as NSString).expandingTildeInPath
            coordinator.connectIfNeeded(profile: p, credentials: [.privateKeyFile(URL(fileURLWithPath: path))])
        } else {
            passwordFor = p
        }
    }
}

/// A profile tile with a live status badge and edit / open / close actions.
struct ProfileCard: View {
    let profile: SessionProfile
    let vm: ConnectionViewModel?
    let selected: Bool
    let onEdit: () -> Void
    let onOpen: () -> Void
    let onClose: () -> Void

    private var statusColor: Color {
        guard let vm else { return .secondary.opacity(0.4) }
        switch vm.state {
        case .connecting: return .yellow
        case .connected: return .green
        case .failed: return .red
        }
    }
    private var statusText: String { vm?.dashboardStatus ?? "Not connected" }
    private var isActive: Bool { vm != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "display").font(.title2).foregroundStyle(.tint)
                Spacer()
                Circle().fill(statusColor).frame(width: 9, height: 9)
            }
            Text(profile.name).font(.headline).lineLimit(1)
            Text(profile.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text(statusText).font(.caption).foregroundStyle(isActive ? .primary : .tertiary).lineLimit(1)

            Divider().padding(.vertical, 2)
            HStack(spacing: 16) {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .help("Edit")
                Button(action: onOpen) { Image(systemName: isActive ? "macwindow.on.rectangle" : "bolt.fill") }
                    .help(isActive ? "Bring to front" : "Connect")
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .help("Disconnect")
                    .foregroundStyle(.red)
                    .disabled(!isActive)
            }
            .buttonStyle(.borderless)
            .imageScale(.large)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
    }
}

struct PasswordPrompt: View {
    let profileName: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    private func submit() { guard !password.isEmpty else { return }; onSubmit(password); dismiss() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Password for \(profileName)").font(.headline)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder).frame(width: 280)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled(password.isEmpty)
            }
        }
        .padding(20)
    }
}
