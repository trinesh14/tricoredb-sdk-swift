import Foundation

/// A bounded pool of connections, for work that runs concurrently.
///
/// A ``TriCore`` is one request/response stream, so concurrency means one connection
/// per concurrent caller. Opening one per request costs a TCP connect plus a
/// handshake every time; a pool pays that once.
///
/// ```swift
/// let pool = TriCorePool(options: options, size: 8)
/// try await pool.withConnection { db in
///     try await db.execute("INSERT INTO t VALUES (?)", [1])
/// }
/// await pool.close()
/// ```
public actor TriCorePool {
    private let options: TriCoreOptions
    /// The maximum number of connections this pool may hold.
    public let size: Int

    private var idle: [TriCore] = []
    private var lent = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false

    public init(options: TriCoreOptions, size: Int = 8) {
        precondition(size >= 1, "a pool needs room for at least one connection")
        self.options = options
        self.size = size
    }

    /// How many connections are idle, and how many are lent out.
    public var stats: (idle: Int, lent: Int) { (idle.count, lent) }

    /// Whether ``close()`` has run.
    public var isClosed: Bool { closed }

    /// Borrow a connection for the duration of `work`, waiting for a free one.
    ///
    /// A connection is never returned to the pool with a transaction still open: it
    /// is rolled back first, and the connection is retired if that rollback fails.
    @discardableResult
    public func withConnection<T: Sendable>(_ work: (TriCore) async throws -> T) async throws -> T {
        let connection = try await acquire()
        var broken = false
        var leftTransactionOpen = false

        let outcome: Result<T, Error>
        do {
            outcome = .success(try await work(connection))
        } catch {
            outcome = .failure(error)
            if let failure = error as? TriCoreError, failure.isConnectionFatal { broken = true }
        }

        if await connection.isClosed {
            broken = true
        } else if await connection.inTransaction {
            leftTransactionOpen = true
            // A rollback this client could not complete leaves a session whose state
            // no next borrower can assume anything about.
            do {
                _ = try await connection.rollback()
            } catch {
                broken = true
            }
        }
        await release(connection, broken: broken)

        switch outcome {
        case .failure(let error):
            throw error
        case .success(let value):
            if leftTransactionOpen {
                throw TriCoreError.invalid("""
                    the closure returned with a transaction still open on the pooled connection; it has been \
                    rolled back rather than handed to the next borrower. Commit or roll back inside the closure, \
                    or use TriCore.withTransaction
                    """)
            }
            return value
        }
    }

    /// Close every idle connection and refuse new borrowing. Connections currently
    /// lent out close when they come back.
    public func close() async {
        closed = true
        let connections = idle
        idle = []
        for waiter in waiters { waiter.resume() }
        waiters = []
        for connection in connections { await connection.close() }
    }

    // MARK: - Internals

    private func acquire() async throws -> TriCore {
        while true {
            if closed { throw TriCoreError(kind: .pool, message: "this pool is closed") }

            if let connection = idle.popLast() {
                lent += 1
                return connection
            }
            if lent < size {
                // Count the slot before connecting, so two callers cannot both decide
                // there is room for the last one.
                lent += 1
                do {
                    return try await TriCore.connect(options)
                } catch {
                    lent -= 1
                    wakeOne()
                    throw error
                }
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
    }

    private func release(_ connection: TriCore, broken: Bool) async {
        lent -= 1
        if broken || closed {
            await connection.close()
        } else {
            idle.append(connection)
        }
        wakeOne()
    }

    private func wakeOne() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}
