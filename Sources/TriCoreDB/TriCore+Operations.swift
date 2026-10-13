import Foundation

// The operations added for server 0.1.0-rc.3.
//
// Every method here needs a server at 0.1.0-rc.3 or later; an older server does not
// know the operation and answers it with an error. A result with one meaningful
// field comes back as that value; a larger one comes back as the server's own JSON
// object, with the server's field names.

/// What a cache call does to a key's expiry.
public struct CacheExpiry: Sendable, Equatable {
    let json: JSONValue

    /// Leave the expiry as it is.
    public static let keep = CacheExpiry(json: "Keep")
    /// Remove the expiry, which is what a plain set does.
    public static let clear = CacheExpiry(json: "Clear")

    /// Expire this long from now.
    public static func after(_ ttl: Duration) -> CacheExpiry {
        CacheExpiry(json: ["Set": ["ttl_ms": TriCore.wholeMilliseconds(ttl)]])
    }
}

/// One end of a sorted-set score range.
///
/// JSON has no infinity, so an unbounded end is sent as the largest finite double,
/// which no finite score lies beyond.
public struct ScoreBound: Sendable, Equatable {
    /// The score at this end.
    public let value: Double
    /// Whether a member with exactly this score is left out.
    public let isExclusive: Bool

    /// A bound that includes members scoring exactly `value`.
    public static func inclusive(_ value: Double) -> ScoreBound { ScoreBound(value: value, isExclusive: false) }
    /// A bound that leaves out members scoring exactly `value`.
    public static func exclusive(_ value: Double) -> ScoreBound { ScoreBound(value: value, isExclusive: true) }
    /// No lower limit.
    public static let lowest = ScoreBound.inclusive(-.infinity)
    /// No upper limit.
    public static let highest = ScoreBound.inclusive(.infinity)

    var json: JSONValue {
        let finite = value.isInfinite
            ? (value < 0 ? -Double.greatestFiniteMagnitude : Double.greatestFiniteMagnitude)
            : value
        return ["value": .double(finite), "exclusive": .bool(isExclusive)]
    }
}

/// One member of a sorted set.
public struct ScoredMember: Sendable, Equatable {
    /// The member's bytes.
    public let member: Data
    /// Its score. `nil` when a range was read without scores.
    public let score: Double?

    public init(member: Data, score: Double?) {
        self.member = member
        self.score = score
    }

    /// A member from text, encoded UTF-8.
    public init(_ member: String, score: Double) {
        self.member = Data(member.utf8)
        self.score = score
    }

    /// The member as text, when it is valid UTF-8.
    public var text: String? { String(data: member, encoding: .utf8) }

    var json: JSONValue {
        ["score": .double(score ?? 0), "member": TriCore.byteList(member)]
    }
}

/// What ``TriCore/cacheGetFresh(_:_:owner:lease:)`` found.
public struct FreshRead: Sendable, Equatable {
    /// `fresh`, `stale`, `missing` (a cached absence) or `miss`.
    public let state: String
    /// The value, when the state is `fresh` or `stale`.
    public let value: Data?
    /// On a stale read: whether this caller holds the refresh lease and should
    /// recompute the value.
    public let refresh: Bool
    /// On a miss: whether this caller holds the lease and should compute the value.
    public let lease: Bool
    /// On a miss without the lease: how long until asking again is worthwhile.
    public let retryAfter: Duration?

    /// A value that is valid UTF-8 arrives as text under `value`; any other arrives
    /// as hex under `valueHex`.
    init(_ json: JSONValue) throws {
        state = json["state"]?.stringValue ?? ""
        if let text = json["value"]?.stringValue {
            value = Data(text.utf8)
        } else if let hex = json["valueHex"]?.stringValue {
            var bytes = [UInt8]()
            var index = hex.startIndex
            while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), index < hex.endIndex {
                guard let byte = UInt8(hex[index..<next], radix: 16) else {
                    throw TriCoreError.protocolViolation("the value's hex form is not hex")
                }
                bytes.append(byte)
                index = next
            }
            value = Data(bytes)
        } else {
            value = nil
        }
        refresh = json["refresh"]?.boolValue ?? false
        lease = json["lease"]?.boolValue ?? false
        retryAfter = json["retryAfterMs"]?.intValue.map { .milliseconds($0) }
    }

    /// The value as text, when it is valid UTF-8.
    public var text: String? { value.flatMap { String(data: $0, encoding: .utf8) } }
}

/// The outcome of one operation of a cache pipeline, transaction or script.
public struct CacheOpResult: Sendable, Equatable {
    /// Why the operation failed, or `nil` when it succeeded.
    public let error: String?
    /// The name of the data variant (`"Json"`, `"CacheValue"`, `"Message"`, ...), or
    /// `""` on failure.
    public let kind: String
    /// That variant's payload.
    public let data: JSONValue

    init(_ raw: JSONValue) {
        if let error = raw["error"] {
            self.error = error.stringValue ?? error.description
            kind = ""
            data = .null
        } else {
            error = nil
            (kind, data) = Response.unwrapVariant(raw["ok"] ?? .null)
        }
    }

    /// Whether the operation succeeded.
    public var isOK: Bool { error == nil }

    /// The payload as bytes, when the operation answered with a cache value that
    /// was not a miss.
    public var value: Data? {
        guard kind == "CacheValue", !data.isNull else { return nil }
        return try? TriCore.decodeBytes(data)
    }
}

/// A cache operation for a pipeline, a transaction or a script: the operation
/// exactly as it would be sent alone.
public struct CacheOp: Sendable, Equatable {
    let json: JSONValue

    /// A liveness check.
    public static let ping = CacheOp(json: "Ping")

    /// Any cache operation by its server name, with its fields as the server names
    /// them. Byte fields are arrays of byte values.
    public static func raw(_ variant: String, _ body: [String: JSONValue]) -> CacheOp {
        CacheOp(json: [variant: .object(body)])
    }

    /// Store a value, expiring after `ttl` when one is given.
    public static func set(_ namespace: String, _ key: String, _ value: Data, ttl: Duration? = nil) -> CacheOp {
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["value"] = TriCore.byteList(value)
        body["ttl_ms"] = TriCore.milliseconds(ttl)
        return raw("Set", body)
    }

    /// Read a value.
    public static func get(_ namespace: String, _ key: String) -> CacheOp {
        raw("Get", TriCore.namespaceKeyObject(namespace, key))
    }

    /// Delete a key.
    public static func delete(_ namespace: String, _ key: String) -> CacheOp {
        raw("Delete", TriCore.namespaceKeyObject(namespace, key))
    }

    /// Whether a key is present.
    public static func exists(_ namespace: String, _ key: String) -> CacheOp {
        raw("Exists", TriCore.namespaceKeyObject(namespace, key))
    }

    /// Add to a counter.
    public static func increment(_ namespace: String, _ key: String, by amount: Int = 1) -> CacheOp {
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["by"] = .int(Int64(amount))
        return raw("Incr", body)
    }

    /// Give a key a new expiry.
    public static func expire(_ namespace: String, _ key: String, ttl: Duration) -> CacheOp {
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["ttl_ms"] = TriCore.wholeMilliseconds(ttl)
        return raw("Expire", body)
    }
}

/// One operation of ``TriCore/documentBulkWrite(_:_:txn:)``.
public struct BulkOp: Sendable, Equatable {
    let json: JSONValue

    /// Insert a document, under `id` when one is given.
    public static func insert(_ document: Document, id: String? = nil) -> BulkOp {
        BulkOp(json: ["Insert": ["id": TriCore.optional(id), "document": .object(document)]])
    }

    /// Set or increment fields on one document. `expectedVersion` applies it only if
    /// the document's `_version` is still that.
    public static func updateOne(
        id: String, _ update: DocumentUpdate, upsert: Bool = false, expectedVersion: Int? = nil
    ) -> BulkOp {
        BulkOp(json: ["UpdateOne": [
            "id": .string(id), "update": update.json, "upsert": .bool(upsert),
            "expected_version": TriCore.optional(expectedVersion),
        ]])
    }

    /// Swap a document's whole body for `document`.
    public static func replace(
        id: String, _ document: Document, upsert: Bool = false, expectedVersion: Int? = nil
    ) -> BulkOp {
        BulkOp(json: ["Replace": [
            "id": .string(id), "document": .object(document), "upsert": .bool(upsert),
            "expected_version": TriCore.optional(expectedVersion),
        ]])
    }

    /// Delete one document by id.
    public static func delete(id: String, expectedVersion: Int? = nil) -> BulkOp {
        BulkOp(json: ["Delete": ["id": .string(id), "expected_version": TriCore.optional(expectedVersion)]])
    }
}

/// One example for ``TriCore/vectorSearchByExamples(_:topK:positive:negative:filter:minScore:includeVectors:excludeExamples:options:)``.
public enum VectorExample: Sendable, Equatable {
    /// A stored vector, named by id.
    case id(String)
    /// A vector given inline.
    case vector([Float])

    var json: JSONValue {
        switch self {
        case .id(let id): return .string(id)
        case .vector(let values): return TriCore.floats(values)
        }
    }
}

