import Foundation
import NIOCore
import NIOSSH

/// Drives one `exec` session channel: sends the exec request on activation,
/// accumulates stdout/stderr, records the exit status, and fulfils the result
/// promise when the channel closes.
final class ExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData

    private let command: String
    private let promise: EventLoopPromise<ExecResult>
    private var stdout = Data()
    private var stderr = Data()
    private var exitStatus: Int32 = -1
    private var completed = false

    init(command: String, promise: EventLoopPromise<ExecResult>) {
        self.command = command
        self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .whenFailure { [promise] in promise.fail($0) }
    }

    func channelActive(context: ChannelHandlerContext) {
        let req = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
        context.triggerUserOutboundEvent(req, promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buf) = channelData.data else { return }
        let bytes = buf.getBytes(at: buf.readerIndex, length: buf.readableBytes) ?? []
        switch channelData.type {
        case .channel: stdout.append(contentsOf: bytes)
        case .stdErr:  stderr.append(contentsOf: bytes)
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus = Int32(status.exitStatus)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !completed { completed = true; promise.fail(error) }
        context.close(promise: nil)
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        promise.succeed(ExecResult(stdout: stdout, stderr: stderr, exitStatus: exitStatus))
    }
}
