import Foundation
import XCTest

@testable import TriCoreDB

/// The operations added for server 0.1.0-rc.3, against a real server.
///
/// Without a server every test skips, with the reason printed.
final class LiveOperationsTests: XCTestCase {
    private func live() throws -> LiveServer {
        if let reason = LiveServer.skipReason { throw XCTSkip(reason) }
        return LiveServer.shared!
    }

    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func text(_ data: Data?) -> String? { data.flatMap { String(data: $0, encoding: .utf8) } }

    private func assertRefused(
        _ what: String, containing fragment: String = "", _ work: () async throws -> Void
    ) async {
        do {
            try await work()
            XCTFail("the server must refuse: \(what)")
        } catch let error as TriCoreError {
            XCTAssertEqual(error.kind, .server, what)
            if !fragment.isEmpty { XCTAssertTrue(error.message.contains(fragment), error.message) }
        } catch {
            XCTFail("\(what): \(error)")
        }
    }

    func testANestedBeginOpensABlockTheOuterTransactionOutlives() async throws {
        let db = try await live().connect()
        let table = unique("nested")
        try await db.execute("CREATE TABLE \(table) (id INT PRIMARY KEY, n INT)")

        try await db.begin()
        try await db.execute("INSERT INTO \(table) VALUES (?, ?)", [1, 1])
        let inner = try await db.begin()
        XCTAssertEqual(inner.nestedDepth, 1)
        try await db.execute("INSERT INTO \(table) VALUES (?, ?)", [2, 2])
        try await db.rollback()
        var open = await db.inTransaction
        XCTAssertTrue(open, "the rollback ended the inner block, not the transaction")

        try await db.begin()
        try await db.execute("INSERT INTO \(table) VALUES (?, ?)", [3, 3])
        try await db.commit()
        open = await db.inTransaction
        XCTAssertTrue(open, "the commit released the inner block, not the transaction")

        try await db.commit()
        open = await db.inTransaction
        XCTAssertFalse(open)
        let rows = try await db.query("SELECT id FROM \(table) ORDER BY id")
        XCTAssertEqual(rows.rows, [["1"], ["3"]], "the outer write and the committed block survive")
        try await db.execute("DROP TABLE \(table)")
        await db.close()
    }

