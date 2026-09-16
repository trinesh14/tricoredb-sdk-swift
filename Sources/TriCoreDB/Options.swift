import Foundation

/// An optional protocol capability, negotiated in the handshake.
public struct Feature: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// The server joins a request's correlation id to its logs, audit trail and
    /// cancel registry.
    public static let correlationID = Feature(rawValue: 1 << 0)

    /// The server binds `?` placeholders from a typed array sent beside the
    /// statement, instead of the client rendering values into the SQL text.
    public static let serverParams = Feature(rawValue: 1 << 1)

    /// The server holds a transaction open across requests on one connection.
    public static let sessionTxn = Feature(rawValue: 1 << 2)

    /// Everything this build understands.
    public static let all: Feature = [.correlationID, .serverParams, .sessionTxn]
}

/// How the TLS session is set up.
///
/// Supplying ``TLSOptions`` at all is what turns TLS on. Once on, the certificate
/// chain and the host name are verified unless ``dangerAcceptInvalidCertificates``
/// says otherwise.
public struct TLSOptions: Sendable, Equatable {
    /// PEM bundle used to verify the server.
    ///
    /// With none, the platform's trust store is used. Point this at your own CA for
    /// a private certificate — which is the usual case for a database.
    public var caFile: String?
    /// The name expected in the certificate, also sent as SNI. Defaults to the host
    /// being connected to.
    public var serverName: String?
    /// PEM client certificate chain, for mutual TLS. Needs ``clientKeyFile``.
    public var clientCertificateFile: String?
    /// PEM private key for ``clientCertificateFile``.
    public var clientKeyFile: String?
    /// Turns off certificate and host name checks.
    ///
    /// **Development only.** Such a connection is encrypted but authenticates
    /// nobody, which is worse than visibly using plain TCP.
    public var dangerAcceptInvalidCertificates: Bool

    public init(
        caFile: String? = nil,
        serverName: String? = nil,
        clientCertificateFile: String? = nil,
        clientKeyFile: String? = nil,
        dangerAcceptInvalidCertificates: Bool = false
    ) {
        self.caFile = caFile
        self.serverName = serverName
        self.clientCertificateFile = clientCertificateFile
        self.clientKeyFile = clientKeyFile
        self.dangerAcceptInvalidCertificates = dangerAcceptInvalidCertificates
    }
}

/// What to connect to, and how.
public struct TriCoreOptions: Sendable, Equatable {
    /// The port `tricore-server` listens on unless configured otherwise.
    public static let defaultPort = 8427

    /// Server host.
    public var host: String
    /// Server port.
    public var port: Int
    /// Principal to authenticate as. `nil` skips authentication, which only a
    /// server that allows anonymous sessions accepts.
    public var user: String?
    /// The password or token sent with ``user``.
    public var secret: String
    /// The database named in every request.
    public var database: String
    /// The name this client reports in the handshake.
    public var clientName: String
    /// How long the connect, TLS and handshake may take together.
    public var connectTimeout: Duration
    /// How long to wait for each reply. `nil` means no bound: a statement runs for
    /// as long as it runs, and the server's own limit is unlimited by default, so
    /// any number here would be a guess at a guarantee the server does not make.
    public var readTimeout: Duration?
    /// A server-side deadline stamped on every request. Unlike ``readTimeout`` this
    /// makes the *server* stop, rather than only ending the wait.
    public var requestTimeout: Duration?
    /// TLS settings. `nil` means plain TCP, on which the secret crosses the wire in
    /// the clear.
    public var tls: TLSOptions?
    /// The capabilities announced in the handshake. The server grants only what was
    /// asked for, so removing one here is how a caller opts out of it.
    public var features: Feature

    public init(
        host: String = "127.0.0.1",
        port: Int = TriCoreOptions.defaultPort,
        user: String? = nil,
        secret: String = "",
        database: String = "main",
        clientName: String = "tricoredb-swift/\(TriCoreDBVersion.current)",
        connectTimeout: Duration = .seconds(10),
        readTimeout: Duration? = nil,
        requestTimeout: Duration? = nil,
        tls: TLSOptions? = nil,
        features: Feature = .all
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.secret = secret
        self.database = database
        self.clientName = clientName
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
        self.requestTimeout = requestTimeout
        self.tls = tls
        self.features = features
    }
}

extension TriCoreOptions: CustomStringConvertible {
    /// Never prints the secret.
    public var description: String {
        "TriCoreOptions(host: \(host), port: \(port), user: \(user ?? "nil"), secret: ***, "
            + "database: \(database), clientName: \(clientName), tls: \(tls == nil ? "off" : "on"))"
    }
}

/// This package's own version, distinct from the wire protocol's.
public enum TriCoreDBVersion {
    public static let current = "0.1.0"
}
