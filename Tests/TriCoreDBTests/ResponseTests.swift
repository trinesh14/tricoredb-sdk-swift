import XCTest

@testable import TriCoreDB

/// What this client reads out of a RESPONSE frame.
final class ResponseTests: XCTestCase {

    func testASuccessfulResponseCarriesItsDiagnostics() {
        let response = Response([
            "request_id": "r1",
            "status": "ok",
            "data": ["Message": "done"],
            "diagnostics": ["route": "local", "elapsed_ms": 4, "warnings": ["shard 2 was unreachable"]],
        ])

        XCTAssertTrue(response.isOK)
        XCTAssertEqual(response.requestID, "r1")
        XCTAssertEqual(response.kind, "Message")
        XCTAssertEqual(response.route, "local")
        XCTAssertEqual(response.elapsedMilliseconds, 4)
        XCTAssertEqual(response.warnings, ["shard 2 was unreachable"],
                       "a partly applied broadcast warns while the status is still ok")
    }

    func testAnExternallyTaggedVariantSplitsIntoNameAndPayload() {
        let rows = Response(["status": "ok", "data": ["Rows": ["columns": ["a"], "rows": []]]])
        XCTAssertEqual(rows.kind, "Rows")
        XCTAssertEqual(rows.data["columns"]?[0]?.stringValue, "a")

        // The unit variants arrive as a bare string.
        let empty = Response(["status": "ok", "data": "Empty"])
        XCTAssertEqual(empty.kind, "Empty")
        XCTAssertTrue(empty.data.isNull)

        let none = Response(["status": "ok"])
        XCTAssertEqual(none.kind, "")
    }

    func testTheWrongVariantIsNamedInTheError() {
        let response = Response(["status": "ok", "data": ["Message": "hi"]])
        XCTAssertThrowsError(try response.expect("Rows", "query")) { error in
            let message = (error as? TriCoreError)?.message ?? ""
            XCTAssertTrue(message.contains("expected Rows"), message)
            XCTAssertTrue(message.contains("Message"), message)
        }
    }

    func testANotLeaderRefusalIsTypedAndNamesTheLeader() {
        let response = Response([
            "status": "error",
            "data": ["Message": "not the raft leader"],
            "diagnostics": ["error_code": "not_leader", "leader_hint": "10.9.9.7:8427"],
        ])
        let error = response.asError()

        XCTAssertEqual(error.kind, .server)
        XCTAssertEqual(error.code, "not_leader")
        XCTAssertTrue(error.isRedirect, "the code decides this, never the message text")
        XCTAssertEqual(error.leaderHint, "10.9.9.7:8427")
        XCTAssertFalse(error.isConnectionFatal, "a refusal leaves the connection usable")
        XCTAssertTrue(error.description.contains("10.9.9.7:8427"), error.description)
    }

    func testMidElectionThereIsACodeButNoAddress() {
        let response = Response([
            "status": "error",
            "data": ["Message": "not the raft leader"],
            "diagnostics": ["error_code": "not_leader"],
        ])
        let error = response.asError()

        XCTAssertTrue(error.isRedirect)
        XCTAssertNil(error.leaderHint,
                     "an absent hint means the destination is unknown, not that there was no redirect")
    }

    func testAnOrdinaryFailureIsNotReadAsARedirect() {
        let response = Response([
            "status": "error",
            "data": ["Message": "syntax error"],
            "diagnostics": ["error_code": "request.invalid"],
        ])
        let error = response.asError()

        XCTAssertFalse(error.isRedirect)
        XCTAssertEqual(error.code, "request.invalid")
        XCTAssertEqual(error.message, "syntax error")
    }

    func testRowsReadByPositionAndByName() {
        let rows = Rows(columns: ["id", "name"], rows: [["1", "ada"], ["2", "grace"]])

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ["1", "ada"])
        XCTAssertEqual(rows.value(row: 0, column: "name"), "ada")
        XCTAssertNil(rows.value(row: 0, column: "missing"))
        XCTAssertEqual(rows.dictionaries().first?["id"], "1")
        XCTAssertEqual(rows.map { $0[1] }, ["ada", "grace"])
    }

    func testATransactionScriptKeepsItsPlaceholdersAndFlattensItsParameters() throws {
        let (script, parameters) = try TriCore.buildTransactionScript([
            Statement("INSERT INTO t VALUES (?, ?)", [1, "ada"]),
            Statement("UPDATE t SET name = ? WHERE id = ?  ; ", ["bob", 1]),
        ])

        XCTAssertEqual(script, "BEGIN; INSERT INTO t VALUES (?, ?); UPDATE t SET name = ? WHERE id = ?; COMMIT")
        XCTAssertEqual(parameters.count, 4)
        XCTAssertEqual(parameters[1], .text("ada"))
    }

    func testCallerSuppliedTransactionControlIsRefused() {
        for sql in ["BEGIN", "begin", "COMMIT", "ROLLBACK", "START TRANSACTION"] {
            XCTAssertThrowsError(try TriCore.buildTransactionScript([Statement(sql)])) { error in
                XCTAssertEqual((error as? TriCoreError)?.kind, .invalidArgument)
            }
        }
        XCTAssertThrowsError(try TriCore.buildTransactionScript([]))
        XCTAssertThrowsError(try TriCore.buildTransactionScript([Statement("  ;  ")]))
    }

    func testBytesRoundTripThroughTheCacheEncoding() throws {
        let original = Data((0...255).map { UInt8($0) })
        XCTAssertEqual(try TriCore.decodeBytes(TriCore.byteList(original)), original)

        // A value outside 0...255 is not a byte: refused rather than masked, because
        // masking would quietly corrupt the payload.
        XCTAssertThrowsError(try TriCore.decodeBytes([1, 256]))
        XCTAssertThrowsError(try TriCore.decodeBytes("hi"))
    }
}
