import Foundation

/// One `(field, value)` entry of a hash or a stream.
///
/// Fields are arbitrary bytes and need not be UTF-8, which is why this is a pair
/// rather than a dictionary key.
public struct CachePair: Sendable, Equatable {
    public let field: Data
    public let value: Data

    public init(field: Data, value: Data) {
        self.field = field
        self.value = value
    }

    /// A pair from text, encoded UTF-8.
    public init(_ field: String, _ value: String) {
        self.field = Data(field.utf8)
        self.value = Data(value.utf8)
    }

    /// The field as text, when it is valid UTF-8.
    public var fieldText: String? { String(data: field, encoding: .utf8) }
    /// The value as text, when it is valid UTF-8.
    public var valueText: String? { String(data: value, encoding: .utf8) }
}

/// One entry of a stream.
public struct StreamEntry: Sendable, Equatable {
    /// The entry's `<ms>-<seq>` id.
    public let id: String
    /// Its fields, in the order the server returned them.
    public let fields: [CachePair]

    /// The fields as text. Wrong for binary payloads, where ``fields`` stays
    /// authoritative.
    public func text() -> [String: String] {
        var out: [String: String] = [:]
        for pair in fields {
            guard let key = pair.fieldText, let value = pair.valueText else { continue }
            out[key] = value
        }
        return out
    }
}

/// One live key in a namespace.
public struct CacheKeyInfo: Sendable, Equatable {
    public let key: String
    /// Milliseconds until it expires, or `nil` when it does not.
    public let ttlMilliseconds: Int?
    /// How many bytes the value occupies.
    public let bytes: Int
}

extension TriCore {

    // MARK: - Keys

    /// A liveness check routed through the cache module.
    ///
    /// Unlike ``ping()``, which never reaches a module, this proves authentication,
    /// routing and dispatch all work.
    public func cachePing() async throws {
        _ = try await send(["Cache": "Ping"])
    }

    /// Read a value. `nil` is a miss — which is how a miss is told apart from a
    /// stored empty value.
    public func cacheGet(_ namespace: String, _ key: String) async throws -> Data? {
        try await cacheValue(["Cache": ["Get": TriCore.namespaceKey(namespace, key)]], "Get")
    }

    /// Store a value, expiring after `ttl`. `nil` means no expiry.
    public func cacheSet(_ namespace: String, _ key: String, _ value: Data, ttl: Duration? = nil) async throws {
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["value"] = TriCore.byteList(value)
        body["ttl_ms"] = TriCore.milliseconds(ttl)
        _ = try await send(["Cache": ["Set": .object(body)]])
    }

    /// Store text, encoded UTF-8.
    public func cacheSet(_ namespace: String, _ key: String, _ value: String, ttl: Duration? = nil) async throws {
        try await cacheSet(namespace, key, Data(value.utf8), ttl: ttl)
    }

    /// Store a value only if the key is absent, reporting whether it was written.
    /// The primitive behind a distributed lock.
    @discardableResult
    public func cacheSetNX(_ namespace: String, _ key: String, _ value: Data, ttl: Duration? = nil) async throws -> Bool {
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["value"] = TriCore.byteList(value)
        body["ttl_ms"] = TriCore.milliseconds(ttl)
        return try await cacheJSON(["Cache": ["SetNx": .object(body)]], "SetNx")["set"]?.boolValue ?? false
    }

    /// Delete a key, reporting whether it was there. Deleting an absent key is not
    /// an error.
    @discardableResult
    public func cacheDelete(_ namespace: String, _ key: String) async throws -> Bool {
        try await cacheJSON(["Cache": ["Delete": TriCore.namespaceKey(namespace, key)]], "Delete")["deleted"]?
            .boolValue ?? false
    }

    /// Whether the key is present and unexpired.
    public func cacheExists(_ namespace: String, _ key: String) async throws -> Bool {
        try await cacheJSON(["Cache": ["Exists": TriCore.namespaceKey(namespace, key)]], "Exists")["exists"]?
            .boolValue ?? false
    }

