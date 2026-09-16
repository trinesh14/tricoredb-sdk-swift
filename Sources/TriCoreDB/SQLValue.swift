import Foundation

/// One value bound to a `?` placeholder.
///
/// The values travel beside the statement and the server substitutes them at value
/// positions its grammar has already fixed, so a value can never become syntax
/// however it is spelled.
///
/// Literals mean you rarely name this type:
///
/// ```swift
/// try await db.execute("INSERT INTO users VALUES (?, ?)", [1, "O'Hara"])
/// ```
public enum SQLValue: Sendable, Hashable {
    /// SQL `NULL`.
    case null
    case bool(Bool)
    /// An exact integer.
    case int(Int64)
    /// A finite floating-point number. `NaN` and infinities are refused when sent.
    case double(Double)
    /// Text.
    case text(String)
    /// Raw bytes for a `BLOB` column, sent as `0x` hex.
    case blob(Data)
    /// An exact decimal, as plain digits with no exponent. Built by ``decimal(_:)``.
    case decimalText(String)
    /// A timestamp, sent in the sortable text form the server stores.
    case timestamp(Date)

    /// An exact decimal from its text form, such as `"-12.500"`.
    ///
    /// Exponents are refused because the server reads `1.5E+3` as a `DOUBLE`; a
    /// `Double` would lose the digits a decimal exists to keep.
    public static func decimal(_ text: String) throws -> SQLValue {
        guard isPlainDecimal(text) else {
            throw TriCoreError.invalid(
                "`\(text)` is not a plain decimal: use digits with an optional sign and fractional part, and no exponent")
        }
        return .decimalText(text)
    }

    static func isPlainDecimal(_ text: String) -> Bool {
        var body = Substring(text)
        if body.first == "+" || body.first == "-" { body = body.dropFirst() }
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 2 else { return false }
        let whole = parts[0]
        let fraction = parts.count == 2 ? parts[1] : Substring("")
        let digits = { (s: Substring) in s.allSatisfy(\.isNumber) }
        guard digits(whole), digits(fraction) else { return false }
        return !(whole.isEmpty && fraction.isEmpty)
    }

    /// The wire form: a JSON scalar the server binds.
    func wireValue(at index: Int) throws -> JSONValue {
        switch self {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .int(let value):
            return .int(value)
        case .double(let value):
            guard value.isFinite else {
                throw TriCoreError.invalid(
                    "parameter \(index + 1) is \(value), which has no SQL representation; only finite numbers can be bound")
            }
            return .double(value)
        case .text(let value):
            return .string(value)
        case .blob(let data):
            // Hex, not base64: a BLOB column parses `0x…`, and bytes that are not
            // valid UTF-8 must survive, which they would not as text.
            return .string("0x" + data.map { String(format: "%02x", $0) }.joined())
        case .decimalText(let text):
            return .string(text)
        case .timestamp(let date):
            return .string(SQLValue.timestampFormatter.string(from: date))
        }
    }

    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

// MARK: - Literals

extension SQLValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension SQLValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension SQLValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension SQLValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension SQLValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
}

// An interpolated string is how a caller writes most parameters. It is still a
// value: what it interpolates never becomes part of the statement text.
extension SQLValue: ExpressibleByStringInterpolation {}

// MARK: - Conversions

extension SQLValue {
    /// Bytes for a `BLOB` column.
    public init(_ data: Data) { self = .blob(data) }
    /// A timestamp.
    public init(_ date: Date) { self = .timestamp(date) }
    /// An integer of any width Swift has.
    public init<T: BinaryInteger>(_ value: T) { self = .int(Int64(value)) }
}

extension [SQLValue] {
    func wireValues() throws -> [JSONValue] {
        try enumerated().map { try $1.wireValue(at: $0) }
    }
}
