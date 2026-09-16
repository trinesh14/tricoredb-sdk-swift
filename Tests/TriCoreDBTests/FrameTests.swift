import XCTest

@testable import TriCoreDB

/// The frame layout, and the ceilings that keep a wrong or hostile peer from making
/// this client allocate whatever length it declares.
final class FrameTests: XCTestCase {

    func testHeaderIsVersionTagAndBigEndianLength() throws {
        let bytes = try Frame.encode(tag: .request, payload: Data("{}".utf8))
        XCTAssertEqual([UInt8](bytes), [1, 2, 0, 0, 0, 2, UInt8(ascii: "{"), UInt8(ascii: "}")])

        let empty = try Frame.encode(tag: .ping, payload: Data())
        XCTAssertEqual([UInt8](empty), [1, 4, 0, 0, 0, 0])
    }

    func testAFrameRoundTrips() throws {
        let payload = try Frame.encodeBody(["ok": false])
        let bytes = try Frame.encode(tag: .authOK, payload: payload)
        let header = try Frame.decodeHeader(bytes.prefix(Frame.headerSize))

        XCTAssertEqual(header.tag, Frame.Tag.authOK.rawValue)
        XCTAssertEqual(header.length, payload.count)

        let body = try Frame.decodeBody(bytes.dropFirst(Frame.headerSize))
        XCTAssertEqual(body?["ok"]?.boolValue, false)
    }

    func testOnlyDataFramesTakeTheLargeCeiling() {
        XCTAssertEqual(Frame.Tag.request.maxPayload, 16 * 1024 * 1024)
        XCTAssertEqual(Frame.Tag.response.maxPayload, 16 * 1024 * 1024)
        for tag: Frame.Tag in [.hello, .auth, .ping, .authOK, .cancelOK] {
            XCTAssertEqual(tag.maxPayload, 64 * 1024)
        }
        // A tag this build cannot name is a tag whose size it cannot vouch for.
        XCTAssertEqual(Frame.maxPayload(forTag: 99), 64 * 1024)
    }

    func testAnOversizedControlFrameIsRefusedOnTheWayOut() throws {
        let tooBig = Data(repeating: 0x61, count: Frame.maxControlPayload + 1)
        XCTAssertThrowsError(try Frame.encode(tag: .auth, payload: tooBig)) { error in
            XCTAssertEqual((error as? TriCoreError)?.code, "frame_too_large")
        }
        // The same payload is fine on a REQUEST, which has the larger ceiling.
        XCTAssertNoThrow(try Frame.encode(tag: .request, payload: tooBig))
    }

    func testADeclaredLengthAboveTheCeilingIsRefusedBeforeThePayloadIsRead() {
        // Six header bytes claiming 64 KiB + 1, and not one byte of body. A client
        // that trusted the length would allocate it and then wait for ever.
        let header = Data([1, Frame.Tag.authOK.rawValue, 0, 1, 0, 1])
        XCTAssertThrowsError(try Frame.decodeHeader(header)) { error in
            XCTAssertEqual((error as? TriCoreError)?.code, "frame_too_large")
        }
    }

    func testAFrameVersionThisClientCannotReadIsRefused() {
        let header = Data([2, Frame.Tag.response.rawValue, 0, 0, 0, 0])
        XCTAssertThrowsError(try Frame.decodeHeader(header)) { error in
            XCTAssertEqual((error as? TriCoreError)?.code, "frame_version")
        }
    }

    func testAShortHeaderIsRefused() {
        XCTAssertThrowsError(try Frame.decodeHeader(Data([1, 3])))
    }

    func testAPayloadThatIsNotJSONIsAProtocolError() throws {
        XCTAssertNil(try Frame.decodeBody(Data()))
        XCTAssertThrowsError(try Frame.decodeBody(Data("{not json".utf8))) { error in
            XCTAssertEqual((error as? TriCoreError)?.kind, .protocolViolation)
        }
    }
}