    /// How long until the key expires.
    ///
    /// `nil` means the key is missing **or** has no expiry; use ``cacheExists(_:_:)``
    /// to tell those apart.
    public func cacheTTL(_ namespace: String, _ key: String) async throws -> Duration? {
        let json = try await cacheJSON(["Cache": ["Ttl": TriCore.namespaceKey(namespace, key)]], "Ttl")
        guard let milliseconds = json["ttl_ms"]?.intValue, milliseconds >= 0 else { return nil }
        return .milliseconds(milliseconds)
    }

    /// Set or replace a key's TTL. `false` when the key does not exist.
    @discardableResult
    public func cacheExpire(_ namespace: String, _ key: String, ttl: Duration) async throws -> Bool {
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["ttl_ms"] = TriCore.milliseconds(ttl)
        return try await cacheJSON(["Cache": ["Expire": .object(body)]], "Expire")["updated"]?.boolValue ?? false
    }

    /// Remove a key's TTL, making it permanent. `false` when it had none.
    @discardableResult
    public func cachePersist(_ namespace: String, _ key: String) async throws -> Bool {
        try await cacheJSON(["Cache": ["Persist": TriCore.namespaceKey(namespace, key)]], "Persist")["persisted"]?
            .boolValue ?? false
    }

    /// Add to a counter and read the new value. A missing key starts at zero; a key
    /// holding something that is not a number is an error, not a conversion.
    @discardableResult
    public func cacheIncrement(_ namespace: String, _ key: String, by amount: Int = 1) async throws -> Int {
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["by"] = .int(Int64(amount))
        return try await cacheJSON(["Cache": ["Incr": .object(body)]], "Incr")["value"]?.intValue ?? 0
    }

    /// Delete every key in a namespace, returning how many went.
    @discardableResult
    public func cacheClearNamespace(_ namespace: String) async throws -> Int {
        let body: JSONValue = ["namespace": .string(namespace)]
        return try await cacheJSON(["Cache": ["ClearNamespace": body]], "ClearNamespace")["cleared"]?.intValue ?? 0
    }

    /// List live keys in a namespace.
    ///
    /// `pattern` is a simple glob where `*` matches any run of characters;
    /// `nil` lists everything, and a `nil` limit leaves the cap to the server.
    public func cacheKeys(_ namespace: String, pattern: String? = nil, limit: Int? = nil) async throws -> [CacheKeyInfo] {
        var body: [String: JSONValue] = ["namespace": .string(namespace)]
        body["pattern"] = pattern.map { .string($0) } ?? .null
        body["limit"] = limit.map { .int(Int64($0)) } ?? .null
        let json = try await cacheJSON(["Cache": ["Keys": .object(body)]], "Keys")
        return (json["keys"]?.arrayValue ?? []).map { entry in
            CacheKeyInfo(
                key: entry["key"]?.stringValue ?? "",
                ttlMilliseconds: entry["ttl_ms"]?.intValue,
                bytes: entry["bytes"]?.intValue ?? 0)
        }
    }

    // MARK: - Lists

    /// Prepend elements, returning the list's new length.
    @discardableResult
    public func cacheLeftPush(_ namespace: String, _ key: String, _ values: [Data]) async throws -> Int {
        try await cachePush("LPush", namespace, key, values)
    }

    /// Append elements, returning the list's new length.
    @discardableResult
    public func cacheRightPush(_ namespace: String, _ key: String, _ values: [Data]) async throws -> Int {
        try await cachePush("RPush", namespace, key, values)
    }

    private func cachePush(_ variant: String, _ namespace: String, _ key: String, _ values: [Data]) async throws -> Int {
        guard !values.isEmpty else { throw TriCoreError.invalid("`values` must not be empty") }
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["values"] = .array(values.map(TriCore.byteList))
        return try await cacheJSON(["Cache": [variant: .object(body)]], variant)["length"]?.intValue ?? 0
    }

