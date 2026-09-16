import XCTest

@testable import TriCoreDB

/// Everything this client can do, against a real `tricore-server`.
///
/// Each case reads the value *back* rather than only checking that nothing was
/// thrown: a client that mangled a quote, a backslash or a 100 KiB payload would
/// pass a "no error" test and fail every one of these.
///
/// Without a server binary every test skips, with the reason printed.
final class LiveTests: XCTestCase {

    private func live() throws -> LiveServer {
        if let reason = LiveServer.skipReason { throw XCTSkip(reason) }
        return LiveServer.shared!
    }

    func testASessionAuthenticatesAndNegotiatesItsCapabilities() async throws {
        let db = try await live().connect()
        try await db.ping()

        let session = await db.sessionID
        XCTAssertNotNil(session, "an authenticated session has an id")
        let bindsParameters = await db.serverParamsGranted
        XCTAssertTrue(bindsParameters, "the server binds parameters")
        let holdsTransactions = await db.sessionTxnGranted
        XCTAssertTrue(holdsTransactions, "the server holds transactions open")
        await db.close()
    }

    func testValuesRoundTripThroughBoundParametersByteForByte() async throws {
        let db = try await live().connect()
        let table = unique("sw_params")
        let victim = unique("sw_victim")
        try await db.execute("CREATE TABLE \(table) (id INT PRIMARY KEY, t TEXT, b BLOB, f DOUBLE, k BOOL)")
        try await db.execute("CREATE TABLE \(victim) (id INT PRIMARY KEY)")

        let quote = "O'Hara said 'hi'"
        let backslash = #"C:\Users\trine\a\'b"#
        let injection = "'; DROP TABLE \(victim); --"
        for (id, text) in [(1, quote), (2, backslash), (3, injection)] {
            try await db.execute("INSERT INTO \(table) (id, t) VALUES (?, ?)", [.int(Int64(id)), .text(text)])
            let rows = try await db.query("SELECT t FROM \(table) WHERE id = ?", [.int(Int64(id))])
            XCTAssertEqual(rows[0][0], text, "value \(id) changed in flight")
        }
        // The proof that the injection string was data: the table it named is still there.
        _ = try await db.query("SELECT id FROM \(victim)")

        let blob = Data([0x00, 0x01, 0xff, 0xfe, 0x27, 0x5c, 0x68, 0x69, 0x00])
        try await db.execute("INSERT INTO \(table) (id, b, f, k) VALUES (?, ?, ?, ?)",
                             [4, .blob(blob), -0.125, true])
        let row = try await db.query("SELECT b, f, k FROM \(table) WHERE id = ?", [4])[0]
        XCTAssertEqual(row[0], "0x0001fffe275c686900", "every byte survives, NUL and invalid UTF-8 included")
        XCTAssertEqual(row[1], "-0.125")
        XCTAssertEqual(row[2], "true")

        // A bound null is SQL NULL, not the four letters N-U-L-L.
        try await db.execute("INSERT INTO \(table) (id, t) VALUES (?, ?)", [5, nil])
        let nulls = try await db.query("SELECT COUNT(*) FROM \(table) WHERE id = ? AND t IS NULL", [5])
        XCTAssertEqual(nulls[0][0], "1")

        try await db.execute("CREATE TABLE \(table)_d (id INT PRIMARY KEY, amount DECIMAL)")
        try await db.execute("INSERT INTO \(table)_d VALUES (?, ?)", [1, try .decimal("10.50")])
        let amount = try await db.query("SELECT amount FROM \(table)_d")
        XCTAssertEqual(amount[0][0], "10.50", "an exact decimal keeps its digits")

        try await db.execute("DROP TABLE \(table)")
        try await db.execute("DROP TABLE \(table)_d")
        try await db.execute("DROP TABLE \(victim)")
        await db.close()
    }

    func testTheQueryAndExecuteSplitIsEnforcedByTheServer() async throws {
        let db = try await live().connect()
        let table = unique("sw_split")
        try await db.execute("CREATE TABLE \(table) (id INT PRIMARY KEY)")

        do {
            _ = try await db.query("INSERT INTO \(table) VALUES (1)")
            XCTFail("a write through query must be refused")
        } catch let error as TriCoreError {
            XCTAssertEqual(error.kind, .server)
        }

        do {
            try await db.execute("THIS IS NOT SQL AT ALL")
            XCTFail("nonsense must not succeed")
        } catch let error as TriCoreError {
            XCTAssertEqual(error.kind, .server)
            XCTAssertNotNil(error.code)
        }

        let closed = await db.isClosed
        XCTAssertFalse(closed, "a refusal leaves the connection usable")
        try await db.ping()
        try await db.execute("DROP TABLE \(table)")
        await db.close()
    }

