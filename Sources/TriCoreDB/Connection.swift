import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// One frame read off the wire.
struct InboundFrame: Sendable {
    let tag: UInt8
    let payload: Data

    var json: JSONValue? {
        get throws { try Frame.decodeBody(payload) }
    }
}

/// Splits the stream into frames, checking each header before its payload is read.
final class FrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = InboundFrame

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes >= Frame.headerSize else { return .needMoreData }
        let headerBytes = buffer.getBytes(at: buffer.readerIndex, length: Frame.headerSize)!
        let header = try Frame.decodeHeader(Data(headerBytes))
        guard buffer.readableBytes >= Frame.headerSize + header.length else { return .needMoreData }

        buffer.moveReaderIndex(forwardBy: Frame.headerSize)
        let payload = header.length == 0 ? Data() : Data(buffer.readBytes(length: header.length)!)
        context.fireChannelRead(wrapInboundOut(InboundFrame(tag: header.tag, payload: payload)))
        return .continue
    }
}

/// Hands each inbound frame to whoever is waiting for it.
///
/// A connection is a single request/response stream, so at most one request is in
/// flight; the queue is there so a failure can fail the waiter rather than hang it.
final class ResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = InboundFrame

    private var waiting: [CheckedContinuation<InboundFrame, Error>] = []
    private var failure: TriCoreError?

    /// Register a waiter. Must run on the channel's event loop.
    func expect(_ continuation: CheckedContinuation<InboundFrame, Error>) {
        if let failure {
            continuation.resume(throwing: failure)
            return
        }
        waiting.append(continuation)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume(returning: frame)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(with: error as? TriCoreError
            ?? TriCoreError(kind: .io, message: "the connection failed: \(error)"))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(with: TriCoreError(kind: .io, message: "the server closed the connection"))
        context.fireChannelInactive()
    }

    /// Fail every waiter, and every later one, with the same error: once the stream
    /// is out of step there is no resynchronisation point in a length-prefixed
    /// protocol.
    func fail(with error: TriCoreError) {
        if failure == nil { failure = error }
        let pending = waiting
        waiting = []
        for continuation in pending { continuation.resume(throwing: error) }
    }
}

/// The socket under a ``TriCore``: a channel, the handler that reads it, and the
/// deadlines around both.
final class Connection: @unchecked Sendable {
    private let channel: Channel
    private let handler: ResponseHandler
    private let group: EventLoopGroup
    private let ownsGroup: Bool

    private init(channel: Channel, handler: ResponseHandler, group: EventLoopGroup, ownsGroup: Bool) {
        self.channel = channel
        self.handler = handler
        self.group = group
        self.ownsGroup = ownsGroup
    }

    var isActive: Bool { channel.isActive }

    /// Dial, and wrap the connection in TLS when the options ask for it.
    static func connect(options: TriCoreOptions, group: EventLoopGroup? = nil) async throws -> Connection {
        let ownsGroup = group == nil
        let group = group ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let handler = ResponseHandler()
        let tlsContext = try options.tls.map { try makeTLSContext($0) }
        let serverName = options.tls?.serverName ?? options.host

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(TimeAmount(options.connectTimeout))
            .channelInitializer { channel in
                do {
                    if let tlsContext {
                        // The handshake has to finish before HELLO goes out: the
                        // secret must travel inside the TLS session, never ahead of it.
                        let tls = try NIOSSLClientHandler(context: tlsContext, serverHostname: sniName(serverName))
                        try channel.pipeline.syncOperations.addHandler(tls)
                    }
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(FrameDecoder()))
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        do {
            let channel = try await bootstrap.connect(host: options.host, port: options.port).get()
            // Request/response round trips are latency-sensitive, not bulk transfer:
            // Nagle's algorithm would add delay to every one. Set after connecting and
            // ignore a refusal — some sandboxes deny it, and an optimisation hint must
            // not be the reason a connection fails.
            try? await channel.setOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1).get()
            return Connection(channel: channel, handler: handler, group: group, ownsGroup: ownsGroup)
        } catch let error as NIOSSLError {
            if ownsGroup { try? await group.shutdownGracefully() }
            throw TriCoreError(kind: .tls, message: "TLS with \(serverName) failed: \(error)")
        } catch {
            if ownsGroup { try? await group.shutdownGracefully() }
            throw TriCoreError(kind: .io, message: "connect to \(options.host):\(options.port) failed: \(error)")
        }
    }

