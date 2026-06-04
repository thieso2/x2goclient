import Foundation
import X2GoSSH
import X2GoProtocol

/// One connection's full lifecycle: SSH connect/auth, start-or-resume the remote
/// agent, fork a local Xvfb sized to the session, tunnel NX over SSH, launch
/// nxproxy into the Xvfb, run the desktop, and tear everything down on
/// suspend/terminate. Owns its SSH connection, tunnel, and helper processes.
public actor X2GoSession {
    public enum Phase: Sendable, Equatable {
        case idle, connecting, listing, starting, resuming, startingDisplay,
             tunneling, launchingProxy, runningCommand, connected,
             suspending, terminating, closed
        case failed(String)
    }

    public struct Config: Sendable {
        public var endpoint: SSHEndpoint
        public var credentials: [SSHCredential]
        public var command: String
        public var kind: SessionKind
        public var displayMode: DisplayMode
        public var screen: Geometry
        public var link: LinkSpeed
        public var pack: String
        public var clipboard: ClipboardMode
        public var keyboardLayout: String
        public var disableServerCompositing: Bool
        public var tools: ToolPaths
        /// Prefer resuming an existing suspended session over starting a new one.
        public var preferResume: Bool
        /// Strict host-key checking (system ssh). Off = lenient for re-imaged boxes.
        public var strictHostKey: Bool
        /// Server graphics backend. Only nxagent renders with this client today.
        public var backend: AgentBackend

        public init(endpoint: SSHEndpoint, credentials: [SSHCredential], command: String,
                    kind: SessionKind = .desktop, displayMode: DisplayMode,
                    screen: Geometry, link: LinkSpeed = .lan, pack: String = "16m-jpeg-9",
                    clipboard: ClipboardMode = .both, keyboardLayout: String = "us",
                    disableServerCompositing: Bool = true, tools: ToolPaths,
                    preferResume: Bool = true, strictHostKey: Bool = false,
                    backend: AgentBackend = .nxagent) {
            self.endpoint = endpoint; self.credentials = credentials; self.command = command
            self.kind = kind; self.displayMode = displayMode; self.screen = screen
            self.link = link; self.pack = pack; self.clipboard = clipboard
            self.keyboardLayout = keyboardLayout
            self.disableServerCompositing = disableServerCompositing; self.tools = tools
            self.preferResume = preferResume
            self.strictHostKey = strictHostKey
            self.backend = backend
        }
    }

    /// What to do with the sessions x2golistsessions reports.
    public enum SessionChoice: Sendable {
        case new
        case resume(SessionInfo)
        case cancel
    }
    public typealias SessionChooser = @Sendable ([SessionInfo]) async -> SessionChoice

    public private(set) var phase: Phase = .idle
    public private(set) var localDisplay: String?      // ":N" of our Xvfb
    public private(set) var sessionId: String?
    public private(set) var serverDisplay: String?     // remote NX display number
    public private(set) var geometry: Geometry?
    public private(set) var wantFullscreen = false

    private let config: Config
    private let ssh: any SSHTransport
    private var xvfb: Process?
    private var nxproxy: Process?
    private var forwarder: (any SSHForwarding)?
    private var displayNum = -1
    private var agentPid = ""

    public init(config: Config) {
        self.config = config
        self.ssh = CLISSHTransport(endpoint: config.endpoint, credentials: config.credentials,
                                   tag: String(UUID().uuidString.prefix(8)),
                                   strictHostKey: config.strictHostKey)
    }

    /// Total bytes carried over the NX tunnel, or nil if the backend (CLI ssh)
    /// can't report it.
    public func transferredBytes() -> Int? { forwarder?.bytesTransferred ?? nil }

    // MARK: - Bring-up

    /// `chooser` is consulted when x2golistsessions reports existing sessions, so
    /// the UI can offer reconnect-vs-new. If nil, falls back to preferResume.
    public func start(chooser: SessionChooser? = nil) async throws {
        do {
            try await bringUp(chooser: chooser)
        } catch {
            phase = .failed("\(error)")
            await teardownLocal()
            throw error
        }
    }

    private func bringUp(chooser: SessionChooser?) async throws {
        // x2gokdrive uses a different display protocol than NX, which this client
        // renders via nxproxy — so it can't display a kdrive session yet.
        if config.backend == .kdrive {
            throw EngineError.unsupported("The x2gokdrive backend isn't supported by this client yet. Choose “X2Go Agent (NX)”.")
        }
        phase = .connecting
        try await ssh.connect()

        phase = .listing
        let list = X2GoParser.sessionList(try await ssh.exec(X2GoCommand.listSessions).stdoutString)

        let resolved = resolveGeometry(config.displayMode, screen: config.screen)
        self.geometry = resolved.geometry
        self.wantFullscreen = resolved.wantFullscreen
        let geo = resolved.geometry.token

        // Decide: offer the user existing sessions to reconnect, or start new.
        let statuses = list.map { "\($0.sessionId.prefix(20))=\($0.status)" }.joined(separator: ", ")
        FileHandle.standardError.write(Data("X2Go: list=\(list.count) [\(statuses)] chooser=\(chooser != nil)\n".utf8))
        let choice: SessionChoice
        if let chooser, !list.isEmpty {
            FileHandle.standardError.write(Data("X2Go: invoking chooser\n".utf8))
            choice = await chooser(list)
        } else if config.preferResume,
                  let s = list.first(where: { $0.isSuspended }) ?? list.first(where: { $0.isRunning }) {
            // Resume a suspended session, or take over a running one (keep-running reconnect).
            FileHandle.standardError.write(Data("X2Go: auto-resume \(s.sessionId) [\(s.status)]\n".utf8))
            choice = .resume(s)
        } else {
            FileHandle.standardError.write(Data("X2Go: starting NEW\n".utf8))
            choice = .new
        }

        var cookie = "", serverDisp = "", sid = "", pid = "", grPort = 0
        var isResume = false
        switch choice {
        case .cancel:
            throw EngineError.cancelled
        case .resume(let s):
            isResume = true
            phase = .resuming
            let out = try await ssh.exec(X2GoCommand.resumeSession(
                id: s.sessionId, geometry: geo, link: config.link, pack: config.pack,
                layout: config.keyboardLayout, kbdType: "query", useKeyboard: false,
                clipboard: config.clipboard)).stdoutString
            let ports = X2GoParser.resumeReply(out)
            cookie = s.cookie; serverDisp = s.display; sid = s.sessionId; pid = s.agentPid
            grPort = Int(ports.grPort ?? "") ?? (s.grPortNumber ?? 0)
        case .new:
            phase = .starting
            let p = X2GoCommand.StartAgentParams(
                geometry: geo, link: config.link, pack: config.pack, depth: 24,
                layout: config.keyboardLayout, kbdType: "query", useKeyboard: false,
                kind: config.kind, command: config.command, clipboard: config.clipboard)
            let out = try await ssh.exec(X2GoCommand.startAgent(p)).stdoutString
            guard let reply = X2GoParser.newSessionReply(out) else {
                throw EngineError.badReply("x2gostartagent: \(out)")
            }
            cookie = reply.cookie; serverDisp = reply.display; sid = reply.sessionId
            pid = reply.agentPid; grPort = reply.grPortNumber ?? 0
        }
        guard grPort > 0, !cookie.isEmpty, !serverDisp.isEmpty else {
            throw EngineError.badReply("missing grPort/cookie/display")
        }
        self.sessionId = sid; self.serverDisplay = serverDisp; self.agentPid = pid

        // Disable remote compositing before the desktop draws (capture path needs
        // it). New sessions only — on resume the desktop is already configured and
        // running; touching it would be pointless.
        if config.disableServerCompositing, !isResume {
            _ = try? await ssh.exec(Self.disableCompositingSnippet)
        }

        // Local Xvfb at exactly the session geometry.
        phase = .startingDisplay
        displayNum = Self.pickFreeDisplay()
        let disp = ":\(displayNum)"
        try startXvfb(display: disp, geometry: geo)
        try await waitForXSocket(displayNum)
        runSetxkbmap(display: disp)

        // NX tunnel: ephemeral local port -> server localhost:grPort.
        phase = .tunneling
        let fwd = try await ssh.openLocalForward(localPort: 0, remoteHost: "localhost", remotePort: grPort)
        self.forwarder = fwd

        // nxproxy options + launch into our Xvfb.
        phase = .launchingProxy
        let nxRoot = NSHomeDirectory() + "/.x2go"
        let sessionDir = nxRoot + "/S-" + sid
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let options = NXProxy.optionsFile(nxRoot: nxRoot, sessionDir: sessionDir,
                                          cookie: cookie, localPort: fwd.localPort, display: serverDisp)
        try options.write(toFile: sessionDir + "/options", atomically: true, encoding: .utf8)
        try startNxproxy(display: disp, sessionDir: sessionDir, serverDisplay: serverDisp)

        // Launch the desktop — NEW sessions only. On resume the desktop is already
        // running; re-running x2goruncommand would start a second session manager
        // that disrupts the resumed desktop (it shows briefly then goes black).
        if !isResume {
            phase = .runningCommand
            _ = try await ssh.exec(X2GoCommand.runCommand(
                display: serverDisp, agentPid: pid, sessionId: sid, sndPort: "-1",
                command: config.command, kind: config.kind))
        }

        self.localDisplay = disp
        phase = .connected
    }

    // MARK: - Teardown

    public func suspend() async {
        if let sid = sessionId {
            phase = .suspending
            _ = try? await ssh.exec(X2GoCommand.suspend(id: sid))
        }
        await teardownLocal()
        await ssh.disconnect()
        phase = .closed
    }

    public func terminate() async {
        if let sid = sessionId {
            phase = .terminating
            _ = try? await ssh.exec(X2GoCommand.terminate(id: sid))
        }
        await teardownLocal()
        await ssh.disconnect()
        phase = .closed
    }

    private func teardownLocal() async {
        if let p = nxproxy, p.isRunning { p.terminate() }
        nxproxy = nil
        if let f = forwarder { await f.close() }
        forwarder = nil
        if let x = xvfb, x.isRunning { x.terminate() }
        xvfb = nil
        if displayNum >= 0 {
            try? FileManager.default.removeItem(atPath: "/tmp/.X\(displayNum)-lock")
            try? FileManager.default.removeItem(atPath: "/tmp/.X11-unix/X\(displayNum)")
        }
    }

    // MARK: - Process helpers

    private func startXvfb(display: String, geometry: String) throws {
        var args = [display, "-screen", "0", geometry + "x24", "-ac", "-noreset"]
        if let fonts = config.tools.fontsPath { args += ["-fp", fonts] }
        if let xkb = config.tools.xkbPath { args += ["-xkbdir", xkb] }
        var env: [String: String] = [:]
        if let xkb = config.tools.xkbPath { env["XKB_BINDIR"] = (config.tools.xvfb as NSString).deletingLastPathComponent; _ = xkb }
        xvfb = try launch(config.tools.xvfb, args, extraEnv: env)
    }

    private func runSetxkbmap(display: String) {
        guard FileManager.default.isExecutableFile(atPath: config.tools.setxkbmap) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.tools.setxkbmap)
        p.arguments = [config.keyboardLayout]
        var env = ProcessInfo.processInfo.environment
        env["DISPLAY"] = display
        p.environment = env
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    private func startNxproxy(display: String, sessionDir: String, serverDisplay: String) throws {
        let args = NXProxy.args(sessionDir: sessionDir, display: serverDisplay)
        var env: [String: String] = [
            "DISPLAY": display,
            "NX_SYSTEM": config.tools.nxSystemDir,
            "NX_CLIENT": config.tools.nxproxy,
        ]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        env["PATH"] = path + ":/opt/X11/bin:/usr/X11/bin:/usr/bin:/bin"
        nxproxy = try launch(config.tools.nxproxy, args, extraEnv: env)
    }

    private func launch(_ path: String, _ args: [String], extraEnv: [String: String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    private func waitForXSocket(_ n: Int) async throws {
        let sock = "/tmp/.X11-unix/X\(n)"
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: sock) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw EngineError.xvfbFailed(":\(n)")
    }

    private static func pickFreeDisplay() -> Int {
        for n in 100..<140 {
            let lock = "/tmp/.X\(n)-lock", sock = "/tmp/.X11-unix/X\(n)"
            if !FileManager.default.fileExists(atPath: lock),
               !FileManager.default.fileExists(atPath: sock) { return n }
        }
        return 199
    }

    /// Edit xfwm4's xfconf XML so use_compositing=false before the desktop draws.
    /// Ported from onmainwindow.cpp (double-quotes only — runs under bash -l -c '…').
    static let disableCompositingSnippet =
        "F=$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml; " +
        "mkdir -p \"$(dirname \"$F\")\"; " +
        "if [ ! -f \"$F\" ]; then printf \"<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?>\\n" +
        "<channel name=\\\"xfwm4\\\" version=\\\"1.0\\\">\\n  <property name=\\\"general\\\" type=\\\"empty\\\">\\n" +
        "    <property name=\\\"use_compositing\\\" type=\\\"bool\\\" value=\\\"false\\\"/>\\n  </property>\\n" +
        "</channel>\\n\" > \"$F\"; " +
        "elif grep -q use_compositing \"$F\"; then " +
        "sed -i \"s/\\(use_compositing\\\"[^>]*value=\\\"\\)true/\\1false/\" \"$F\"; " +
        "else sed -i \"/name=\\\"general\\\"/a <property name=\\\"use_compositing\\\" type=\\\"bool\\\" value=\\\"false\\\"/>\" \"$F\"; fi"
}

public enum EngineError: Error, CustomStringConvertible, LocalizedError {
    case badReply(String)
    case xvfbFailed(String)
    case cancelled
    case unsupported(String)
    public var description: String {
        switch self {
        case .badReply(let s): return "unexpected server reply: \(s)"
        case .xvfbFailed(let d): return "Xvfb \(d) did not come up"
        case .cancelled: return "cancelled"
        case .unsupported(let m): return m
        }
    }
    public var errorDescription: String? { description }
}
