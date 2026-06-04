import SwiftUI
import X2GoProtocol
import X2GoSSH

/// Modern session manager: a grid of profile cards with create/edit/delete/
/// connect + legacy import. Connecting opens a per-connection window.
struct SessionManagerView: View {
    @Bindable var store: ProfileStore
    let coordinator: SessionCoordinator

    @Environment(\.openWindow) private var openWindow
    @State private var selection: UUID?
    @State private var editing: SessionProfile?
    @State private var isNew = false
    @State private var passwordFor: SessionProfile?
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

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 16)]

    var body: some View {
        Group {
            if store.profiles.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filtered) { profile in
                            ProfileCard(profile: profile, selected: selection == profile.id)
                                .onTapGesture { selection = profile.id }
                                .onTapGesture(count: 2) { connect(profile) }
                                .contextMenu {
                                    Button("Connect") { connect(profile) }
                                    Button("Edit…") { edit(profile) }
                                    Divider()
                                    Button("Delete", role: .destructive) { store.delete(profile) }
                                }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .searchable(text: $search, placement: .toolbar, prompt: "Search sessions")
        .toolbar {
            ToolbarItemGroup {
                Button { newProfile() } label: { Label("New", systemImage: "plus") }
                Button { if let p = selected { edit(p) } } label: { Label("Edit", systemImage: "pencil") }
                    .disabled(selected == nil)
                Button { if let p = selected { store.delete(p); selection = nil } } label: {
                    Label("Delete", systemImage: "trash")
                }.disabled(selected == nil)
                Spacer()
                Button { if let p = selected { connect(p) } } label: { Label("Connect", systemImage: "bolt.fill") }
                    .disabled(selected == nil)
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Import from old X2Go client…") { runImport() }
                } label: { Label("More", systemImage: "ellipsis.circle") }
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
                let id = coordinator.connect(profile: profile, credentials: [.password(password)])
                openWindow(id: "connection", value: id)
            }
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
            Text("Create a session or import from the old X2Go client.")
                .foregroundStyle(.secondary)
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

    private func connect(_ p: SessionProfile) {
        if let key = p.keyPath, !key.isEmpty {
            let path = (key as NSString).expandingTildeInPath
            let id = coordinator.connect(profile: p, credentials: [.privateKeyFile(URL(fileURLWithPath: path))])
            openWindow(id: "connection", value: id)
        } else {
            passwordFor = p
        }
    }
}

struct ProfileCard: View {
    let profile: SessionProfile
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "display").font(.title2).foregroundStyle(.tint)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            Text(profile.name).font(.headline).lineLimit(1)
            Text(profile.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text(profile.command).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
    }
}

struct PasswordPrompt: View {
    let profileName: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Password for \(profileName)").font(.headline)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Connect") { onSubmit(password); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(password.isEmpty)
            }
        }
        .padding(20)
    }
}
