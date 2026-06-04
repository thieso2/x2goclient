import SwiftUI
import AppKit
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

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose an SSH private key"
        let sshDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if FileManager.default.fileExists(atPath: sshDir.path) { panel.directoryURL = sshDir }
        if panel.runModal() == .OK, let url = panel.url { profile.keyPath = url.path }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    TextField("Name", text: $profile.name)
                    TextField("Host", text: $profile.host)
                    TextField("SSH port", value: $profile.sshPort, format: .number)
                    TextField("User", text: $profile.user)
                    HStack {
                        TextField("Private key (optional)", text: keyBinding)
                            .help("Leave empty to use ssh-agent/ssh_config (system ssh) or be prompted for a password.")
                        Button("Choose…") { chooseKeyFile() }
                    }
                    Toggle("Use system ssh (agent, ssh_config, RSA/ECDSA, certificates)",
                           isOn: $profile.useSystemSSH)
                    Toggle("Strict host-key checking", isOn: $profile.strictHostKey)
                        .help("Off (default) tolerates re-imaged hosts whose key changed.")
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
                Section("NX connection") {
                    Picker("Link speed", selection: $profile.speed) {
                        ForEach(LinkSpeed.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    Picker("Image quality", selection: $profile.quality) {
                        ForEach(0...9, id: \.self) { q in
                            Text(q == 0 ? "0 (lowest)" : q == 9 ? "9 (best)" : "\(q)").tag(q)
                        }
                    }
                    Picker("Compression", selection: $profile.pack) {
                        ForEach(["16m-jpeg", "16m-png", "16m-rgb", "256-png", "2-adaptive"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }
                Section("Advanced") {
                    Picker("Clipboard", selection: $profile.clipboard) {
                        ForEach(ClipboardMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
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
