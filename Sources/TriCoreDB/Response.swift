import Foundation

/// A SQL result set: the column names, and each row's values as the server
/// rendered them.
public struct Rows: Sendable, Equatable {
    /// Column names, in the order the values come in.
    public let columns: [String]
    /// One entry per row.
    public let rows: [[String]]

    public init(columns: [String], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }

    /// How many rows came back.
    public var count: Int { rows.count }
    /// Whether the result set is empty.
    public var isEmpty: Bool { rows.isEmpty }

    /// One row's value for a column, by name.
    public func value(row: Int, column: String) -> String? {
        guard let index = columns.firstIndex(of: column), rows.indices.contains(row) else { return nil }
        let values = rows[row]
        return values.indices.contains(index) ? values[index] : nil
    }

    /// Every row as a dictionary keyed by column name.
    public func dictionaries() -> [[String: String]] {
        rows.map { row in
            Dictionary(uniqueKeysWithValues: zip(columns, row).map { ($0, $1) })
        }
    }
}

extension Rows: Collection {
    public var startIndex: Int { rows.startIndex }
    public var endIndex: Int { rows.endIndex }
    public func index(after i: Int) -> Int { rows.index(after: i) }
    public subscript(position: Int) -> [String] { rows[position] }
}

/// What the server did with a transaction.
public struct TransactionResult: Sendable, Equatable {
    /// How many statements ran.
    public let statements: Int
    /// How many writes were made durable.
    public let committedWrites: Int
    /// How many buffered writes were thrown away.
    public let discardedWrites: Int
    /// `"began"`, `"committed"` or `"rolled_back"`.
    public let outcome: String

    init(_ json: JSONValue) {
        statements = json["statements"]?.intValue ?? 0
        committedWrites = json["committed_writes"]?.intValue ?? 0
        discardedWrites = json["discarded_writes"]?.intValue ?? 0
        outcome = json["transaction"]?.stringValue ?? "unknown"
    }
}

/// A decoded `RESPONSE` frame: the operation's result, and how it was produced.
public struct Response: Sendable, Equatable {
    /// The `request_id` the server echoed back.
    public let requestID: String
    /// The server's status. `"ok"` on success; anything else is raised as an error.
    public let status: String
    /// The name of the data variant — `"Json"`, `"Rows"`, `"CacheValue"`,
    /// `"Documents"`, `"Message"`, `"Toon"` or `"Empty"` — or `""` when there was none.
    public let kind: String
    /// That variant's payload.
    public let data: JSONValue
    /// Which route served the request.
    public let route: String?
    /// How long the server took.
    public let elapsedMilliseconds: Int?
    /// Non-fatal warnings. Not decorative: a broadcast that could not reach every
    /// shard reports it here while the status is still `"ok"`.
    public let warnings: [String]
    /// The server's machine-readable failure code, when it failed.
    public let errorCode: String?
    /// On a `not_leader` refusal, the leader's `host:port` when the cluster knows one.
    public let leaderHint: String?

    /// Whether the operation succeeded.
    public var isOK: Bool { status == "ok" }

    init(_ raw: JSONValue) {
        requestID = raw["request_id"]?.stringValue ?? ""
        status = raw["status"]?.stringValue ?? "error"

        let (kind, payload) = Response.unwrapVariant(raw["data"] ?? .null)
        self.kind = kind
        self.data = payload

        let diagnostics = raw["diagnostics"] ?? .null
        route = diagnostics["route"]?.stringValue
        elapsedMilliseconds = diagnostics["elapsed_ms"]?.intValue
        warnings = diagnostics["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        errorCode = diagnostics["error_code"]?.stringValue
        leaderHint = diagnostics["leader_hint"]?.stringValue
    }

    /// Unwrap an externally tagged `data` field — `{"Variant": payload}`, or the
    /// bare string `"Empty"` — into the variant's name and its payload.
    static func unwrapVariant(_ data: JSONValue) -> (kind: String, payload: JSONValue) {
        switch data {
        case .null:
            return ("", .null)
        case .string(let name):
            // The unit variants arrive as a bare string.
            return (name, .null)
        case .object(let members):
            guard let first = members.first else { return ("", .null) }
            return (first.key, first.value)
        default:
            return ("", data)
        }
    }

    /// The payload, when the variant is the expected one.
    func expect(_ expected: String, _ what: String) throws -> JSONValue {
        guard kind == expected else {
            throw TriCoreError.protocolViolation(
                "expected \(expected) from \(what), got \(kind.isEmpty ? "no data" : kind)")
        }
        return data
    }

    /// The error to raise for a response that is not `ok`.
    func asError() -> TriCoreError {
        let text: String
        switch kind {
        case "Message", "Toon":
            text = data.stringValue ?? data.description
        case "Json":
            text = data.description
        default:
            text = status.isEmpty ? "the request failed" : "the server answered `\(status)`"
        }
        return TriCoreError(kind: .server, message: text, code: errorCode, leaderHint: leaderHint)
    }
}
