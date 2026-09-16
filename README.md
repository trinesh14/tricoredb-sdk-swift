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
    .package(url: "https://github.com/trinesh14/tricoredb-sdk-swift", from: "0.1.0")
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

**Leader redirects.** In a cluster, a write that reaches a follower fails with
`code == "not_leader"`, which `error.isRedirect` tests. When the leader is known,
`error.leaderHint` holds its `host:port`; a `nil` hint means the leader is not known
yet, so wait and retry. This client does not follow the redirect for you — where to
resend a write is your application's decision.

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
