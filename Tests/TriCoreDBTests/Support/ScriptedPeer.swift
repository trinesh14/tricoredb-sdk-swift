import Foundation
import NIOCore
import NIOPosix

@testable import TriCoreDB

/// A peer that speaks the handshake and then plays a scripted answer.
///
/// A real server cannot be asked to answer `not_leader` on demand, to hang up
/// mid-frame, or to declare a payload it does not send. What is under test is this
/// client's reading of those answers, and the shape it reads is the one a real
/// cluster sends.
final class ScriptedPeer: @unchecked Sendable {

    /// What the peer does when the next request arrives.
    enum Step: Sendable {
        /// Answer with a frame carrying this JSON.
        case reply(tag: Frame.Tag, json: JSONValue)
        /// Answer with these exact bytes, for the malformed cases a codec would
        /// refuse to produce.
        case raw(Data)
        /// Close the socket without answering.
        case hangUp
        /// Answer nothing at all, and hold the socket open.
        case silence
    }

    private let group: EventLoopGroup
    private var channel: Channel!

    /// The port this peer listens on.
    private(set) var port: Int = 0

    /// A peer that grants `features` in the handshake and then runs `steps`.
    ///
    /// Binding is awaited rather than waited on: blocking a cooperative thread from
    /// an async test is how a suite deadlocks before its first assertion.
    static func start(features: UInt64 = 7, steps: [Step]) async throws -> ScriptedPeer {
        var script: [Step] = [
            .reply(tag: .helloOK, json: [
                "ok": true,
                "server_version": ["major": 1, "minor": 0],
                "message": "ok",
                "features": .int(Int64(features)),
            ]),
            .reply(tag: .authOK, json: ["ok": true, "session_id": "s-1"]),
        ]
        script.append(contentsOf: steps)
        return try await start(rawScript: script)
    }

    /// A peer that runs `steps` from the very first frame, handshake included.
    static func start(rawScript steps: [Step]) async throws -> ScriptedPeer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let handler = ScriptHandler(steps: steps)
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 4)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(FrameDecoder()))
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return ScriptedPeer(group: group, channel: channel)
    }

    private init(group: EventLoopGroup, channel: Channel) {
        self.group = group
        self.channel = channel
        self.port = channel.localAddress?.port ?? 0
    }

    /// Options pointing at this peer.
    func options(user: String? = "admin", features: Feature = .all, readTimeout: Duration? = nil) -> TriCoreOptions {
        TriCoreOptions(
            host: "127.0.0.1", port: port, user: user, secret: "pw",
            connectTimeout: .seconds(5), readTimeout: readTimeout, features: features)
    }

    /// Connect a client to this peer.
    func connect(user: String? = "admin", features: Feature = .all, readTimeout: Duration? = nil) async throws -> TriCore {
        try await TriCore.connect(options(user: user, features: features, readTimeout: readTimeout))
    }

    /// Tear the peer down without blocking: `wait()` here would block whichever
    /// thread the test is running on.
    func shutdown() {
        channel?.close(promise: nil)
        group.shutdownGracefully { _ in }
    }

    /// Plays one step per inbound frame.
    private final class ScriptHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = InboundFrame
        typealias OutboundOut = ByteBuffer

        private let steps: [Step]
        private var index = 0

        init(steps: [Step]) { self.steps = steps }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            _ = unwrapInboundIn(data)
            guard index < steps.count else { return }
            play(context, steps[index])
            index += 1
            // A hang-up is not an answer to a request of its own: it follows the
            // step before it, which is what "the peer went away mid-frame" means.
            while index < steps.count, case .hangUp = steps[index] {
                play(context, steps[index])
                index += 1
            }
        }

        private func play(_ context: ChannelHandlerContext, _ step: Step) {
            switch step {
            case .reply(let tag, let json):
                guard let payload = try? Frame.encodeBody(json),
                      let bytes = try? Frame.encode(tag: tag, payload: payload) else { return }
                write(context, bytes)
            case .raw(let bytes):
                write(context, bytes)
            case .hangUp:
                context.close(promise: nil)
            case .silence:
                break
            }
        }

        private func write(_ context: ChannelHandlerContext, _ bytes: Data) {
            var buffer = context.channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }
}

extension ScriptedPeer.Step {
    /// A `RESPONSE` frame carrying a server payload.
    static func response(_ json: JSONValue) -> ScriptedPeer.Step {
        .reply(tag: .response, json: json)
    }

    /// A header that declares more bytes than the peer sends.
    static func overlongHeader(tag: Frame.Tag, declaring length: Int) -> ScriptedPeer.Step {
        var bytes = Data([Frame.version, tag.rawValue])
        bytes.append(UInt8(truncatingIfNeeded: length >> 24))
        bytes.append(UInt8(truncatingIfNeeded: length >> 16))
        bytes.append(UInt8(truncatingIfNeeded: length >> 8))
        bytes.append(UInt8(truncatingIfNeeded: length))
        return .raw(bytes)
    }
}
