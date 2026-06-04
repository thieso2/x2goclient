import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// A local TCP listener that bridges each inbound connection to a direct-tcpip
/// SSH channel — i.e. `ssh -L localPort:remoteHost:remotePort`, in pure Swift.
/// This is the NX tunnel: nxproxy connects to 127.0.0.1:localPort and its bytes
/// flow over SSH to the remote nxagent.
/// Thread-safe byte counter shared by a tunnel's two glue handlers.
public final class ByteCounter: @unchecked Sendable {
    private var v = 0
    private let lock = NSLock()
    func add(_ n: Int) { lock.lock(); v += n; lock.unlock() }
    public var total: Int { lock.lock(); defer { lock.unlock() }; return v }
}

public final class PortForwarder: @unchecked Sendable {
    private let serverChannel: Channel
    public let localPort: Int
    private let counter: ByteCounter
    /// Total bytes forwarded through the tunnel (both directions).
    public var bytesTransferred: Int { counter.total }

    private init(serverChannel: Channel, localPort: Int, counter: ByteCounter) {
        self.serverChannel = serverChannel
        self.localPort = localPort
        self.counter = counter
    }

    public func close() async {
        try? await serverChannel.close().get()
    }

    static func start(
        group: EventLoopGroup, sshChannel: Channel, sshHandler: NIOSSHHandler,
        localPort: Int, remoteHost: String, remotePort: Int
    ) async throws -> PortForwarder {
        let counter = ByteCounter()
        let ctx = ForwardContext(sshChannel: sshChannel, sshHandler: sshHandler,
                                 remoteHost: remoteHost, remotePort: remotePort, counter: counter)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { inbound in
                ctx.bridge(inbound: inbound)
            }
        let server = try await bootstrap.bind(host: "127.0.0.1", port: localPort).get()
        let actualPort = server.localAddress?.port ?? localPort
        return PortForwarder(serverChannel: server, localPort: actualPort, counter: counter)
    }
}

/// Loop-bound carrier so the @Sendable child initializer can reach the SSH
/// channel/handler. Everything here runs on the single shared event loop.
private final class ForwardContext: @unchecked Sendable {
    let sshChannel: Channel
    let sshHandler: NIOSSHHandler
    let remoteHost: String
    let remotePort: Int
    let counter: ByteCounter
    init(sshChannel: Channel, sshHandler: NIOSSHHandler, remoteHost: String, remotePort: Int, counter: ByteCounter) {
        self.sshChannel = sshChannel; self.sshHandler = sshHandler
        self.remoteHost = remoteHost; self.remotePort = remotePort; self.counter = counter
    }

    func bridge(inbound: Channel) -> EventLoopFuture<Void> {
        let childPromise = sshChannel.eventLoop.makePromise(of: Channel.self)
        let origin = inbound.remoteAddress
            ?? (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))
            ?? (try! SocketAddress(unixDomainSocketPath: "/tmp/x2go.fwd"))
        let type = SSHChannelType.directTCPIP(.init(
            targetHost: remoteHost, targetPort: remotePort, originatorAddress: origin))
        sshHandler.createChannel(childPromise, channelType: type) { child, _ in
            child.pipeline.addHandler(SSHChannelByteCodec())
        }
        let counter = self.counter
        return childPromise.futureResult.flatMap { child -> EventLoopFuture<Void> in
            let (a, b) = GlueHandler.matchedPair(counter: counter)
            let f1 = inbound.pipeline.addHandler(a)
            let f2 = child.pipeline.addHandler(b)   // after the codec -> speaks ByteBuffer
            return f1.and(f2).map { _ in }
        }.flatMapError { error in
            inbound.close(promise: nil)
            return inbound.eventLoop.makeFailedFuture(error)
        }
    }
}

/// On an SSH child channel: translate SSHChannelData(.channel) <-> ByteBuffer so
/// the glue can treat it like a plain byte stream.
final class SSHChannelByteCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .whenComplete { _ in }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard case .byteBuffer(let buf) = d.data, d.type == .channel else { return }
        context.fireChannelRead(wrapInboundOut(buf))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buf))
        context.write(wrapOutboundOut(wrapped), promise: promise)
    }
}

/// Forwards bytes between two channels (both speaking ByteBuffer) and propagates
/// close in both directions. Single-event-loop; nxproxy uses one long-lived
/// connection, so plain forwarding (no cross-loop hops) is sufficient.
final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var context: ChannelHandlerContext?
    private weak var partner: GlueHandler?
    private var counter: ByteCounter?

    static func matchedPair(counter: ByteCounter) -> (GlueHandler, GlueHandler) {
        let a = GlueHandler(), b = GlueHandler()
        a.partner = b; b.partner = a
        a.counter = counter; b.counter = counter
        return (a, b)
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        counter?.add(buf.readableBytes)
        partner?.forward(buf)
    }

    private func forward(_ buf: ByteBuffer) {
        context?.writeAndFlush(wrapOutboundOut(buf), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerClosed()
        context.fireChannelInactive()
    }

    private func partnerClosed() {
        context?.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
