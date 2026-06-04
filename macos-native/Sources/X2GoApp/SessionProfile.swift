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
    /// Strict host-key checking. Off (default) is lenient — handy for re-imaged
    /// LAN/dev boxes whose host key changes.
    var strictHostKey: Bool = false

    var displayMode: DisplayMode {
        switch displayKind {
        case .fullscreen: return .fullscreen
        case .maxAvailable: return .maxAvailable
        case .custom: return .custom(width: width, height: height)
        }
    }

    var resolvedPack: String { "\(pack)-\(quality)" }

    var subtitle: String { "\(user)@\(host)" + (sshPort != 22 ? ":\(sshPort)" : "") }

    init() {}

    /// Tolerant decoder: any key missing from older saved JSON falls back to its
    /// default, so adding profile fields never wipes the user's saved sessions.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func g<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decode(T.self, forKey: k)) ?? d }
        id = g(.id, UUID())
        name = g(.name, "New Session")
        host = g(.host, "")
        sshPort = g(.sshPort, 22)
        user = g(.user, "")
        keyPath = (try? c.decode(String?.self, forKey: .keyPath)) ?? nil
        command = g(.command, "startxfce4")
        rootless = g(.rootless, false)
        displayKind = g(.displayKind, .custom)
        width = g(.width, 1280)
        height = g(.height, 800)
        pack = g(.pack, "16m-jpeg")
        quality = g(.quality, 9)
        speed = g(.speed, .lan)
        clipboard = g(.clipboard, .both)
        keyboardLayout = g(.keyboardLayout, "us")
        strictHostKey = g(.strictHostKey, false)
    }

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
            preferResume: true,
            strictHostKey: strictHostKey)
    }
}
