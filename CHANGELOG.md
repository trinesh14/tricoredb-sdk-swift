# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/trinesh14/tricoredb-sdk-swift/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/trinesh14/tricoredb-sdk-swift/releases/tag/v0.1.0
