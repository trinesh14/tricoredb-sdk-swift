import Foundation

/// One JSON document as the server stores it. Every stored document carries an
/// `_id`, whether the caller chose it or the server did.
public typealias Document = [String: JSONValue]

/// A query predicate.
///
/// Field paths use dot notation (`"address.city"`) into nested objects. A document
/// that lacks the path never matches — including for ``notEqual(_:_:)``.
///
/// This is not MongoDB's query language: there is no `or`, no `not` and no regular
/// expression, because the server implements none of them.
public struct DocumentFilter: Sendable, Equatable {
    let json: JSONValue

    private init(_ json: JSONValue) { self.json = json }

    private static func field(_ variant: String, _ field: String, _ value: JSONValue) -> DocumentFilter {
        DocumentFilter([variant: ["field": .string(field), "value": value]])
    }

    /// Match every document. Say this on purpose: there is no filter that means it
    /// by accident.
    public static let all = DocumentFilter(.string("All"))

    /// The field equals this value.
    public static func equal(_ path: String, _ value: JSONValue) -> DocumentFilter { field("Eq", path, value) }
    /// The field exists and does not equal this value.
    public static func notEqual(_ path: String, _ value: JSONValue) -> DocumentFilter { field("Ne", path, value) }
    /// The field is greater than this value.
    public static func greaterThan(_ path: String, _ value: JSONValue) -> DocumentFilter { field("Gt", path, value) }
    /// The field is greater than or equal to this value.
    public static func atLeast(_ path: String, _ value: JSONValue) -> DocumentFilter { field("Gte", path, value) }
    /// The field is less than this value.
    public static func lessThan(_ path: String, _ value: JSONValue) -> DocumentFilter { field("Lt", path, value) }
    /// The field is less than or equal to this value.
    public static func atMost(_ path: String, _ value: JSONValue) -> DocumentFilter { field("Lte", path, value) }
    /// A string field holds this substring, or an array field holds this element.
    public static func contains(_ path: String, _ value: JSONValue) -> DocumentFilter { field("Contains", path, value) }

    /// The field equals one of these values.
    public static func oneOf(_ path: String, _ values: [JSONValue]) -> DocumentFilter {
        DocumentFilter(["In": ["field": .string(path), "values": .array(values)]])
    }

    /// Every one of these filters holds.
    public static func all(of filters: [DocumentFilter]) -> DocumentFilter {
        DocumentFilter(["And": .array(filters.map(\.json))])
    }
}

/// Field changes applied to one document.
///
/// `set` overwrites the value at a dot path, `increment` adds a number to it, and
/// every set happens before every increment. Incrementing a field that holds
/// anything but a number is an error on the server, never a conversion; a missing
/// field increments from zero, and a negative delta is how you subtract.
public struct DocumentUpdate: Sendable, Equatable {
    private var setFields: [String: JSONValue] = [:]
    private var incrementFields: [String: JSONValue] = [:]

    public init() {}

    /// Overwrite the value at a dot path.
    public func set(_ path: String, _ value: JSONValue) -> DocumentUpdate {
        var copy = self
        copy.setFields[path] = value
        return copy
    }

    /// Add a number to the value at a dot path.
    public func increment(_ path: String, by delta: JSONValue) -> DocumentUpdate {
        var copy = self
        copy.incrementFields[path] = delta
        return copy
    }

    var isEmpty: Bool { setFields.isEmpty && incrementFields.isEmpty }

    var json: JSONValue {
        var body: [String: JSONValue] = [:]
        if !setFields.isEmpty { body["set"] = .object(setFields) }
        if !incrementFields.isEmpty { body["inc"] = .object(incrementFields) }
        return .object(body)
    }
}

/// One reduction inside a group stage.
public struct Accumulator: Sendable, Equatable {
    let json: JSONValue

    /// Total the numeric values at a field. Documents where it is missing or not a
    /// number are ignored, so an absent field never contributes a zero.
    public static func sum(_ field: String) -> Accumulator { Accumulator(json: ["Sum": .string(field)]) }
    /// Average the numeric values at a field.
    public static func average(_ field: String) -> Accumulator { Accumulator(json: ["Avg": .string(field)]) }
    /// The smallest value at a field.
    public static func minimum(_ field: String) -> Accumulator { Accumulator(json: ["Min": .string(field)]) }
    /// The largest value at a field.
    public static func maximum(_ field: String) -> Accumulator { Accumulator(json: ["Max": .string(field)]) }
    /// Count documents. It takes no field because it counts documents, not values.
    public static let count = Accumulator(json: .string("Count"))
}

/// How a group stage derives its key.
public struct GroupKey: Sendable, Equatable {
    let json: JSONValue

    /// Group by the value at a dot path. A document that lacks the path groups under
    /// null rather than being dropped.
    public static func field(_ path: String) -> GroupKey { GroupKey(json: ["Field": .string(path)]) }
    /// Put the whole collection in one group — how a collection-wide total is
    /// expressed.
    public static func constant(_ value: JSONValue) -> GroupKey { GroupKey(json: ["Constant": value]) }
}

