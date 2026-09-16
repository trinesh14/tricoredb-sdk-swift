import Foundation

@testable import TriCoreDB

/// A private `tricore-server` for the tests that need a real one.
///
/// The binary is named by `TRICORE_SERVER_BIN`, or found in a sibling
/// `tricore/tricore-db/target/{release,debug}` checkout. It is never built here:
/// building the server from a test is slow and collides with anything else
/// compiling.
///
/// When there is no binary, ``skipReason`` says so and the live tests skip. Someone
/// who added this package as a dependency has no server, and `swift test` must still
/// be green for them.
final class LiveServer: @unchecked Sendable {

    private static let configuration = """
        [server]
        host = "127.0.0.1"
        port = 0
        protocol = "tricore"
        node_id = "sdk-swift-tests"
        region_id = "local"

        [modules]
        sql = true
        document = true
        cache = true
        vector = true
        graph = true
        llm = true
        cluster = false

        [security]
        auth_mode = "password"
        dev_auth = true
        allow_default_admin = false

        [tls]
        enabled = false
        """

    /// One server for every live test in this process.
    static let shared: LiveServer? = {
        guard binary != nil else { return nil }
        return try? LiveServer()
    }()

    /// Why the live tests cannot run, or `nil` when they can.
    static var skipReason: String? {
        if binary == nil {
            return "no tricore-server binary: set TRICORE_SERVER_BIN, or run one from the Docker image (see the README)"
        }
        return shared == nil ? "the tricore-server binary could not be started" : nil
    }

    private static let binary: String? = {
        let name = "tricore-server"
        if let named = ProcessInfo.processInfo.environment["TRICORE_SERVER_BIN"], !named.isEmpty {
            return FileManager.default.isExecutableFile(atPath: named) ? named : nil
        }
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" && !directory.path.isEmpty {
            for profile in ["release", "debug"] {
                let candidate = directory.appendingPathComponent("target/\(profile)/\(name)").path
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return nil
    }()

    private let process = Process()
    private let directory: URL

    /// The host the server bound to.
    let host: String
    /// The port it is listening on.
    let port: Int

    private init() throws {
        guard let binary = LiveServer.binary else {
            throw TriCoreError.invalid("no tricore-server binary")
        }
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tricoredb-swift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configurationFile = directory.appendingPathComponent("tricore.toml")
        try LiveServer.configuration.write(to: configurationFile, atomically: true, encoding: .utf8)
        let dataDirectory = directory.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "--config", configurationFile.path,
            "--port", "0",
            "--data-dir", dataDirectory.path,
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        // The address is read from the server's own line rather than assumed: sibling
        // runs bind their own servers at the same time. Reading continues afterwards,
        // because a full pipe would stop the server dead.
        let found = Locked<String?>(nil)
        let handle = output.fileHandleForReading
        let reader = Thread {
            var buffered = ""
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffered += String(decoding: chunk, as: UTF8.self)
                while let newline = buffered.firstIndex(of: "\n") {
                    let line = String(buffered[..<newline])
                    buffered = String(buffered[buffered.index(after: newline)...])
                    if let range = line.range(of: "listening on ") {
                        found.set(String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }
        reader.start()

        let deadline = Date().addingTimeInterval(60)
        while found.get() == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let address = found.get(), let separator = address.lastIndex(of: ":"),
              let port = Int(address[address.index(after: separator)...])
        else {
            process.terminate()
            try? FileManager.default.removeItem(at: directory)
            throw TriCoreError.invalid("the server never said which address it is listening on")
        }
        self.host = String(address[..<separator])
        self.port = port
    }

    /// Options pointing at this server.
    func options() -> TriCoreOptions {
        TriCoreOptions(host: host, port: port, user: "admin", secret: "pw", connectTimeout: .seconds(15))
    }

    /// Connect to this server as `admin`.
    func connect() async throws -> TriCore {
        try await TriCore.connect(options())
    }

    deinit {
        process.terminate()
        try? FileManager.default.removeItem(at: directory)
    }

    /// A tiny mutex, so the reader thread and the waiting one agree on the address.
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }

        func get() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ newValue: Value) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

/// A name no other test in this run uses, so tests can share one server safely.
func unique(_ prefix: String) -> String {
    "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))"
}
