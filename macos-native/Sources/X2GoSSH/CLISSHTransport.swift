import Foundation
import Darwin

/// SSH backend that drives the system `/usr/bin/ssh` via a ControlMaster socket.
/// This gives, for free, everything OpenSSH supports: ssh-agent, ~/.ssh/config,
/// all key types (RSA/ECDSA/ed25519, certificates), ProxyJump, known_hosts, etc.
/// A profile key (-i) is used if given; otherwise the agent / ssh_config decide.
/// A password (if provided) is fed via SSH_ASKPASS.
public final class CLISSHTransport: SSHTransport, @unchecked Sendable {
    private let endpoint: SSHEndpoint
    private let credentials: [SSHCredential]
    private let controlPath: String
    private let askpassPath: String?
    private let password: String?
    private let strictHostKey: Bool

    public init(endpoint: SSHEndpoint, credentials: [SSHCredential], tag: String,
                strictHostKey: Bool = false) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.strictHostKey = strictHostKey
        self.controlPath = "/tmp/x2go-\(tag).sock"
        self.password = credentials.compactMap {
            if case .password(let p) = $0 { return p } else { return nil }
        }.first
        // An askpass helper lets ssh read the password without a tty.
        if password != nil {
            let p = "/tmp/x2go-askpass-\(tag).sh"
            let script = "#!/bin/sh\nprintf '%s\\n' \"$X2GO_PW\"\n"
            try? script.write(toFile: p, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: p)
            self.askpassPath = p
        } else {
            self.askpassPath = nil
        }
    }

    private var userHost: String { "\(endpoint.username)@\(endpoint.host)" }

    /// Args shared by every ssh invocation (control socket, port, host key policy).
    private var commonArgs: [String] {
        var a = ["-o", "ControlPath=\(controlPath)",
                 "-p", "\(endpoint.port)",
                 "-o", "ConnectTimeout=20"]
        if strictHostKey {
            // Use the user's known_hosts; new hosts auto-add, changed hosts fail.
            a += ["-o", "StrictHostKeyChecking=accept-new"]
        } else {
            // Lenient (LAN/dev boxes get re-imaged): never fail on host keys.
            a += ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                  "-o", "LogLevel=ERROR"]
        }
        for c in credentials {
            if case .privateKeyFile(let url) = c {
                a += ["-i", url.path, "-o", "IdentitiesOnly=yes"]
            }
        }
        return a
    }

    public func connect() async throws {
        // Bring up the master; -f backgrounds it after auth, so this returns when
        // authentication has completed (exit 0) or failed (non-zero + stderr).
        var args = ["-M", "-N", "-f",
                    "-o", "ControlMaster=yes",
                    "-o", "ControlPersist=300"]
        if password != nil {
            args += ["-o", "NumberOfPasswordPrompts=1", "-o", "PreferredAuthentications=password,keyboard-interactive"]
        }
        args += commonArgs + [userHost]
        let r = await run(args)
        if r.status != 0 {
            throw SSHError.channelError(sshMessage(r.err, fallback: "ssh connection failed"))
        }
    }

    public func exec(_ command: String) async throws -> ExecResult {
        let args = ["-o", "ControlMaster=no"] + commonArgs + [userHost, command]
        let r = await run(args)
        return ExecResult(stdout: r.out, stderr: r.err, exitStatus: r.status)
    }

    public func openLocalForward(localPort: Int, remoteHost: String, remotePort: Int) async throws -> any SSHForwarding {
        let port = localPort > 0 ? localPort : Self.freeLocalPort()
        let spec = "127.0.0.1:\(port):\(remoteHost):\(remotePort)"
        let args = ["-O", "forward", "-L", spec] + commonArgs + [userHost]
        let r = await run(args)
        if r.status != 0 {
            throw SSHError.channelError(sshMessage(r.err, fallback: "port-forward failed"))
        }
        let uh = userHost, common = commonArgs
        return CLIForward(localPort: port) { [weak self] in
            _ = await self?.run(["-O", "cancel", "-L", spec] + common + [uh])
        }
    }

    public func disconnect() async {
        _ = await run(["-O", "exit"] + commonArgs + [userHost])
        if let askpassPath { try? FileManager.default.removeItem(atPath: askpassPath) }
    }

    /// Run /usr/bin/ssh with our args, returning (status, stdout, stderr).
    private func run(_ args: [String]) async -> (status: Int32, out: Data, err: Data) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            if let askpassPath, let password {
                env["SSH_ASKPASS"] = askpassPath
                env["SSH_ASKPASS_REQUIRE"] = "force"
                env["X2GO_PW"] = password
                env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            }
            p.environment = env
            let outPipe = Pipe(), errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let o = outPipe.fileHandleForReading.readDataToEndOfFile()
                let e = errPipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: (proc.terminationStatus, o, e))
            }
            do { try p.run() }
            catch { cont.resume(returning: (-1, Data(), Data("\(error)".utf8))) }
        }
    }

    private func sshMessage(_ stderr: Data, fallback: String) -> String {
        let s = String(decoding: stderr, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
            .joined(separator: "\n")
        return s.isEmpty ? fallback : s
    }

    private static func freeLocalPort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return Int.random(in: 30000...40000) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

/// A forward set up via the ssh ControlMaster (`-O forward`); close() cancels it
/// (`-O cancel`). Byte stats aren't available from the CLI master.
final class CLIForward: SSHForwarding, @unchecked Sendable {
    let localPort: Int
    let bytesTransferred: Int? = nil
    private let onClose: @Sendable () async -> Void

    init(localPort: Int, onClose: @escaping @Sendable () async -> Void) {
        self.localPort = localPort
        self.onClose = onClose
    }
    func close() async { await onClose() }
}