    func testTransactionsCommitTogetherAndRollBackTogether() async throws {
        let db = try await live().connect()
        let table = unique("sw_txn")
        try await db.execute("CREATE TABLE \(table) (id INT PRIMARY KEY, name TEXT)")

        let result = try await db.transaction([
            Statement("INSERT INTO \(table) VALUES (?, ?)", [1, "ada"]),
            Statement("INSERT INTO \(table) VALUES (?, ?)", [2, "grace"]),
        ])
        XCTAssertEqual(result.outcome, "committed")
        XCTAssertEqual(result.committedWrites, 2)

        _ = try await db.begin()
        try await db.execute("INSERT INTO \(table) VALUES (?, ?)", [3, "hopper"])
        _ = try await db.rollback()
        let afterRollback = try await db.query("SELECT COUNT(*) FROM \(table)")
        XCTAssertEqual(afterRollback[0][0], "2", "a rolled-back write must not persist")
        let open = await db.inTransaction
        XCTAssertFalse(open)

        try await db.withTransaction { tx in
            try await tx.execute("INSERT INTO \(table) VALUES (?, ?)", [4, "eve"])
        }
        let afterCommit = try await db.query("SELECT COUNT(*) FROM \(table)")
        XCTAssertEqual(afterCommit[0][0], "3")

        try await db.execute("DROP TABLE \(table)")
        await db.close()
    }

    func testACacheValueOf100KiBRoundTripsByteForByte() async throws {
        let db = try await live().connect()
        let namespace = unique("sw_cache")
        // Larger than one TCP segment: the case a single-read client passes locally
        // and corrupts in production.
        var bytes = [UInt8]()
        bytes.reserveCapacity(100 * 1024)
        for index in 0..<(100 * 1024) {
            bytes.append(UInt8((index &* 31 &+ 7) % 256))
        }
        let big = Data(bytes)
        try await db.cacheSet(namespace, "big", big)
        let read = try await db.cacheGet(namespace, "big")
        XCTAssertEqual(read, big)

        let miss = try await db.cacheGet(namespace, "absent")
        XCTAssertNil(miss, "a miss is nil")
        try await db.cacheSet(namespace, "empty", Data())
        let empty = try await db.cacheGet(namespace, "empty")
        XCTAssertEqual(empty, Data(), "an empty value is not a miss")

        let exists = try await db.cacheExists(namespace, "big")
        XCTAssertTrue(exists)
        let deleted = try await db.cacheDelete(namespace, "big")
        XCTAssertTrue(deleted)
        let deletedAgain = try await db.cacheDelete(namespace, "big")
        XCTAssertFalse(deletedAgain, "deleting an absent key is false, not an error")

        _ = try await db.cacheClearNamespace(namespace)
        await db.close()
    }

    func testCacheCollectionsBehave() async throws {
        let db = try await live().connect()
        let namespace = unique("sw_coll")
        try await db.cachePing()

        let pushed = try await db.cacheRightPush(namespace, "q", [Data("a".utf8), Data("b".utf8)])
        XCTAssertEqual(pushed, 2)
        let prepended = try await db.cacheLeftPush(namespace, "q", [Data("z".utf8)])
        XCTAssertEqual(prepended, 3)
        let first = try await db.cacheLeftPop(namespace, "q")
        XCTAssertEqual(first, Data("z".utf8))

        let added = try await db.cacheSetAdd(namespace, "tags", [Data("swift".utf8), Data("db".utf8)])
        XCTAssertEqual(added, 2)
        let again = try await db.cacheSetAdd(namespace, "tags", [Data("swift".utf8)])
        XCTAssertEqual(again, 0, "an existing member adds nothing")
        let member = try await db.cacheSetContains(namespace, "tags", Data("db".utf8))
        XCTAssertTrue(member)

        // A field and a value that are not valid UTF-8 must survive, which is why
        // this API speaks bytes rather than text.
        let field = Data([0xff, 0x00, 0xfe])
        let value = Data([0x00, 0xc3, 0x28])
        _ = try await db.cacheHashSet(namespace, "h", [CachePair(field: field, value: value)])
        let readBack = try await db.cacheHashGet(namespace, "h", field)
        XCTAssertEqual(readBack, value)

        let id = try await db.cacheStreamAdd(namespace, "events", [CachePair("msg", "hi")])
        XCTAssertFalse(id.isEmpty)
        let entries = try await db.cacheStreamRange(namespace, "events")
        XCTAssertEqual(entries.first?.text()["msg"], "hi")

        let counter = try await db.cacheIncrement(namespace, "hits", by: 5)
        XCTAssertEqual(counter, 5)
        let locked = try await db.cacheSetNX(namespace, "lock", Data("1".utf8))
        XCTAssertTrue(locked)
        let lockedAgain = try await db.cacheSetNX(namespace, "lock", Data("2".utf8))
        XCTAssertFalse(lockedAgain, "set-if-absent is how a lock is taken")

        _ = try await db.cacheClearNamespace(namespace)
        await db.close()
    }