/// How a vector search's results are shaped and how hard it looks, beyond the query
/// itself. Only the fields given are sent; the server's defaults apply to the rest.
public struct VectorSearchOptions: Sendable, Equatable {
    /// Skip this many ranked hits before returning `topK`.
    public var offset: Int?
    /// Whether each hit carries its metadata. The server's default is true.
    public var includeMetadata: Bool?
    /// Only hits within this distance of the query, in the metric's own units.
    public var maxDistance: Double?
    /// The HNSW beam width for this query.
    public var efSearch: Int?
    /// Score every stored vector instead of walking the index.
    public var exact: Bool?
    /// Rank by this metric (`cosine`, `dot`, `l2`, `l1` or `linf`) instead of the
    /// collection's own.
    public var scoreMetric: String?
    /// How a metadata filter meets the index: `auto`, `graph` or `exact`.
    public var filterStrategy: String?
    /// Search this named vector of the collection rather than its default one.
    public var using: String?
    /// Confine the search to one tenant's vectors.
    public var tenant: String?
    /// Confine the search to one namespace of the collection.
    public var namespace: String?
    /// The dense score's weight in a hybrid search, from 0 to 1.
    public var hybridAlpha: Double?
    /// Give each hit a one-line plain-language `reason`.
    public var explain: Bool?
    /// Rank by an expression over `score` and numeric metadata fields.
    public var scoreExpression: String?
    /// The query's text, for `explain` to name the words a hit shares with it.
    public var explainText: String?
    /// The approximate index to search through: `hnsw`, `ivf` or `ivf_pq`.
    public var ann: String?
    /// IVF lists probed per search.
    public var nprobe: Int?

    public init(
        offset: Int? = nil, includeMetadata: Bool? = nil, maxDistance: Double? = nil, efSearch: Int? = nil,
        exact: Bool? = nil, scoreMetric: String? = nil, filterStrategy: String? = nil, using: String? = nil,
        tenant: String? = nil, namespace: String? = nil, hybridAlpha: Double? = nil, explain: Bool? = nil,
        scoreExpression: String? = nil, explainText: String? = nil, ann: String? = nil, nprobe: Int? = nil
    ) {
        self.offset = offset
        self.includeMetadata = includeMetadata
        self.maxDistance = maxDistance
        self.efSearch = efSearch
        self.exact = exact
        self.scoreMetric = scoreMetric
        self.filterStrategy = filterStrategy
        self.using = using
        self.tenant = tenant
        self.namespace = namespace
        self.hybridAlpha = hybridAlpha
        self.explain = explain
        self.scoreExpression = scoreExpression
        self.explainText = explainText
        self.ann = ann
        self.nprobe = nprobe
    }

    var json: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if let offset { out["offset"] = .int(Int64(offset)) }
        if let includeMetadata { out["include_metadata"] = .bool(includeMetadata) }
        if let maxDistance { out["max_distance"] = .double(maxDistance) }
        if let efSearch { out["ef_search"] = .int(Int64(efSearch)) }
        if let exact { out["exact"] = .bool(exact) }
        if let scoreMetric { out["score_metric"] = .string(scoreMetric) }
        if let filterStrategy { out["filter_strategy"] = .string(filterStrategy) }
        if let using { out["using"] = .string(using) }
        if let tenant { out["tenant"] = .string(tenant) }
        if let namespace { out["namespace"] = .string(namespace) }
        if let hybridAlpha { out["hybrid_alpha"] = .double(hybridAlpha) }
        if let explain { out["explain"] = .bool(explain) }
        if let scoreExpression { out["score_expr"] = .string(scoreExpression) }
        if let explainText { out["explain_text"] = .string(explainText) }
        if let ann { out["ann"] = .string(ann) }
        if let nprobe { out["nprobe"] = .int(Int64(nprobe)) }
        return out
    }
}

/// When a conditional cache write is allowed to proceed.
public enum SetCondition: String, Sendable {
    case always = "Always"
    case ifAbsent = "IfAbsent"
    case ifPresent = "IfPresent"
}

/// The bitwise operation applied across the sources. `Not` takes exactly one source.
public enum BitOperation: String, Sendable {
    case and = "And"
    case or = "Or"
    case xor = "Xor"
    case not = "Not"
}

/// Which end of a list an element leaves or joins.
public enum ListEnd: String, Sendable {
    case left = "Left"
    case right = "Right"
}

/// Whether a by-id write hands back the document it touched, and which version of it.
public enum ReturnDocument: String, Sendable {
    case none = "None"
    case before = "Before"
    case after = "After"
}

/// Which connectivity components are grouped by.
public enum ComponentKind: String, Sendable {
    case weak = "weak"
    case strong = "strong"
}

/// Which centrality is computed.
public enum CentralityMeasure: String, Sendable {
    case betweenness = "betweenness"
    case closeness = "closeness"
    case eigenvector = "eigenvector"
}

/// How two neighbour sets are scored.
public enum SimilarityMetric: String, Sendable {
    case jaccard = "jaccard"
    case overlap = "overlap"
}

/// What a graph constraint enforces.
public enum ConstraintKind: String, Sendable {
    case unique = "unique"
    case required = "required"
}

/// What a constraint's label names.
public enum ConstraintTarget: String, Sendable {
    case node = "node"
    case edge = "edge"
}

/// How a multi-query search combines its rankings.
public enum FusionMethod: String, Sendable {
    case rrf = "rrf"
    case max = "max"
    case mean = "mean"
}

extension TriCore {

    // MARK: - Cache

