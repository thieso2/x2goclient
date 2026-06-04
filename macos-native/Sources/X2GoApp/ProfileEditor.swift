import SwiftUI
import X2GoProtocol

/// Create/edit a SessionProfile.
struct ProfileEditor: View {
    @State var profile: SessionProfile
    let isNew: Bool
    let onSave: (SessionProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    private var keyBinding: Binding<String> {
        Binding(get: { profile.keyPath ?? "" },
                set: { profile.keyPath = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    TextField("Name", text: $profile.name)
                    TextField("Host", text: $profile.host)
                    TextField("SSH port", value: $profile.sshPort, format: .number)
                    TextField("User", text: $profile.user)
                    TextField("Private key path (optional)", text: keyBinding)
                        .help("Leave empty to be prompted for a password on connect.")
                }
                Section("Session") {
                    TextField("Command", text: $profile.command)
                    Toggle("Single application (rootless)", isOn: $profile.rootless)
                    Picker("Display", selection: $profile.displayKind) {
                        ForEach(SessionProfile.DisplayKind.allCases) { Text($0.label).tag($0) }
                    }
                    if profile.displayKind == .custom {
                        TextField("Width", value: $profile.width, format: .number)
                        TextField("Height", value: $profile.height, format: .number)
                    }
                }
                Section("Advanced") {
                    Picker("Clipboard", selection: $profile.clipboard) {
                        ForEach(ClipboardMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Link speed", selection: $profile.speed) {
                        ForEach(LinkSpeed.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    TextField("Keyboard layout", text: $profile.keyboardLayout)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { onSave(profile); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(profile.name.isEmpty || profile.host.isEmpty || profile.user.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 470, height: 540)
    }
}
