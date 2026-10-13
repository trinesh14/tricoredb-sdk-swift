# tricoredb-sdk-swift

Official Swift client for [TriCoreDB](https://hub.docker.com/r/trinesh14/tricoredb):
SQL, documents, vectors, graphs and cache over one native connection.

[![Swift](https://img.shields.io/badge/swift-5.9%2B-orange?logo=swift&cacheSeconds=86400)](Package.swift)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iOS%20%7C%20Linux-blue?cacheSeconds=86400)](Package.swift)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue?cacheSeconds=86400)](LICENSE)

- **async/await throughout.** Nothing blocks a thread waiting for the server.
- **Built on SwiftNIO**, the way PostgresNIO, MySQLNIO and RediStack are.
- **Server-side parameters.** Values never become part of the SQL text.
- **Transactions, a connection pool, TLS and mutual TLS.**

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Running a server](#running-a-server)
- [Quick start](#quick-start)
- [Connecting](#connecting)
- [SQL](#sql)
- [Transactions](#transactions)
- [Connection pool](#connection-pool)
- [Cache](#cache)
- [Documents](#documents)
- [Vectors](#vectors)
- [Graphs](#graphs)
- [Operations added for server 0.1.0-rc.3](#operations-added-for-server-010-rc3)
- [LLM context](#llm-context)
- [Admin](#admin)
- [Errors](#errors)
- [TLS](#tls)
- [Testing](#testing)

## Requirements

- Swift **5.9** or later; macOS 13+, iOS 16+, or Linux
- A TriCoreDB server speaking protocol 1.0 (`tricore-server` 0.1.0-rc.1 or later).
  See [Running a server](#running-a-server).

## Installation

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/trinesh14/tricoredb-sdk-swift", from: "0.3.0")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "TriCoreDB", package: "tricoredb-sdk-swift")
    ])
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repository URL.

This package depends on [SwiftNIO](https://github.com/apple/swift-nio) and
[NIOSSL](https://github.com/apple/swift-nio-ssl). The other TriCoreDB SDKs have no
dependencies, and this one does on purpose: a networked database client in Swift is
built on NIO — and TLS on Linux has no system library to fall back on, so a
dependency-free client could only offer TLS on Apple platforms.

## Running a server

The quickest way is the official Docker image,
[`trinesh14/tricoredb`](https://hub.docker.com/r/trinesh14/tricoredb).

**Local development** (no TLS and no encryption, for this machine only). Set
`TRICORE_ADMIN_PASSWORD` in your shell first. Then create the admin and start the
server:

```bash
docker run --rm -v tricoredb-dev:/var/lib/tricoredb -e TRICORE_ADMIN_PASSWORD --entrypoint /usr/local/bin/tricore trinesh14/tricoredb:0.1.0-rc.1-r2 auth init-admin --user admin --password-env TRICORE_ADMIN_PASSWORD --data-dir /var/lib/tricoredb/data
docker run -d --name tricoredb-dev -p 127.0.0.1:8427:8427 -e TRICORE_TLS=off -e TRICORE_ENCRYPTION=off -e TRICORE_MODULES=all -v tricoredb-dev:/var/lib/tricoredb trinesh14/tricoredb:0.1.0-rc.1-r2
```

**Anything else:** by default the image runs with **TLS on** and an **encrypted data
volume**. Follow the quick start on the
[Docker Hub page](https://hub.docker.com/r/trinesh14/tricoredb) to create the
certificate and key, then connect with [TLS](#tls).

`TRICORE_MODULES=all` enables every data model. The image's default is `sql`,
`document` and `cache`; a call to a disabled model throws a `TriCoreError` whose
`code` is `engine.disabled`.

## Quick start

```swift
import TriCoreDB

let db = try await TriCore.connect(host: "127.0.0.1", port: 8427, user: "admin", secret: "your-password")

try await db.execute("CREATE TABLE IF NOT EXISTS users (id INT PRIMARY KEY, name TEXT)")
try await db.execute("INSERT INTO users VALUES (?, ?)", [1, "O'Hara"])

let rows = try await db.query("SELECT id, name FROM users WHERE id = ?", [1])
print(rows.value(row: 0, column: "name") ?? "")   // O'Hara

try await db.cacheSet("sessions", "u1", "token")
let token = try await db.cacheGet("sessions", "u1")   // nil on a miss

await db.close()
```

## Connecting

`TriCore` is an `actor`, so a connection is never used by two tasks at the same
time — the compiler enforces what the protocol requires. Use a
[pool](#connection-pool) when you want requests to run concurrently.

| `TriCoreOptions` field | Default | Meaning |
| --- | --- | --- |
| `host` | `"127.0.0.1"` | Server host |
| `port` | `8427` | Server port |
| `user` | `nil` | Principal to authenticate as; `nil` skips authentication |
| `secret` | `""` | Password or token |
| `database` | `"main"` | Database named in every request |
| `clientName` | `"tricoredb-swift/<version>"` | Name reported in the handshake |
| `connectTimeout` | `.seconds(10)` | Bound on the connect, TLS and handshake |
| `readTimeout` | `nil` | Bound on each wait for a reply |
| `requestTimeout` | `nil` | Server-side deadline stamped on each request |
| `tls` | `nil` (plain TCP) | See [TLS](#tls) |
| `features` | `.all` | Capabilities announced in the handshake |
| `followLeader` | `true` | Send a `not_leader` refusal again, to the leader |
| `leaderRetries` | `5` | How many times a refused request is sent again |
| `leaderRetryDelay` | `.milliseconds(250)` | First pause before asking again; doubles up to 2 s |

```swift
var options = TriCoreOptions(host: "db.internal", user: "admin", secret: "your-password")
options.database = "reporting"
options.readTimeout = .seconds(30)
let db = try await TriCore.connect(options)
```

`options.description` prints `secret: ***`, so a logged configuration never leaks
the password.

## SQL

`query` runs only `SELECT`. `execute` runs everything else. The server enforces the
split: a write sent through `query` is refused.

```swift
try await db.execute("INSERT INTO users VALUES (?, ?)", [2, "ada"])
let rows = try await db.query("SELECT id, name FROM users")

rows.count                              // 2
rows[0]                                 // ["1", "O'Hara"]
rows.value(row: 0, column: "name")      // "O'Hara"
rows.dictionaries()                     // rows keyed by column name
```

Placeholders are bound **on the server**: the values travel next to the statement,
so a value can never be read as SQL syntax, however it is spelled. Literals mean you
rarely name `SQLValue`:

| Swift value | Sent as |
| --- | --- |
| `nil` | SQL `NULL` |
| `Bool` | a boolean |
| integer literals, `SQLValue(anyInteger)` | an exact number |
| `Double` | a number; `NaN` and infinities are refused |
| `try SQLValue.decimal("10.50")` | plain digits, no exponent — for `DECIMAL` |
| `SQLValue.blob(data)` | `0x`-prefixed hex, for `BLOB` |
| `String` | text |
| `SQLValue.timestamp(date)` | the timestamp text the server stores |

Binding needs the `SERVER_PARAMS` capability, agreed in the handshake
(`await db.serverParamsGranted`). Against a server that did not grant it, a call with
parameters throws **before anything is sent** — it never falls back to pasting
values into the statement text.

## Transactions

`transaction(_:)` sends a whole `BEGIN … COMMIT` script in **one request**. It works
on every node and is right when every statement is known up front:

```swift
let result = try await db.transaction([
    Statement("UPDATE accounts SET balance = balance - ? WHERE id = ?", [10, 1]),
    Statement("UPDATE accounts SET balance = balance + ? WHERE id = ?", [10, 2]),
])
result.outcome   // "committed"
```

`begin`, `commit` and `rollback` keep a transaction open **across requests on this
connection**. `withTransaction` commits when the closure returns and rolls back when
it throws:

```swift
try await db.withTransaction { tx in
    try await tx.execute("INSERT INTO t VALUES (?, ?)", [1, "ada"])
}
```

These need the `SESSION_TXN` capability; without it `begin` throws by name rather
than running each statement on its own. The transaction belongs to this connection:
another connection cannot commit it, and a dropped socket rolls it back.

## Connection pool

```swift
let pool = TriCorePool(options: options, size: 8)

try await withThrowingTaskGroup(of: Void.self) { group in
    for id in 1...8 {
        group.addTask {
            try await pool.withConnection { db in
                try await db.execute("INSERT INTO users VALUES (?, ?)", [.int(Int64(id)), "grace"])
            }
        }
    }
    try await group.waitForAll()
}

await pool.close()
```

`withConnection` lends a connection for the duration of a closure. A connection is
never returned to the pool with a transaction still open: it is rolled back first,
and the connection is retired if that rollback fails.

## Cache

Values are bytes. `nil` is a miss, which is how a miss is told apart from a stored
empty value.

```swift
try await db.cacheSet("sessions", "u1", Data("token".utf8))
try await db.cacheSet("sessions", "u2", "token", ttl: .seconds(30))
let value = try await db.cacheGet("sessions", "u1")

_ = try await db.cacheIncrement("counters", "hits")
_ = try await db.cacheRightPush("queue", "jobs", [Data("a".utf8), Data("b".utf8)])
_ = try await db.cacheSetAdd("tags", "post:1", [Data("swift".utf8)])
_ = try await db.cacheHashSet("user:1", "profile", [CachePair("name", "ada")])
let id = try await db.cacheStreamAdd("events", "log", [CachePair("msg", "hi")])
```

| Family | Methods |
| --- | --- |
| Keys | `cacheGet`, `cacheSet`, `cacheSetNX`, `cacheDelete`, `cacheExists`, `cacheTTL`, `cacheExpire`, `cachePersist`, `cacheIncrement`, `cacheKeys`, `cacheClearNamespace`, `cachePing` |
| Lists | `cacheLeftPush`, `cacheRightPush`, `cacheLeftPop`, `cacheRightPop`, `cacheRange`, `cacheLength`, `cacheIndex` |
| Sets | `cacheSetAdd`, `cacheSetRemove`, `cacheSetContains`, `cacheSetCount`, `cacheSetMembers` |
| Hashes | `cacheHashSet`, `cacheHashGet`, `cacheHashDelete`, `cacheHashAll`, `cacheHashContains`, `cacheHashCount` |
| Streams | `cacheStreamAdd`, `cacheStreamLength`, `cacheStreamRange`, `cacheStreamRead`, `cacheStreamDelete`, `cacheStreamTrim` |

## Documents

```swift
try await db.documentCreateCollection("products")
let id = try await db.documentInsert("products", ["name": "widget", "price": 9])
let cheap = try await db.documentFind("products", .lessThan("price", 10))
try await db.documentUpdateOne("products", id: id, DocumentUpdate().increment("price", by: 1))

let totals = try await db.documentAggregate("orders", [
    .match(.equal("status", "paid")),
    .group(by: .field("customer"), [("total", .sum("amount"))]),
    .sort([(field: "total", descending: true)]),
    .limit(10),
])
```

Filters and pipeline stages are built with these constructors, so the request JSON
is never written by hand. Also available: `documentGet`, `documentSet`,
`documentUpsertOne`, `documentUpdateMany`, `documentDelete`,
`documentListCollections`, `documentDropCollection`, `documentCreateIndex`,
`documentDropIndex`, `documentListIndexes` and `documentAnalyze`.

## Vectors

```swift
try await db.vectorCreateCollection("embeddings", dimension: 3, metric: .cosine)
try await db.vectorUpsert("embeddings", id: "a", [0.1, 0.2, 0.3], metadata: ["kind": "doc"])

let hits = try await db.vectorSearch("embeddings", [0.1, 0.2, 0.3], topK: 5)
let onlyDocs = try await db.vectorSearch("embeddings", [0.1, 0.2, 0.3], topK: 5, filter: ["kind": "doc"])
```

The score is a **similarity**: higher is closer under every metric, and results come
back best first. L2 is the case worth knowing — the server negates the squared
distance, so an L2 score is `<= 0` and `-0.02` is nearer than `-196.0`.

## Graphs

```swift
try await db.graphCreate("social")
try await db.graphAddNode("social", id: "u1", labels: ["User"], properties: ["name": "ada"])
try await db.graphAddNode("social", id: "u2", labels: ["User"])
try await db.graphAddEdge("social", id: "e1", from: "u1", to: "u2", label: "FOLLOWS")

let neighbours = try await db.graphNeighbors("social", of: "u1")
let path = try await db.graphShortestPath("social", from: "u1", to: "u2")
print(path.found, path.hops, path.nodePath)
```

"No path" comes back as `found == false`, not as an error. Also available:
`graphGetNode`, `graphGetEdge`, `graphDeleteNode`, `graphDeleteEdge`, `graphList`,
`graphDrop`, `graphTraverse`, `graphWeightedShortestPath`, `graphDegree`,
`graphListNodes`, `graphListEdges` and `graphQuery` for the read-only Cypher subset.

## Operations added for server 0.1.0-rc.3

These need a server at **0.1.0-rc.3 or later**. An older server does not know the
operation and answers it with an error, which this client raises like any other
refusal.

### Cache

| Method | Server operation | What it does |
| --- | --- | --- |
| `cacheSetFresh` | `Cache.SetFresh` | Store a value that answers as fresh for the given time and as stale after it, until its TTL (if any) ends |
| `cacheGetFresh` | `Cache.GetFresh` | Read with stale-while-revalidate and stampede protection |
| `cacheSetMissing` | `Cache.SetMissing` | Negative caching |
| `cacheWarm` | `Cache.Warm` | Cache warming |
| `cacheGetMany` | `Cache.MGet` | Read many values in one request |
| `cacheSetMany` | `Cache.MSet` | Write many values as one batch, all with the same optional TTL |
| `cacheSetIf` | `Cache.SetIf` | Write a value under a condition, with explicit control over the TTL |
| `cacheSortedAdd` | `Cache.ZAdd` | Add scored members to a sorted set, or re-score ones already there |
| `cacheSortedRemove` | `Cache.ZRem` | Remove members from a sorted set, returning how many were present |
| `cacheSortedScore` | `Cache.ZScore` | The score of one member, or null when it is not in the set |
| `cacheSortedCount` | `Cache.ZCard` | How many members a sorted set holds |
| `cacheSortedRank` | `Cache.ZRank` | A member's position in the ordering, or null when it is absent |
| `cacheSortedRange` | `Cache.ZRange` | Members by rank, `start..=stop` inclusive |
| `cacheSortedRangeByScore` | `Cache.ZRangeByScore` | Members by score, between two bounds |
| `cacheSortedIncrement` | `Cache.ZIncrBy` | Add to a member's score, creating it at that score when absent |
| `cacheLockAcquire` | `Cache.LockAcquire` | Take a lease on a lock, or refresh one already held by `owner` |
| `cacheLockRenew` | `Cache.LockRenew` | Extend a lease the caller still holds |
| `cacheLockRelease` | `Cache.LockRelease` | Give up a lock |
| `cacheSetBit` | `Cache.SetBit` | Set one bit of a string value, growing it with zero bytes if needed |
| `cacheGetBit` | `Cache.GetBit` | Read one bit |
| `cacheBitCount` | `Cache.BitCount` | Count the set bits, optionally within a byte range `(start, end)` with signed indices |
| `cacheBitPosition` | `Cache.BitPos` | The position of the first bit equal to `bit`, optionally within a byte range, or -1 when there is none |
| `cacheBitOperation` | `Cache.BitOp` | Combine several values bitwise and store the result at `dest` |
| `cacheHyperLogLogAdd` | `Cache.PfAdd` | Add elements to a HyperLogLog, creating it when absent |
| `cacheHyperLogLogCount` | `Cache.PfCount` | Estimated number of distinct elements |
| `cacheHyperLogLogMerge` | `Cache.PfMerge` | Merge several HyperLogLogs into `dest`, which is included as a source when it already exists |
| `cacheListMove` | `Cache.LMove` | Atomically pop an element from one end of `source` and push it onto one end of `destination` |
| `cacheExpireAt` | `Cache.ExpireAt` | Set the absolute instant an existing live key dies |
| `cacheStats` | `Cache.Stats` | What this node's cache is doing |
| `cacheFlushDatabase` | `Cache.FlushDatabase` | Delete every cache key in this database, across every namespace |
| `cacheAppend` | `Cache.Append` | Concatenate bytes onto what a key already holds, and return the new length |
| `cacheCompareAndSwap` | `Cache.CompareAndSwap` | Write only if the key still holds `expected` (null |
| `cacheGetAndDelete` | `Cache.GetDel` | Read a key and delete it in one atomic step |
| `cacheGetAndSet` | `Cache.GetSet` | Write a value and return the one it replaced, atomically |
| `cacheGetAndExpire` | `Cache.GetEx` | Read a key and change its expiry in the same atomic step |
| `cacheListTrim` | `Cache.LTrim` | Keep only the inclusive index range of a list, dropping everything outside it |
| `cacheSetUnion` | `Cache.SUnion` | Every member of every named set, without duplicates |
| `cacheSetIntersection` | `Cache.SInter` | The members present in every named set |
| `cacheSetDifference` | `Cache.SDiff` | The members of the first set that are in none of the rest |
| `cacheSetRandomMembers` | `Cache.SRandMember` | Random members of a set, without removing them |
| `cacheHashIncrement` | `Cache.HIncrBy` | Add to one hash field, atomically, returning its new value |
| `cachePipeline` | `Cache.Pipeline` | Run cache operations in order in one round trip, each exactly as if it had been sent alone |
| `cacheTransaction` | `Cache.Transaction` | Run cache operations in order holding the cache write lock, so no other writer interleaves with them |
| `cacheScriptLoad` | `Cache.ScriptLoad` | Store a script |
| `cacheScriptRun` | `Cache.ScriptRun` | Run a stored script with these arguments as one transaction |
| `cacheHotKeys` | `Cache.HotKeys` | The most frequently addressed keys on this node since it started, with estimated counts |
| `cachePurgeExpired` | `Cache.PurgeExpired` | Delete every expired cache key in this database now, rather than leaving it to compaction |
| `cacheBlockingLeftPop` | `Cache.BLPop` | Pop the head of the first non-empty list among `keys`, waiting up to the timeout for one to receive an element |
| `cacheBlockingRightPop` | `Cache.BRPop` | Pop the tail of the first non-empty list among `keys`, waiting up to the timeout for one to receive an element |
| `cacheSetNamespaceLimit` | `Cache.SetNamespaceLimit` | Cap a namespace at `max_keys` live keys and `max_bytes` of values |
| `cacheGetNamespaceLimit` | `Cache.GetNamespaceLimit` | A namespace's limit and what it holds now |
| `cachePublish` | `Cache.Publish` | Append a message to a channel, returning the id it was given |
| `cachePoll` | `Cache.Poll` | The messages after id `after` on these channels (a trailing `*` is a pattern) |

### Documents

| Method | Server operation | What it does |
| --- | --- | --- |
| `documentReplace` | `Document.Replace` | Swap a document's whole body for a new one |
| `documentInsertMany` | `Document.InsertMany` | Insert several documents as one atomic batch |
| `documentDeleteMany` | `Document.DeleteMany` | Delete every document a filter matches, returning how many went |
| `documentRenameCollection` | `Document.RenameCollection` | Move a collection, with its documents and indexes, to a new name |
| `documentPurgeExpired` | `Document.PurgeExpired` | Delete the documents a TTL index says have expired, now |
| `documentExplain` | `Document.Explain` | Run a find and describe how it ran instead of returning its documents |
| `documentBeginTransaction` | `Document.BeginTransaction` | Open a document transaction spanning requests, returning its id |
| `documentCommitTransaction` | `Document.CommitTransaction` | Commit a document transaction |
| `documentRollbackTransaction` | `Document.RollbackTransaction` | Discard a document transaction |
| `documentRebuildIndex` | `Document.RebuildIndex` | Rebuild one index from the stored documents |
| `documentSetCollectionOptions` | `Document.SetCollectionOptions` | Set a collection's options (`schema`, `defaults`, `versioned`), replacing any it had |
| `documentGetCollectionOptions` | `Document.GetCollectionOptions` | A collection's options |
| `documentBulkWrite` | `Document.BulkWrite` | Many inserts, updates, replaces and deletes on one collection, applied in order as one atomic batch |

### Vectors

| Method | Server operation | What it does |
| --- | --- | --- |
| `vectorEmbed` | `Vector.Embed` | Embed texts with the server's built-in embedder (deterministic feature hashing |
| `vectorUpsertText` | `Vector.UpsertText` | Embed each text at the collection's dimension and upsert the vectors as one atomic batch |
| `vectorSetAlias` | `Vector.SetAlias` | Point an alias at a collection; a null collection removes it |
| `vectorListAliases` | `Vector.ListAliases` | Every alias and the collection it names, as `{alias, collection}` |
| `vectorAddNamedVector` | `Vector.AddNamedVector` | Declare a named vector on a collection |
| `vectorUpsertNamed` | `Vector.UpsertNamed` | Write an item's vectors by name (`default` is the collection's own), each with the same metadata |
| `vectorUpsertMany` | `Vector.UpsertMany` | Write many vectors as one atomic batch |
| `vectorDeleteMany` | `Vector.DeleteMany` | Delete many vectors by id as one atomic batch, returning how many of the ids were present |
| `vectorSearchBatch` | `Vector.SearchBatch` | Run several query vectors against one collection in one request |
| `vectorDeleteByFilter` | `Vector.DeleteByFilter` | Delete every vector whose metadata matches a filter, as one atomic batch |
| `vectorUpdateByFilter` | `Vector.UpdateByFilter` | Merge `set` into the metadata of every vector matching a filter, as one atomic batch |
| `vectorCount` | `Vector.Count` | How many vectors a collection holds, or, with a filter, how many match it |
| `vectorListPartitions` | `Vector.ListPartitions` | The partitions of a collection |
| `vectorRenameCollection` | `Vector.RenameCollection` | Rename a collection, moving its catalog record and every vector with it |
| `vectorRebuildIndex` | `Vector.RebuildIndex` | Rebuild the collection's ANN index from its stored vectors and persist it, clearing every tombstone |
| `vectorIndexStats` | `Vector.IndexStats` | The shape of the collection's ANN index |
| `vectorMeasureRecall` | `Vector.MeasureRecall` | Measure the ANN index's recall |
| `vectorSearchMulti` | `Vector.SearchMulti` | Search with several query vectors and return one fused ranking |
| `vectorSetCollectionConfig` | `Vector.SetCollectionConfig` | Change a collection's configuration, returning it |
| `vectorCopyCollection` | `Vector.CopyCollection` | Copy a collection (configuration and every vector) to a new name |
| `vectorSearchByExamples` | `Vector.SearchByExamples` | Search with a query built from examples |

### Graphs

| Method | Server operation | What it does |
| --- | --- | --- |
| `graphAddMany` | `Graph.AddMany` | Write many nodes and edges as one unit |
| `graphRemoveMany` | `Graph.RemoveMany` | Delete many nodes and edges as one unit |
| `graphUpdateNode` | `Graph.UpdateNode` | Change an existing node in place, returning it |
| `graphUpdateEdge` | `Graph.UpdateEdge` | Change an existing edge in place, returning it |
| `graphCopy` | `Graph.CopyGraph` | Copy a graph (nodes, edges and schema) to a new name |
| `graphDfs` | `Graph.Dfs` | A bounded depth-first walk from a node |
| `graphConnectedComponents` | `Graph.ConnectedComponents` | Partition the graph's nodes into connected components, largest first |
| `graphDetectCycle` | `Graph.DetectCycle` | Whether the graph contains a cycle (`hasCycle`), and one `cycle` as evidence |
| `graphStats` | `Graph.GraphStats` | Counts describing a graph |
| `graphSubgraph` | `Graph.Subgraph` | The part of the graph within `max_depth` hops of the seeds |
| `graphSchema` | `Graph.GraphSchema` | What the graph's data looks like |
| `graphKShortestPaths` | `Graph.KShortestPaths` | The `k` cheapest loopless paths between two nodes, cheapest first (default 3, at most 20) |
| `graphAllPaths` | `Graph.AllPaths` | Every simple path between two nodes of at most `max_depth` edges (default 5, at most 10) |
| `graphCentrality` | `Graph.Centrality` | Betweenness, closeness or eigenvector centrality |
| `graphCommunities` | `Graph.Communities` | Communities by Louvain modularity optimisation, direction ignored, largest first, with the partition's `modularity` |
| `graphTriangleCount` | `Graph.TriangleCount` | Triangles and clustering coefficients, direction ignored |
| `graphNodeSimilarity` | `Graph.NodeSimilarity` | The nodes whose neighbour sets most resemble a node's, under `results` |
| `graphCheckConsistency` | `Graph.CheckConsistency` | Check a graph's stored records against each other and against the resident mirror |
| `graphCreateNodeIndex` | `Graph.CreateNodeIndex` | Index node properties for finding nodes |
| `graphCreateConstraint` | `Graph.CreateConstraint` | Enforce a rule on a property of every node (or, with target `edge`, every relationship) carrying a label |
| `graphDropSchemaObject` | `Graph.DropSchemaObject` | Drop an index or a constraint by name |
| `graphListSchemaObjects` | `Graph.ListSchemaObjects` | A graph's `indexes` and `constraints` |
| `graphFindNodes` | `Graph.FindNodes` | Nodes with a label (when given) whose properties equal the given values, in id order |
| `graphImportCsv` | `Graph.ImportCsv` | Import nodes and edges from CSV text as one atomic batch, so constraints apply |
| `graphPageRank` | `Graph.PageRank` | PageRank over edge direction |
| `graphExecute` | `Graph.Execute` | Run a Cypher write |
| `graphBeginTransaction` | `Graph.BeginTransaction` | Open a transaction on a graph, returning its id |
| `graphCommitTransaction` | `Graph.CommitTransaction` | Apply every statement queued in a graph transaction as one |
| `graphRollbackTransaction` | `Graph.RollbackTransaction` | Discard a graph transaction and its queued statements |
`documentBulkWrite` takes its operations from `BulkOp` (`insert`, `updateOne`,
`replace`, `delete`), and a cache pipeline, transaction or script takes its from
`CacheOp`:

```swift
try await db.documentBulkWrite("people", [
    .insert(["name": "ada"], id: "a"),
    .updateOne(id: "a", DocumentUpdate().set("city", "Pune")),
    .delete(id: "b"),
]) // every operation lands, or none does

let results = try await db.cachePipeline([
    .set("sessions", "abc", Data("ada".utf8)),
    .get("sessions", "abc"),
])
results[1].value // the bytes the second operation read
```

A document transaction is named in each call that runs inside it, and a graph
transaction queues Cypher writes until it commits:

```swift
let txn = try await db.documentBeginTransaction()
try await db.documentInsertMany("people", [["_id": "a", "name": "ada"]], txn: txn)
try await db.documentCommitTransaction(txn: txn)

let graphTxn = try await db.graphBeginTransaction("social")
try await db.graphExecute("social", cypher: "CREATE (n:Person {name: 'ada'})", txn: graphTxn)
try await db.graphCommitTransaction("social", txn: graphTxn)
```

The methods added here take `txn`; the document methods that were already there
(`documentInsert`, `documentGet`, `documentFind`, ...) do not yet, so inside a
transaction send those through `request(_:txn:)`.

A result with one meaningful field comes back as that value; a larger one comes
back as the server's own JSON object (`JSONValue`), with the server's field names.

## LLM context

```swift
let bundle = try await db.llmContext([
    .sql("SELECT id, name FROM users"),
    .documents("products", limit: 50),
], format: .toon)

let schema = try await db.llmSchema(format: .markdown)
```

Sensitive fields are redacted by default.

## Admin

```swift
try await db.adminPing()
let status = try await db.adminStatus()
```

Admin calls need the cluster module enabled on the server, even on a single node.
`db.ping()` checks the connection itself and reaches no module.

## Errors

Everything this package throws is a `TriCoreError`. Branch on `kind` and `code`,
never on the message text:

| `kind` | Means |
| --- | --- |
| `.server` | The request arrived and the operation failed. The connection stays usable. |
| `.auth` / `.handshake` | The credentials, or the handshake, were refused. |
| `.protocolViolation` | The peer broke the protocol. |
| `.io` / `.closed` | The transport failed, or the connection was already closed. |
| `.timeout` | A deadline passed; the connection is dropped, because the late reply must not be read as the next answer. |
| `.featureNotGranted` | The server lacks a capability this call needs, so nothing was sent. |
| `.invalidArgument` | A value this client refused; nothing was sent. |
| `.tls` | TLS configuration or handshake failed. |
| `.pool` | The pool is closed, or no connection was available. |

`error.isConnectionFatal` says whether the connection can still be used.

**Leader redirects.** In a cluster only the leader accepts writes, and a follower
refuses with `code == "not_leader"` (`error.isRedirect`). The client handles that itself
(`options.followLeader`, on by default):

- when the refusal names the leader (`error.leaderHint`), it opens a connection there
  with the same user, secret and TLS settings (the leader's host is the certificate
  name), sends the request again, and keeps that connection (`await db.address`);
- while an election is in progress (no hint), it waits and asks the same node again,
  pausing 250 ms, then 500 ms, up to 2 s (`leaderRetryDelay`);
- after `leaderRetries` (5) it throws the last refusal.

This is safe because a `not_leader` refusal was applied nowhere. Nothing is sent again
inside a session transaction, and never a refusal with `TriCoreError.outcomeUnknown`: a
follower handed that request to the leader and lost the answer, or the leader could not
confirm it, so it may have been applied. The leader's address must be reachable from your
application; when it is not, the client keeps its connection and waits. To handle
redirects yourself, set `options.followLeader = false`:

```swift
do {
    try await db.execute("INSERT INTO t VALUES (1)")
} catch let error as TriCoreError where error.isRedirect {
    if let leader = error.leaderHint { try await retry(against: leader) }
}
```

## TLS

TLS is off until `options.tls` is set.

```swift
var options = TriCoreOptions(host: "db.internal", user: "admin", secret: "your-password")
options.tls = TLSOptions(caFile: "/etc/tricore/ca.pem", serverName: "db.internal")
let db = try await TriCore.connect(options)
```

With TLS on, the certificate chain and the host name are verified. With no `caFile`
the platform's trust store is used, so point it at your own CA for a private
certificate — which is the usual case for a database. For mutual TLS set
`clientCertificateFile` and `clientKeyFile` together. Errors name a certificate or
key file's *path*, never its contents.

| `TLSOptions` field | Default | Meaning |
| --- | --- | --- |
| `caFile` | `nil` (platform trust store) | PEM bundle that verifies the server |
| `serverName` | the connection host | Expected name (SNI and certificate check) |
| `clientCertificateFile` / `clientKeyFile` | `nil` | PEM certificate and key, for mutual TLS |
| `dangerAcceptInvalidCertificates` | `false` | **Development only.** Skips all verification. |

## Testing

```bash
swift test
```

The unit tests and the scripted-peer tests need no server: a peer built on NIO plays
the answers a real cluster would send, including a `not_leader` refusal and a frame
that declares more bytes than it sends. The live tests start their own
`tricore-server` — point `TRICORE_SERVER_BIN` at the binary, and without one they
are **skipped** rather than failed.

## License

[Apache License 2.0](LICENSE)
