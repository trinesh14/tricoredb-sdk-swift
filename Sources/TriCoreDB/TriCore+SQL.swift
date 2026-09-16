import Foundation

extension TriCore {

    /// The refusal when the server did not grant server-side binding. One wording,
    /// so it is searchable.
    static let noServerParams = """
        this server did not grant server-side parameters (SERVER_PARAMS was not in the granted feature set), \
        so this client will not bind `?` placeholders on this connection. It will not render the values into \
        the statement text instead: escaping and binding are not the same guarantee
        """

    /// Run a statement that is not a `SELECT`: DDL, `INSERT`, `UPDATE`, `DELETE`,
    /// or a transaction script.
    @discardableResult
    public func execute(_ sql: String, _ parameters: [SQLValue] = []) async throws -> Response {
        try await send(["Sql": ["Exec": try sqlBody(sql, parameters)]])
    }

    /// Run a `SELECT`. The server refuses a write sent this way.
    @discardableResult
    public func query(_ sql: String, _ parameters: [SQLValue] = []) async throws -> Rows {
        let response = try await send(["Sql": ["Query": try sqlBody(sql, parameters)]])
        return try TriCore.rows(from: response, "query")
    }

    /// Build the `{sql, params}` body.
    ///
    /// How many placeholders a statement has is left to the server: it counts them
    /// against the parameters it was given and refuses a mismatch by name, and it
    /// also understands `$n`, which a client-side scan for `?` would miscount.
    private func sqlBody(_ sql: String, _ parameters: [SQLValue]) throws -> JSONValue {
        guard !parameters.isEmpty else { return ["sql": .string(sql)] }
        try requireFeature(.serverParams, TriCore.noServerParams)
        return ["sql": .string(sql), "params": .array(try parameters.wireValues())]
    }

    static func rows(from response: Response, _ what: String) throws -> Rows {
        let payload = try response.expect("Rows", what)
        let columns = payload["columns"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let rows = payload["rows"]?.arrayValue?.map { row in
            row.arrayValue?.map { $0.stringValue ?? $0.description } ?? []
        } ?? []
        return Rows(columns: columns, rows: rows)
    }

    // MARK: - Transactions

    /// Run a whole `BEGIN … COMMIT` script in **one request**.
    ///
    /// One round trip, one replication event, and it works on every node, including
    /// those that withhold session transactions. Use it when every statement is
    /// known up front; use ``begin()`` when a later statement depends on what an
    /// earlier one read.
    @discardableResult
    public func transaction(_ statements: [Statement]) async throws -> TransactionResult {
        let (script, parameters) = try TriCore.buildTransactionScript(statements)
        let response = try await execute(script, parameters)
        return TransactionResult(try response.expect("Json", "transaction"))
    }

    /// Open a transaction that stays open across requests on this connection.
    ///
    /// Every statement until ``commit()`` or ``rollback()`` runs inside it, at one
    /// snapshot, invisible to other connections until committed. The transaction
    /// belongs to this connection's socket: another connection cannot commit it, and
    /// a dropped socket rolls it back.
    ///
    /// Needs the `SESSION_TXN` capability. Without it this fails before writing
    /// anything, rather than sending a `BEGIN` the server would run as a
    /// one-statement script.
    @discardableResult
    public func begin() async throws -> TransactionResult {
        try requireFeature(.sessionTxn, """
            this server did not grant session transactions (SESSION_TXN was not in the granted feature set), \
            so begin/commit/rollback cannot open a transaction on this connection. Use transaction(_:) to send \
            the whole unit as one request
            """)
        return try await transactionControl("BEGIN")
    }

    /// Commit the transaction opened by ``begin()``.
    @discardableResult
    public func commit() async throws -> TransactionResult {
        try await transactionControl("COMMIT")
    }

    /// Discard the transaction opened by ``begin()``.
    @discardableResult
    public func rollback() async throws -> TransactionResult {
        try await transactionControl("ROLLBACK")
    }

    /// Run a closure inside a transaction: commit when it returns, roll back when it
    /// throws.
    ///
    /// The closure must send its statements on this same connection. A statement on
    /// any other connection is outside the transaction.
    @discardableResult
    public func withTransaction<T: Sendable>(_ work: (TriCore) async throws -> T) async throws -> T {
        _ = try await begin()
        do {
            let value = try await work(self)
            _ = try await commit()
            return value
        } catch {
            // The caller's error is the one that matters; the rollback is
            // best-effort because the server ends the transaction anyway when this
            // connection goes.
            if inTransaction { _ = try? await rollback() }
            throw error
        }
    }

    /// Send one transaction-control keyword.
    ///
    /// Control travels as `Exec`, because the server authorizes it as a write. Every
    /// `COMMIT`/`ROLLBACK` reply — a refusal included — ends the transaction, since
    /// the server ends it either way. The exception is a request that never left
    /// this process.
    private func transactionControl(_ keyword: String) async throws -> TransactionResult {
        do {
            let response = try await execute(keyword)
            setTransactionOpen(keyword == "BEGIN")
            return TransactionResult(try response.expect("Json", keyword))
        } catch let error as TriCoreError {
            let refusedLocally = error.kind == .invalidArgument || error.kind == .featureNotGranted
            if keyword != "BEGIN" && !refusedLocally { setTransactionOpen(false) }
            throw error
        }
    }

    /// Assemble `BEGIN; …; COMMIT` and the flat parameter list that goes with it.
    ///
    /// The parameters of every statement are concatenated in statement order, which
    /// is how the server binds a multi-statement script: it walks the script left to
    /// right and takes one parameter per placeholder. So the script keeps its
    /// placeholders instead of having values pasted into it.
    static func buildTransactionScript(_ statements: [Statement]) throws -> (String, [SQLValue]) {
        guard !statements.isEmpty else {
            throw TriCoreError.invalid("a transaction needs at least one statement")
        }
        var parts: [String] = []
        var parameters: [SQLValue] = []
        for statement in statements {
            var text = statement.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            while text.hasSuffix(";") {
                text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !text.isEmpty else {
                throw TriCoreError.invalid("every statement in a transaction must be non-empty SQL")
            }
            let first = text.split(separator: " ", maxSplits: 1).first.map { $0.uppercased() } ?? ""
            // Caller-supplied transaction control changes what the script means in a
            // way the caller almost certainly did not intend.
            if ["BEGIN", "START", "COMMIT", "ROLLBACK"].contains(first) {
                throw TriCoreError.invalid(
                    "transaction(_:) brackets the script itself — remove the `\(first)` statement")
            }
            parts.append(text)
            parameters.append(contentsOf: statement.parameters)
        }
        return ("BEGIN; " + parts.joined(separator: "; ") + "; COMMIT", parameters)
    }
}

/// One statement of a transaction script, with the values bound to it.
public struct Statement: Sendable, Equatable, ExpressibleByStringLiteral {
    /// The statement text, with `?` placeholders.
    public let sql: String
    /// The values for those placeholders, in order.
    public let parameters: [SQLValue]

    public init(_ sql: String, _ parameters: [SQLValue] = []) {
        self.sql = sql
        self.parameters = parameters
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }
}