    func testSortedSetsLocksBitmapsAndHyperLogLogs() async throws {
        let db = try await live().connect()
        let ns = unique("zset")
        let added = try await db.cacheSortedAdd(
            ns, "z", [ScoredMember("a", score: 1.5), ScoredMember("b", score: 2), ScoredMember("c", score: 3)])
        XCTAssertEqual(added["added"]?.intValue, 3)
        var count = try await db.cacheSortedCount(ns, "z")
        XCTAssertEqual(count, 3)
        var score = try await db.cacheSortedScore(ns, "z", member: bytes("a"))
        XCTAssertEqual(score, 1.5)
        score = try await db.cacheSortedScore(ns, "z", member: bytes("nobody"))
        XCTAssertNil(score)
        var rank = try await db.cacheSortedRank(ns, "z", member: bytes("c"), rev: true)
        XCTAssertEqual(rank, 0)
        rank = try await db.cacheSortedRank(ns, "z", member: bytes("nobody"))
        XCTAssertNil(rank)
        let all = try await db.cacheSortedRange(ns, "z", start: 0, stop: -1, withScores: true)
        XCTAssertEqual(all.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(all.map(\.score), [1.5, 2.0, 3.0])
        let middle = try await db.cacheSortedRangeByScore(
            ns, "z", min: .exclusive(1.5), max: .highest, limit: (0, 1))
        XCTAssertEqual(middle.map(\.text), ["b"])
        XCTAssertNil(middle.first?.score, "scores were not asked for")
        let everything = try await db.cacheSortedRangeByScore(ns, "z", min: .lowest, max: .highest)
        XCTAssertEqual(everything.count, 3)
        let bumped = try await db.cacheSortedIncrement(ns, "z", member: bytes("a"), by: 2.25)
        XCTAssertEqual(bumped, 3.75)
        count = try await db.cacheSortedRemove(ns, "z", [bytes("c"), bytes("nobody")])
        XCTAssertEqual(count, 1)

        let first = try await db.cacheLockAcquire(ns, "job", owner: "worker-1", ttl: .seconds(30))
        XCTAssertEqual(first["acquired"]?.boolValue, true)
        let second = try await db.cacheLockAcquire(ns, "job", owner: "worker-2", ttl: .seconds(30))
        XCTAssertEqual(second["acquired"]?.boolValue, false)
        XCTAssertEqual(second["holder"]?.stringValue, "worker-1")
        let renewed = try await db.cacheLockRenew(ns, "job", owner: "worker-1", ttl: .seconds(30))
        XCTAssertEqual(renewed["token"]?.intValue, first["token"]?.intValue)
        var released = try await db.cacheLockRelease(ns, "job", owner: "worker-2")
        XCTAssertFalse(released)
        released = try await db.cacheLockRelease(ns, "job", owner: "worker-1")
        XCTAssertTrue(released)
        let next = try await db.cacheLockAcquire(ns, "job", owner: "worker-2", ttl: .seconds(30))
        XCTAssertGreaterThan(next["token"]?.intValue ?? 0, first["token"]?.intValue ?? 0)

        var bit = try await db.cacheSetBit(ns, "a", offset: 7, value: true)
        XCTAssertEqual(bit, 0)
        bit = try await db.cacheGetBit(ns, "a", offset: 7)
        XCTAssertEqual(bit, 1)
        count = try await db.cacheBitCount(ns, "a", range: (0, 0))
        XCTAssertEqual(count, 1)
        count = try await db.cacheBitPosition(ns, "a", bit: true)
        XCTAssertEqual(count, 7)
        try await db.cacheSetBit(ns, "b", offset: 0, value: true)
        count = try await db.cacheBitOperation(ns, op: .or, dest: "c", keys: ["a", "b"])
        XCTAssertEqual(count, 1)
        let combined = try await db.cacheGet(ns, "c")
        XCTAssertEqual(combined, Data([0x81]))

        let changed = try await db.cacheHyperLogLogAdd(ns, "x", [bytes("a"), bytes("b"), bytes("c")])
        XCTAssertTrue(changed)
        try await db.cacheHyperLogLogAdd(ns, "y", [bytes("c"), bytes("d")])
        count = try await db.cacheHyperLogLogCount(ns, ["x", "y"])
        XCTAssertEqual(count, 4)
        try await db.cacheHyperLogLogMerge(ns, dest: "all", sources: ["x", "y"])
        count = try await db.cacheHyperLogLogCount(ns, ["all"])
        XCTAssertEqual(count, 4)
        await db.close()
    }

    func testManyKeysConditionalWritesFreshReadsAndCollections() async throws {
        let db = try await live().connect()
        let ns = unique("multi")
        var count = try await db.cacheSetMany(ns, ["a": bytes("1"), "b": bytes("2")])
        XCTAssertEqual(count, 2)
        let values = try await db.cacheGetMany(ns, ["a", "missing", "b", "a"])
        XCTAssertEqual(values.map(text), ["1", nil, "2", "1"])
        let warmed = try await db.cacheWarm(ns, ["a": bytes("other"), "c": bytes("3")])
        XCTAssertEqual(warmed["written"]?.intValue, 1)
        XCTAssertEqual(warmed["alreadyCached"]?.intValue, 1)

        var wrote = try await db.cacheSetIf(ns, "k", bytes("v1"), condition: .ifPresent)
        XCTAssertFalse(wrote)
        wrote = try await db.cacheSetIf(ns, "k", bytes("v1"), condition: .ifAbsent)
        XCTAssertTrue(wrote)
        wrote = try await db.cacheSetIf(ns, "k", bytes("v2"), condition: .ifPresent, expiry: .after(.seconds(300)))
        XCTAssertTrue(wrote)
        var ttl = try await db.cacheTTL(ns, "k")
        XCTAssertNotNil(ttl)
        var value = try await db.cacheGetAndExpire(ns, "k", expiry: .clear)
        XCTAssertEqual(text(value), "v2")
        ttl = try await db.cacheTTL(ns, "k")
        XCTAssertNil(ttl)
        value = try await db.cacheGetAndSet(ns, "k", bytes("v3"))
        XCTAssertEqual(text(value), "v2")
        count = try await db.cacheAppend(ns, "k", bytes("!"))
        XCTAssertEqual(count, 3)
        value = try await db.cacheGetAndDelete(ns, "k")
        XCTAssertEqual(text(value), "v3!")
        value = try await db.cacheGetAndDelete(ns, "k")
        XCTAssertNil(value)

        var swap = try await db.cacheCompareAndSwap(ns, "cas", expected: nil, value: bytes("one"))
        XCTAssertEqual(swap["swapped"]?.boolValue, true)
        swap = try await db.cacheCompareAndSwap(ns, "cas", expected: bytes("wrong"), value: bytes("two"))
        XCTAssertEqual(swap["swapped"]?.boolValue, false)
        XCTAssertEqual(swap["current"]?.stringValue, "one")
        swap = try await db.cacheCompareAndSwap(ns, "cas", expected: bytes("one"), value: nil)
        XCTAssertEqual(swap["swapped"]?.boolValue, true)
        try await db.cacheSet(ns, "e", "x")
        let expiring = try await db.cacheExpireAt(ns, "e", at: Date().addingTimeInterval(300))
        XCTAssertEqual(expiring["updated"]?.boolValue, true)

        let miss = try await db.cacheGetFresh(ns, "f", owner: "me", lease: .seconds(5))
        XCTAssertEqual(miss.state, "miss")
        XCTAssertTrue(miss.lease, "the first caller computes the value")
        let until = try await db.cacheSetFresh(ns, "f", bytes("v"), freshFor: .seconds(60))
        XCTAssertGreaterThan(until, Int(Date().timeIntervalSince1970 * 1000))
        let fresh = try await db.cacheGetFresh(ns, "f", owner: "me", lease: .seconds(5))
        XCTAssertEqual(fresh.state, "fresh")
        XCTAssertEqual(fresh.text, "v")
        let binary = Data([0, 159, 146, 150])
        try await db.cacheSetFresh(ns, "bin", binary, freshFor: .seconds(60))
        let read = try await db.cacheGetFresh(ns, "bin", owner: "me", lease: .seconds(5))
        XCTAssertEqual(read.value, binary, "bytes that are not UTF-8 survive")
        try await db.cacheSetFresh(ns, "old", bytes("v"), freshFor: .milliseconds(1), ttl: .seconds(60))
        try await Task.sleep(for: .milliseconds(50))
        let stale = try await db.cacheGetFresh(ns, "old", owner: "me", lease: .seconds(5))
        XCTAssertEqual(stale.state, "stale")
        XCTAssertTrue(stale.refresh)
        try await db.cacheSetMissing(ns, "gone", ttl: .seconds(60))
        let missing = try await db.cacheGetFresh(ns, "gone", owner: "me", lease: .seconds(5))
        XCTAssertEqual(missing.state, "missing")

        _ = try await db.cacheRightPush(ns, "src", [bytes("a"), bytes("b"), bytes("c")])
        value = try await db.cacheListMove(ns, source: "src", destination: "dst", from: .left, to: .right)
        XCTAssertEqual(text(value), "a")
        let trimmed = try await db.cacheListTrim(ns, "src", start: 0, stop: 0)
        XCTAssertEqual(trimmed["length"]?.intValue, 1)
        let popped = try await db.cacheBlockingLeftPop(ns, ["empty", "dst"], timeout: .milliseconds(100))
        XCTAssertEqual(popped?.key, "dst")
        XCTAssertEqual(text(popped?.value), "a")
        let nothing = try await db.cacheBlockingRightPop(ns, ["empty"], timeout: .milliseconds(100))
        XCTAssertNil(nothing)

        _ = try await db.cacheSetAdd(ns, "s1", [bytes("a"), bytes("b")])
        _ = try await db.cacheSetAdd(ns, "s2", [bytes("b"), bytes("c")])
        var members = try await db.cacheSetUnion(ns, ["s1", "s2"])
        XCTAssertEqual(members.map(text), ["a", "b", "c"])
        members = try await db.cacheSetIntersection(ns, ["s1", "s2"])
        XCTAssertEqual(members.map(text), ["b"])
        members = try await db.cacheSetDifference(ns, ["s1", "s2"])
        XCTAssertEqual(members.map(text), ["a"])
        members = try await db.cacheSetRandomMembers(ns, "s1", count: -5)
        XCTAssertEqual(members.count, 5)
        count = try await db.cacheHashIncrement(ns, "h", field: bytes("n"), by: 5)
        XCTAssertEqual(count, 5)
        await db.close()
    }

    func testPipelinesScriptsPubSubLimitsAndStats() async throws {
        let server = try live()
        let db = try await server.connect()
        let ns = unique("pipe")
        let results = try await db.cachePipeline([
            .set(ns, "k", bytes("x")), .get(ns, "k"), .increment(ns, "k"), .exists(ns, "k"), .ping,
        ])
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(results[0].data["set"]?.boolValue, true)
        XCTAssertEqual(text(results[1].value), "x")
        XCTAssertFalse(results[2].isOK, "x is not a number")
        XCTAssertEqual(results[3].data["exists"]?.boolValue, true, "a failing operation does not stop the rest")
        let atomic = try await db.cacheTransaction([.set(ns, "n", bytes("1")), .increment(ns, "n", by: 4)])
        XCTAssertEqual(atomic[1].data["value"]?.intValue, 5)

        let script = unique("script")
        try await db.cacheScriptLoad(name: script, ops: [.set(ns, "$1", bytes("$2")), .get(ns, "$1")])
        let ran = try await db.cacheScriptRun(name: script, args: ["sk", "sv"])
        XCTAssertEqual(text(ran[1].value), "sv")

        let channel = unique("channel")
        let first = try await db.cachePublish(channel: channel, message: "hello")
        let second = try await db.cachePublish(channel: channel, message: "again")
        let polled = try await db.cachePoll([channel], after: first - 1)
        XCTAssertEqual(polled["messages"]?.arrayValue?.compactMap { $0["message"]?.stringValue }, ["hello", "again"])
        XCTAssertEqual(polled["next"]?.intValue, second)

        let limited = unique("limit")
        let limit = try await db.cacheSetNamespaceLimit(limited, maxKeys: 1)
        XCTAssertEqual(limit["max_keys"]?.intValue, 1)
        try await db.cacheSet(limited, "a", "x")
        await assertRefused("a second key past the limit") { try await db.cacheSet(limited, "b", "x") }
        let held = try await db.cacheGetNamespaceLimit(limited)
        XCTAssertEqual(held["keys"]?.intValue, 1)
        try await db.cacheSetNamespaceLimit(limited)
        try await db.cacheSet(limited, "b", "x")
        let stats = try await db.cacheStats()
        XCTAssertNotNil(stats["hits"]?.intValue)

        do {
            _ = try await db.cacheHotKeys(limit: 3)
        } catch let error as TriCoreError {
            XCTAssertTrue(error.message.contains("tracking is off"), error.message)
        }
        await db.close()

        // These two act on a whole database, so they get one nobody else uses.
        var options = server.options()
        options.database = unique("db")
        let own = try await TriCore.connect(options)
        try await own.cacheSet("n", "keep", "x")
        try await own.cacheSet("n", "gone", "x", ttl: .milliseconds(1))
        try await Task.sleep(for: .milliseconds(50))
        let purged = try await own.cachePurgeExpired()
        XCTAssertEqual(purged, 1)
        let cleared = try await own.cacheFlushDatabase()
        XCTAssertEqual(cleared, 1)
        await own.close()
    }

    func testDocumentsBulkWritesOptionsAndTransactions() async throws {
        let db = try await live().connect()
        let collection = unique("docs")
        try await db.documentCreateCollection(collection)
        let ids = try await db.documentInsertMany(collection, [
            ["_id": "a", "n": 1, "city": "Pune"], ["n": 2, "city": "Pune"], ["_id": "c", "n": 3, "city": "Delhi"],
        ])
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids.first, "a")

        let replaced = try await db.documentReplace(collection, id: "a", document: ["n": 10], returnDocument: .after)
        XCTAssertEqual(replaced["document"]?["n"]?.intValue, 10)
        XCTAssertNil(replaced["document"]?["city"], "a replace keeps nothing of the old body")
        await assertRefused("replacing a document that is not there") {
            try await db.documentReplace(collection, id: "nobody", document: ["n": 1])
        }
        let upserted = try await db.documentReplace(collection, id: "new", document: ["n": 5], upsert: true)
        XCTAssertEqual(upserted["inserted"]?.boolValue, true)

        let bulk = try await db.documentBulkWrite(collection, [
            .insert(["n": 1], id: "b1"),
            .insert(["n": 2]),
            .updateOne(id: "b1", DocumentUpdate().set("n", 5).increment("m", by: 1)),
            .updateOne(id: "b9", DocumentUpdate().set("n", 9), upsert: true),
            .replace(id: "a", ["n": 7]),
            .delete(id: "new"),
        ])
        XCTAssertEqual(bulk["inserted"]?.intValue, 2)
        XCTAssertEqual(bulk["updated"]?.intValue, 1)
        XCTAssertEqual(bulk["upserted"]?.intValue, 1)
        XCTAssertEqual(bulk["replaced"]?.intValue, 1)
        XCTAssertEqual(bulk["deleted"]?.intValue, 1)
        await assertRefused("a batch with one bad operation") {
            try await db.documentBulkWrite(collection, [.insert(["n": 1], id: "fresh"), .insert(["n": 1], id: "b1")])
        }
        let leftover = try await db.documentGet(collection, id: "fresh")
        XCTAssertNil(leftover, "one refused operation leaves nothing of the batch behind")

        let deleted = try await db.documentDeleteMany(collection, filter: .equal("city", "Delhi"))
        XCTAssertEqual(deleted, 1)
        let plan = try await db.documentExplain(collection, filter: .equal("city", "Pune"), limit: 5)
        XCTAssertEqual(plan["rows_returned"]?.intValue, 1)
        try await db.documentCreateIndex(collection, name: "by_n", field: "n")
        let rebuilt = try await db.documentRebuildIndex(collection, indexName: "by_n")
        XCTAssertEqual(rebuilt["rebuilt"]?.stringValue, "by_n")
        let purged = try await db.documentPurgeExpired(collection)
        XCTAssertEqual(purged, 0)
        try await db.documentRenameCollection(collection, to: collection + "_renamed")
        let moved = try await db.documentGet(collection + "_renamed", id: "a")
        XCTAssertNotNil(moved)
        try await db.documentDropCollection(collection + "_renamed")

        let versioned = unique("opts")
        try await db.documentCreateCollection(versioned)
        try await db.documentSetCollectionOptions(versioned, options: [
            "schema": ["required": ["n"], "fields": ["n": ["type": "number", "minimum": 0]]],
            "defaults": ["status": "new"],
            "versioned": true,
        ])
        let options = try await db.documentGetCollectionOptions(versioned)
        XCTAssertEqual(options["versioned"]?.boolValue, true)
        _ = try await db.documentInsert(versioned, ["n": 1], id: "v")
        let stored = try await db.documentGet(versioned, id: "v")
        XCTAssertEqual(stored?["status"]?.stringValue, "new")
        XCTAssertEqual(stored?["_version"]?.intValue, 1)
        await assertRefused("a document that breaks the schema") {
            _ = try await db.documentInsert(versioned, ["x": 1])
        }
        try await db.documentReplace(versioned, id: "v", document: ["n": 2], expectedVersion: 1)
        await assertRefused("a stale version", containing: "version conflict") {
            try await db.documentReplace(versioned, id: "v", document: ["n": 3], expectedVersion: 1)
        }

        let txn = try await db.documentBeginTransaction()
        try await db.documentInsertMany(versioned, [["_id": "t1", "n": 1]], txn: txn)
        var outside = try await db.documentGet(versioned, id: "t1")
        XCTAssertNil(outside, "nobody else sees the write before it commits")
        let committed = try await db.documentCommitTransaction(txn: txn)
        XCTAssertEqual(committed["committed"]?.boolValue, true)
        outside = try await db.documentGet(versioned, id: "t1")
        XCTAssertNotNil(outside)

        let discarded = try await db.documentBeginTransaction(serializable: true)
        try await db.documentInsertMany(versioned, [["_id": "t2", "n": 1]], txn: discarded)
        try await db.documentRollbackTransaction(txn: discarded)
        outside = try await db.documentGet(versioned, id: "t2")
        XCTAssertNil(outside)
        await assertRefused("committing a discarded transaction") {
            try await db.documentCommitTransaction(txn: discarded)
        }
        try await db.documentDropCollection(versioned)
        await db.close()
    }