    /// Remove and return the first element. `nil` when the list is empty or missing.
    public func cacheLeftPop(_ namespace: String, _ key: String) async throws -> Data? {
        try await cacheValue(["Cache": ["LPop": TriCore.namespaceKey(namespace, key)]], "LPop")
    }

    /// Remove and return the last element.
    public func cacheRightPop(_ namespace: String, _ key: String) async throws -> Data? {
        try await cacheValue(["Cache": ["RPop": TriCore.namespaceKey(namespace, key)]], "RPop")
    }

    /// Read an inclusive index range. Negative indices count from the end and
    /// out-of-range bounds are clamped.
    public func cacheRange(_ namespace: String, _ key: String, from start: Int, to stop: Int) async throws -> [Data] {
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["start"] = .int(Int64(start))
        body["stop"] = .int(Int64(stop))
        let json = try await cacheJSON(["Cache": ["LRange": .object(body)]], "LRange")
        return try (json["values"]?.arrayValue ?? []).map(TriCore.decodeBytes)
    }

    /// How many elements the list holds; zero when the key is missing.
    public func cacheLength(_ namespace: String, _ key: String) async throws -> Int {
        try await cacheJSON(["Cache": ["LLen": TriCore.namespaceKey(namespace, key)]], "LLen")["length"]?.intValue ?? 0
    }

    /// One element by index; negative counts from the end.
    public func cacheIndex(_ namespace: String, _ key: String, _ index: Int) async throws -> Data? {
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["index"] = .int(Int64(index))
        return try await cacheValue(["Cache": ["LIndex": .object(body)]], "LIndex")
    }

    // MARK: - Sets

    /// Add members, returning how many were new.
    @discardableResult
    public func cacheSetAdd(_ namespace: String, _ key: String, _ members: [Data]) async throws -> Int {
        guard !members.isEmpty else { throw TriCoreError.invalid("`members` must not be empty") }
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["members"] = .array(members.map(TriCore.byteList))
        return try await cacheJSON(["Cache": ["SAdd": .object(body)]], "SAdd")["added"]?.intValue ?? 0
    }

    /// Remove members, returning how many were there.
    @discardableResult
    public func cacheSetRemove(_ namespace: String, _ key: String, _ members: [Data]) async throws -> Int {
        guard !members.isEmpty else { throw TriCoreError.invalid("`members` must not be empty") }
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["members"] = .array(members.map(TriCore.byteList))
        return try await cacheJSON(["Cache": ["SRem": .object(body)]], "SRem")["removed"]?.intValue ?? 0
    }

    /// Whether a member is in the set.
    public func cacheSetContains(_ namespace: String, _ key: String, _ member: Data) async throws -> Bool {
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["member"] = TriCore.byteList(member)
        return try await cacheJSON(["Cache": ["SIsMember": .object(body)]], "SIsMember")["is_member"]?.boolValue ?? false
    }

    /// How many members the set holds; zero when the key is missing.
    public func cacheSetCount(_ namespace: String, _ key: String) async throws -> Int {
        try await cacheJSON(["Cache": ["SCard": TriCore.namespaceKey(namespace, key)]], "SCard")["cardinality"]?
            .intValue ?? 0
    }

    /// Every member, in ascending byte order.
    public func cacheSetMembers(_ namespace: String, _ key: String) async throws -> [Data] {
        let json = try await cacheJSON(["Cache": ["SMembers": TriCore.namespaceKey(namespace, key)]], "SMembers")
        return try (json["members"]?.arrayValue ?? []).map(TriCore.decodeBytes)
    }

    // MARK: - Hashes

    /// Set fields, returning how many were created rather than overwritten.
    @discardableResult
    public func cacheHashSet(_ namespace: String, _ key: String, _ entries: [CachePair]) async throws -> Int {
        guard !entries.isEmpty else { throw TriCoreError.invalid("`entries` must not be empty") }
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["entries"] = .array(entries.map { .array([TriCore.byteList($0.field), TriCore.byteList($0.value)]) })
        return try await cacheJSON(["Cache": ["HSet": .object(body)]], "HSet")["created"]?.intValue ?? 0
    }

