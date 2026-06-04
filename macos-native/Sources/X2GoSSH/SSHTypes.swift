import Foundation

// Shared value types for the SSH layer. The transport is the system `ssh` CLI
// (see CLISSHTransport) — no pure-Swift SSH stack, so no swift-nio dependency.

public struct SSHEndpoint: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public init(host: String, port: Int = 22, username: String) {
        self.host = host; self.port = port; self.username = username
    }
}

public enum SSHCredential: Sendable {
    case privateKeyFile(URL)
    case password(String)
}

public struct ExecResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitStatus: Int32
    public init(stdout: Data, stderr: Data, exitStatus: Int32) {
        self.stdout = stdout; self.stderr = stderr; self.exitStatus = exitStatus
    }
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum SSHError: Error, CustomStringConvertible, LocalizedError {
    case notConnected
    case channelError(String)
    public var description: String {
        switch self {
        case .notConnected: return "SSH connection not established"
        case .channelError(let m): return "SSH error: \(m)"
        }
    }
    public var errorDescription: String? { description }
}
