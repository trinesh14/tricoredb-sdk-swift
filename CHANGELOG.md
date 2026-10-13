# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-10-13

Every method added here needs a server at **0.1.0-rc.3 or later**. An older server
does not know the operation and answers it with an error.

### Added

- 116 methods, one for each operation the server gained since 0.1.0-rc.2. The README
  lists every one beside the server operation it sends.
  - Cache (53): sorted sets, locks with fencing tokens, bitmaps, HyperLogLog,
    multi-key reads and writes, conditional and atomic read-and-change writes,
    stale-while-revalidate reads, list moves and blocking pops, set algebra,
    pipelines, transactions and scripts, publish and poll, namespace limits and
    statistics.
  - Documents (13): `documentReplace`, `documentInsertMany`, `documentDeleteMany`,
    `documentBulkWrite`, `documentExplain`, collection options, renaming, index
    rebuilds and transactions spanning requests.
  - Vectors (21): batch upserts and deletes, batch, multi-query and by-example
    searches, named vectors, aliases, filters, counts, partitions, text embedding,
    index statistics and collection configuration.
  - Graphs (29): bulk writes, in-place updates, traversals and algorithms
    (components, cycles, k shortest paths, centrality, communities, PageRank and
    more), indexes and constraints, CSV import, Cypher writes and transactions.
- `BulkOp`, the four kinds of item a `documentBulkWrite` takes, and `CacheOp`, the
  operations a cache pipeline, transaction or script runs.
- `ScoredMember`, `ScoreBound`, `CacheExpiry`, `FreshRead`, `CacheOpResult`,
  `VectorExample`, `VectorSearchOptions` and the enums the new methods take.
- `txn` on `request(_:txn:)` and on the new document and graph methods, naming the
  transaction a call runs inside. The document methods that were already there do
  not take it yet.
- `VectorHit.vector`, `VectorHit.reason` and `VectorHit.matched`, for the searches
  that return them, and `TransactionResult.nestedDepth`.

### Fixed

- `inTransaction` stays true while an outer transaction is open. Since 2026-09-29
  the server opens a nested block when `BEGIN` is sent inside a transaction, and the
  `COMMIT` or `ROLLBACK` that ends the block (answered with `nested_depth`) leaves
  the outer transaction open. The client used to report the transaction as over, so
  a pool could lend the connection on with it still open.


## [0.2.0] - 2026-09-17

### Added

- Following the leader: a request refused with `not_leader` is sent again, to the
  leader the refusal names (over a new connection that replaces the current one) or,
  while no leader is known, to the same node after a pause. On by default;
  `TriCoreOptions.followLeader = false` restores the previous behaviour, and
  `leaderRetries` (5) and `leaderRetryDelay` (250 ms) bound it. Never inside a session
  transaction.
- `TriCoreError.outcomeUnknown`: a request that may or may not have been applied. It is
  never sent again.
- `TriCore.address`.

## [0.1.0] - 2026-09-16

First release.

### Added

- `TriCore`: the native `tricore` wire protocol over TCP or TLS, with handshake
  feature negotiation and password authentication. Every call is `async`, and the
  client is an `actor`, so the compiler — not a runtime check — is what stops two
  tasks interleaving frames on one connection.
- SQL: `query` and `execute` with `?` placeholders bound **by the server**, plus
  one-request scripts (`transaction`) and session transactions (`begin`, `commit`,
  `rollback`, `withTransaction`).
- `TriCorePool`: a bounded pool that lends a connection to a closure and never
  returns one with a transaction still open.
- Cache (keys, lists, sets, hashes, streams), documents with filters and aggregation
  pipelines, vectors, graphs, LLM context export and the admin reads.
- `TriCoreError` with a `kind`, the server's own `code`, and a leader hint;
  `isRedirect` and `isConnectionFatal` for the two questions callers actually ask.
- `JSONValue` for the protocol's dynamic payloads, with literal syntax and typed
  accessors.
- TLS and mutual TLS through `TLSOptions`, on Apple platforms and Linux alike.

### Security

- A call that needs a capability the server did not grant — server-side parameters,
  session transactions — throws before anything is sent, instead of falling back to
  a weaker behaviour.
- A frame's declared length is checked against the protocol's ceiling before a
  payload byte is read, so a wrong or hostile peer cannot make the client allocate
  what it claimed.
- A connection that timed out or lost frame alignment is dropped rather than reused:
  a late reply can never be read as the answer to the next request.
- Errors name a certificate or key file's path, never its contents, and
  `TriCoreOptions.description` prints the secret as `***`.

[Unreleased]: https://github.com/trinesh14/tricoredb-sdk-swift/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/trinesh14/tricoredb-sdk-swift/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/trinesh14/tricoredb-sdk-swift/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/trinesh14/tricoredb-sdk-swift/releases/tag/v0.1.0