    /// Read one field. `nil` when the field or the key is absent.
    public func cacheHashGet(_ namespace: String, _ key: String, _ field: Data) async throws -> Data? {
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["field"] = TriCore.byteList(field)
        return try await cacheValue(["Cache": ["HGet": .object(body)]], "HGet")
    }

    /// Delete fields, returning how many were there.
    @discardableResult
    public func cacheHashDelete(_ namespace: String, _ key: String, _ fields: [Data]) async throws -> Int {
        guard !fields.isEmpty else { throw TriCoreError.invalid("`fields` must not be empty") }
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["fields"] = .array(fields.map(TriCore.byteList))
        return try await cacheJSON(["Cache": ["HDel": .object(body)]], "HDel")["deleted"]?.intValue ?? 0
    }

    /// Every field and value, in ascending field order.
    public func cacheHashAll(_ namespace: String, _ key: String) async throws -> [CachePair] {
        let json = try await cacheJSON(["Cache": ["HGetAll": TriCore.namespaceKey(namespace, key)]], "HGetAll")
        return try (json["entries"]?.arrayValue ?? []).map { entry in
            guard let pair = entry.arrayValue, pair.count == 2 else {
                throw TriCoreError.protocolViolation("expected each hash entry to be a [field, value] pair")
            }
            return CachePair(field: try TriCore.decodeBytes(pair[0]), value: try TriCore.decodeBytes(pair[1]))
        }
    }

    /// Whether a field exists in the hash.
    public func cacheHashContains(_ namespace: String, _ key: String, _ field: Data) async throws -> Bool {
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["field"] = TriCore.byteList(field)
        return try await cacheJSON(["Cache": ["HExists": .object(body)]], "HExists")["exists"]?.boolValue ?? false
    }

    /// How many fields the hash holds; zero when the key is missing.
    public func cacheHashCount(_ namespace: String, _ key: String) async throws -> Int {
        try await cacheJSON(["Cache": ["HLen": TriCore.namespaceKey(namespace, key)]], "HLen")["length"]?.intValue ?? 0
    }

    // MARK: - Streams

    /// Append an entry, returning the id it was given.
    ///
    /// `id` is `nil` or `"*"` to generate one, `"<ms>"` or `"<ms>-*"` to fix the
    /// millisecond, or `"<ms>-<seq>"` for an exact id. Ids must increase.
    @discardableResult
    public func cacheStreamAdd(_ namespace: String, _ key: String, _ fields: [CachePair], id: String? = nil) async throws -> String {
        guard !fields.isEmpty else { throw TriCoreError.invalid("`fields` must not be empty") }
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["fields"] = .array(fields.map { .array([TriCore.byteList($0.field), TriCore.byteList($0.value)]) })
        body["id"] = id.map { .string($0) } ?? .null
        return try await cacheJSON(["Cache": ["XAdd": .object(body)]], "XAdd")["id"]?.stringValue ?? ""
    }

    /// How many entries the stream holds; zero when the key is missing.
    public func cacheStreamLength(_ namespace: String, _ key: String) async throws -> Int {
        try await cacheJSON(["Cache": ["XLen": TriCore.namespaceKey(namespace, key)]], "XLen")["length"]?.intValue ?? 0
    }

    /// Read entries whose id falls in an inclusive range. `"-"` and `"+"` are the
    /// smallest and largest ids.
    public func cacheStreamRange(
        _ namespace: String, _ key: String, from start: String = "-", to end: String = "+", count: Int? = nil
    ) async throws -> [StreamEntry] {
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["start"] = .string(start)
        body["end"] = .string(end)
        body["count"] = count.map { .int(Int64($0)) } ?? .null
        return try await streamEntries(["Cache": ["XRange": .object(body)]], "XRange")
    }

