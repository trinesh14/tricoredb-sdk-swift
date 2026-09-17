/// The error every call in this package throws.
///
/// Branch on ``kind`` and ``code``, never on the message text: a message is free to
/// be reworded, and matching one is how a client ends up acting on the wrong failure.
public struct TriCoreError: Error, Sendable, Equatable {

    /// What category of failure this is.
    public enum Kind: String, Sendable, Equatable {
        /// A socket read, write or connect failed.
        case io
        /// A deadline elapsed. The connection is closed afterwards, because the
        /// reply may still arrive and would be read as the next answer.
        case timeout
        /// The peer sent something this client cannot parse or did not expect.
        case protocolViolation
        /// Authentication was refused.
        case auth
        /// The server refused the handshake.
        case handshake
        /// The server answered with a status other than `ok`. The connection
        /// remains usable.
        case server
        /// The server sent a connection-level `ERROR` frame.
        case refused
        /// The operation needs a protocol capability the server did not grant.
        case featureNotGranted
        /// An argument was refused before anything was sent.
        case invalidArgument
        /// TLS configuration or the TLS handshake failed.
        case tls
        /// The connection was already closed.
        case closed
        /// No pooled connection was available, or the pool is closed.
        case pool
    }

    /// The code a Raft follower attaches when it cannot serve a request.
    public static let notLeader = "not_leader"
    /// The code of a request a follower handed to the leader and lost the answer
    /// to, or one the leader could not confirm. It may or may not have been
    /// applied, so the client never sends it again.
    public static let outcomeUnknown = "outcome_unknown"

    /// The failure category.
    public let kind: Kind
    /// The server's stable machine-readable code, when it sent one.
    public let code: String?
    /// Human-readable description.
    public let message: String
    /// On a `not_leader` refusal, the leader's client-facing `host:port` when the
    /// cluster knows one. `nil` means wait and retry.
    public let leaderHint: String?

    public init(kind: Kind, message: String, code: String? = nil, leaderHint: String? = nil) {
        self.kind = kind
        self.message = message
        self.code = code
        self.leaderHint = leaderHint
    }

    /// True for every `not_leader` refusal, with or without a hint.
    ///
    /// Unless ``TriCoreOptions/followLeader`` is off, the client has already sent the
    /// request again before throwing this.
    public var isRedirect: Bool { code == TriCoreError.notLeader }

    /// Whether the connection that produced this error can still be used.
    ///
    /// A server refusal — bad SQL, a missing table — leaves the stream perfectly
    /// aligned. A timeout or a protocol failure does not.
    public var isConnectionFatal: Bool {
        switch kind {
        case .io, .timeout, .protocolViolation, .refused, .closed, .tls, .handshake:
            return true
        case .server, .featureNotGranted, .invalidArgument, .auth, .pool:
            return false
        }
    }

    // MARK: - Internal constructors

    static func invalid(_ message: String) -> TriCoreError {
        TriCoreError(kind: .invalidArgument, message: message)
    }

    static func protocolViolation(_ message: String, code: String? = nil) -> TriCoreError {
        TriCoreError(kind: .protocolViolation, message: message, code: code)
    }

    static func featureRefusal(_ message: String) -> TriCoreError {
        TriCoreError(kind: .featureNotGranted, message: message, code: "feature_not_granted")
    }
}

extension TriCoreError: CustomStringConvertible {
    public var description: String {
        var text = code.map { "\(kind.rawValue) [\($0)]: \(message)" } ?? "\(kind.rawValue): \(message)"
        if let leaderHint {
            text += " (the leader serves clients at \(leaderHint))"
        }
        return text
    }
}
