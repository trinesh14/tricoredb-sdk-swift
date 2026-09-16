import Foundation

/// How a collection measures closeness. Fixed when the collection is created.
public enum VectorMetric: String, Sendable {
    /// Cosine similarity: higher is closer.
    case cosine
    /// Dot product: higher is closer.
    case dot
    /// Squared Euclidean distance, **returned negated** so that higher is still
    /// closer. An l2 score is therefore `<= 0`, and `-0.02` is nearer than `-196.0`.
    case l2
}

/// How the search index stores vectors in memory.
///
/// An index-level choice only: the durable records always keep full `Float`
/// precision, so ``TriCore/vectorGet(_:id:)`` returns the same values either way.
public enum VectorQuantization: String, Sendable {
    case none
    case int8
}

/// One stored vector and its metadata.
public struct VectorItem: Sendable, Equatable {
    public let id: String
    public let vector: [Float]
    public let metadata: [String: JSONValue]
}

/// One search result.
///
/// The score is a similarity, never a distance: **higher is closer under every
/// metric**, and results come back best first. Sorting these ascending, or reading
/// the score as a distance, inverts an l2 ranking while a "is the expected id in the
/// top k" check still passes.
public struct VectorHit: Sendable, Equatable {
    public let id: String
    public let score: Double
    public let metadata: [String: JSONValue]
}

/// A collection's metadata and its live vector count.
public struct VectorCollectionInfo: Sendable, Equatable {
    public let collection: String
    public let dimension: Int
    public let metric: String
    public let count: Int
    public let quantization: String
}

extension TriCore {

    /// Create a collection. The dimension and metric are fixed for its lifetime.
    public func vectorCreateCollection(
        _ collection: String,
        dimension: Int,
        metric: VectorMetric = .cosine,
        quantization: VectorQuantization = .none
    ) async throws {
        _ = try await send(["Vector": ["CreateCollection": [
            "collection": .string(collection),
            "dimension": .int(Int64(dimension)),
            "metric": .string(metric.rawValue),
            "quantization": .string(quantization.rawValue),
        ]]])
    }

    /// Drop a collection and every vector in it.
    public func vectorDropCollection(_ collection: String) async throws {
        _ = try await send(["Vector": ["DropCollection": ["collection": .string(collection)]]])
    }

    /// Store a vector under an id, replacing whatever was there.
    ///
    /// The vector's length must equal the collection's dimension; a mismatch is
    /// refused rather than padded or truncated.
    public func vectorUpsert(
        _ collection: String, id: String, _ values: [Float], metadata: [String: JSONValue]? = nil
    ) async throws {
        _ = try await send(["Vector": ["Upsert": [
            "collection": .string(collection),
            "id": .string(id),
            "vector": .array(values.map { .double(Double($0)) }),
            "metadata": metadata.map { JSONValue.object($0) } ?? .null,
        ]]])
    }

    /// Fetch one stored vector. `nil` when there is no such id.
    public func vectorGet(_ collection: String, id: String) async throws -> VectorItem? {
        let response = try await send(["Vector": ["Get": [
            "collection": .string(collection), "id": .string(id),
        ]]])
        let payload = try response.expect("Json", "Get")
        guard !payload.isNull else { return nil }
        return TriCore.vectorItem(payload)
    }

    /// Delete one vector. Deleting an absent id is not an error; a missing
    /// collection is.
    public func vectorDelete(_ collection: String, id: String) async throws {
        _ = try await send(["Vector": ["Delete": [
            "collection": .string(collection), "id": .string(id),
        ]]])
    }

    /// The `topK` nearest vectors to a query vector, optionally restricted to those
    /// whose metadata matches every entry of `filter`.
    ///
    /// Exact equality on top-level fields only: the server implements no ranges and
    /// no nesting here.
    public func vectorSearch(
        _ collection: String, _ values: [Float], topK: Int, filter: [String: JSONValue]? = nil
    ) async throws -> [VectorHit] {
        let json = try await send(["Vector": ["Search": [
            "collection": .string(collection),
            "vector": .array(values.map { .double(Double($0)) }),
            "top_k": .int(Int64(topK)),
            "filter": (filter?.isEmpty == false) ? .object(filter!) : .null,
        ]]]).expect("Json", "Search")

        return (json["results"]?.arrayValue ?? []).map { hit in
            VectorHit(
                id: hit["id"]?.stringValue ?? "",
                score: hit["score"]?.doubleValue ?? 0,
                metadata: hit["metadata"]?.objectValue ?? [:])
        }
    }

    /// Describe every vector collection in the database.
    public func vectorListCollections() async throws -> [VectorCollectionInfo] {
        let json = try await send(["Vector": "ListCollections"]).expect("Json", "ListCollections")
        return (json["details"]?.arrayValue ?? []).map { entry in
            VectorCollectionInfo(
                collection: entry["name"]?.stringValue ?? entry["collection"]?.stringValue ?? "",
                dimension: entry["dimension"]?.intValue ?? 0,
                metric: entry["metric"]?.stringValue ?? "",
                count: entry["count"]?.intValue ?? 0,
                quantization: entry["quantization"]?.stringValue ?? "none")
        }
    }

    /// Read one collection's metadata and live count.
    public func vectorDescribeCollection(_ collection: String) async throws -> VectorCollectionInfo {
        let json = try await send(["Vector": ["DescribeCollection": ["collection": .string(collection)]]])
            .expect("Json", "DescribeCollection")
        return VectorCollectionInfo(
            collection: json["collection"]?.stringValue ?? collection,
            dimension: json["dimension"]?.intValue ?? 0,
            metric: json["metric"]?.stringValue ?? "",
            count: json["count"]?.intValue ?? 0,
            quantization: json["quantization"]?.stringValue ?? "none")
    }

    /// One page of a collection's vectors, ordered by id.
    public func vectorListVectors(
        _ collection: String, limit: Int? = nil, offset: Int? = nil
    ) async throws -> [VectorItem] {
        var body: [String: JSONValue] = ["collection": .string(collection)]
        if let limit, limit > 0 { body["limit"] = .int(Int64(limit)) }
        if let offset, offset > 0 { body["offset"] = .int(Int64(offset)) }
        let json = try await send(["Vector": ["ListVectors": .object(body)]]).expect("Json", "ListVectors")
        return (json["vectors"]?.arrayValue ?? []).map(TriCore.vectorItem)
    }

    private static func vectorItem(_ json: JSONValue) -> VectorItem {
        VectorItem(
            id: json["id"]?.stringValue ?? "",
            vector: (json["vector"]?.arrayValue ?? []).compactMap { $0.doubleValue.map(Float.init) },
            metadata: json["metadata"]?.objectValue ?? [:])
    }
}