/// One stage of an aggregation pipeline.
///
/// Stages apply in the order given, and the order is meaning rather than style: a
/// match before a group filters documents, after it filters groups.
public struct AggregateStage: Sendable, Equatable {
    let json: JSONValue

    /// Filter with the same matcher ``TriCore/documentFind(_:_:limit:)`` uses.
    public static func match(_ filter: DocumentFilter) -> AggregateStage {
        AggregateStage(json: ["Match": filter.json])
    }

    /// Group by a key and apply accumulators, each writing into a named field.
    public static func group(by key: GroupKey, _ accumulators: [(output: String, op: Accumulator)]) -> AggregateStage {
        let list = accumulators.map { JSONValue.object(["output": .string($0.output), "op": $0.op.json]) }
        return AggregateStage(json: ["Group": ["by": key.json, "accumulators": .array(list)]])
    }

    /// Order the documents. After a group stage the addressable fields are `_id` and
    /// the accumulator outputs, not the original document's fields.
    public static func sort(_ keys: [(field: String, descending: Bool)]) -> AggregateStage {
        let list = keys.map { JSONValue.object(["field": .string($0.field), "descending": .bool($0.descending)]) }
        return AggregateStage(json: ["Sort": .array(list)])
    }

    /// Drop the first `count` documents.
    public static func skip(_ count: Int) -> AggregateStage { AggregateStage(json: ["Skip": .int(Int64(count))]) }
    /// Keep at most `count` documents.
    public static func limit(_ count: Int) -> AggregateStage { AggregateStage(json: ["Limit": .int(Int64(count))]) }

    /// Keep (or drop) these top-level fields. Nested projection is refused by the
    /// server.
    public static func project(_ fields: [String], include: Bool = true) -> AggregateStage {
        AggregateStage(json: ["Project": ["fields": .array(fields.map { .string($0) }), "include": .bool(include)]])
    }

    /// Replace the documents with one that holds the input count under `field`.
    public static func count(into field: String) -> AggregateStage {
        AggregateStage(json: ["Count": ["field": .string(field)]])
    }
}

/// One secondary index on a collection.
public struct DocumentIndex: Sendable, Equatable {
    public let name: String
    public let field: String
    public let unique: Bool
}

/// What ``TriCore/documentAnalyze(_:)`` measured.
public struct DocumentStats: Sendable, Equatable {
    public let collection: String
    public let documentCount: Int
    public let indexedFields: Int
}

/// What ``TriCore/documentUpdateMany(_:matching:_:)`` changed.
///
/// `matched` counts the documents the filter selected; `modified` counts those whose
/// contents actually changed, so rewriting a document to the value it already held is
/// matched but not modified.
public struct UpdateCounts: Sendable, Equatable {
    public let matched: Int
    public let modified: Int
}

extension TriCore {

    /// Create a collection.
    public func documentCreateCollection(_ collection: String) async throws {
        _ = try await send(["Document": ["CreateCollection": ["collection": .string(collection)]]])
    }

    /// Drop a collection with its documents and indexes. Dropping one that does not
    /// exist is an error.
    public func documentDropCollection(_ collection: String) async throws {
        _ = try await send(["Document": ["DropCollection": ["collection": .string(collection)]]])
    }

