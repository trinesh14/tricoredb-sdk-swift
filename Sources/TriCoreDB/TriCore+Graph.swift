import Foundation

/// Which edges of a node an operation follows.
public enum GraphDirection: String, Sendable {
    /// Edges the node is the `from` end of. The server's default.
    case outgoing
    /// Edges the node is the `to` end of.
    case incoming
    /// Edges in either direction.
    case both
}

/// One stored node.
public struct GraphNode: Sendable, Equatable {
    public let id: String
    public let labels: [String]
    public let properties: [String: JSONValue]
}

/// One stored edge, directed from one node to another.
public struct GraphEdge: Sendable, Equatable {
    public let id: String
    public let from: String
    public let to: String
    public let label: String
    public let properties: [String: JSONValue]
}

/// One edge incident to a node, and the node at its other end.
public struct GraphNeighbor: Sendable, Equatable {
    public let edgeID: String
    public let nodeID: String
    public let label: String
    /// The edge's orientation relative to the node that was asked about, which is
    /// what makes a `both` result readable.
    public let direction: String
}

/// One node reached by a traversal.
public struct GraphVisit: Sendable, Equatable {
    public let id: String
    public let depth: Int
    public let labels: [String]
    public let properties: [String: JSONValue]
}

/// The outcome of a bounded breadth-first walk.
public struct GraphTraversal: Sendable, Equatable {
    public let start: String
    public let maxDepth: Int
    public let count: Int
    /// Whether a bound stopped the walk before it ran out of nodes. The nodes
    /// returned are real; the answer is simply not exhaustive.
    public let truncated: Bool
    public let nodes: [GraphVisit]
}

/// The outcome of a path search.
///
/// `found == false` is an ordinary answer, not an error: either no path exists or
/// the search stopped at a bound, and ``message`` says which. A search stopped by a
/// bound is inconclusive, not proof that no path exists.
public struct GraphPath: Sendable, Equatable {
    public let found: Bool
    public let from: String
    public let to: String
    public let hops: Int
    public let nodePath: [String]
    public let edgePath: [String]
    /// The summed weight — meaningful only for the weighted search, and zero for the
    /// unweighted one, which minimises hops.
    public let totalCost: Double
    public let message: String
}

/// The result of a Cypher query. Cells stay as JSON because a `RETURN` can yield a
/// scalar, a list, or a whole node.
public struct GraphRows: Sendable, Equatable {
    public let columns: [String]
    public let rows: [[JSONValue]]
    public let truncated: Bool
}

extension TriCore {

    /// Create an empty graph.
    public func graphCreate(_ graph: String) async throws {
        _ = try await send(["Graph": ["CreateGraph": ["graph": .string(graph)]]])
    }

    /// Drop a graph with its nodes and edges.
    public func graphDrop(_ graph: String) async throws {
        _ = try await send(["Graph": ["DropGraph": ["graph": .string(graph)]]])
    }