    func testDocumentsCanBeWrittenQueriedAndAggregated() async throws {
        let db = try await live().connect()
        let collection = unique("sw_docs")
        try await db.documentCreateCollection(collection)

        let id = try await db.documentInsert(collection, ["name": "widget", "price": 9, "kind": "tool"])
        _ = try await db.documentInsert(collection, ["name": "gadget", "price": 20, "kind": "tool"], id: "gadget")

        let gadget = try await db.documentGet(collection, id: "gadget")
        XCTAssertEqual(gadget?["name"]?.stringValue, "gadget")
        let missing = try await db.documentGet(collection, id: "missing")
        XCTAssertNil(missing, "an absent document is nil, not an empty map")

        let dear = try await db.documentFind(collection, .greaterThan("price", 10))
        XCTAssertEqual(dear.count, 1)
        let all = try await db.documentFind(collection)
        XCTAssertEqual(all.count, 2)

        try await db.documentUpdateOne(collection, id: "gadget", DocumentUpdate().increment("price", by: 5))
        let updated = try await db.documentGet(collection, id: "gadget")
        XCTAssertEqual(updated?["price"]?.intValue, 25)

        let counts = try await db.documentUpdateMany(
            collection, matching: .equal("kind", "tool"), DocumentUpdate().set("kind", "hardware"))
        XCTAssertEqual(counts.matched, 2)

        try await db.documentCreateIndex(collection, name: "by_name", field: "name", unique: true)
        let indexes = try await db.documentListIndexes(collection)
        XCTAssertTrue(indexes.contains { $0.name == "by_name" && $0.unique })
        try await db.documentDropIndex(collection, name: "by_name")

        let stats = try await db.documentAnalyze(collection)
        XCTAssertEqual(stats.documentCount, 2)

        let totals = try await db.documentAggregate(collection, [
            .match(.greaterThan("price", 1)),
            .group(by: .constant("all"), [("total", .sum("price")), ("n", .count)]),
        ])
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0]["total"]?.intValue, 34, "9 + 25")
        XCTAssertEqual(totals[0]["n"]?.intValue, 2)

        try await db.documentDelete(collection, id: id)
        try await db.documentDropCollection(collection)
        await db.close()
    }

    func testVectorsAreSearchableAndFilterable() async throws {
        let db = try await live().connect()
        let collection = unique("sw_vec")
        try await db.vectorCreateCollection(collection, dimension: 3, metric: .cosine)
        try await db.vectorUpsert(collection, id: "a", [0.1, 0.2, 0.3], metadata: ["kind": "doc"])
        try await db.vectorUpsert(collection, id: "b", [0.9, 0.1, 0.0], metadata: ["kind": "image"])

        let stored = try await db.vectorGet(collection, id: "a")
        XCTAssertEqual(stored?.vector.count, 3)
        XCTAssertEqual(stored?.metadata["kind"]?.stringValue, "doc")
        let absent = try await db.vectorGet(collection, id: "zz")
        XCTAssertNil(absent)

        let hits = try await db.vectorSearch(collection, [0.1, 0.2, 0.3], topK: 2)
        XCTAssertEqual(hits.first?.id, "a", "the nearest vector comes first")

        let filtered = try await db.vectorSearch(collection, [0.1, 0.2, 0.3], topK: 5, filter: ["kind": "image"])
        XCTAssertEqual(filtered.map(\.id), ["b"])

        let info = try await db.vectorDescribeCollection(collection)
        XCTAssertEqual(info.dimension, 3)
        XCTAssertEqual(info.count, 2)

        // A wrong-length vector is refused rather than padded or truncated.
        do {
            try await db.vectorUpsert(collection, id: "bad", [1.0, 2.0])
            XCTFail("a dimension mismatch must be refused")
        } catch let error as TriCoreError {
            XCTAssertEqual(error.kind, .server)
        }

        try await db.vectorDelete(collection, id: "a")
        try await db.vectorDropCollection(collection)
        await db.close()
    }

    func testGraphsTraverseAndFindPaths() async throws {
        let db = try await live().connect()
        let graph = unique("sw_graph")
        try await db.graphCreate(graph)
        for id in ["u1", "u2", "u3"] {
            try await db.graphAddNode(graph, id: id, labels: ["User"])
        }
        try await db.graphAddEdge(graph, id: "e1", from: "u1", to: "u2", label: "FOLLOWS",
                                  properties: ["weight": 1.0])
        try await db.graphAddEdge(graph, id: "e2", from: "u2", to: "u3", label: "FOLLOWS",
                                  properties: ["weight": 1.0])

        let node = try await db.graphGetNode(graph, id: "u1")
        XCTAssertEqual(node?.labels, ["User"])
        let nobody = try await db.graphGetNode(graph, id: "nobody")
        XCTAssertNil(nobody)

        let neighbours = try await db.graphNeighbors(graph, of: "u1")
        XCTAssertEqual(neighbours.count, 1)
        XCTAssertEqual(neighbours.first?.nodeID, "u2")

        let degree = try await db.graphDegree(graph, of: "u2", direction: .both)
        XCTAssertEqual(degree, 2)

        let walk = try await db.graphTraverse(graph, from: "u1", maxDepth: 5)
        XCTAssertTrue(walk.nodes.contains { $0.id == "u3" })

        let path = try await db.graphShortestPath(graph, from: "u1", to: "u3")
        XCTAssertTrue(path.found)
        XCTAssertEqual(path.nodePath, ["u1", "u2", "u3"])

        let weighted = try await db.graphWeightedShortestPath(graph, from: "u1", to: "u3")
        XCTAssertTrue(weighted.found)
        XCTAssertEqual(weighted.totalCost, 2.0)

        // No path is an answer, not an error.
        let backwards = try await db.graphShortestPath(graph, from: "u3", to: "u1")
        XCTAssertFalse(backwards.found)

        try await db.graphDeleteEdge(graph, id: "e1")
        try await db.graphDeleteNode(graph, id: "u1")
        try await db.graphDrop(graph)
        await db.close()
    }

    func testContextExportsRenderInTheFormatAskedFor() async throws {
        let db = try await live().connect()
        let table = unique("sw_llm")
        try await db.execute("CREATE TABLE \(table) (id INT PRIMARY KEY, name TEXT)")
        try await db.execute("INSERT INTO \(table) VALUES (?, ?)", [1, "ada"])

        let bundle = try await db.llmContext([.sql("SELECT id, name FROM \(table)")], format: .toon)
        XCTAssertTrue(bundle.contains("ada"), "the bundle holds the row: \(bundle)")

        let schema = try await db.llmSchema(format: .markdown)
        XCTAssertFalse(schema.isEmpty)

        try await db.execute("DROP TABLE \(table)")
        await db.close()
    }

    func testADisabledModuleIsRefusedByName() async throws {
        let db = try await live().connect()
        // The test server runs without the cluster module, so the admin plane says so
        // rather than pretending to be healthy.
        do {
            try await db.adminPing()
            XCTFail("cluster is off in the test configuration")
        } catch let error as TriCoreError {
            XCTAssertEqual(error.kind, .server)
            XCTAssertNotNil(error.code)
        }
        try await db.ping()
        await db.close()
    }

    func testAPoolServesSeveralTasksAtOnce() async throws {
        let server = try live()
        let table = unique("sw_pool")
        let pool = TriCorePool(options: server.options(), size: 4)

        try await pool.withConnection { db in
            try await db.execute("CREATE TABLE \(table) (id INT PRIMARY KEY)")
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 1...8 {
                group.addTask { () async throws -> Void in
                    try await pool.withConnection { (db: TriCore) async throws -> Void in
                        try await db.execute("INSERT INTO \(table) VALUES (?)", [.int(Int64(id))])
                    }
                }
            }
            try await group.waitForAll()
        }

        try await pool.withConnection { db in
            let rows = try await db.query("SELECT COUNT(*) FROM \(table)")
            XCTAssertEqual(rows[0][0], "8")
            try await db.execute("DROP TABLE \(table)")
        }

        let stats = await pool.stats
        XCTAssertEqual(stats.lent, 0, "every connection came back")
        await pool.close()
    }

    func testAPooledConnectionIsNeverReturnedMidTransaction() async throws {
        let server = try live()
        let table = unique("sw_pool_txn")
        let pool = TriCorePool(options: server.options(), size: 2)

        try await pool.withConnection { db in
            try await db.execute("CREATE TABLE \(table) (id INT PRIMARY KEY)")
        }

        do {
            try await pool.withConnection { db in
                _ = try await db.begin()
                try await db.execute("INSERT INTO \(table) VALUES (?)", [1])
            }
            XCTFail("leaving a transaction open must be reported")
        } catch let error as TriCoreError {
            XCTAssertTrue(error.message.contains("rolled back"), error.message)
        }

        try await pool.withConnection { db in
            let rows = try await db.query("SELECT COUNT(*) FROM \(table)")
            XCTAssertEqual(rows[0][0], "0", "the write was rolled back")
            try await db.execute("DROP TABLE \(table)")
        }
        await pool.close()
    }
}
