import Foundation
import NIOCore

/// One session with a TriCoreDB server: a connection plus a completed handshake.
///
/// A connection is a single request/response stream, and this is an `actor`, so
/// overlapping calls queue instead of interleaving frames. Use a ``TriCorePool``
/// when you want requests to actually run at the same time.
///
/// ```swift
/// let db = try await TriCore.connect(
///     TriCoreOptions(host: "127.0.0.1", user: "admin", secret: "pw"))
/// try await db.execute("INSERT INTO users VALUES (?, ?)", [1, "O'Hara"])
/// let rows = try await db.query("SELECT name FROM users WHERE id = ?", [1])
/// await db.close()
/// ```
public actor TriCore {
    private let connection: Connection
    private let options: TriCoreOptions

    private var sessionIdentifier: String?
    private var granted: Feature = []
    private var requestCounter: UInt64 = 0
    private let requestPrefix: String
    private var lastRequest: String?
    private var transactionOpen = false
    private var closed = false

    private static let protocolName = "tricore"
    private static let protocolVersion = 1

    private init(connection: Connection, options: TriCoreOptions) {
        self.connection = connection
        self.options = options
        self.requestPrefix = TriCore.nextConnectionPrefix()
    }

    // MARK: - Connecting

    /// Connect, shake hands, and authenticate when ``TriCoreOptions/user`` is set.
    public static func connect(_ options: TriCoreOptions) async throws -> TriCore {
        let connection = try await Connection.connect(options: options)
        let client = TriCore(connection: connection, options: options)
        do {
            try await client.handshake()
            if let user = options.user {
                try await client.authenticate(user: user, secret: options.secret)
            }
        } catch {
            await connection.shutdown()
            throw error
        }
        return client
    }

    /// Connect to a host and port as a named user.
    public static func connect(
        host: String, port: Int = TriCoreOptions.defaultPort, user: String, secret: String
    ) async throws -> TriCore {
        try await connect(TriCoreOptions(host: host, port: port, user: user, secret: secret))
    }

    private func handshake() async throws {
        let payload: JSONValue = [
            "protocol": .string(TriCore.protocolName),
            "version": ["major": .int(Int64(TriCore.protocolVersion)), "minor": 0],
            "client": .string(options.clientName),
            "features": .int(Int64(options.features.rawValue)),
        ]
        let frame = try await exchange(tag: .hello, payload: payload, timeout: options.connectTimeout)
        switch Frame.Tag(rawValue: frame.tag) {
        case .helloOK:
            break
        case .error:
            throw TriCoreError(kind: .handshake, message: try Self.errorText(frame),
                               code: try Self.errorCode(frame))
        default:
            throw TriCoreError.protocolViolation("expected HELLO_OK, got frame tag \(frame.tag)")
        }
        let body = try frame.json ?? .null
        guard body["ok"]?.boolValue == true else {
            let message = body["message"]?.stringValue ?? "the server refused the handshake"
            throw TriCoreError(kind: .handshake, message: message, code: body["code"]?.stringValue)
        }
        granted = Feature(rawValue: UInt64(body["features"]?.intValue ?? 0))
    }

    private func authenticate(user: String, secret: String) async throws {
        let payload: JSONValue = [
            "username": .string(user),
            // A byte array, not a base64 string: this is what the server reads here.
            "secret": .array(Array(secret.utf8).map { .int(Int64($0)) }),
        ]
        let frame = try await exchange(tag: .auth, payload: payload, timeout: options.connectTimeout)
        switch Frame.Tag(rawValue: frame.tag) {
        case .authOK:
            break
        case .error:
            throw TriCoreError(kind: .auth, message: try Self.errorText(frame), code: try Self.errorCode(frame))
        default:
            throw TriCoreError.protocolViolation("expected AUTH_OK, got frame tag \(frame.tag)")
        }
        let body = try frame.json ?? .null
        // An AUTH_OK-tagged frame carrying `ok: false` is still a refusal: the tag
        // names the answer's shape, not its verdict.
        guard body["ok"]?.boolValue == true else {
            throw TriCoreError(kind: .auth, message: body["message"]?.stringValue ?? "authentication refused")
        }
        sessionIdentifier = body["session_id"]?.stringValue
    }

    // MARK: - Session

    /// The session id the server assigned, or `nil` when the connection never
    /// authenticated.
    public var sessionID: String? { sessionIdentifier }

    /// The capabilities the server granted in the handshake.
    public var grantedFeatures: Feature { granted }

    /// Whether the server granted server-side parameter binding.
    public var serverParamsGranted: Bool { granted.contains(.serverParams) }

    /// Whether the server granted session transactions.
    public var sessionTxnGranted: Bool { granted.contains(.sessionTxn) }

    /// Whether a ``begin()`` block is open on this connection.
    public var inTransaction: Bool { transactionOpen && !closed }

    /// Whether this connection has been closed.
    public var isClosed: Bool { closed || !connection.isActive }

    /// The database named in every request from this connection.
    public var database: String { options.database }

    /// The `request_id` most recently sent. Pass it to ``cancel(_:)`` from a
    /// *second* connection to stop a running statement.
    public var lastRequestID: String? { lastRequest }

    /// Check liveness with a PING/PONG round trip.
    public func ping() async throws {
        let frame = try await exchange(tag: .ping, payload: nil, timeout: options.readTimeout)
        guard Frame.Tag(rawValue: frame.tag) == .pong else {
            throw TriCoreError.protocolViolation("expected PONG, got frame tag \(frame.tag)")
        }
    }

    /// Ask the server to stop one of this principal's running statements.
    ///
    /// Send this on a **second** connection: the one running the statement is
    /// blocked reading its reply and will not see anything else. An unknown id stops
    /// nothing and is not an error.
    @discardableResult
    public func cancel(_ requestID: String) async throws -> Int {
        guard !requestID.isEmpty else {
            throw TriCoreError.invalid("a request id to cancel must not be empty")
        }
        let frame = try await exchange(
            tag: .cancel, payload: ["request_id": .string(requestID)], timeout: options.readTimeout)
        switch Frame.Tag(rawValue: frame.tag) {
        case .cancelOK:
            return (try frame.json)?["cancelled"]?.intValue ?? 0
        case .error:
            throw TriCoreError(kind: .server, message: try Self.errorText(frame), code: try Self.errorCode(frame))
        default:
            throw TriCoreError.protocolViolation("expected CANCEL_OK, got frame tag \(frame.tag)")
        }
    }

    /// End the session politely and release the socket. Calling it twice is safe.
    public func close() async {
        guard !closed else { return }
        closed = true
        transactionOpen = false
        await connection.shutdown()
    }

    // MARK: - Requests

    /// Send a raw operation and return the decoded response.
    ///
    /// The typed methods cover every operation a client should need; reach for this
    /// only when there is none — an operation that exists to be refused
    /// (`Cache::XGroup`), or one a newer server added ahead of this package.
    @discardableResult
    public func request(_ op: JSONValue) async throws -> Response {
        try await send(op)
    }

    @discardableResult
    func send(_ op: JSONValue) async throws -> Response {
        requestCounter += 1
        let requestID = "sw-\(requestPrefix)-\(requestCounter)"
        lastRequest = requestID

        var envelope: [String: JSONValue] = [
            "request_id": .string(requestID),
            "database": .string(options.database),
            "op": op,
        ]
        if let requestTimeout = options.requestTimeout {
            let milliseconds = requestTimeout.components.seconds * 1000
                + requestTimeout.components.attoseconds / 1_000_000_000_000_000
            envelope["options"] = ["timeout_ms": .int(milliseconds)]
        }

        let frame = try await exchange(tag: .request, payload: .object(envelope), timeout: options.readTimeout)
        switch Frame.Tag(rawValue: frame.tag) {
        case .response:
            break
        case .error:
            throw TriCoreError(kind: .refused, message: try Self.errorText(frame), code: try Self.errorCode(frame))
        default:
            throw TriCoreError.protocolViolation("expected RESPONSE, got frame tag \(frame.tag)")
        }

        let response = Response(try frame.json ?? .null)
        // Anything but `ok` means the operation did not happen, and must not reach a
        // caller wearing a success's clothes. Compared against `ok` rather than a
        // list of failures, so a status added later fails closed.
        guard response.isOK else { throw response.asError() }
        return response
    }

    private func exchange(tag: Frame.Tag, payload: JSONValue?, timeout: Duration?) async throws -> InboundFrame {
        guard !closed else {
            throw TriCoreError(kind: .closed, message: "this connection is closed")
        }
        let body = try payload.map { try Frame.encodeBody($0) } ?? Data()
        do {
            return try await connection.exchange(tag: tag, payload: body, timeout: timeout)
        } catch let error as TriCoreError {
            if error.isConnectionFatal { closed = true }
            throw error
        }
    }

    func setTransactionOpen(_ open: Bool) { transactionOpen = open }

    func requireFeature(_ feature: Feature, _ message: String) throws {
        guard granted.contains(feature) else { throw TriCoreError.featureRefusal(message) }
    }

    // MARK: - Helpers

    private static func errorText(_ frame: InboundFrame) throws -> String {
        guard let json = try frame.json else {
            return "the server refused the connection without saying why"
        }
        for key in ["message", "error"] {
            if let text = json[key]?.stringValue, !text.isEmpty { return text }
        }
        return json.description
    }

    private static func errorCode(_ frame: InboundFrame) throws -> String? {
        try frame.json?["code"]?.stringValue
    }

    /// A prefix that makes this connection's request ids unique among every other
    /// connection the same principal holds.
    ///
    /// The server's cancel registry is keyed by request id **scoped to the
    /// principal** and stops every entry that matches, so with a bare per-connection
    /// counter a pool's connections would all issue a `-1` and one cancel would stop
    /// all of them.
    private static func nextConnectionPrefix() -> String {
        let counter = ConnectionCounter.shared.next()
        let stamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        return String(stamp, radix: 16) + "-" + String(counter, radix: 16)
    }
}

/// A process-wide counter for request-id prefixes.
final class ConnectionCounter: @unchecked Sendable {
    static let shared = ConnectionCounter()
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