    /// Name every graph in the database.
    public func graphList() async throws -> [String] {
        let json = try await send(["Graph": "ListGraphs"]).expect("Json", "ListGraphs")
        return json["graphs"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// Store a node, replacing whatever was under that id.
    public func graphAddNode(
        _ graph: String, id: String, labels: [String] = [], properties: [String: JSONValue]? = nil
    ) async throws {
        _ = try await send(["Graph": ["AddNode": [
            "graph": .string(graph),
            "id": .string(id),
            "labels": .array(labels.map { .string($0) }),
            "properties": properties.map { JSONValue.object($0) } ?? .null,
        ]]])
    }

    /// Fetch one node. `nil` when there is no such id.
    public func graphGetNode(_ graph: String, id: String) async throws -> GraphNode? {
        let payload = try await send(["Graph": ["GetNode": [
            "graph": .string(graph), "id": .string(id),
        ]]]).expect("Json", "GetNode")
        guard !payload.isNull else { return nil }
        return TriCore.node(payload)
    }

    /// Delete a node. Deleting an absent node is not an error; a missing graph is.
    public func graphDeleteNode(_ graph: String, id: String) async throws {
        _ = try await send(["Graph": ["DeleteNode": ["graph": .string(graph), "id": .string(id)]]])
    }

    /// Store a directed edge. Both endpoints must already exist: a dangling endpoint
    /// is refused rather than created.
    public func graphAddEdge(
        _ graph: String, id: String, from: String, to: String, label: String,
        properties: [String: JSONValue]? = nil
    ) async throws {
        _ = try await send(["Graph": ["AddEdge": [
            "graph": .string(graph),
            "id": .string(id),
            "from": .string(from),
            "to": .string(to),
            "label": .string(label),
            "properties": properties.map { JSONValue.object($0) } ?? .null,
        ]]])
    }

    /// Fetch one edge. `nil` when there is no such id.
    public func graphGetEdge(_ graph: String, id: String) async throws -> GraphEdge? {
        let payload = try await send(["Graph": ["GetEdge": [
            "graph": .string(graph), "id": .string(id),
        ]]]).expect("Json", "GetEdge")
        guard !payload.isNull else { return nil }
        return GraphEdge(
            id: payload["id"]?.stringValue ?? "",
            from: payload["from"]?.stringValue ?? "",
            to: payload["to"]?.stringValue ?? "",
            label: payload["label"]?.stringValue ?? "",
            properties: payload["properties"]?.objectValue ?? [:])
    }

    /// Delete an edge. Deleting an absent edge is not an error; a missing graph is.
    public func graphDeleteEdge(_ graph: String, id: String) async throws {
        _ = try await send(["Graph": ["DeleteEdge": ["graph": .string(graph), "id": .string(id)]]])
    }

    /// The edges incident to a node, and the node at the far end of each. A node
    /// with no matching edges gives an empty list, not an error.
    public func graphNeighbors(
        _ graph: String, of nodeID: String, direction: GraphDirection? = nil,
        label: String? = nil, limit: Int? = nil
    ) async throws -> [GraphNeighbor] {
        var body: [String: JSONValue] = ["graph": .string(graph), "node_id": .string(nodeID)]
        TriCore.put(&body, "direction", direction?.rawValue)
        TriCore.put(&body, "label", label)
        TriCore.put(&body, "limit", limit)
        let json = try await send(["Graph": ["Neighbors": .object(body)]]).expect("Json", "Neighbors")
        return (json["neighbors"]?.arrayValue ?? []).map { entry in
            GraphNeighbor(
                edgeID: entry["edge_id"]?.stringValue ?? "",
                nodeID: entry["node_id"]?.stringValue ?? "",
                label: entry["label"]?.stringValue ?? "",
                direction: entry["direction"]?.stringValue ?? "outgoing")
        }
    }

    /// How many edges are incident to a node. `both` counts each edge once,
    /// self-loops included.
    public func graphDegree(_ graph: String, of nodeID: String, direction: GraphDirection? = nil) async throws -> Int {
        var body: [String: JSONValue] = ["graph": .string(graph), "node_id": .string(nodeID)]
        TriCore.put(&body, "direction", direction?.rawValue)
        let json = try await send(["Graph": ["Degree": .object(body)]]).expect("Json", "Degree")
        return json["degree"]?.intValue ?? 0
    }

    /// Walk outward from a node by breadth-first search. The start node must exist.
    public func graphTraverse(
        _ graph: String, from start: String, direction: GraphDirection? = nil,
        label: String? = nil, maxDepth: Int? = nil, limit: Int? = nil
    ) async throws -> GraphTraversal {
        var body: [String: JSONValue] = ["graph": .string(graph), "start": .string(start)]
        TriCore.put(&body, "direction", direction?.rawValue)
        TriCore.put(&body, "label", label)
        TriCore.put(&body, "max_depth", maxDepth)
        TriCore.put(&body, "limit", limit)
        let json = try await send(["Graph": ["Traverse": .object(body)]]).expect("Json", "Traverse")
        let nodes = (json["nodes"]?.arrayValue ?? []).map { entry in
            GraphVisit(
                id: entry["id"]?.stringValue ?? "",
                depth: entry["depth"]?.intValue ?? 0,
                labels: entry["labels"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                properties: entry["properties"]?.objectValue ?? [:])
        }
        return GraphTraversal(
            start: json["start"]?.stringValue ?? start,
            maxDepth: json["max_depth"]?.intValue ?? 0,
            count: json["count"]?.intValue ?? nodes.count,
            truncated: json["truncated"]?.boolValue ?? false,
            nodes: nodes)
    }

    /// The path with the fewest hops between two nodes. Both must exist. "No path"
    /// comes back as `found == false`, not as an error.
    public func graphShortestPath(
        _ graph: String, from: String, to: String, direction: GraphDirection? = nil,
        label: String? = nil, maxDepth: Int? = nil
    ) async throws -> GraphPath {
        var body: [String: JSONValue] = [
            "graph": .string(graph), "from": .string(from), "to": .string(to),
        ]
        TriCore.put(&body, "direction", direction?.rawValue)
        TriCore.put(&body, "label", label)
        TriCore.put(&body, "max_depth", maxDepth)
        let json = try await send(["Graph": ["ShortestPath": .object(body)]]).expect("Json", "ShortestPath")
        return TriCore.path(json)
    }

    /// The least-cost path between two nodes, by summed edge weight.
    ///
    /// A different question from ``graphShortestPath(_:from:to:direction:label:maxDepth:)``,
    /// which minimises hops: with unequal weights the two return different paths and
    /// neither substitutes for the other.
    public func graphWeightedShortestPath(
        _ graph: String, from: String, to: String, direction: GraphDirection? = nil,
        label: String? = nil, weightProperty: String? = nil
    ) async throws -> GraphPath {
        var body: [String: JSONValue] = [
            "graph": .string(graph), "from": .string(from), "to": .string(to),
        ]
        TriCore.put(&body, "direction", direction?.rawValue)
        TriCore.put(&body, "label", label)
        TriCore.put(&body, "weight_property", weightProperty)
        let json = try await send(["Graph": ["WeightedShortestPath": .object(body)]])
            .expect("Json", "WeightedShortestPath")
        return TriCore.path(json)
    }

    /// One page of a graph's nodes, ordered by id.
    public func graphListNodes(_ graph: String, limit: Int? = nil, offset: Int? = nil) async throws -> [GraphNode] {
        var body: [String: JSONValue] = ["graph": .string(graph)]
        TriCore.put(&body, "limit", limit)
        TriCore.put(&body, "offset", offset)
        let json = try await send(["Graph": ["ListNodes": .object(body)]]).expect("Json", "ListNodes")
        return (json["nodes"]?.arrayValue ?? []).map(TriCore.node)
    }

    /// One page of a graph's edges, ordered by id.
    public func graphListEdges(_ graph: String, limit: Int? = nil, offset: Int? = nil) async throws -> [GraphEdge] {
        var body: [String: JSONValue] = ["graph": .string(graph)]
        TriCore.put(&body, "limit", limit)
        TriCore.put(&body, "offset", offset)
        let json = try await send(["Graph": ["ListEdges": .object(body)]]).expect("Json", "ListEdges")
        return (json["edges"]?.arrayValue ?? []).map { entry in
            GraphEdge(
                id: entry["id"]?.stringValue ?? "",
                from: entry["from"]?.stringValue ?? "",
                to: entry["to"]?.stringValue ?? "",
                label: entry["label"]?.stringValue ?? "",
                properties: entry["properties"]?.objectValue ?? [:])
        }
    }

    /// Run a read-only Cypher query.
    ///
    /// The server implements `MATCH` / `WHERE` / `RETURN` with labels, property
    /// predicates, relationship direction and type, bounded variable-length paths,
    /// `DISTINCT`, `ORDER BY` / `SKIP` / `LIMIT`, and global aggregates. Every other
    /// clause is refused by name rather than ignored, so a rejected query is an error
    /// instead of an answer computed from half a statement.
    public func graphQuery(_ graph: String, cypher: String) async throws -> GraphRows {
        let json = try await send(["Graph": ["Query": [
            "graph": .string(graph), "cypher": .string(cypher),
        ]]]).expect("Json", "Query")
        return GraphRows(
            columns: json["columns"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            rows: (json["rows"]?.arrayValue ?? []).map { $0.arrayValue ?? [] },
            truncated: json["truncated"]?.boolValue ?? false)
    }

    // MARK: - Helpers

    private static func node(_ json: JSONValue) -> GraphNode {
        GraphNode(
            id: json["id"]?.stringValue ?? "",
            labels: json["labels"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            properties: json["properties"]?.objectValue ?? [:])
    }

    private static func path(_ json: JSONValue) -> GraphPath {
        GraphPath(
            found: json["found"]?.boolValue ?? false,
            from: json["from"]?.stringValue ?? "",
            to: json["to"]?.stringValue ?? "",
            hops: json["hops"]?.intValue ?? 0,
            nodePath: json["node_path"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            edgePath: json["edge_path"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            totalCost: json["total_cost"]?.doubleValue ?? 0,
            message: json["message"]?.stringValue ?? "")
    }

    /// Write a value only when the caller chose one, so an unset option lands on the
    /// server's default instead of being sent as an empty string or a zero bound.
    static func put(_ body: inout [String: JSONValue], _ key: String, _ value: String?) {
        if let value, !value.isEmpty { body[key] = .string(value) }
    }

    static func put(_ body: inout [String: JSONValue], _ key: String, _ value: Int?) {
        if let value, value > 0 { body[key] = .int(Int64(value)) }
    }
}
