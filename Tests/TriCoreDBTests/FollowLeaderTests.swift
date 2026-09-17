import Foundation
import NIOCore
import NIOPosix
import XCTest

@testable import TriCoreDB

/// Following the leader: what the client does with `not_leader` by default. Peers
/// that accept any number of connections stand in for a follower and a leader; a
/// real follower's refusal was applied nowhere, which is what makes sending the
/// request again safe.
final class FollowLeaderTests: XCTestCase {

    /// A value shared between the test and the peer's event loop.
    final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func withLockedValue<R>(_ body: (inout Value) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    /// A peer serving any number of connections; `reply(requestID, n)` answers the
    /// n-th request it has seen.
    final class Peer: @unchecked Sendable {
        struct Seen {
            var connections = 0
            var users: [String] = []
            var requestIDs: [String] = []
        }

        let seen = Locked(Seen())
        private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        private var channel: Channel!
        private(set) var port = 0

        static func start(_ reply: @escaping @Sendable (String, Int) -> JSONValue) async throws -> Peer {
            let peer = Peer()
            let seen = peer.seen
            peer.channel = try await ServerBootstrap(group: peer.group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    seen.withLockedValue { $0.connections += 1 }
                    do {
                        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(FrameDecoder()))
                        try channel.pipeline.syncOperations.addHandler(Handler(seen: seen, reply: reply))
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            peer.port = peer.channel.localAddress?.port ?? 0
            return peer
        }

        var address: String { "127.0.0.1:\(port)" }
        var requests: Int { seen.withLockedValue { $0.requestIDs.count } }
        var connections: Int { seen.withLockedValue { $0.connections } }

        func options(user: String? = nil) -> TriCoreOptions {
            TriCoreOptions(host: "127.0.0.1", port: port, user: user, secret: "s",
                           connectTimeout: .seconds(5), leaderRetryDelay: .milliseconds(1))
        }

        func shutdown() {
            channel?.close(promise: nil)
            group.shutdownGracefully { _ in }
        }

        private final class Handler: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = InboundFrame
            typealias OutboundOut = ByteBuffer

            let seen: Locked<Seen>
            let reply: @Sendable (String, Int) -> JSONValue

            init(seen: Locked<Seen>, reply: @escaping @Sendable (String, Int) -> JSONValue) {
                self.seen = seen
                self.reply = reply
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let frame = unwrapInboundIn(data)
                let body = (try? frame.json) ?? .null
                switch Frame.Tag(rawValue: frame.tag) {
                case .hello:
                    write(context, .helloOK, ["ok": true, "features": 7])
                case .auth:
                    seen.withLockedValue { $0.users.append(body["username"]?.stringValue ?? "") }
                    write(context, .authOK, ["ok": true, "session_id": "s-1"])
                case .close:
                    write(context, .bye, [:])
                    context.close(promise: nil)
                case .request:
                    let rid = body["request_id"]?.stringValue ?? ""
                    let n = seen.withLockedValue { state -> Int in
                        state.requestIDs.append(rid)
                        return state.requestIDs.count
                    }
                    write(context, .response, reply(rid, n))
                default:
                    break
                }
            }

            private func write(_ context: ChannelHandlerContext, _ tag: Frame.Tag, _ json: JSONValue) {
                guard let payload = try? Frame.encodeBody(json),
                      let bytes = try? Frame.encode(tag: tag, payload: payload) else { return }
                var buffer = context.channel.allocator.buffer(capacity: bytes.count)
                buffer.writeBytes(bytes)
                context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
            }
        }
    }

    static func ok(_ rid: String) -> JSONValue {
        ["request_id": .string(rid), "status": "ok",
         "data": ["Json": ["transaction": "began", "statements": 0]], "diagnostics": [:]]
    }

    static func refusal(_ rid: String, _ code: String, leader: String? = nil) -> JSONValue {
        var diagnostics: [String: JSONValue] = ["error_code": .string(code)]
        if let leader { diagnostics["leader_hint"] = .string(leader) }
        return ["request_id": .string(rid), "status": "error",
                "data": ["Message": "not the raft leader"], "diagnostics": .object(diagnostics)]
    }

    func testARefusedRequestGoesToTheLeaderAndStaysThere() async throws {
        let leader = try await Peer.start { rid, _ in Self.ok(rid) }
        defer { leader.shutdown() }
        let leaderAddress = leader.address
        let follower = try await Peer.start { rid, _ in
            Self.refusal(rid, TriCoreError.notLeader, leader: leaderAddress)
        }
        defer { follower.shutdown() }

        let db = try await TriCore.connect(follower.options(user: "u"))
        try await db.execute("INSERT INTO t VALUES (1)")
        let address = await db.address
        XCTAssertEqual(address, leader.address)
        try await db.execute("INSERT INTO t VALUES (2)")
        XCTAssertEqual(follower.requests, 1)
        XCTAssertEqual(leader.requests, 2)
        XCTAssertEqual(leader.connections, 1)
        XCTAssertEqual(leader.seen.withLockedValue { $0.users }, ["u"])
        XCTAssertEqual(leader.seen.withLockedValue { $0.requestIDs.first },
                       follower.seen.withLockedValue { $0.requestIDs.first })
        await db.close()
    }

    func testWithNoLeaderNamedTheClientWaitsAndAsksAgain() async throws {
        let peer = try await Peer.start { rid, n in
            n < 3 ? Self.refusal(rid, TriCoreError.notLeader) : Self.ok(rid)
        }
        defer { peer.shutdown() }
        let db = try await TriCore.connect(peer.options())
        try await db.execute("INSERT INTO t VALUES (1)")
        XCTAssertEqual(peer.requests, 3)
        XCTAssertEqual(peer.connections, 1)
        await db.close()
    }

    func testRetriesAreBoundedAndReported() async throws {
        let peer = try await Peer.start { rid, _ in Self.refusal(rid, TriCoreError.notLeader) }
        defer { peer.shutdown() }
        var options = peer.options()
        options.leaderRetries = 2
        let db = try await TriCore.connect(options)
        do {
            try await db.execute("INSERT INTO t VALUES (1)")
            XCTFail("never served")
        } catch let error as TriCoreError {
            XCTAssertTrue(error.isRedirect)
            XCTAssertTrue(error.message.contains("sent again 2 times"), error.message)
        }
        XCTAssertEqual(peer.requests, 3)
        await db.close()
    }

    func testAnUnreachableLeaderLeavesTheConnectionWhereItWas() async throws {
        let dead = try await Peer.start { rid, _ in Self.ok(rid) }
        let nowhere = dead.address
        dead.shutdown()
        try await Task.sleep(for: .milliseconds(100))
        let peer = try await Peer.start { rid, n in
            n == 1 ? Self.refusal(rid, TriCoreError.notLeader, leader: nowhere) : Self.ok(rid)
        }
        defer { peer.shutdown() }
        let db = try await TriCore.connect(peer.options())
        try await db.execute("INSERT INTO t VALUES (1)")
        let address = await db.address
        XCTAssertEqual(address, peer.address)
        XCTAssertEqual(peer.requests, 2)
        await db.close()
    }

    func testNothingIsSentAgainInsideASessionTransaction() async throws {
        let peer = try await Peer.start { rid, n in
            n == 1 ? Self.ok(rid) : Self.refusal(rid, TriCoreError.notLeader)
        }
        defer { peer.shutdown() }
        let db = try await TriCore.connect(peer.options())
        try await db.begin()
        do {
            try await db.execute("INSERT INTO t VALUES (1)")
            XCTFail("refused")
        } catch let error as TriCoreError {
            XCTAssertTrue(error.isRedirect)
        }
        XCTAssertEqual(peer.requests, 2)
        await db.close()
    }

    func testOutcomeUnknownIsNeverSentAgain() async throws {
        let peer = try await Peer.start { rid, _ in Self.refusal(rid, TriCoreError.outcomeUnknown) }
        defer { peer.shutdown() }
        let db = try await TriCore.connect(peer.options())
        do {
            try await db.execute("INSERT INTO t VALUES (1)")
            XCTFail("unknown")
        } catch let error as TriCoreError {
            XCTAssertEqual(error.code, TriCoreError.outcomeUnknown)
            XCTAssertFalse(error.isRedirect)
        }
        XCTAssertEqual(peer.requests, 1)
        await db.close()
    }
}