    /// Store a value that answers as fresh for the given time and as stale after
    /// it, until its TTL (if any) ends. Returns the instant, in Unix milliseconds,
    /// it stops being fresh.
    @discardableResult
    public func cacheSetFresh(
        _ namespace: String,
        _ key: String,
        _ value: Data,
        freshFor: Duration,
        ttl: Duration? = nil
    ) async throws -> Int {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "value": TriCore.byteList(value),
            "fresh_ms": TriCore.wholeMilliseconds(freshFor),
            "ttl_ms": TriCore.milliseconds(ttl),
        ]
        let response = try await operation("Cache", "SetFresh", body)
        let json = try response.expect("Json", "SetFresh")
        return json["freshUntilMs"]?.intValue ?? 0
    }

    /// Read with stale-while-revalidate and stampede protection. The state is
    /// `fresh`, `stale` (with `refresh` true for the one caller holding the refresh
    /// lease), `missing` (a cached absence) or `miss` (with `lease` true for the
    /// one caller that should compute the value).
    @discardableResult
    public func cacheGetFresh(
        _ namespace: String,
        _ key: String,
        owner: String,
        lease: Duration
    ) async throws -> FreshRead {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "owner": .string(owner),
            "lease_ms": TriCore.wholeMilliseconds(lease),
        ]
        let response = try await operation("Cache", "GetFresh", body)
        let json = try response.expect("Json", "GetFresh")
        return try FreshRead(json)
    }

    /// Negative caching: remember for the given time that the source has no value
    /// for the key.
    public func cacheSetMissing(_ namespace: String, _ key: String, ttl: Duration) async throws {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "ttl_ms": TriCore.wholeMilliseconds(ttl),
        ]
        _ = try await operation("Cache", "SetMissing", body)
    }

    /// Cache warming: write the entries that are not already cached, leaving live
    /// values alone. Answers `written` and `alreadyCached`.
    @discardableResult
    public func cacheWarm(
        _ namespace: String,
        _ entries: KeyValuePairs<String, Data>,
        ttl: Duration? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "entries": .array(entries.map { ["key": .string($0.key), "value": TriCore.byteList($0.value)] }),
            "ttl_ms": TriCore.milliseconds(ttl),
        ]
        let response = try await operation("Cache", "Warm", body)
        let json = try response.expect("Json", "Warm")
        return json
    }

    /// Read many values in one request. One result per requested key, in order,
    /// with null where the key is absent or expired. Not a snapshot.
    @discardableResult
    public func cacheGetMany(_ namespace: String, _ keys: [String]) async throws -> [Data?] {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "keys": .array(keys.map { .string($0) }),
        ]
        let response = try await operation("Cache", "MGet", body)
        return try TriCore.cacheValues(response, "MGet")
    }

    /// Write many values as one batch, all with the same optional TTL. A repeated
    /// key is refused. Returns how many were written.
    @discardableResult
    public func cacheSetMany(
        _ namespace: String,
        _ entries: KeyValuePairs<String, Data>,
        ttl: Duration? = nil
    ) async throws -> Int {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "entries": .array(entries.map { ["key": .string($0.key), "value": TriCore.byteList($0.value)] }),
            "ttl_ms": TriCore.milliseconds(ttl),
        ]
        let response = try await operation("Cache", "MSet", body)
        let json = try response.expect("Json", "MSet")
        return json["set"]?.intValue ?? 0
    }

    /// Write a value under a condition, with explicit control over the TTL. False
    /// means the condition was not met, not that anything failed.
    @discardableResult
    public func cacheSetIf(
        _ namespace: String,
        _ key: String,
        _ value: Data,
        condition: SetCondition = .always,
        expiry: CacheExpiry = .clear
    ) async throws -> Bool {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "value": TriCore.byteList(value),
            "condition": .string(condition.rawValue),
            "expiry": expiry.json,
        ]
        let response = try await operation("Cache", "SetIf", body)
        let json = try response.expect("Json", "SetIf")
        return json["set"]?.boolValue ?? false
    }

    /// Add scored members to a sorted set, or re-score ones already there. Answers
    /// `added` and `updated`. A NaN score is refused.
    @discardableResult
    public func cacheSortedAdd(
        _ namespace: String,
        _ key: String,
        _ members: [ScoredMember]
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "members": .array(members.map(\.json)),
        ]
        let response = try await operation("Cache", "ZAdd", body)
        let json = try response.expect("Json", "ZAdd")
        return json
    }

    /// Remove members from a sorted set, returning how many were present.
    @discardableResult
    public func cacheSortedRemove(_ namespace: String, _ key: String, _ members: [Data]) async throws -> Int {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "members": .array(members.map(TriCore.byteList)),
        ]
        let response = try await operation("Cache", "ZRem", body)
        let json = try response.expect("Json", "ZRem")
        return json["removed"]?.intValue ?? 0
    }

    /// The score of one member, or null when it is not in the set.
    @discardableResult
    public func cacheSortedScore(_ namespace: String, _ key: String, member: Data) async throws -> Double? {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "member": TriCore.byteList(member),
        ]
        let response = try await operation("Cache", "ZScore", body)
        let json = try response.expect("Json", "ZScore")
        return json["score"]?.doubleValue
    }

    /// How many members a sorted set holds.
    @discardableResult
    public func cacheSortedCount(_ namespace: String, _ key: String) async throws -> Int {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
        ]
        let response = try await operation("Cache", "ZCard", body)
        let json = try response.expect("Json", "ZCard")
        return json["cardinality"]?.intValue ?? 0
    }

    /// A member's position in the ordering, or null when it is absent. `rev` counts
    /// from the high-scoring end.
    @discardableResult
    public func cacheSortedRank(
        _ namespace: String,
        _ key: String,
        member: Data,
        rev: Bool = false
    ) async throws -> Int? {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "member": TriCore.byteList(member),
            "rev": .bool(rev),
        ]
        let response = try await operation("Cache", "ZRank", body)
        let json = try response.expect("Json", "ZRank")
        return json["rank"]?.intValue
    }

    /// Members by rank, `start..=stop` inclusive. Negative indices count from the
    /// end, so `0, -1` is the whole set.
    @discardableResult
    public func cacheSortedRange(
        _ namespace: String,
        _ key: String,
        start: Int,
        stop: Int,
        rev: Bool = false,
        withScores: Bool = false
    ) async throws -> [ScoredMember] {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "start": .int(Int64(start)),
            "stop": .int(Int64(stop)),
            "rev": .bool(rev),
            "with_scores": .bool(withScores),
        ]
        let response = try await operation("Cache", "ZRange", body)
        let json = try response.expect("Json", "ZRange")
        return try TriCore.scoredMembers(json)
    }

    /// Members by score, between two bounds. `limit` is `(offset, count)`, applied
    /// after the range is selected.
    @discardableResult
    public func cacheSortedRangeByScore(
        _ namespace: String,
        _ key: String,
        min: ScoreBound,
        max: ScoreBound,
        rev: Bool = false,
        withScores: Bool = false,
        limit: (Int, Int)? = nil
    ) async throws -> [ScoredMember] {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "min": min.json,
            "max": max.json,
            "rev": .bool(rev),
            "with_scores": .bool(withScores),
            "limit": limit.map { .array([.int(Int64($0.0)), .int(Int64($0.1))]) } ?? .null,
        ]
        let response = try await operation("Cache", "ZRangeByScore", body)
        let json = try response.expect("Json", "ZRangeByScore")
        return try TriCore.scoredMembers(json)
    }

    /// Add to a member's score, creating it at that score when absent. Returns the
    /// resulting score.
    @discardableResult
    public func cacheSortedIncrement(
        _ namespace: String,
        _ key: String,
        member: Data,
        by: Double
    ) async throws -> Double {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "member": TriCore.byteList(member),
            "by": .double(by),
        ]
        let response = try await operation("Cache", "ZIncrBy", body)
        let json = try response.expect("Json", "ZIncrBy")
        return json["score"]?.doubleValue ?? 0
    }

    /// Take a lease on a lock, or refresh one already held by `owner`. Answers
    /// `acquired`, `token` (a fencing token that strictly increases with every
    /// acquisition and is never reused), `holder` and `expiresAtMs`.
    @discardableResult
    public func cacheLockAcquire(
        _ namespace: String,
        _ key: String,
        owner: String,
        ttl: Duration
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "owner": .string(owner),
            "ttl_ms": TriCore.wholeMilliseconds(ttl),
        ]
        let response = try await operation("Cache", "LockAcquire", body)
        let json = try response.expect("Json", "LockAcquire")
        return json
    }

    /// Extend a lease the caller still holds. Answers `renewed`, `token` and
    /// `expiresAtMs`. Refused once the lease has lapsed, even if nobody else has
    /// taken the lock since.
    @discardableResult
    public func cacheLockRenew(
        _ namespace: String,
        _ key: String,
        owner: String,
        ttl: Duration
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "owner": .string(owner),
            "ttl_ms": TriCore.wholeMilliseconds(ttl),
        ]
        let response = try await operation("Cache", "LockRenew", body)
        let json = try response.expect("Json", "LockRenew")
        return json
    }

    /// Give up a lock. Only the current, live holder can release it.
    @discardableResult
    public func cacheLockRelease(_ namespace: String, _ key: String, owner: String) async throws -> Bool {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "owner": .string(owner),
        ]
        let response = try await operation("Cache", "LockRelease", body)
        let json = try response.expect("Json", "LockRelease")
        return json["released"]?.boolValue ?? false
    }

    /// Set one bit of a string value, growing it with zero bytes if needed. Returns
    /// the bit's old value. Bits are numbered from the most significant bit of byte
    /// 0.
    @discardableResult
    public func cacheSetBit(_ namespace: String, _ key: String, offset: Int, value: Bool) async throws -> Int {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "offset": .int(Int64(offset)),
            "value": .bool(value),
        ]
        let response = try await operation("Cache", "SetBit", body)
        let json = try response.expect("Json", "SetBit")
        return json["previous"]?.intValue ?? 0
    }

    /// Read one bit. Past the end of the value, and on a missing key, every bit is
    /// 0.
    @discardableResult
    public func cacheGetBit(_ namespace: String, _ key: String, offset: Int) async throws -> Int {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "offset": .int(Int64(offset)),
        ]
        let response = try await operation("Cache", "GetBit", body)
        let json = try response.expect("Json", "GetBit")
        return json["bit"]?.intValue ?? 0
    }

    /// Count the set bits, optionally within a byte range `(start, end)` with
    /// signed indices.
    @discardableResult
    public func cacheBitCount(_ namespace: String, _ key: String, range: (Int, Int)? = nil) async throws -> Int {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "range": range.map { .array([.int(Int64($0.0)), .int(Int64($0.1))]) } ?? .null,
        ]
        let response = try await operation("Cache", "BitCount", body)
        let json = try response.expect("Json", "BitCount")
        return json["count"]?.intValue ?? 0
    }

    /// The position of the first bit equal to `bit`, optionally within a byte
    /// range, or -1 when there is none.
    @discardableResult
    public func cacheBitPosition(
        _ namespace: String,
        _ key: String,
        bit: Bool,
        range: (Int, Int)? = nil
    ) async throws -> Int {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "bit": .bool(bit),
            "range": range.map { .array([.int(Int64($0.0)), .int(Int64($0.1))]) } ?? .null,
        ]
        let response = try await operation("Cache", "BitPos", body)
        let json = try response.expect("Json", "BitPos")
        return json["position"]?.intValue ?? 0
    }

    /// Combine several values bitwise and store the result at `dest`. Returns the
    /// result's size in bytes.
    @discardableResult
    public func cacheBitOperation(
        _ namespace: String,
        op: BitOperation,
        dest: String,
        keys: [String]
    ) async throws -> Int {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "op": .string(op.rawValue),
            "dest": .string(dest),
            "keys": .array(keys.map { .string($0) }),
        ]
        let response = try await operation("Cache", "BitOp", body)
        let json = try response.expect("Json", "BitOp")
        return json["length"]?.intValue ?? 0
    }

    /// Add elements to a HyperLogLog, creating it when absent. Returns whether the
    /// estimate may have moved.
    @discardableResult
    public func cacheHyperLogLogAdd(_ namespace: String, _ key: String, _ elements: [Data]) async throws -> Bool {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "elements": .array(elements.map(TriCore.byteList)),
        ]
        let response = try await operation("Cache", "PfAdd", body)
        let json = try response.expect("Json", "PfAdd")
        return json["changed"]?.boolValue ?? false
    }

    /// Estimated number of distinct elements. With several keys, the estimate is of
    /// their union.
    @discardableResult
    public func cacheHyperLogLogCount(_ namespace: String, _ keys: [String]) async throws -> Int {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "keys": .array(keys.map { .string($0) }),
        ]
        let response = try await operation("Cache", "PfCount", body)
        let json = try response.expect("Json", "PfCount")
        return json["count"]?.intValue ?? 0
    }

    /// Merge several HyperLogLogs into `dest`, which is included as a source when
    /// it already exists.
    public func cacheHyperLogLogMerge(_ namespace: String, dest: String, sources: [String]) async throws {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "dest": .string(dest),
            "sources": .array(sources.map { .string($0) }),
        ]
        _ = try await operation("Cache", "PfMerge", body)
    }

    /// Atomically pop an element from one end of `source` and push it onto one end
    /// of `destination`. Returns the element, or null when `source` is empty.
    @discardableResult
    public func cacheListMove(
        _ namespace: String,
        source: String,
        destination: String,
        from: ListEnd,
        to: ListEnd
    ) async throws -> Data? {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "source": .string(source),
            "destination": .string(destination),
            "from": .string(from.rawValue),
            "to": .string(to.rawValue),
        ]
        let response = try await operation("Cache", "LMove", body)
        return try TriCore.cacheValue(response, "LMove")
    }

    /// Set the absolute instant an existing live key dies. A deadline already
    /// passed deletes the key. Answers `updated` and `deleted`.
    @discardableResult
    public func cacheExpireAt(_ namespace: String, _ key: String, at: Date) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "at_ms": .int(Int64((at.timeIntervalSince1970 * 1000).rounded())),
        ]
        let response = try await operation("Cache", "ExpireAt", body)
        let json = try response.expect("Json", "ExpireAt")
        return json
    }

    /// What this node's cache is doing: lookup hits and misses, the memory budget
    /// and the eviction policy. Node-wide, not per database.
    @discardableResult
    public func cacheStats() async throws -> JSONValue {
        let response = try await operation("Cache", "Stats", nil)
        let json = try response.expect("Json", "Stats")
        return json
    }

    /// Delete every cache key in this database, across every namespace. Returns how
    /// many keys were removed.
    @discardableResult
    public func cacheFlushDatabase() async throws -> Int {
        let response = try await operation("Cache", "FlushDatabase", nil)
        let json = try response.expect("Json", "FlushDatabase")
        return json["cleared"]?.intValue ?? 0
    }

    /// Concatenate bytes onto what a key already holds, and return the new length.
    /// A missing key is created; an existing key keeps its expiry.
    @discardableResult
    public func cacheAppend(_ namespace: String, _ key: String, _ value: Data) async throws -> Int {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "value": TriCore.byteList(value),
        ]
        let response = try await operation("Cache", "Append", body)
        let json = try response.expect("Json", "Append")
        return json["length"]?.intValue ?? 0
    }

    /// Write only if the key still holds `expected` (null: the key must be absent).
    /// A null `value` deletes the key. Answers `swapped`; on a mismatch, `current`
    /// holds the value present when it is valid UTF-8, and `currentIsBinary` is
    /// true when it is not.
    @discardableResult
    public func cacheCompareAndSwap(
        _ namespace: String,
        _ key: String,
        expected: Data?,
        value: Data?,
        ttl: Duration? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "expected": expected.map(TriCore.byteList) ?? .null,
            "value": value.map(TriCore.byteList) ?? .null,
            "ttl_ms": TriCore.milliseconds(ttl),
        ]
        let response = try await operation("Cache", "CompareAndSwap", body)
        let json = try response.expect("Json", "CompareAndSwap")
        return json
    }

    /// Read a key and delete it in one atomic step. Null when the key was absent or
    /// expired.
    @discardableResult
    public func cacheGetAndDelete(_ namespace: String, _ key: String) async throws -> Data? {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
        ]
        let response = try await operation("Cache", "GetDel", body)
        return try TriCore.cacheValue(response, "GetDel")
    }

    /// Write a value and return the one it replaced, atomically. Any TTL on the old
    /// value is dropped.
    @discardableResult
    public func cacheGetAndSet(
        _ namespace: String,
        _ key: String,
        _ value: Data,
        ttl: Duration? = nil
    ) async throws -> Data? {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "value": TriCore.byteList(value),
            "ttl_ms": TriCore.milliseconds(ttl),
        ]
        let response = try await operation("Cache", "GetSet", body)
        return try TriCore.cacheValue(response, "GetSet")
    }

    /// Read a key and change its expiry in the same atomic step. The value itself
    /// is never modified.
    @discardableResult
    public func cacheGetAndExpire(_ namespace: String, _ key: String, expiry: CacheExpiry) async throws -> Data? {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "expiry": expiry.json,
        ]
        let response = try await operation("Cache", "GetEx", body)
        return try TriCore.cacheValue(response, "GetEx")
    }

    /// Keep only the inclusive index range of a list, dropping everything outside
    /// it. Answers `length` and `removed`.
    @discardableResult
    public func cacheListTrim(_ namespace: String, _ key: String, start: Int, stop: Int) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "start": .int(Int64(start)),
            "stop": .int(Int64(stop)),
        ]
        let response = try await operation("Cache", "LTrim", body)
        let json = try response.expect("Json", "LTrim")
        return json
    }

    /// Every member of every named set, without duplicates. A missing key is the
    /// empty set.
    @discardableResult
    public func cacheSetUnion(_ namespace: String, _ keys: [String]) async throws -> [Data] {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "keys": .array(keys.map { .string($0) }),
        ]
        let response = try await operation("Cache", "SUnion", body)
        let json = try response.expect("Json", "SUnion")
        return try (json["members"]?.arrayValue ?? []).map(TriCore.decodeBytes)
    }

    /// The members present in every named set.
    @discardableResult
    public func cacheSetIntersection(_ namespace: String, _ keys: [String]) async throws -> [Data] {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "keys": .array(keys.map { .string($0) }),
        ]
        let response = try await operation("Cache", "SInter", body)
        let json = try response.expect("Json", "SInter")
        return try (json["members"]?.arrayValue ?? []).map(TriCore.decodeBytes)
    }

    /// The members of the first set that are in none of the rest.
    @discardableResult
    public func cacheSetDifference(_ namespace: String, _ keys: [String]) async throws -> [Data] {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "keys": .array(keys.map { .string($0) }),
        ]
        let response = try await operation("Cache", "SDiff", body)
        let json = try response.expect("Json", "SDiff")
        return try (json["members"]?.arrayValue ?? []).map(TriCore.decodeBytes)
    }

    /// Random members of a set, without removing them. No count: at most one. A
    /// positive count: up to that many distinct members. A negative count: exactly
    /// that many, repeats allowed.
    @discardableResult
    public func cacheSetRandomMembers(_ namespace: String, _ key: String, count: Int? = nil) async throws -> [Data] {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "count": TriCore.optional(count),
        ]
        let response = try await operation("Cache", "SRandMember", body)
        let json = try response.expect("Json", "SRandMember")
        return try (json["members"]?.arrayValue ?? []).map(TriCore.decodeBytes)
    }

    /// Add to one hash field, atomically, returning its new value. A missing field
    /// starts at zero.
    @discardableResult
    public func cacheHashIncrement(_ namespace: String, _ key: String, field: Data, by: Int) async throws -> Int {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "key": .string(key),
            "field": TriCore.byteList(field),
            "by": .int(Int64(by)),
        ]
        let response = try await operation("Cache", "HIncrBy", body)
        let json = try response.expect("Json", "HIncrBy")
        return json["value"]?.intValue ?? 0
    }

    /// Run cache operations in order in one round trip, each exactly as if it had
    /// been sent alone. A failing operation does not stop the rest.
    @discardableResult
    public func cachePipeline(_ ops: [CacheOp]) async throws -> [CacheOpResult] {
        let body: [String: JSONValue] = [
            "ops": .array(ops.map(\.json)),
        ]
        let response = try await operation("Cache", "Pipeline", body)
        let json = try response.expect("Json", "Pipeline")
        return (json["results"]?.arrayValue ?? []).map(CacheOpResult.init)
    }

    /// Run cache operations in order holding the cache write lock, so no other
    /// writer interleaves with them. Every operation's inputs are checked before
    /// any runs; after that there is no rollback.
    @discardableResult
    public func cacheTransaction(_ ops: [CacheOp]) async throws -> [CacheOpResult] {
        let body: [String: JSONValue] = [
            "ops": .array(ops.map(\.json)),
        ]
        let response = try await operation("Cache", "Transaction", body)
        let json = try response.expect("Json", "Transaction")
        return (json["results"]?.arrayValue ?? []).map(CacheOpResult.init)
    }

    /// Store a script: operations run as one transaction, where any string (or
    /// value) written `$1`, `$2`, ... is replaced by that argument at run time.
    /// Loading the same name again replaces it.
    public func cacheScriptLoad(name: String, ops: [CacheOp]) async throws {
        let body: [String: JSONValue] = [
            "name": .string(name),
            "ops": .array(ops.map(\.json)),
        ]
        _ = try await operation("Cache", "ScriptLoad", body)
    }

    /// Run a stored script with these arguments as one transaction.
    @discardableResult
    public func cacheScriptRun(name: String, args: [String] = []) async throws -> [CacheOpResult] {
        let body: [String: JSONValue] = [
            "name": .string(name),
            "args": .array(args.map { .string($0) }),
        ]
        let response = try await operation("Cache", "ScriptRun", body)
        let json = try response.expect("Json", "ScriptRun")
        return (json["results"]?.arrayValue ?? []).map(CacheOpResult.init)
    }

    /// The most frequently addressed keys on this node since it started, with
    /// estimated counts. The server must be configured with `[cache] hot_keys`
    /// above zero; otherwise it refuses.
    @discardableResult
    public func cacheHotKeys(limit: Int? = nil) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "limit": TriCore.optional(limit),
        ]
        let response = try await operation("Cache", "HotKeys", body)
        let json = try response.expect("Json", "HotKeys")
        return json
    }

    /// Delete every expired cache key in this database now, rather than leaving it
    /// to compaction. Returns how many went.
    @discardableResult
    public func cachePurgeExpired() async throws -> Int {
        let response = try await operation("Cache", "PurgeExpired", nil)
        let json = try response.expect("Json", "PurgeExpired")
        return json["purged"]?.intValue ?? 0
    }

    /// Pop the head of the first non-empty list among `keys`, waiting up to the
    /// timeout for one to receive an element. Null when the wait ran out.
    @discardableResult
    public func cacheBlockingLeftPop(
        _ namespace: String,
        _ keys: [String],
        timeout: Duration
    ) async throws -> (key: String, value: Data)? {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "keys": .array(keys.map { .string($0) }),
            "timeout_ms": TriCore.wholeMilliseconds(timeout),
        ]
        let response = try await operation("Cache", "BLPop", body)
        return try TriCore.popped(response, "BLPop")
    }

    /// Pop the tail of the first non-empty list among `keys`, waiting up to the
    /// timeout for one to receive an element. Null when the wait ran out.
    @discardableResult
    public func cacheBlockingRightPop(
        _ namespace: String,
        _ keys: [String],
        timeout: Duration
    ) async throws -> (key: String, value: Data)? {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "keys": .array(keys.map { .string($0) }),
            "timeout_ms": TriCore.wholeMilliseconds(timeout),
        ]
        let response = try await operation("Cache", "BRPop", body)
        return try TriCore.popped(response, "BRPop")
    }

    /// Cap a namespace at `maxKeys` live keys and `maxBytes` of values. A write
    /// that would pass either is refused. Both absent removes the limit.
    @discardableResult
    public func cacheSetNamespaceLimit(
        _ namespace: String,
        maxKeys: Int? = nil,
        maxBytes: Int? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
            "max_keys": TriCore.optional(maxKeys),
            "max_bytes": TriCore.optional(maxBytes),
        ]
        let response = try await operation("Cache", "SetNamespaceLimit", body)
        let json = try response.expect("Json", "SetNamespaceLimit")
        return json
    }

    /// A namespace's limit and what it holds now: `max_keys`, `max_bytes`, `keys`
    /// and `bytes`.
    @discardableResult
    public func cacheGetNamespaceLimit(_ namespace: String) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "namespace": .string(namespace),
        ]
        let response = try await operation("Cache", "GetNamespaceLimit", body)
        let json = try response.expect("Json", "GetNamespaceLimit")
        return json
    }

    /// Append a message to a channel, returning the id it was given.
    @discardableResult
    public func cachePublish(channel: String, message: String) async throws -> Int {
        let body: [String: JSONValue] = [
            "channel": .string(channel),
            "message": .string(message),
        ]
        let response = try await operation("Cache", "Publish", body)
        let json = try response.expect("Json", "Publish")
        return json["id"]?.intValue ?? 0
    }

    /// The messages after id `after` on these channels (a trailing `*` is a
    /// pattern). Answers `messages` and `next`, the id to pass as `after` next
    /// time.
    @discardableResult
    public func cachePoll(_ channels: [String], after: Int = 0, limit: Int = 100) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "channels": .array(channels.map { .string($0) }),
            "after": .int(Int64(after)),
            "limit": .int(Int64(limit)),
        ]
        let response = try await operation("Cache", "Poll", body)
        let json = try response.expect("Json", "Poll")
        return json
    }

    // MARK: - Documents

    /// Swap a document's whole body for a new one: afterwards the stored body is
    /// exactly `document`, plus `_id`. With `upsert`, a missing document is created
    /// rather than refused. Answers `id`, `replaced`, `inserted` and, when asked
    /// for, `document`.
    @discardableResult
    public func documentReplace(
        _ collection: String,
        id: String,
        document: [String: JSONValue],
        upsert: Bool = false,
        returnDocument: ReturnDocument = .none,
        expectedVersion: Int? = nil,
        txn: String? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "id": .string(id),
            "document": .object(document),
            "upsert": .bool(upsert),
            "return": .string(returnDocument.rawValue),
            "expected_version": TriCore.optional(expectedVersion),
        ]
        let response = try await operation("Document", "Replace", body, txn: txn)
        let json = try response.expect("Json", "Replace")
        return json
    }

    /// Insert several documents as one atomic batch: either every document lands or
    /// none does. Each document's id is its own `_id` when it carries one, and is
    /// generated otherwise. Returns the ids, in order.
    @discardableResult
    public func documentInsertMany(
        _ collection: String,
        _ documents: [[String: JSONValue]],
        txn: String? = nil
    ) async throws -> [String] {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "documents": .array(documents.map { .object($0) }),
        ]
        let response = try await operation("Document", "InsertMany", body, txn: txn)
        let json = try response.expect("Json", "InsertMany")
        return (json["ids"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    /// Delete every document a filter matches, returning how many went.
    @discardableResult
    public func documentDeleteMany(
        _ collection: String,
        filter: DocumentFilter,
        txn: String? = nil
    ) async throws -> Int {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "filter": filter.json,
        ]
        let response = try await operation("Document", "DeleteMany", body, txn: txn)
        let json = try response.expect("Json", "DeleteMany")
        return json["deleted"]?.intValue ?? 0
    }

    /// Move a collection, with its documents and indexes, to a new name. Refused
    /// when the new name already exists.
    public func documentRenameCollection(_ collection: String, to: String) async throws {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "to": .string(to),
        ]
        _ = try await operation("Document", "RenameCollection", body)
    }

    /// Delete the documents a TTL index says have expired, now. Returns how many
    /// went.
    @discardableResult
    public func documentPurgeExpired(_ collection: String) async throws -> Int {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
        ]
        let response = try await operation("Document", "PurgeExpired", body)
        let json = try response.expect("Json", "PurgeExpired")
        return json["purged"]?.intValue ?? 0
    }

    /// Run a find and describe how it ran instead of returning its documents: the
    /// plan, the index, why it scanned, the estimate, records examined and
    /// returned, and the time taken.
    @discardableResult
    public func documentExplain(
        _ collection: String,
        filter: DocumentFilter = .all,
        limit: Int? = nil,
        sort: [[String: JSONValue]] = [],
        skip: Int? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "filter": filter.json,
            "limit": TriCore.optional(limit),
            "sort": .array(sort.map { .object($0) }),
            "skip": TriCore.optional(skip),
        ]
        let response = try await operation("Document", "Explain", body)
        let json = try response.expect("Json", "Explain")
        return json
    }

    /// Open a document transaction spanning requests, returning its id. Each later
    /// call given that id as `txn` reads and writes inside it, seeing its own
    /// writes and nobody else's since it began. Snapshot isolation, or
    /// serializable.
    @discardableResult
    public func documentBeginTransaction(serializable: Bool = false) async throws -> String {
        let body: [String: JSONValue] = [
            "serializable": .bool(serializable),
        ]
        let response = try await operation("Document", "BeginTransaction", body)
        let json = try response.expect("Json", "BeginTransaction")
        return json["txn"]?.stringValue ?? ""
    }

    /// Commit a document transaction: every write lands as one atomic batch, or a
    /// conflict is returned and nothing lands.
    @discardableResult
    public func documentCommitTransaction(txn: String) async throws -> JSONValue {
        let response = try await operation("Document", "CommitTransaction", nil, txn: txn)
        let json = try response.expect("Json", "CommitTransaction")
        return json
    }

    /// Discard a document transaction.
    public func documentRollbackTransaction(txn: String) async throws {
        _ = try await operation("Document", "RollbackTransaction", nil, txn: txn)
    }

    /// Rebuild one index from the stored documents. Answers `rebuilt`, `documents`
    /// and `entries`.
    @discardableResult
    public func documentRebuildIndex(_ collection: String, indexName: String) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "index_name": .string(indexName),
        ]
        let response = try await operation("Document", "RebuildIndex", body)
        let json = try response.expect("Json", "RebuildIndex")
        return json
    }

    /// Set a collection's options (`schema`, `defaults`, `versioned`), replacing
    /// any it had. Refused when an existing document would break the new schema.
    @discardableResult
    public func documentSetCollectionOptions(
        _ collection: String,
        options: [String: JSONValue]
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "options": .object(options),
        ]
        let response = try await operation("Document", "SetCollectionOptions", body)
        let json = try response.expect("Json", "SetCollectionOptions")
        return json
    }

    /// A collection's options.
    @discardableResult
    public func documentGetCollectionOptions(_ collection: String) async throws -> [String: JSONValue] {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
        ]
        let response = try await operation("Document", "GetCollectionOptions", body)
        let json = try response.expect("Json", "GetCollectionOptions")
        return json["options"]?.objectValue ?? [:]
    }

    /// Many inserts, updates, replaces and deletes on one collection, applied in
    /// order as one atomic batch: every operation lands or none does. Answers
    /// `inserted`, `inserted_ids`, `updated`, `upserted`, `replaced` and `deleted`.
    @discardableResult
    public func documentBulkWrite(
        _ collection: String,
        _ ops: [BulkOp],
        txn: String? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "ops": .array(ops.map(\.json)),
        ]
        let response = try await operation("Document", "BulkWrite", body, txn: txn)
        let json = try response.expect("Json", "BulkWrite")
        return json
    }

    // MARK: - Vectors

    /// Embed texts with the server's built-in embedder (deterministic feature
    /// hashing: lexical, no model). Nothing is stored. Answers `vectors`, `sparse`,
    /// `embedder` and `dimension`.
    @discardableResult
    public func vectorEmbed(_ texts: [String], dimension: Int) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "texts": .array(texts.map { .string($0) }),
            "dimension": .int(Int64(dimension)),
        ]
        let response = try await operation("Vector", "Embed", body)
        let json = try response.expect("Json", "Embed")
        return json
    }

    /// Embed each text at the collection's dimension and upsert the vectors as one
    /// atomic batch. Items are `{id, text, metadata}`; the text is kept in the
    /// metadata under `text`. Returns how many were written.
    @discardableResult
    public func vectorUpsertText(_ collection: String, _ items: [[String: JSONValue]]) async throws -> Int {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "items": .array(items.map { .object($0) }),
        ]
        let response = try await operation("Vector", "UpsertText", body)
        let json = try response.expect("Json", "UpsertText")
        return json["upserted"]?.intValue ?? 0
    }

    /// Point an alias at a collection; a null collection removes it. Every
    /// operation naming the alias acts on the collection.
    public func vectorSetAlias(alias: String, collection: String? = nil) async throws {
        let body: [String: JSONValue] = [
            "alias": .string(alias),
            "collection": TriCore.optional(collection),
        ]
        _ = try await operation("Vector", "SetAlias", body)
    }

    /// Every alias and the collection it names, as `{alias, collection}`.
    @discardableResult
    public func vectorListAliases() async throws -> [JSONValue] {
        let response = try await operation("Vector", "ListAliases", nil)
        let json = try response.expect("Json", "ListAliases")
        return json["aliases"]?.arrayValue ?? []
    }

    /// Declare a named vector on a collection: a second vector per item, with its
    /// own dimension and metric.
    public func vectorAddNamedVector(
        _ collection: String,
        name: String,
        dimension: Int,
        metric: VectorMetric = .cosine
    ) async throws {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "name": .string(name),
            "dimension": .int(Int64(dimension)),
            "metric": .string(metric.rawValue),
        ]
        _ = try await operation("Vector", "AddNamedVector", body)
    }

    /// Write an item's vectors by name (`default` is the collection's own), each
    /// with the same metadata.
    public func vectorUpsertNamed(
        _ collection: String,
        id: String,
        vectors: [String: [Float]],
        metadata: [String: JSONValue]? = nil
    ) async throws {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "id": .string(id),
            "vectors": .object(vectors.mapValues(TriCore.floats)),
            "metadata": metadata.map { .object($0) } ?? .null,
        ]
        _ = try await operation("Vector", "UpsertNamed", body)
    }

    /// Write many vectors as one atomic batch. Items are `{id, vector, metadata}`.
    /// Every item is validated before any is written, and a repeated id is refused.
    /// Returns how many were written.
    @discardableResult
    public func vectorUpsertMany(_ collection: String, _ items: [[String: JSONValue]]) async throws -> Int {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "items": .array(items.map { .object($0) }),
        ]
        let response = try await operation("Vector", "UpsertMany", body)
        let json = try response.expect("Json", "UpsertMany")
        return json["upserted"]?.intValue ?? 0
    }

    /// Delete many vectors by id as one atomic batch, returning how many of the ids
    /// were present.
    @discardableResult
    public func vectorDeleteMany(_ collection: String, ids: [String]) async throws -> Int {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "ids": .array(ids.map { .string($0) }),
        ]
        let response = try await operation("Vector", "DeleteMany", body)
        let json = try response.expect("Json", "DeleteMany")
        return json["deleted"]?.intValue ?? 0
    }

    /// Run several query vectors against one collection in one request. One result
    /// list per query, in the order asked, each what a single search with the same
    /// arguments returns.
    @discardableResult
    public func vectorSearchBatch(
        _ collection: String,
        _ vectors: [[Float]],
        topK: Int,
        filter: [String: JSONValue]? = nil,
        minScore: Double? = nil,
        includeVectors: Bool = false,
        options: VectorSearchOptions? = nil
    ) async throws -> [[VectorHit]] {
        var body: [String: JSONValue] = [
            "collection": .string(collection),
            "vectors": .array(vectors.map(TriCore.floats)),
            "top_k": .int(Int64(topK)),
            "filter": filter.map { .object($0) } ?? .null,
            "min_score": TriCore.optional(minScore),
            "include_vectors": .bool(includeVectors),
        ]
        body.merge(options?.json ?? [:]) { _, given in given }
        let response = try await operation("Vector", "SearchBatch", body)
        let json = try response.expect("Json", "SearchBatch")
        return (json["results"]?.arrayValue ?? []).map(TriCore.hits)
    }

    /// Delete every vector whose metadata matches a filter, as one atomic batch. An
    /// empty filter is refused.
    @discardableResult
    public func vectorDeleteByFilter(_ collection: String, filter: [String: JSONValue]) async throws -> Int {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "filter": .object(filter),
        ]
        let response = try await operation("Vector", "DeleteByFilter", body)
        let json = try response.expect("Json", "DeleteByFilter")
        return json["deleted"]?.intValue ?? 0
    }

    /// Merge `set` into the metadata of every vector matching a filter, as one
    /// atomic batch. Vectors are never touched.
    @discardableResult
    public func vectorUpdateByFilter(
        _ collection: String,
        filter: [String: JSONValue],
        set: [String: JSONValue]
    ) async throws -> Int {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "filter": .object(filter),
            "set": .object(set),
        ]
        let response = try await operation("Vector", "UpdateByFilter", body)
        let json = try response.expect("Json", "UpdateByFilter")
        return json["updated"]?.intValue ?? 0
    }

    /// How many vectors a collection holds, or, with a filter, how many match it.
    /// An exact count.
    @discardableResult
    public func vectorCount(_ collection: String, filter: [String: JSONValue]? = nil) async throws -> Int {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "filter": filter.map { .object($0) } ?? .null,
        ]
        let response = try await operation("Vector", "Count", body)
        let json = try response.expect("Json", "Count")
        return json["count"]?.intValue ?? 0
    }

    /// The partitions of a collection: each distinct value of `field` (`_namespace`
    /// or `_tenant`) with its vector count, under `partitions`, plus
    /// `unpartitioned`.
    @discardableResult
    public func vectorListPartitions(_ collection: String, field: String = "_namespace") async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "field": .string(field),
        ]
        let response = try await operation("Vector", "ListPartitions", body)
        let json = try response.expect("Json", "ListPartitions")
        return json
    }

    /// Rename a collection, moving its catalog record and every vector with it.
    /// Refused when the new name already exists.
    public func vectorRenameCollection(_ collection: String, to: String) async throws {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "to": .string(to),
        ]
        _ = try await operation("Vector", "RenameCollection", body)
    }

    /// Rebuild the collection's ANN index from its stored vectors and persist it,
    /// clearing every tombstone.
    @discardableResult
    public func vectorRebuildIndex(_ collection: String) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
        ]
        let response = try await operation("Vector", "RebuildIndex", body)
        let json = try response.expect("Json", "RebuildIndex")
        return json
    }

    /// The shape of the collection's ANN index: layers, degrees, tombstones,
    /// reachability and memory.
    @discardableResult
    public func vectorIndexStats(_ collection: String) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
        ]
        let response = try await operation("Vector", "IndexStats", body)
        let json = try response.expect("Json", "IndexStats")
        return json
    }

    /// Measure the ANN index's recall: sampled stored vectors are each searched
    /// through the index and by an exact scan, and the overlap is reported under
    /// `recall`.
    @discardableResult
    public func vectorMeasureRecall(
        _ collection: String,
        sample: Int? = nil,
        topK: Int? = nil,
        efSearch: Int? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "sample": TriCore.optional(sample),
            "top_k": TriCore.optional(topK),
            "ef_search": TriCore.optional(efSearch),
        ]
        let response = try await operation("Vector", "MeasureRecall", body)
        let json = try response.expect("Json", "MeasureRecall")
        return json
    }

    /// Search with several query vectors and return one fused ranking.
    @discardableResult
    public func vectorSearchMulti(
        _ collection: String,
        _ vectors: [[Float]],
        topK: Int,
        fusion: FusionMethod = .rrf,
        filter: [String: JSONValue]? = nil
    ) async throws -> [VectorHit] {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "vectors": .array(vectors.map(TriCore.floats)),
            "top_k": .int(Int64(topK)),
            "fusion": .string(fusion.rawValue),
            "filter": filter.map { .object($0) } ?? .null,
        ]
        let response = try await operation("Vector", "SearchMulti", body)
        let json = try response.expect("Json", "SearchMulti")
        return TriCore.hits(json["results"])
    }

    /// Change a collection's configuration, returning it. `normalize` can only
    /// change on an empty collection; `m` and `efConstruction` shape the HNSW
    /// graph; `multiTenant` requires every vector to carry a `_tenant`.
    @discardableResult
    public func vectorSetCollectionConfig(
        _ collection: String,
        normalize: Bool? = nil,
        m: Int? = nil,
        efConstruction: Int? = nil,
        multiTenant: Bool? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "normalize": TriCore.optional(normalize),
            "m": TriCore.optional(m),
            "ef_construction": TriCore.optional(efConstruction),
            "multi_tenant": TriCore.optional(multiTenant),
        ]
        let response = try await operation("Vector", "SetCollectionConfig", body)
        let json = try response.expect("Json", "SetCollectionConfig")
        return json
    }

    /// Copy a collection (configuration and every vector) to a new name. Refused
    /// when the new name exists.
    public func vectorCopyCollection(_ collection: String, to: String) async throws {
        let body: [String: JSONValue] = [
            "collection": .string(collection),
            "to": .string(to),
        ]
        _ = try await operation("Vector", "CopyCollection", body)
    }

    /// Search with a query built from examples: the sum of the positive examples
    /// minus the sum of the negative ones. An example is a stored vector's id or a
    /// vector given inline. Examples named by id are left out of the results unless
    /// `excludeExamples` is false.
    @discardableResult
    public func vectorSearchByExamples(
        _ collection: String,
        topK: Int,
        positive: [VectorExample] = [],
        negative: [VectorExample] = [],
        filter: [String: JSONValue]? = nil,
        minScore: Double? = nil,
        includeVectors: Bool = false,
        excludeExamples: Bool = true,
        options: VectorSearchOptions? = nil
    ) async throws -> [VectorHit] {
        var body: [String: JSONValue] = [
            "collection": .string(collection),
            "top_k": .int(Int64(topK)),
            "positive": .array(positive.map(\.json)),
            "negative": .array(negative.map(\.json)),
            "filter": filter.map { .object($0) } ?? .null,
            "min_score": TriCore.optional(minScore),
            "include_vectors": .bool(includeVectors),
            "exclude_examples": .bool(excludeExamples),
        ]
        body.merge(options?.json ?? [:]) { _, given in given }
        let response = try await operation("Vector", "SearchByExamples", body)
        let json = try response.expect("Json", "SearchByExamples")
        return TriCore.hits(json["results"])
    }

    // MARK: - Graphs

    /// Write many nodes and edges as one unit: every record lands or none does.
    /// Nodes are `{id, labels, properties}` and edges `{id, from, to, label,
    /// properties}`; an edge may join nodes created in the same batch. Answers
    /// `nodes` and `edges`.
    @discardableResult
    public func graphAddMany(
        _ graph: String,
        nodes: [[String: JSONValue]] = [],
        edges: [[String: JSONValue]] = []
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "nodes": .array(nodes.map { .object($0) }),
            "edges": .array(edges.map { .object($0) }),
        ]
        let response = try await operation("Graph", "AddMany", body)
        let json = try response.expect("Json", "AddMany")
        return json
    }

    /// Delete many nodes and edges as one unit. An id that is not there is skipped.
    /// With `detach`, every edge touching a removed node goes too. Answers
    /// `nodes_removed` and `edges_removed`.
    @discardableResult
    public func graphRemoveMany(
        _ graph: String,
        nodes: [String] = [],
        edges: [String] = [],
        detach: Bool = false
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "nodes": .array(nodes.map { .string($0) }),
            "edges": .array(edges.map { .string($0) }),
            "detach": .bool(detach),
        ]
        let response = try await operation("Graph", "RemoveMany", body)
        let json = try response.expect("Json", "RemoveMany")
        return json
    }

    /// Change an existing node in place, returning it. `properties` is a JSON merge
    /// patch: a key set to a value is set, a key set to null is removed.
    /// `removeLabels` applies before `addLabels`.
    @discardableResult
    public func graphUpdateNode(
        _ graph: String,
        id: String,
        properties: [String: JSONValue] = [:],
        addLabels: [String] = [],
        removeLabels: [String] = []
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "id": .string(id),
            "properties": .object(properties),
            "add_labels": .array(addLabels.map { .string($0) }),
            "remove_labels": .array(removeLabels.map { .string($0) }),
        ]
        let response = try await operation("Graph", "UpdateNode", body)
        let json = try response.expect("Json", "UpdateNode")
        return json
    }

    /// Change an existing edge in place, returning it. `properties` merges as for a
    /// node, and `label`, when given, changes the edge's type. The endpoints cannot
    /// change.
    @discardableResult
    public func graphUpdateEdge(
        _ graph: String,
        id: String,
        properties: [String: JSONValue] = [:],
        label: String? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "id": .string(id),
            "properties": .object(properties),
            "label": TriCore.optional(label),
        ]
        let response = try await operation("Graph", "UpdateEdge", body)
        let json = try response.expect("Json", "UpdateEdge")
        return json
    }

    /// Copy a graph (nodes, edges and schema) to a new name. Refused when the new
    /// name exists. Answers `nodes` and `edges`.
    @discardableResult
    public func graphCopy(_ graph: String, to: String) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "to": .string(to),
        ]
        let response = try await operation("Graph", "CopyGraph", body)
        let json = try response.expect("Json", "CopyGraph")
        return json
    }

    /// A bounded depth-first walk from a node: the nodes within `maxDepth` hops
    /// (default 3, at most 10), in DFS preorder, each with the shortest `depth`
    /// found.
    @discardableResult
    public func graphDfs(
        _ graph: String,
        start: String,
        direction: GraphDirection = .outgoing,
        label: String? = nil,
        maxDepth: Int? = nil,
        limit: Int? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "start": .string(start),
            "direction": .string(direction.rawValue),
            "label": TriCore.optional(label),
            "max_depth": TriCore.optional(maxDepth),
            "limit": TriCore.optional(limit),
        ]
        let response = try await operation("Graph", "Dfs", body)
        let json = try response.expect("Json", "Dfs")
        return json
    }

    /// Partition the graph's nodes into connected components, largest first. `weak`
    /// ignores edge direction; `strong` groups nodes that can each reach the other.
    @discardableResult
    public func graphConnectedComponents(
        _ graph: String,
        kind: ComponentKind = .weak,
        label: String? = nil,
        limit: Int? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "kind": .string(kind.rawValue),
            "label": TriCore.optional(label),
            "limit": TriCore.optional(limit),
        ]
        let response = try await operation("Graph", "ConnectedComponents", body)
        let json = try response.expect("Json", "ConnectedComponents")
        return json
    }

    /// Whether the graph contains a cycle (`hasCycle`), and one `cycle` as
    /// evidence.
    @discardableResult
    public func graphDetectCycle(
        _ graph: String,
        directed: Bool = true,
        label: String? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "directed": .bool(directed),
            "label": TriCore.optional(label),
        ]
        let response = try await operation("Graph", "DetectCycle", body)
        let json = try response.expect("Json", "DetectCycle")
        return json
    }

    /// Counts describing a graph: nodes and edges, per node label and per edge
    /// type, self-loops, isolated nodes, degree extremes, and edges whose endpoint
    /// no longer exists.
    @discardableResult
    public func graphStats(_ graph: String) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
        ]
        let response = try await operation("Graph", "GraphStats", body)
        let json = try response.expect("Json", "GraphStats")
        return json
    }

    /// The part of the graph within `maxDepth` hops of the seeds: the nodes reached
    /// and every edge joining two of them.
    @discardableResult
    public func graphSubgraph(
        _ graph: String,
        _ seeds: [String],
        direction: GraphDirection = .both,
        label: String? = nil,
        maxDepth: Int? = nil,
        limit: Int? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "seeds": .array(seeds.map { .string($0) }),
            "direction": .string(direction.rawValue),
            "label": TriCore.optional(label),
            "max_depth": TriCore.optional(maxDepth),
            "limit": TriCore.optional(limit),
        ]
        let response = try await operation("Graph", "Subgraph", body)
        let json = try response.expect("Json", "Subgraph")
        return json
    }

    /// What the graph's data looks like: its node labels and edge types, each with
    /// a count and the property keys seen on it.
    @discardableResult
    public func graphSchema(_ graph: String) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
        ]
        let response = try await operation("Graph", "GraphSchema", body)
        let json = try response.expect("Json", "GraphSchema")
        return json
    }

    /// The `k` cheapest loopless paths between two nodes, cheapest first (default
    /// 3, at most 20). Without `weightProperty` every edge costs 1.
    @discardableResult
    public func graphKShortestPaths(
        _ graph: String,
        from: String,
        to: String,
        k: Int? = nil,
        direction: GraphDirection = .outgoing,
        label: String? = nil,
        weightProperty: String? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "from": .string(from),
            "to": .string(to),
            "k": TriCore.optional(k),
            "direction": .string(direction.rawValue),
            "label": TriCore.optional(label),
            "weight_property": TriCore.optional(weightProperty),
        ]
        let response = try await operation("Graph", "KShortestPaths", body)
        let json = try response.expect("Json", "KShortestPaths")
        return json
    }

    /// Every simple path between two nodes of at most `maxDepth` edges (default 5,
    /// at most 10). `complete` says whether the enumeration finished.
    @discardableResult
    public func graphAllPaths(
        _ graph: String,
        from: String,
        to: String,
        direction: GraphDirection = .outgoing,
        label: String? = nil,
        maxDepth: Int? = nil,
        limit: Int? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "from": .string(from),
            "to": .string(to),
            "direction": .string(direction.rawValue),
            "label": TriCore.optional(label),
            "max_depth": TriCore.optional(maxDepth),
            "limit": TriCore.optional(limit),
        ]
        let response = try await operation("Graph", "AllPaths", body)
        let json = try response.expect("Json", "AllPaths")
        return json
    }

    /// Betweenness, closeness or eigenvector centrality: the top `limit` nodes
    /// (default 20) under `results`. `iterations` and `tolerance` tune eigenvector
    /// only.
    @discardableResult
    public func graphCentrality(
        _ graph: String,
        measure: CentralityMeasure,
        directed: Bool = true,
        label: String? = nil,
        limit: Int? = nil,
        iterations: Int? = nil,
        tolerance: Double? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "measure": .string(measure.rawValue),
            "directed": .bool(directed),
            "label": TriCore.optional(label),
            "limit": TriCore.optional(limit),
            "iterations": TriCore.optional(iterations),
            "tolerance": TriCore.optional(tolerance),
        ]
        let response = try await operation("Graph", "Centrality", body)
        let json = try response.expect("Json", "Centrality")
        return json
    }

    /// Communities by Louvain modularity optimisation, direction ignored, largest
    /// first, with the partition's `modularity`.
    @discardableResult
    public func graphCommunities(
        _ graph: String,
        label: String? = nil,
        iterations: Int? = nil,
        limit: Int? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "label": TriCore.optional(label),
            "iterations": TriCore.optional(iterations),
            "limit": TriCore.optional(limit),
        ]
        let response = try await operation("Graph", "Communities", body)
        let json = try response.expect("Json", "Communities")
        return json
    }

    /// Triangles and clustering coefficients, direction ignored.
    @discardableResult
    public func graphTriangleCount(
        _ graph: String,
        label: String? = nil,
        limit: Int? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "label": TriCore.optional(label),
            "limit": TriCore.optional(limit),
        ]
        let response = try await operation("Graph", "TriangleCount", body)
        let json = try response.expect("Json", "TriangleCount")
        return json
    }

    /// The nodes whose neighbour sets most resemble a node's, under `results`.
    @discardableResult
    public func graphNodeSimilarity(
        _ graph: String,
        node: String,
        direction: GraphDirection = .both,
        label: String? = nil,
        metric: SimilarityMetric = .jaccard,
        limit: Int? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "node": .string(node),
            "direction": .string(direction.rawValue),
            "label": TriCore.optional(label),
            "metric": .string(metric.rawValue),
            "limit": TriCore.optional(limit),
        ]
        let response = try await operation("Graph", "NodeSimilarity", body)
        let json = try response.expect("Json", "NodeSimilarity")
        return json
    }

    /// Check a graph's stored records against each other and against the resident
    /// mirror: dangling edges, undecodable records, misfiled records and any
    /// disagreement between mirror and storage.
    @discardableResult
    public func graphCheckConsistency(_ graph: String) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
        ]
        let response = try await operation("Graph", "CheckConsistency", body)
        let json = try response.expect("Json", "CheckConsistency")
        return json
    }

    /// Index node properties for finding nodes. With one property it is a property
    /// index, with several a composite one; `label` limits it to nodes carrying
    /// that label.
    public func graphCreateNodeIndex(
        _ graph: String,
        name: String,
        properties: [String],
        label: String? = nil
    ) async throws {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "name": .string(name),
            "properties": .array(properties.map { .string($0) }),
            "label": TriCore.optional(label),
        ]
        _ = try await operation("Graph", "CreateNodeIndex", body)
    }

    /// Enforce a rule on a property of every node (or, with target `edge`, every
    /// relationship) carrying a label. Refused when a stored record already breaks
    /// it; afterwards every write that would break it is refused.
    public func graphCreateConstraint(
        _ graph: String,
        name: String,
        label: String,
        property: String,
        kind: ConstraintKind,
        target: ConstraintTarget = .node
    ) async throws {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "name": .string(name),
            "label": .string(label),
            "property": .string(property),
            "kind": .string(kind.rawValue),
            "target": .string(target.rawValue),
        ]
        _ = try await operation("Graph", "CreateConstraint", body)
    }

    /// Drop an index or a constraint by name.
    public func graphDropSchemaObject(_ graph: String, name: String) async throws {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "name": .string(name),
        ]
        _ = try await operation("Graph", "DropSchemaObject", body)
    }

    /// A graph's `indexes` and `constraints`.
    @discardableResult
    public func graphListSchemaObjects(_ graph: String) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
        ]
        let response = try await operation("Graph", "ListSchemaObjects", body)
        let json = try response.expect("Json", "ListSchemaObjects")
        return json
    }

    /// Nodes with a label (when given) whose properties equal the given values, in
    /// id order. `plan` says whether an index, the label index or a scan answered.
    @discardableResult
    public func graphFindNodes(
        _ graph: String,
        label: String? = nil,
        properties: [String: JSONValue] = [:],
        limit: Int? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "label": TriCore.optional(label),
            "properties": .object(properties),
            "limit": TriCore.optional(limit),
        ]
        let response = try await operation("Graph", "FindNodes", body)
        let json = try response.expect("Json", "FindNodes")
        return json
    }

    /// Import nodes and edges from CSV text as one atomic batch, so constraints
    /// apply. Answers `nodes` and `edges`.
    @discardableResult
    public func graphImportCsv(
        _ graph: String,
        nodes: String? = nil,
        edges: String? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "nodes": TriCore.optional(nodes),
            "edges": TriCore.optional(edges),
        ]
        let response = try await operation("Graph", "ImportCsv", body)
        let json = try response.expect("Json", "ImportCsv")
        return json
    }

    /// PageRank over edge direction: the top `limit` nodes (default 20) under
    /// `ranks`. `damping` defaults to 0.85.
    @discardableResult
    public func graphPageRank(
        _ graph: String,
        damping: Double? = nil,
        iterations: Int? = nil,
        tolerance: Double? = nil,
        label: String? = nil,
        limit: Int? = nil
    ) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "damping": TriCore.optional(damping),
            "iterations": TriCore.optional(iterations),
            "tolerance": TriCore.optional(tolerance),
            "label": TriCore.optional(label),
            "limit": TriCore.optional(limit),
        ]
        let response = try await operation("Graph", "PageRank", body)
        let json = try response.expect("Json", "PageRank")
        return json
    }

    /// Run a Cypher write: `CREATE`, `MERGE`, `SET`, `REMOVE` or `[DETACH] DELETE`,
    /// optionally after `MATCH ... [WHERE ...]`. Given a transaction id as `txn`,
    /// the statement is queued rather than applied.
    @discardableResult
    public func graphExecute(_ graph: String, cypher: String, txn: String? = nil) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
            "cypher": .string(cypher),
        ]
        let response = try await operation("Graph", "Execute", body, txn: txn)
        let json = try response.expect("Json", "Execute")
        return json
    }

    /// Open a transaction on a graph, returning its id. An execute given that id as
    /// `txn` is queued until the transaction commits.
    @discardableResult
    public func graphBeginTransaction(_ graph: String) async throws -> String {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
        ]
        let response = try await operation("Graph", "BeginTransaction", body)
        let json = try response.expect("Json", "BeginTransaction")
        return json["transaction"]?.stringValue ?? ""
    }

    /// Apply every statement queued in a graph transaction as one: all of them or
    /// none.
    @discardableResult
    public func graphCommitTransaction(_ graph: String, txn: String) async throws -> JSONValue {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
        ]
        let response = try await operation("Graph", "CommitTransaction", body, txn: txn)
        let json = try response.expect("Json", "CommitTransaction")
        return json
    }

    /// Discard a graph transaction and its queued statements.
    public func graphRollbackTransaction(_ graph: String, txn: String) async throws {
        let body: [String: JSONValue] = [
            "graph": .string(graph),
        ]
        _ = try await operation("Graph", "RollbackTransaction", body, txn: txn)
    }

    // MARK: - Shared

    /// Send one operation. `body` is `nil` for an operation that has no fields.
    private func operation(
        _ family: String, _ variant: String, _ body: [String: JSONValue]?, txn: String? = nil
    ) async throws -> Response {
        let op: JSONValue = body.map { [variant: .object($0)] } ?? .string(variant)
        return try await send([family: op], txn: txn)
    }

    static func optional(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }
    static func optional(_ value: Int?) -> JSONValue { value.map { .int(Int64($0)) } ?? .null }
    static func optional(_ value: Double?) -> JSONValue { value.map { .double($0) } ?? .null }
    static func optional(_ value: Bool?) -> JSONValue { value.map { .bool($0) } ?? .null }

    /// A duration the server requires, in whole milliseconds.
    static func wholeMilliseconds(_ duration: Duration) -> JSONValue {
        .int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    static func floats(_ values: [Float]) -> JSONValue {
        .array(values.map { .double(Double($0)) })
    }

    static func cacheValue(_ response: Response, _ what: String) throws -> Data? {
        let payload = try response.expect("CacheValue", what)
        return payload.isNull ? nil : try decodeBytes(payload)
    }

    static func cacheValues(_ response: Response, _ what: String) throws -> [Data?] {
        let payload = try response.expect("CacheValues", what)
        return try (payload.arrayValue ?? []).map { $0.isNull ? nil : try decodeBytes($0) }
    }

    /// A blocking pop answers `[key, value]`, or `[null, null]` when the wait ran out.
    static func popped(_ response: Response, _ what: String) throws -> (key: String, value: Data)? {
        let values = try cacheValues(response, what)
        guard values.count == 2, let key = values[0], let value = values[1] else { return nil }
        return (String(decoding: key, as: UTF8.self), value)
    }

    /// A range read with scores answers `{member, score}` objects; without, the
    /// members alone.
    static func scoredMembers(_ json: JSONValue) throws -> [ScoredMember] {
        try (json["members"]?.arrayValue ?? []).map { item in
            if let member = item["member"] {
                return ScoredMember(member: try decodeBytes(member), score: item["score"]?.doubleValue)
            }
            return ScoredMember(member: try decodeBytes(item), score: nil)
        }
    }

    static func hits(_ results: JSONValue?) -> [VectorHit] {
        (results?.arrayValue ?? []).map { hit in
            VectorHit(
                id: hit["id"]?.stringValue ?? "",
                score: hit["score"]?.doubleValue ?? 0,
                metadata: hit["metadata"]?.objectValue ?? [:],
                vector: hit["vector"]?.arrayValue?.compactMap { $0.doubleValue.map { Float($0) } },
                reason: hit["reason"]?.stringValue,
                matched: hit["matched"]?.intValue)
        }
    }
}