    func testVectorsBatchesNamedVectorsAndAliases() async throws {
        let db = try await live().connect()
        let collection = unique("vec")
        try await db.vectorCreateCollection(collection, dimension: 3)
        var count = try await db.vectorUpsertMany(collection, [
            ["id": "a", "vector": [1.0, 0.0, 0.0], "metadata": ["kind": "x", "_namespace": "n1"]],
            ["id": "b", "vector": [0.0, 1.0, 0.0], "metadata": ["kind": "y", "_namespace": "n1"]],
            ["id": "c", "vector": [0.0, 0.0, 1.0]],
            ["id": "d", "vector": [0.9, 0.1, 0.0], "metadata": ["kind": "x", "_namespace": "n2"]],
        ])
        XCTAssertEqual(count, 4)

        let batches = try await db.vectorSearchBatch(collection, [[1, 0, 0], [0, 1, 0]], topK: 2)
        XCTAssertEqual(batches.map { $0.first?.id }, ["a", "b"])
        let exact = try await db.vectorSearchBatch(
            collection, [[1, 0, 0]], topK: 2, filter: ["kind": "x"], includeVectors: true,
            options: VectorSearchOptions(exact: true, namespace: "n1", explain: true))
        XCTAssertEqual(exact.first?.map(\.id), ["a"])
        XCTAssertEqual(exact.first?.first?.vector, [1, 0, 0])
        XCTAssertNotNil(exact.first?.first?.reason)

        count = try await db.vectorCount(collection, filter: ["kind": "x"])
        XCTAssertEqual(count, 2)
        count = try await db.vectorUpdateByFilter(collection, filter: ["kind": "x"], set: ["seen": true])
        XCTAssertEqual(count, 2)
        let partitions = try await db.vectorListPartitions(collection)
        XCTAssertEqual(partitions["partitions"]?.arrayValue?.count, 2)
        XCTAssertEqual(partitions["unpartitioned"]?.intValue, 1)

        let fused = try await db.vectorSearchMulti(collection, [[1, 0, 0], [0, 1, 0]], topK: 3, fusion: .max)
        XCTAssertEqual(fused.first?.matched, 2)
        let alike = try await db.vectorSearchByExamples(
            collection, topK: 2, positive: [.id("a"), .vector([0, 1, 0])], negative: [.id("c")])
        XCTAssertFalse(alike.map(\.id).contains("a"), "an example named by id is left out")
        let including = try await db.vectorSearchByExamples(
            collection, topK: 1, positive: [.id("a")], excludeExamples: false)
        XCTAssertEqual(including.first?.id, "a")

        count = try await db.vectorDeleteMany(collection, ids: ["c", "nobody"])
        XCTAssertEqual(count, 1)
        count = try await db.vectorDeleteByFilter(collection, filter: ["kind": "y"])
        XCTAssertEqual(count, 1)
        await assertRefused("deleting by an empty filter") {
            try await db.vectorDeleteByFilter(collection, filter: [:])
        }
        let stats = try await db.vectorIndexStats(collection)
        XCTAssertEqual(stats["stored"]?.intValue, 2)
        let rebuilt = try await db.vectorRebuildIndex(collection)
        XCTAssertEqual(rebuilt["rebuilt"]?.boolValue, true)
        let recall = try await db.vectorMeasureRecall(collection, sample: 2)
        XCTAssertNotNil(recall["recall"]?.doubleValue)

        try await db.vectorCopyCollection(collection, to: collection + "_copy")
        try await db.vectorRenameCollection(collection + "_copy", to: collection + "_renamed")
        count = try await db.vectorCount(collection + "_renamed")
        XCTAssertEqual(count, 2)
        try await db.vectorDropCollection(collection + "_renamed")
        try await db.vectorDropCollection(collection)

        let named = unique("named")
        try await db.vectorCreateCollection(named, dimension: 3)
        let configured = try await db.vectorSetCollectionConfig(named, normalize: true, m: 8, efConstruction: 100)
        XCTAssertEqual(configured["normalize"]?.boolValue, true)
        XCTAssertEqual(configured["m"]?.intValue, 8)
        try await db.vectorAddNamedVector(named, name: "title", dimension: 2, metric: .dot)
        try await db.vectorUpsertNamed(
            named, id: "n1", vectors: ["default": [1, 0, 0], "title": [1, 0]], metadata: ["kind": "named"])
        let alias = unique("alias")
        try await db.vectorSetAlias(alias: alias, collection: named)
        var aliases = try await db.vectorListAliases()
        XCTAssertTrue(aliases.contains { $0["alias"]?.stringValue == alias && $0["collection"]?.stringValue == named })
        count = try await db.vectorCount(alias)
        XCTAssertEqual(count, 1, "an operation naming the alias acts on the collection")
        try await db.vectorSetAlias(alias: alias)
        aliases = try await db.vectorListAliases()
        XCTAssertFalse(aliases.contains { $0["alias"]?.stringValue == alias })
        try await db.vectorDropCollection(named)

        let embedded = try await db.vectorEmbed(["hello world", "goodbye"], dimension: 4)
        XCTAssertEqual(embedded["vectors"]?.arrayValue?.count, 2)
        let texts = unique("text")
        try await db.vectorCreateCollection(texts, dimension: 8)
        count = try await db.vectorUpsertText(texts, [
            ["id": "t1", "text": "the quick brown fox"], ["id": "t2", "text": "lazy dog"],
        ])
        XCTAssertEqual(count, 2)
        let stored = try await db.vectorGet(texts, id: "t1")
        XCTAssertEqual(stored?.metadata["text"]?.stringValue, "the quick brown fox")
        try await db.vectorDropCollection(texts)
        await db.close()
    }