    /// Read entries newer than `after` — the non-blocking poll. This never blocks.
    public func cacheStreamRead(
        _ namespace: String, _ key: String, after: String = "0-0", count: Int? = nil
    ) async throws -> [StreamEntry] {
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["after"] = .string(after)
        body["count"] = count.map { .int(Int64($0)) } ?? .null
        return try await streamEntries(["Cache": ["XRead": .object(body)]], "XRead")
    }

    /// Delete entries by exact id, returning how many were there.
    @discardableResult
    public func cacheStreamDelete(_ namespace: String, _ key: String, ids: [String]) async throws -> Int {
        guard !ids.isEmpty else { throw TriCoreError.invalid("`ids` must not be empty") }
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["ids"] = .array(ids.map { .string($0) })
        return try await cacheJSON(["Cache": ["XDel": .object(body)]], "XDel")["deleted"]?.intValue ?? 0
    }

    /// Cap the stream by evicting its oldest entries, returning how many went.
    @discardableResult
    public func cacheStreamTrim(_ namespace: String, _ key: String, maxLength: Int) async throws -> Int {
        var body = TriCore.namespaceKeyObject(namespace, key)
        body["max_len"] = .int(Int64(maxLength))
        return try await cacheJSON(["Cache": ["XTrim": .object(body)]], "XTrim")["trimmed"]?.intValue ?? 0
    }

    // MARK: - Shared

    private func cacheJSON(_ op: JSONValue, _ what: String) async throws -> JSONValue {
        try await send(op).expect("Json", what)
    }

    /// Read a `CacheValue`, where a null payload is a miss.
    private func cacheValue(_ op: JSONValue, _ what: String) async throws -> Data? {
        let payload = try await send(op).expect("CacheValue", what)
        guard !payload.isNull else { return nil }
        return try TriCore.decodeBytes(payload)
    }

    private func streamEntries(_ op: JSONValue, _ what: String) async throws -> [StreamEntry] {
        let json = try await cacheJSON(op, what)
        return try (json["entries"]?.arrayValue ?? []).map { entry in
            let fields = try (entry["fields"]?.arrayValue ?? []).map { pair -> CachePair in
                guard let parts = pair.arrayValue, parts.count == 2 else {
                    throw TriCoreError.protocolViolation("expected each stream field to be a [field, value] pair")
                }
                return CachePair(field: try TriCore.decodeBytes(parts[0]), value: try TriCore.decodeBytes(parts[1]))
            }
            return StreamEntry(id: entry["id"]?.stringValue ?? "", fields: fields)
        }
    }

    static func namespaceKeyObject(_ namespace: String, _ key: String) -> [String: JSONValue] {
        ["namespace": .string(namespace), "key": .string(key)]
    }

    static func namespaceKey(_ namespace: String, _ key: String) -> JSONValue {
        .object(namespaceKeyObject(namespace, key))
    }

    /// Bytes as the server expects them: an array of numbers, not base64 or text.
    /// A client that spoke only text would corrupt every value that is not valid
    /// UTF-8.
    static func byteList(_ data: Data) -> JSONValue {
        .array(data.map { .int(Int64($0)) })
    }

    /// The inverse. A value outside `0...255` is refused rather than masked,
    /// because masking would quietly corrupt the payload.
    static func decodeBytes(_ value: JSONValue) throws -> Data {
        guard let items = value.arrayValue else {
            throw TriCoreError.protocolViolation("expected an array of bytes, got \(value)")
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            guard let number = item.intValue, (0...255).contains(number) else {
                throw TriCoreError.protocolViolation(
                    "byte \(index) of the value is \(item), which is not a number in 0...255")
            }
            bytes.append(UInt8(number))
        }
        return Data(bytes)
    }

    static func milliseconds(_ duration: Duration?) -> JSONValue {
        guard let duration, duration > .zero else { return .null }
        let value = duration.components.seconds * 1000
            + duration.components.attoseconds / 1_000_000_000_000_000
        return .int(value)
    }
}
