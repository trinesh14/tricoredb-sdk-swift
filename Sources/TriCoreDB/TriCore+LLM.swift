import Foundation

/// How the server should render an export.
public enum OutputFormat: String, Sendable {
    /// TriCoreDB's own representation.
    case native
    /// Standard JSON.
    case json
    /// The token-oriented rendering meant for a model's context window.
    case toon
    /// Markdown, for a person to read.
    case markdown
}

/// What to include in an export, and what to hide.
///
/// The default matches the server's own: redact, no schema, no row cap. Build from
/// it rather than from a zeroed struct, so redaction is never turned off by accident.
public struct LlmOptions: Sendable, Equatable {
    /// Cap the rows included. `nil` leaves the cap to the server.
    public var maxRows: Int?
    /// Redact sensitive fields before exporting.
    public var redactSensitive: Bool
    /// Include type information alongside the data.
    public var includeSchema: Bool

    public init(maxRows: Int? = nil, redactSensitive: Bool = true, includeSchema: Bool = false) {
        self.maxRows = maxRows
        self.redactSensitive = redactSensitive
        self.includeSchema = includeSchema
    }

    var json: JSONValue {
        [
            "max_rows": maxRows.map { JSONValue.int(Int64($0)) } ?? .null,
            "redact_sensitive": .bool(redactSensitive),
            "include_schema": .bool(includeSchema),
        ]
    }
}

/// One read-only source contributing to a context bundle.
public struct LlmSource: Sendable, Equatable {
    let json: JSONValue

    /// A `SELECT`. The caller needs permission to read it.
    public static func sql(_ query: String) -> LlmSource {
        LlmSource(json: ["Sql": ["query": .string(query)]])
    }

    /// A document query. The caller needs permission to read the collection.
    public static func documents(
        _ collection: String, filter: DocumentFilter = .all, limit: Int? = nil
    ) -> LlmSource {
        LlmSource(json: ["DocumentFind": [
            "collection": .string(collection),
            "filter": filter.json,
            "limit": limit.map { JSONValue.int(Int64($0)) } ?? .null,
        ]])
    }
}

extension TriCore {

    /// Assemble a context bundle from one or more read-only sources.
    ///
    /// The result is the rendered bundle: text for TOON and Markdown, JSON otherwise.
    public func llmContext(
        _ sources: [LlmSource], format: OutputFormat = .toon, options: LlmOptions = LlmOptions()
    ) async throws -> String {
        guard !sources.isEmpty else {
            throw TriCoreError.invalid("a context bundle needs at least one source")
        }
        let response = try await send(["Llm": ["Context": [
            "sources": .array(sources.map(\.json)),
            "format": .string(format.rawValue),
            "options": options.json,
        ]]])
        return try TriCore.rendered(response)
    }

    /// Export the schema catalog: SQL tables and document collections.
    public func llmSchema(
        format: OutputFormat = .toon, options: LlmOptions = LlmOptions()
    ) async throws -> String {
        let response = try await send(["Llm": ["Schema": [
            "format": .string(format.rawValue),
            "options": options.json,
        ]]])
        return try TriCore.rendered(response)
    }

    /// Round-trip a request through the whole pipeline.
    ///
    /// Unlike ``ping()``, which never reaches a module, this proves authentication,
    /// routing and dispatch work — what a readiness check actually wants. Needs the
    /// admin permission and the cluster module.
    public func adminPing() async throws {
        _ = try await send(["Admin": "Ping"])
    }

    /// The server's status, as the cluster core reports it.
    ///
    /// A single node without structured status answers with a plain message, which is
    /// returned under the `message` key rather than raised as an error.
    public func adminStatus() async throws -> [String: JSONValue] {
        let response = try await send(["Admin": "Status"])
        if response.kind == "Message" {
            return ["message": .string(response.data.stringValue ?? "")]
        }
        return try response.expect("Json", "admin status").objectValue ?? [:]
    }

    /// Unwrap whichever payload the requested format produced.
    private static func rendered(_ response: Response) throws -> String {
        switch response.kind {
        case "Toon", "Message":
            return response.data.stringValue ?? response.data.description
        case "Json":
            return response.data.description
        default:
            throw TriCoreError.protocolViolation(
                "expected a rendered export, got \(response.kind.isEmpty ? "no data" : response.kind)")
        }
    }
}
