import Foundation

/// Abstraction over an SSH backend so the engine can use either the pure-Swift
/// transport (swift-nio-ssh) or the system `ssh` CLI (agent, ssh_config, all key
/// types incl. certificates).
public protocol SSHTransport: Sendable {
    func connect() async throws
    func exec(_ command: String) async throws -> ExecResult
    func openLocalForward(localPort: Int, remoteHost: String, remotePort: Int) async throws -> any SSHForwarding
    func disconnect() async
}

/// A live local→remote port forward.
public protocol SSHForwarding: Sendable {
    var localPort: Int { get }
    /// Total bytes forwarded, or nil if the backend can't report it (CLI ssh).
    var bytesTransferred: Int? { get }
    func close() async
}
