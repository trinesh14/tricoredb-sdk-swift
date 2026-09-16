import XCTest

@testable import TriCoreDB

/// The JSON value type the protocol's dynamic payloads decode into.
final class JSONValueTests: XCTestCase {

    func testLiteralsBuildTheValueTheyLookLike() {
        let value: JSONValue = ["name": "ada", "age": 36, "admin": true, "score": 1.5, "tags": ["a", "b"], "note": nil]

        XCTAssertEqual(value["name"]?.stringValue, "ada")
        XCTAssertEqual(value["age"]?.intValue, 36)
        XCTAssertEqual(value["admin"]?.boolValue, true)
        XCTAssertEqual(value["score"]?.doubleValue, 1.5)
        XCTAssertEqual(value["tags"]?.arrayValue?.count, 2)
        XCTAssertEqual(value["note"], JSONValue.null)
    }

    func testAnAbsentKeyAndANullValueAreDifferentThings() {
        let value: JSONValue = ["present": nil]

        XCTAssertNotNil(value["present"], "the key is there")
        XCTAssertTrue(value["present"]!.isNull, "and its value is null")
        XCTAssertNil(value["absent"], "this key is not there at all")
    }

    func testNumbersKeepTheirKind() {
        XCTAssertEqual(JSONValue.int(42).intValue, 42)
        XCTAssertEqual(JSONValue.int(42).doubleValue, 42)
        // A whole double reads as an integer, because the server sends counts that way.
        XCTAssertEqual(JSONValue.double(34).intValue, 34)
        XCTAssertNil(JSONValue.double(1.5).intValue)
        XCTAssertNil(JSONValue.string("42").intValue)
    }

    func testValuesRoundTripThroughJSON() throws {
        let original: JSONValue = ["a": [1, 2, ["b": "c"]], "d": nil, "e": -0.125]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded["a"]?[2]?["b"]?.stringValue, "c")
    }
}

/// How a Swift value reaches the server as a bound parameter.
final class SQLValueTests: XCTestCase {

    func testAnInterpolatedStringIsAValueLikeAnyOther() throws {
        let name = "ada"
        let value: SQLValue = "\(name)'; DROP TABLE t; --"
        XCTAssertEqual(try value.wireValue(at: 0), "ada'; DROP TABLE t; --",
                       "it is bound as text, never spliced into the statement")
        let json: JSONValue = "\(name) lovelace"
        XCTAssertEqual(json.stringValue, "ada lovelace")
    }

    private func wire(_ value: SQLValue) throws -> JSONValue {
        try value.wireValue(at: 0)
    }

    func testScalarsPassThroughUnchanged() throws {
        XCTAssertEqual(try wire(nil), .null)
        XCTAssertEqual(try wire(true), .bool(true))
        XCTAssertEqual(try wire(42), .int(42))
        XCTAssertEqual(try wire(-0.125), .double(-0.125))
        XCTAssertEqual(try wire("O'Hara"), .string("O'Hara"), "a quote is data, never syntax")
    }

    func testBytesBecomeLowercaseHexABlobColumnParses() throws {
        XCTAssertEqual(try wire(.blob(Data([0x00, 0xab, 0xff, 0x10]))), .string("0x00abff10"))
        XCTAssertEqual(try wire(.blob(Data())), .string("0x"))
        // Invalid UTF-8 has to survive, which is why bytes never go through a String.
        XCTAssertEqual(try wire(.blob(Data([0xc3, 0x28]))), .string("0xc328"))
    }

    func testADecimalGoesOutAsPlainDigits() throws {
        // A Double would lose the digits a decimal exists to keep, and an exponent
        // reads as a DOUBLE on the server.
        XCTAssertEqual(try wire(try .decimal("10.50")), .string("10.50"))
        XCTAssertEqual(try wire(try .decimal("-0.123456789012345678")), .string("-0.123456789012345678"))

        for bad in ["1.5E+3", "1e10", "", "-", ".", "1.2.3", "12a", "NaN", " 1"] {
            XCTAssertThrowsError(try SQLValue.decimal(bad), "\(bad) should be refused")
        }
        XCTAssertNoThrow(try SQLValue.decimal("+10"))
        XCTAssertNoThrow(try SQLValue.decimal(".5"))
    }

    func testNonFiniteNumbersAreRefusedByName() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try SQLValue.double(value).wireValue(at: 2)) { error in
                let failure = error as? TriCoreError
                XCTAssertEqual(failure?.kind, .invalidArgument)
                XCTAssertTrue(failure?.message.contains("parameter 3") ?? false, "\(failure?.message ?? "")")
            }
        }
    }

    func testATimestampGoesOutInTheFormTheServerStores() throws {
        let date = Date(timeIntervalSince1970: 1_789_000_000)
        let encoded = try wire(.timestamp(date)).stringValue ?? ""
        XCTAssertTrue(encoded.contains(":"), "a timestamp is text, not a number: \(encoded)")
        XCTAssertEqual(encoded.count, "yyyy-MM-dd HH:mm:ss.SSS".count)
    }

    func testAParameterListKeepsItsOrder() throws {
        let values: [SQLValue] = [1, "ada", nil, .blob(Data([1]))]
        XCTAssertEqual(try values.wireValues(), [.int(1), .string("ada"), .null, .string("0x01")])
    }
}
