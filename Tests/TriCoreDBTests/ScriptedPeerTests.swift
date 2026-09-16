import XCTest

@testable import TriCoreDB

/// How this client reads the protocol, proved without a server. These always run.
final class ScriptedPeerTests: XCTestCase {

    func testANotLeaderRefusalIsTypedAndCarriesTheLeaderAddress() async throws {
        let peer = try await ScriptedPeer.start(steps: [
            .response([
                "request_id": "r1",
                "status": "error",
                "data": ["Message": "not the raft leader"],
                "diagnostics": ["error_code": "not_leader", "leader_hint": "10.9.9.7:8427"],
            ])
        ])
        defer { peer.shutdown() }

        let db = try await peer.connect()
        do {
            try await db.execute("INSERT INTO t VALUES (1)")
            XCTFail("a follower must refuse the write")
        } catch let error as TriCoreError {
            XCTAssertEqual(error.kind, .server)
            XCTAssertEqual(error.code, "not_leader")
            XCTAssertTrue(error.isRedirect)
            XCTAssertEqual(error.leaderHint, "10.9.9.7:8427")
            let closed = await db.isClosed
            XCTAssertFalse(closed, "a refusal leaves the connection usable")
        }
        await db.close()
    }

    func testMidElectionThereIsACodeButNoAddress() async throws {
        let peer = try await ScriptedPeer.start(steps: [
            .response([
                "request_id": "r1",
                "status": "error",
                "data": ["Message": "not the raft leader"],
                "diagnostics": ["error_code": "not_leader"],
            ])
        ])
        defer { peer.shutdown() }

        let db = try await peer.connect()
        do {
            try await db.execute("INSERT INTO t VALUES (1)")
            XCTFail("the write must be refused")
        } catch let error as TriCoreError {
            XCTAssertTrue(error.isRedirect)
            XCTAssertNil(error.leaderHint,
                         "an absent hint means the destination is unknown, not that there was no redirect")
        }
        await db.close()
    }

    func testAnAuthOKFrameCarryingOKFalseIsStillARefusal() async throws {
        let peer = try await ScriptedPeer.start(rawScript: [
            .reply(tag: .helloOK, json: ["ok": true, "message": "ok", "features": 7]),
            // The tag names the answer's shape; the body is the verdict.
            .reply(tag: .authOK, json: ["ok": false, "message": "bad password"]),
        ])
        defer { peer.shutdown() }

        do {
            _ = try await peer.connect()
            XCTFail("authentication must be refused")
        } catch let error as TriCoreError {
            XCTAssertEqual(error.kind, .auth)
            XCTAssertEqual(error.message, "bad password")
        }
    }

    func testAHandshakeRefusalIsReportedAsOne() async throws {
        let peer = try await ScriptedPeer.start(rawScript: [
            .reply(tag: .helloOK, json: [
                "ok": false, "message": "unsupported protocol version", "code": "protocol_version",
            ])
        ])
        defer { peer.shutdown() }

        do {
            _ = try await peer.connect()
            XCTFail("the handshake must be refused")
        } catch let error as TriCoreError {
            XCTAssertEqual(error.kind, .handshake)
            XCTAssertTrue(error.message.contains("unsupported protocol"), error.message)
        }
    }

    func testADeclaredPayloadAboveTheCeilingIsRefusedBeforeItIsRead() async throws {
        // A control frame claiming 64 KiB + 1 bytes, with none of them sent. A client
        // that trusted the length would allocate it and then wait for ever.
        let peer = try await ScriptedPeer.start(steps: [
            .overlongHeader(tag: .authOK, declaring: Frame.maxControlPayload + 1)
        ])
        defer { peer.shutdown() }

        let db = try await peer.connect()
        do {
            try await db.ping()
            XCTFail("the frame must be refused")
        } catch let error as TriCoreError {
            XCTAssertEqual(error.kind, .protocolViolation)
            XCTAssertEqual(error.code, "frame_too_large")
            let closed = await db.isClosed
            XCTAssertTrue(closed, "a stream that cannot be resynchronised is dropped, not reused")
        }
    }

    func testAPeerThatHangsUpMidFrameDoesNotLeaveTheClientWaiting() async throws {
        let peer = try await ScriptedPeer.start(steps: [
            .raw(Data([Frame.version, Frame.Tag.response.rawValue, 0, 0, 0, 10, UInt8(ascii: "{")])),
            .hangUp,
        ])
        defer { peer.shutdown() }

        let db = try await peer.connect()
        do {
            try await db.execute("SELECT 1")
            XCTFail("the peer went away mid-frame")
        } catch let error as TriCoreError {
            XCTAssertTrue(error.isConnectionFatal, "\(error)")
        }
        await db.close()
    }

