import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// Pure-Swift SSH client over Apple's swift-nio-ssh. Provides the three things the
// X2Go engine needs: connect+auth, run a remote command (exec), and a local TCP
// port-forward (direct-tcpip) to tunnel nxproxy <-> the remote nxagent.

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
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum SSHError: Error, CustomStringConvertible, LocalizedError {
    case notConnected
    case channelError(String)
    public var description: String {
        switch self {
        case .notConnected: return "SSH connection not established"
        case .channelError(let m): return "SSH channel error: \(m)"
        }
    }
    public var errorDescription: String? { description }
}

public actor SSHConnection {
    private let endpoint: SSHEndpoint
    private let credentials: [SSHCredential]
    private let group: EventLoopGroup
    private var channel: Channel?

    public init(endpoint: SSHEndpoint, credentials: [SSHCredential]) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    public func connect() async throws {
        var offers: [NIOSSHUserAuthenticationOffer.Offer] = []
        for c in credentials {
            switch c {
            case .privateKeyFile(let url):
                let key = try OpenSSHPrivateKey.load(contentsOf: url)
                offers.append(.privateKey(.init(privateKey: key)))
            case .password(let p):
                offers.append(.password(.init(password: p)))
            }
        }
        let auth = X2GoAuthDelegate(username: endpoint.username, offers: offers)
        let hostKey = X2GoAcceptingHostKeyDelegate()

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { ch in
                ch.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: auth, serverAuthDelegate: hostKey)),
                        allocator: ch.allocator,
                        inboundChildChannelInitializer: nil)
                ])
            }
        self.channel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
    }

    private func sshHandler() async throws -> (Channel, NIOSSHHandler) {
        guard let channel else { throw SSHError.notConnected }
        let handler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        return (channel, handler)
    }

    /// Run a remote command and collect its stdout/stderr/exit status (async).
    /// Auth/channel-creation failures surface here too.
    public func exec(_ command: String) async throws -> ExecResult {
        let (channel, handler) = try await sshHandler()
        return try await withCheckedThrowingContinuation { cont in
            // The only EventLoopPromise we keep: swift-nio-ssh's createChannel
            // requires one to report channel-creation failure. The command's
            // result is delivered via ExecHandler's async callback.
            let creation = channel.eventLoop.makePromise(of: Channel.self)
            creation.futureResult.whenFailure { cont.resume(throwing: $0) }
            let handlerObj = ExecHandler(command: command) { cont.resume(with: $0) }
            channel.eventLoop.execute {
                handler.createChannel(creation, channelType: .session) { child, _ in
                    child.pipeline.addHandler(handlerObj)
                }
            }
        }
    }

    /// Open a local listener on 127.0.0.1:`localPort`; each inbound connection is
    /// bridged over a direct-tcpip SSH channel to `remoteHost:remotePort`.
    public func openLocalForward(localPort: Int, remoteHost: String, remotePort: Int) async throws -> PortForwarder {
        let (channel, handler) = try await sshHandler()
        return try await PortForwarder.start(
            group: group, sshChannel: channel, sshHandler: handler,
            localPort: localPort, remoteHost: remoteHost, remotePort: remotePort)
    }

    public func disconnect() async {
        if let channel { try? await channel.close().get() }
        channel = nil
        try? await group.shutdownGracefully()
    }
}

// MARK: - Auth / host-key delegates (run on the NIO event loop)

/// Offers credentials in order, filtered by what the server accepts. Succeeds
/// with nil (auth fails) once the list is exhausted.
final class X2GoAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var queue: [NIOSSHUserAuthenticationOffer.Offer]
    init(username: String, offers: [NIOSSHUserAuthenticationOffer.Offer]) {
        self.username = username
        self.queue = offers
    }
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while !queue.isEmpty {
            let offer = queue.removeFirst()
            let usable: Bool
            switch offer {
            case .privateKey: usable = availableMethods.contains(.publicKey)
            case .password:   usable = availableMethods.contains(.password)
            default:          usable = false
            }
            if usable {
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer))
                return
            }
        }
        nextChallengePromise.succeed(nil)   // out of methods -> auth fails
    }
}

/// TOFU host-key acceptance for the gate. P6 replaces this with a known-hosts
/// store that surfaces unknown/changed keys to the UI.
final class X2GoAcceptingHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}