    func testGraphsBulkWritesAlgorithmsSchemaAndTransactions() async throws {
        let db = try await live().connect()
        let graph = unique("graph")
        try await db.graphCreate(graph)
        let added = try await db.graphAddMany(
            graph,
            nodes: [
                ["id": "a", "labels": ["Person"], "properties": ["name": "ada", "age": 36]],
                ["id": "b", "labels": ["Person"], "properties": ["name": "bob"]],
                ["id": "c", "labels": ["Person"], "properties": ["name": "cy"]],
                ["id": "d"],
                ["id": "e", "labels": ["City"]],
            ],
            edges: [
                ["id": "e1", "from": "a", "to": "b", "label": "KNOWS", "properties": ["w": 1]],
                ["id": "e2", "from": "b", "to": "c", "label": "KNOWS", "properties": ["w": 2]],
                ["id": "e3", "from": "c", "to": "a", "label": "KNOWS"],
                ["id": "e4", "from": "a", "to": "c", "label": "LIKES"],
                ["id": "e5", "from": "c", "to": "d", "label": "KNOWS"],
            ])
        XCTAssertEqual(added["nodes"]?.intValue, 5)
        XCTAssertEqual(added["edges"]?.intValue, 5)

        let node = try await db.graphUpdateNode(
            graph, id: "a", properties: ["age": nil, "city": "Pune"], addLabels: ["Admin"])
        XCTAssertEqual(node["labels"]?.arrayValue?.compactMap(\.stringValue), ["Person", "Admin"])
        XCTAssertNil(node["properties"]?["age"])
        let edge = try await db.graphUpdateEdge(graph, id: "e4", properties: ["since": 2020], label: "LOVES")
        XCTAssertEqual(edge["label"]?.stringValue, "LOVES")

        let walk = try await db.graphDfs(graph, start: "a")
        XCTAssertEqual(walk["order"]?.stringValue, "depth_first")
        XCTAssertEqual(walk["count"]?.intValue, 4)
        let weak = try await db.graphConnectedComponents(graph)
        XCTAssertEqual(weak["largest"]?.intValue, 4)
        let strong = try await db.graphConnectedComponents(graph, kind: .strong, label: "KNOWS")
        XCTAssertEqual(strong["largest"]?.intValue, 3)
        var cycle = try await db.graphDetectCycle(graph)
        XCTAssertEqual(cycle["hasCycle"]?.boolValue, true)
        cycle = try await db.graphDetectCycle(graph, directed: false, label: "LOVES")
        XCTAssertEqual(cycle["hasCycle"]?.boolValue, false)
        let stats = try await db.graphStats(graph)
        XCTAssertEqual(stats["edgeTypes"]?["KNOWS"]?.intValue, 4)
        let schema = try await db.graphSchema(graph)
        XCTAssertEqual(schema["nodes"]?.intValue, 5)
        let sub = try await db.graphSubgraph(graph, ["a"])
        XCTAssertEqual(sub["node_count"]?.intValue, 3)
        XCTAssertEqual(sub["edge_count"]?.intValue, 4)
        let weighted = try await db.graphKShortestPaths(
            graph, from: "a", to: "c", k: 2, label: "KNOWS", weightProperty: "w")
        XCTAssertEqual(weighted["paths"]?[0]?["cost"]?.doubleValue, 3.0)
        let paths = try await db.graphAllPaths(graph, from: "a", to: "c")
        XCTAssertEqual(paths["complete"]?.boolValue, true)
        XCTAssertEqual(paths["count"]?.intValue, 2)
        for measure in [CentralityMeasure.betweenness, .closeness, .eigenvector] {
            let central = try await db.graphCentrality(graph, measure: measure, limit: 3)
            XCTAssertEqual(central["results"]?.arrayValue?.count, 3, measure.rawValue)
        }
        let communities = try await db.graphCommunities(graph)
        XCTAssertEqual(communities["algorithm"]?.stringValue, "louvain")
        let triangles = try await db.graphTriangleCount(graph)
        XCTAssertEqual(triangles["triangles"]?.intValue, 1)
        let similar = try await db.graphNodeSimilarity(graph, node: "a", metric: .overlap, limit: 1)
        XCTAssertEqual(similar["results"]?.arrayValue?.count, 1)
        let ranks = try await db.graphPageRank(graph, damping: 0.9, limit: 2)
        XCTAssertEqual(ranks["ranks"]?.arrayValue?.count, 2)
        let consistency = try await db.graphCheckConsistency(graph)
        XCTAssertEqual(consistency["consistent"]?.boolValue, true)

        let removed = try await db.graphRemoveMany(graph, nodes: ["d", "nobody"], edges: ["e4"], detach: true)
        XCTAssertEqual(removed["nodes_removed"]?.intValue, 1)
        XCTAssertEqual(removed["edges_removed"]?.intValue, 2)
        let copied = try await db.graphCopy(graph, to: graph + "_copy")
        XCTAssertEqual(copied["nodes"]?.intValue, 4)
        await assertRefused("copying onto a graph that exists") { try await db.graphCopy(graph, to: graph + "_copy") }
        try await db.graphDrop(graph + "_copy")
        try await db.graphDrop(graph)

        let schemaGraph = unique("schema")
        try await db.graphCreate(schemaGraph)
        try await db.graphImportCsv(
            schemaGraph, nodes: "id,labels,name\nx1,Person,xena\nx2,Person,yuri\n",
            edges: "id,from,to,label\nxe1,x1,x2,KNOWS\n")
        try await db.graphCreateNodeIndex(schemaGraph, name: "by_name", properties: ["name"], label: "Person")
        try await db.graphCreateConstraint(
            schemaGraph, name: "unique_name", label: "Person", property: "name", kind: .unique)
        let objects = try await db.graphListSchemaObjects(schemaGraph)
        XCTAssertEqual(objects["indexes"]?[0]?["name"]?.stringValue, "by_name")
        XCTAssertEqual(objects["constraints"]?[0]?["kind"]?.stringValue, "unique")
        let found = try await db.graphFindNodes(schemaGraph, label: "Person", properties: ["name": "xena"])
        XCTAssertEqual(found["count"]?.intValue, 1)
        XCTAssertEqual(found["plan"]?.stringValue?.contains("by_name"), true)
        await assertRefused("a second xena under a unique constraint") {
            try await db.graphAddNode(schemaGraph, id: "dup", labels: ["Person"], properties: ["name": "xena"])
        }
        await assertRefused("a constraint a stored edge already breaks") {
            try await db.graphCreateConstraint(
                schemaGraph, name: "edge_since", label: "KNOWS", property: "since", kind: .required, target: .edge)
        }
        try await db.graphDropSchemaObject(schemaGraph, name: "unique_name")

        let written = try await db.graphExecute(schemaGraph, cypher: "CREATE (n:Person {name: 'zed'})")
        XCTAssertEqual(written["nodesCreated"]?.intValue, 1)
        let txn = try await db.graphBeginTransaction(schemaGraph)
        let queued = try await db.graphExecute(schemaGraph, cypher: "CREATE (n:Person {name: 'queued'})", txn: txn)
        XCTAssertEqual(queued["queued"]?.intValue, 1)
        var seen = try await db.graphFindNodes(schemaGraph, properties: ["name": "queued"])
        XCTAssertEqual(seen["count"]?.intValue, 0)
        let committed = try await db.graphCommitTransaction(schemaGraph, txn: txn)
        XCTAssertEqual(committed["committed"]?.intValue, 1)
        seen = try await db.graphFindNodes(schemaGraph, properties: ["name": "queued"])
        XCTAssertEqual(seen["count"]?.intValue, 1)
        let discarded = try await db.graphBeginTransaction(schemaGraph)
        try await db.graphExecute(schemaGraph, cypher: "CREATE (n:Person {name: 'never'})", txn: discarded)
        try await db.graphRollbackTransaction(schemaGraph, txn: discarded)
        seen = try await db.graphFindNodes(schemaGraph, properties: ["name": "never"])
        XCTAssertEqual(seen["count"]?.intValue, 0)
        try await db.graphDrop(schemaGraph)
        await db.close()
    }
}
