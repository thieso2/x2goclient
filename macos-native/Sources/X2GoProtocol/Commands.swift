import Foundation

// Builders for the remote x2go commands, matching the exact strings the Qt
// client sends (src/onmainwindow.cpp). All pure string construction.

public enum X2GoCommand {

    /// `export HOSTNAME && x2golistsessions`
    public static let listSessions = "export HOSTNAME && x2golistsessions"

    public struct StartAgentParams: Sendable {
        public var geometry: String          // "WxH" or "fullscreen"
        public var link: LinkSpeed
        public var pack: String              // resolved, e.g. "16m-jpeg-9"
        public var depth: Int                // client color depth, e.g. 24
        public var layout: String            // e.g. "us"
        public var kbdType: String           // macOS uses "query"
        public var useKeyboard: Bool         // the 0|1 flag (macOS: false)
        public var kind: SessionKind
        public var command: String           // e.g. "startxfce4"
        public var clipboard: ClipboardMode
        public var dpi: Int?                 // optional X2GODPI override

        public init(geometry: String, link: LinkSpeed = .lan, pack: String = "16m-jpeg-9",
                    depth: Int = 24, layout: String = "us", kbdType: String = "query",
                    useKeyboard: Bool = false, kind: SessionKind = .desktop,
                    command: String, clipboard: ClipboardMode = .both, dpi: Int? = nil) {
            self.geometry = geometry; self.link = link; self.pack = pack; self.depth = depth
            self.layout = layout; self.kbdType = kbdType; self.useKeyboard = useKeyboard
            self.kind = kind; self.command = command; self.clipboard = clipboard; self.dpi = dpi
        }
    }

    /// `[X2GODPI=n ]x2gostartagent <geom> <link> <pack> unix-kde-depth_<depth>
    ///   <layout> <kbdType> <0|1> <Kind> <command> <clipboard>`
    public static func startAgent(_ p: StartAgentParams) -> String {
        var cmd = ""
        if let dpi = p.dpi { cmd += "X2GODPI=\(dpi) " }
        cmd += "x2gostartagent \(p.geometry) \(p.link.rawValue) \(p.pack)"
        cmd += " unix-kde-depth_\(p.depth) \(p.layout) \(p.kbdType) "
        cmd += p.useKeyboard ? "1 " : "0 "
        cmd += "\(p.kind.rawValue) \(p.command) \(p.clipboard.rawValue)"
        return cmd
    }

    /// `x2goresume-session <id> <geom> <link> <pack> <layout> <kbdType> <0|1> <clipboard>`
    public static func resumeSession(id: String, geometry: String, link: LinkSpeed,
                                     pack: String, layout: String, kbdType: String,
                                     useKeyboard: Bool, clipboard: ClipboardMode) -> String {
        "x2goresume-session \(id) \(geometry) \(link.rawValue) \(pack) \(layout) "
            + "\(kbdType) \(useKeyboard ? "1" : "0") \(clipboard.rawValue)"
    }

    /// `setsid x2goruncommand <display> <agentPid> <id> <sndPort> <command> nosnd <Kind>
    ///   1> /dev/null 2>/dev/null & exit` (v1: no sound -> "nosnd").
    public static func runCommand(display: String, agentPid: String, sessionId: String,
                                  sndPort: String, command: String, kind: SessionKind) -> String {
        "setsid x2goruncommand \(display) \(agentPid) \(sessionId) \(sndPort) "
            + "\(command) nosnd \(kind.rawValue) 1> /dev/null 2>/dev/null & exit"
    }

    public static func suspend(id: String) -> String { "x2gosuspend-session \(id)" }
    public static func terminate(id: String) -> String { "x2goterminate-session \(id)" }
}

/// nxproxy options-file content + command, matching onmainwindow.cpp:5477-5588.
public enum NXProxy {
    /// `nx/nx,root=<nxRoot>,connect=localhost,cookie=<cookie>,port=<localPort>,
    ///  errors=<sessionDir>/sessions:<display>`
    public static func optionsFile(nxRoot: String, sessionDir: String, cookie: String,
                                   localPort: Int, display: String) -> String {
        "nx/nx,root=\(nxRoot),connect=localhost,cookie=\(cookie),port=\(localPort),"
            + "errors=\(sessionDir)/sessions:\(display)"
    }

    /// Args for `nxproxy`: `-S nx/nx,options=<sessionDir>/options:<display>`
    public static func args(sessionDir: String, display: String) -> [String] {
        ["-S", "nx/nx,options=\(sessionDir)/options:\(display)"]
    }
}