    /// Write one frame and wait for its reply, bounded by `timeout` when given.
    func exchange(tag: Frame.Tag, payload: Data, timeout: Duration?) async throws -> InboundFrame {
        guard channel.isActive else {
            throw TriCoreError(kind: .closed, message: "this connection is closed")
        }
        let bytes = try Frame.encode(tag: tag, payload: payload)

        let reply: InboundFrame
        do {
            reply = try await withDeadline(timeout) {
                // A continuation does not notice cancellation by itself, so the
                // deadline has to reach the waiter: without this the request would
                // outlive the timeout that was supposed to bound it.
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedThrowingContinuation) in
                        self.channel.eventLoop.execute {
                            self.handler.expect(continuation)
                            var buffer = self.channel.allocator.buffer(capacity: bytes.count)
                            buffer.writeBytes(bytes)
                            self.channel.writeAndFlush(buffer).whenFailure { error in
                                self.handler.fail(with: TriCoreError(kind: .io, message: "write failed: \(error)"))
                            }
                        }
                    }
                } onCancel: {
                    self.channel.eventLoop.execute {
                        self.handler.fail(with: TriCoreError(kind: .closed,
                                                             message: "the request was abandoned"))
                    }
                    self.channel.close(promise: nil)
                }
            }
        } catch let error as TriCoreError {
            // Past the write, a failure leaves the stream un-resynchronised: the
            // reply may still arrive and would be read as the next answer.
            if error.isConnectionFatal { close() }
            throw error
        }
        return reply
    }

    /// Say goodbye, best effort, and drop the socket.
    func shutdown() async {
        if channel.isActive {
            if let bytes = try? Frame.encode(tag: .close, payload: Data()) {
                var buffer = channel.allocator.buffer(capacity: bytes.count)
                buffer.writeBytes(bytes)
                _ = try? await channel.writeAndFlush(buffer).get()
            }
        }
        close()
        if ownsGroup { try? await group.shutdownGracefully() }
    }

    func close() {
        handler.fail(with: TriCoreError(kind: .closed, message: "this connection is closed"))
        channel.close(promise: nil)
    }

    // MARK: - Helpers

    private typealias CheckedThrowingContinuation = CheckedContinuation<InboundFrame, Error>

    /// Race the work against a deadline, so a server that never answers does not
    /// hold a caller for ever.
    private func withDeadline<T: Sendable>(
        _ timeout: Duration?, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let timeout else { return try await work() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TriCoreError(kind: .timeout, message: "no reply within \(timeout)")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw TriCoreError(kind: .io, message: "the request produced no result")
            }
            return first
        }
    }

    private static func makeTLSContext(_ options: TLSOptions) throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        if let caFile = options.caFile {
            do {
                configuration.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(caFile))
            } catch {
                // The path, never the contents: key and certificate bytes must not
                // reach a log through an error message.
                throw TriCoreError(kind: .tls, message: "cannot read the CA file at \(caFile)")
            }
        }
        switch (options.clientCertificateFile, options.clientKeyFile) {
        case (let certFile?, let keyFile?):
            do {
                configuration.certificateChain = try NIOSSLCertificate.fromPEMFile(certFile).map { .certificate($0) }
                configuration.privateKey = .privateKey(try NIOSSLPrivateKey(file: keyFile, format: .pem))
            } catch {
                throw TriCoreError(kind: .tls,
                                   message: "cannot read the client identity (certificate \(certFile), key \(keyFile))")
            }
        case (nil, nil):
            break
        case (_?, nil):
            throw TriCoreError.invalid("clientKeyFile is required alongside clientCertificateFile (mutual TLS needs both)")
        case (nil, _?):
            throw TriCoreError.invalid("clientCertificateFile is required alongside clientKeyFile (mutual TLS needs both)")
        }
        if options.dangerAcceptInvalidCertificates {
            configuration.certificateVerification = .none
        }
        do {
            return try NIOSSLContext(configuration: configuration)
        } catch {
            throw TriCoreError(kind: .tls, message: "cannot configure TLS: \(error)")
        }
    }

    /// An IP address is not a valid SNI name, and NIOSSL refuses one.
    private static func sniName(_ name: String) -> String? {
        let isIPv4 = name.split(separator: ".").count == 4
            && name.split(separator: ".").allSatisfy { UInt8($0) != nil }
        if isIPv4 || name.contains(":") { return nil }
        return name
    }
}

extension TimeAmount {
    init(_ duration: Duration) {
        let components = duration.components
        self = .nanoseconds(components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000)
    }
}