    func testAReplyThatNeverArrivesEndsAtTheReadTimeout() async throws {
        let peer = try await ScriptedPeer.start(steps: [.silence])
        defer { peer.shutdown() }

        let db = try await peer.connect(readTimeout: .milliseconds(200))
        let started = ContinuousClock.now
        do {
            try await db.execute("SELECT 1")
            XCTFail("no reply was ever sent")
        } catch let error as TriCoreError {
            XCTAssertEqual(error.kind, .timeout)
            XCTAssertLessThan(started.duration(to: .now), .seconds(3), "it did not wait")
            let closed = await db.isClosed
            XCTAssertTrue(closed, "the reply may still arrive, so the socket cannot be reused")
        }
    }

    func testAStatusThisClientDoesNotKnowIsTreatedAsAFailure() async throws {
        let peer = try await ScriptedPeer.start(steps: [
            .response([
                "request_id": "r1",
                "status": "not_implemented",
                "data": ["Message": "Cache::XGroup is refused in V1"],
            ])
        ])
        defer { peer.shutdown() }

        let db = try await peer.connect()
        do {
            _ = try await db.request(["Cache": ["XGroup": [:]]])
            XCTFail("anything but ok is a failure")
        } catch let error as TriCoreError {
            XCTAssertEqual(error.kind, .server)
            XCTAssertTrue(error.message.contains("XGroup"), error.message)
        }
        await db.close()
    }

    func testAServerThatGrantedNothingMakesTheClientRefuseBeforeSending() async throws {
        // An older server grants no capabilities at all.
        let peer = try await ScriptedPeer.start(features: 0, steps: [.silence])
        defer { peer.shutdown() }

        let db = try await peer.connect()
        let granted = await db.grantedFeatures
        XCTAssertTrue(granted.isEmpty)
        let bindsParameters = await db.serverParamsGranted
        XCTAssertFalse(bindsParameters)

        do {
            _ = try await db.query("SELECT * FROM t WHERE id = ?", [1])
            XCTFail("binding needs the capability")
        } catch let error as TriCoreError {
            XCTAssertEqual(error.kind, .featureNotGranted)
            XCTAssertTrue(error.message.contains("SERVER_PARAMS"), error.message)
            let closed = await db.isClosed
            XCTAssertFalse(closed, "nothing was sent, so the connection is untouched")
        }

        do {
            _ = try await db.begin()
            XCTFail("a session transaction needs the capability")
        } catch let error as TriCoreError {
            XCTAssertEqual(error.kind, .featureNotGranted)
            XCTAssertTrue(error.message.contains("SESSION_TXN"), error.message)
        }
        await db.close()
    }

    func testWarningsAndDiagnosticsReachTheCallerOnASuccessfulResponse() async throws {
        let peer = try await ScriptedPeer.start(steps: [
            .response([
                "request_id": "r1",
                "status": "ok",
                "data": ["Message": "done"],
                "diagnostics": ["route": "local", "elapsed_ms": 4, "warnings": ["shard 2 was unreachable"]],
            ])
        ])
        defer { peer.shutdown() }

        let db = try await peer.connect()
        let response = try await db.request(["Admin": "Ping"])
        XCTAssertTrue(response.isOK)
        XCTAssertEqual(response.warnings, ["shard 2 was unreachable"])
        XCTAssertEqual(response.route, "local")
        XCTAssertEqual(response.elapsedMilliseconds, 4)
        await db.close()
    }

    func testTheRequestEnvelopeCarriesTheDatabaseAndAUniqueID() async throws {
        let peer = try await ScriptedPeer.start(steps: [
            .response([
                "request_id": "r1",
                "status": "ok",
                "data": ["Rows": ["columns": ["n"], "rows": [["1"]]]],
            ])
        ])
        defer { peer.shutdown() }

        var options = peer.options()
        options.database = "reporting"
        let db = try await TriCore.connect(options)
        let rows = try await db.query("SELECT 1")
        XCTAssertEqual(rows[0], ["1"])

        let identifier = await db.lastRequestID
        XCTAssertTrue(identifier?.hasPrefix("sw-") ?? false, identifier ?? "nil")
        let database = await db.database
        XCTAssertEqual(database, "reporting")
        await db.close()
    }
}