    /// Name every collection in the database.
    public func documentListCollections() async throws -> [String] {
        let json = try await send(["Document": "ListCollections"]).expect("Json", "ListCollections")
        return json["collections"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// Insert a document, optionally under an id you choose, and return that id.
    ///
    /// Inserting over an existing id is an error rather than an overwrite — see
    /// ``documentUpsertOne(_:id:_:)``.
    @discardableResult
    public func documentInsert(_ collection: String, _ document: Document, id: String? = nil) async throws -> String {
        let response = try await send(["Document": ["Insert": [
            "collection": .string(collection),
            "id": id.map { .string($0) } ?? .null,
            "document": .object(document),
        ]]])
        let json = try response.expect("Json", "Insert")
        guard let identifier = json["id"]?.stringValue, !identifier.isEmpty else {
            throw TriCoreError.protocolViolation("Insert answered with no document id")
        }
        return identifier
    }

    /// Fetch one document by id. `nil` when there is no such document, which is how
    /// an absent document is told apart from a stored empty one.
    public func documentGet(_ collection: String, id: String) async throws -> Document? {
        let response = try await send(["Document": ["Get": ["collection": .string(collection), "id": .string(id)]]])
        return try TriCore.documents(response, "Get").first
    }

    /// Every document matching a filter, at most `limit` of them.
    public func documentFind(
        _ collection: String, _ filter: DocumentFilter = .all, limit: Int? = nil
    ) async throws -> [Document] {
        let response = try await send(["Document": ["Find": [
            "collection": .string(collection),
            "filter": filter.json,
            "limit": limit.map { .int(Int64($0)) } ?? .null,
        ]]])
        return try TriCore.documents(response, "Find")
    }

    /// Set fields on an existing document. A missing id is an error: this is not an
    /// upsert, and `_id` cannot be set.
    public func documentSet(_ collection: String, id: String, _ fields: Document) async throws {
        _ = try await send(["Document": ["Update": [
            "collection": .string(collection), "id": .string(id), "set": .object(fields),
        ]]])
    }

    /// Apply an update to one document by id. A missing id is an error; use
    /// ``documentUpsertOne(_:id:_:)`` to create instead.
    public func documentUpdateOne(_ collection: String, id: String, _ update: DocumentUpdate) async throws {
        _ = try await updateOne(collection, id: id, update, upsert: false)
    }

    /// Apply an update to one document by id, creating it from the update when it
    /// does not exist. Returns whether it was created.
    @discardableResult
    public func documentUpsertOne(_ collection: String, id: String, _ update: DocumentUpdate) async throws -> Bool {
        let json = try await updateOne(collection, id: id, update, upsert: true)
        return json["inserted"]?.boolValue ?? false
    }

    private func updateOne(
        _ collection: String, id: String, _ update: DocumentUpdate, upsert: Bool
    ) async throws -> JSONValue {
        guard !update.isEmpty else {
            throw TriCoreError.invalid("an update must set or increment at least one field")
        }
        let response = try await send(["Document": ["UpdateOne": [
            "collection": .string(collection),
            "id": .string(id),
            "update": update.json,
            "upsert": .bool(upsert),
        ]]])
        return try response.expect("Json", "UpdateOne")
    }

    /// Apply an update to every document matching a filter. Never an upsert: a
    /// filter that matches nothing changes nothing, and that is not an error.
    @discardableResult
    public func documentUpdateMany(
        _ collection: String, matching filter: DocumentFilter, _ update: DocumentUpdate
    ) async throws -> UpdateCounts {
        guard !update.isEmpty else {
            throw TriCoreError.invalid("an update must set or increment at least one field")
        }
        let json = try await send(["Document": ["UpdateMany": [
            "collection": .string(collection), "filter": filter.json, "update": update.json,
        ]]]).expect("Json", "UpdateMany")
        return UpdateCounts(matched: json["matched"]?.intValue ?? 0, modified: json["modified"]?.intValue ?? 0)
    }

    /// Delete one document by id. Deleting an absent document is not an error.
    public func documentDelete(_ collection: String, id: String) async throws {
        _ = try await send(["Document": ["Delete": ["collection": .string(collection), "id": .string(id)]]])
    }

    /// Build a secondary index on a top-level field. A unique index over a collection
    /// that already holds duplicates is refused before anything is written.
    public func documentCreateIndex(
        _ collection: String, name: String, field: String, unique: Bool = false
    ) async throws {
        _ = try await send(["Document": ["CreateIndex": [
            "collection": .string(collection),
            "index_name": .string(name),
            "field": .string(field),
            "unique": .bool(unique),
        ]]])
    }

    /// Remove a named index.
    public func documentDropIndex(_ collection: String, name: String) async throws {
        _ = try await send(["Document": ["DropIndex": [
            "collection": .string(collection), "index_name": .string(name),
        ]]])
    }

    /// List a collection's indexes.
    public func documentListIndexes(_ collection: String) async throws -> [DocumentIndex] {
        let json = try await send(["Document": ["ListIndexes": ["collection": .string(collection)]]])
            .expect("Json", "ListIndexes")
        return (json["indexes"]?.arrayValue ?? []).map { entry in
            DocumentIndex(
                name: entry["index_name"]?.stringValue ?? "",
                field: entry["field"]?.stringValue ?? "",
                unique: entry["unique"]?.boolValue ?? false)
        }
    }

    /// Collect the statistics the planner uses to choose between an index lookup and
    /// a scan.
    public func documentAnalyze(_ collection: String) async throws -> DocumentStats {
        let json = try await send(["Document": ["Analyze": ["collection": .string(collection)]]])
            .expect("Json", "Analyze")
        return DocumentStats(
            collection: json["analyzed"]?.stringValue ?? collection,
            documentCount: json["document_count"]?.intValue ?? 0,
            indexedFields: json["indexed_fields"]?.intValue ?? 0)
    }

    /// Run an aggregation pipeline. An empty pipeline returns the collection
    /// unchanged.
    public func documentAggregate(_ collection: String, _ pipeline: [AggregateStage]) async throws -> [Document] {
        let response = try await send(["Document": ["Aggregate": [
            "collection": .string(collection), "pipeline": .array(pipeline.map(\.json)),
        ]]])
        return try TriCore.documents(response, "Aggregate")
    }

    static func documents(_ response: Response, _ what: String) throws -> [Document] {
        let payload = try response.expect("Documents", what)
        guard let array = payload.arrayValue else {
            throw TriCoreError.protocolViolation("malformed Documents payload from \(what)")
        }
        return array.compactMap(\.objectValue)
    }
}
