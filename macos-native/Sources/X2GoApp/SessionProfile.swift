import Foundation
import X2GoProtocol
import X2GoSSH
import X2GoEngine

/// A saved connection profile (the modern Codable store; one-time-imported from
/// the old ~/.x2goclient/sessions INI).
struct SessionProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = "New Session"
    var host: String = ""
    var sshPort: Int = 22
    var user: String = ""
    var keyPath: String? = nil
    var command: String = "startxfce4"
    var rootless: Bool = false

    enum DisplayKind: String, Codable, CaseIterable, Identifiable {
        case fullscreen, maxAvailable, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fullscreen: return "Fullscreen"
            case .maxAvailable: return "Maximize to screen"
            case .custom: return "Custom size"
            }
        }
    }
    var displayKind: DisplayKind = .custom
    var width: Int = 1280
    var height: Int = 800

    var pack: String = "16m-jpeg"
    var quality: Int = 9
    var speed: LinkSpeed = .lan
    var clipboard: ClipboardMode = .both
    var keyboardLayout: String = "us"

    var displayMode: DisplayMode {
        switch displayKind {
        case .fullscreen: return .fullscreen
        case .maxAvailable: return .maxAvailable
        case .custom: return .custom(width: width, height: height)
        }
    }

    var resolvedPack: String { "\(pack)-\(quality)" }

    var subtitle: String { "\(user)@\(host)" + (sshPort != 22 ? ":\(sshPort)" : "") }

    func makeConfig(screen: Geometry, tools: ToolPaths, credentials: [SSHCredential]) -> X2GoSession.Config {
        X2GoSession.Config(
            endpoint: SSHEndpoint(host: host, port: sshPort, username: user),
            credentials: credentials,
            command: command,
            kind: rootless ? .rootless : .desktop,
            displayMode: displayMode,
            screen: screen,
            link: speed,
            pack: resolvedPack,
            clipboard: clipboard,
            keyboardLayout: keyboardLayout,
            disableServerCompositing: true,
            tools: tools,
            preferResume: true)
    }
}
