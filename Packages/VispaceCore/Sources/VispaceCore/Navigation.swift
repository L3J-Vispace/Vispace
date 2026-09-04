import Foundation

public enum NavigationError: Error, Equatable, Sendable {
    case duplicateNode(SpatialNodeID)
    case nodeNotFound(SpatialNodeID)
    case edgeNotFound(from: SpatialNodeID, to: SpatialNodeID)
    case invalidCost
    case costBelowEuclideanDistance
    case nodeKeyMismatch(SpatialNodeID)
    case edgeKeyMismatch(NavigationEdgeKey)
}

public struct NavigationNode: Codable, Hashable, Sendable {
    public let id: SpatialNodeID
    public var position: Vec3
    public var isBlocked: Bool

    public init(id: SpatialNodeID = SpatialNodeID(), position: Vec3, isBlocked: Bool = false) {
        self.id = id
        self.position = position
        self.isBlocked = isBlocked
    }
}

public struct NavigationEdgeKey: Codable, Hashable, Sendable {
    public let from: SpatialNodeID
    public let to: SpatialNodeID

    public init(from: SpatialNodeID, to: SpatialNodeID) {
        self.from = from
        self.to = to
    }
}

public struct NavigationEdge: Codable, Hashable, Sendable {
    public let key: NavigationEdgeKey
    public let cost: Double
    public var isBlocked: Bool

    public init(key: NavigationEdgeKey, cost: Double, isBlocked: Bool = false) throws {
        guard cost.isFinite, cost >= 0 else {
            throw NavigationError.invalidCost
        }
        self.key = key
        self.cost = cost
        self.isBlocked = isBlocked
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case cost
        case isBlocked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                key: container.decode(NavigationEdgeKey.self, forKey: .key),
                cost: container.decode(Double.self, forKey: .cost),
                isBlocked: container.decode(Bool.self, forKey: .isBlocked)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .cost,
                in: container,
                debugDescription: "Navigation cost must be finite and nonnegative."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(cost, forKey: .cost)
        try container.encode(isBlocked, forKey: .isBlocked)
    }
}

public struct NavigationPath: Codable, Hashable, Sendable {
    public let nodes: [SpatialNodeID]
    public let totalCost: Double

    public init(nodes: [SpatialNodeID], totalCost: Double) {
        self.nodes = nodes
        self.totalCost = totalCost
    }
}

/// A deterministic A* graph. Custom costs must be at least the straight-line
/// distance so the Euclidean heuristic remains admissible.
public struct NavigationGraph: Codable, Sendable {
    public private(set) var nodes: [SpatialNodeID: NavigationNode] = [:]
    public private(set) var edges: [NavigationEdgeKey: NavigationEdge] = [:]

    public init() {}

    public init(
        validatingNodes nodes: [SpatialNodeID: NavigationNode],
        edges: [NavigationEdgeKey: NavigationEdge]
    ) throws {
        for (key, node) in nodes where key != node.id {
            throw NavigationError.nodeKeyMismatch(key)
        }
        for (key, edge) in edges {
            guard key == edge.key else {
                throw NavigationError.edgeKeyMismatch(key)
            }
            guard let source = nodes[key.from] else {
                throw NavigationError.nodeNotFound(key.from)
            }
            guard let destination = nodes[key.to] else {
                throw NavigationError.nodeNotFound(key.to)
            }
            let distance = source.position.distance(to: destination.position)
            guard edge.cost + .ulpOfOne >= distance else {
                throw NavigationError.costBelowEuclideanDistance
            }
        }
        self.nodes = nodes
        self.edges = edges
    }

    public mutating func addNode(_ node: NavigationNode) throws {
        guard nodes[node.id] == nil else {
            throw NavigationError.duplicateNode(node.id)
        }
        nodes[node.id] = node
    }

    public mutating func setNodeBlocked(_ id: SpatialNodeID, blocked: Bool) throws {
        guard var node = nodes[id] else {
            throw NavigationError.nodeNotFound(id)
        }
        node.isBlocked = blocked
        nodes[id] = node
    }

    public mutating func addEdge(
        from: SpatialNodeID,
        to: SpatialNodeID,
        cost customCost: Double? = nil,
        bidirectional: Bool = true,
        isBlocked: Bool = false
    ) throws {
        guard let source = nodes[from] else {
            throw NavigationError.nodeNotFound(from)
        }
        guard let destination = nodes[to] else {
            throw NavigationError.nodeNotFound(to)
        }
        let distance = source.position.distance(to: destination.position)
        let cost = customCost ?? distance
        guard cost.isFinite, cost >= 0 else {
            throw NavigationError.invalidCost
        }
        guard cost + .ulpOfOne >= distance else {
            throw NavigationError.costBelowEuclideanDistance
        }

        let forwardKey = NavigationEdgeKey(from: from, to: to)
        edges[forwardKey] = try NavigationEdge(
            key: forwardKey,
            cost: cost,
            isBlocked: isBlocked
        )
        if bidirectional {
            let reverseKey = NavigationEdgeKey(from: to, to: from)
            edges[reverseKey] = try NavigationEdge(
                key: reverseKey,
                cost: cost,
                isBlocked: isBlocked
            )
        }
    }

    public mutating func setEdgeBlocked(
        from: SpatialNodeID,
        to: SpatialNodeID,
        blocked: Bool,
        bidirectional: Bool = true
    ) throws {
        let forwardKey = NavigationEdgeKey(from: from, to: to)
        guard var forward = edges[forwardKey] else {
            throw NavigationError.edgeNotFound(from: from, to: to)
        }
        let reverseKey = NavigationEdgeKey(from: to, to: from)
        var reverse: NavigationEdge?
        if bidirectional {
            guard let existingReverse = edges[reverseKey] else {
                throw NavigationError.edgeNotFound(from: to, to: from)
            }
            reverse = existingReverse
        }

        forward.isBlocked = blocked
        edges[forwardKey] = forward
        if var reverse {
            reverse.isBlocked = blocked
            edges[reverseKey] = reverse
        }
    }

    public func shortestPath(
        from start: SpatialNodeID,
        to goal: SpatialNodeID
    ) throws -> NavigationPath? {
        guard let startNode = nodes[start] else {
            throw NavigationError.nodeNotFound(start)
        }
        guard let goalNode = nodes[goal] else {
            throw NavigationError.nodeNotFound(goal)
        }
        guard !startNode.isBlocked, !goalNode.isBlocked else {
            return nil
        }
        if start == goal {
            return NavigationPath(nodes: [start], totalCost: 0)
        }

        var open: Set<SpatialNodeID> = [start]
        var closed: Set<SpatialNodeID> = []
        var cameFrom: [SpatialNodeID: SpatialNodeID] = [:]
        var gScore: [SpatialNodeID: Double] = [start: 0]
        var fScore: [SpatialNodeID: Double] = [
            start: startNode.position.distance(to: goalNode.position)
        ]

        while let current = lowestScoreNode(in: open, fScore: fScore, gScore: gScore) {
            if current == goal {
                return NavigationPath(
                    nodes: reconstructPath(cameFrom: cameFrom, current: current),
                    totalCost: gScore[current] ?? 0
                )
            }

            open.remove(current)
            closed.insert(current)

            for edge in outgoingEdges(from: current) where !edge.isBlocked {
                let neighbor = edge.key.to
                guard let neighborNode = nodes[neighbor], !neighborNode.isBlocked,
                    !closed.contains(neighbor)
                else {
                    continue
                }

                let tentative = (gScore[current] ?? .infinity) + edge.cost
                let existing = gScore[neighbor] ?? .infinity
                let preferredEqualPredecessor =
                    tentative == existing
                    && current < (cameFrom[neighbor] ?? current)
                if tentative < existing || preferredEqualPredecessor {
                    cameFrom[neighbor] = current
                    gScore[neighbor] = tentative
                    fScore[neighbor] =
                        tentative
                        + neighborNode.position.distance(to: goalNode.position)
                    open.insert(neighbor)
                }
            }
        }
        return nil
    }

    private func outgoingEdges(from node: SpatialNodeID) -> [NavigationEdge] {
        edges.values
            .filter { $0.key.from == node }
            .sorted { lhs, rhs in lhs.key.to < rhs.key.to }
    }

    private func lowestScoreNode(
        in open: Set<SpatialNodeID>,
        fScore: [SpatialNodeID: Double],
        gScore: [SpatialNodeID: Double]
    ) -> SpatialNodeID? {
        open.min { lhs, rhs in
            let leftF = fScore[lhs] ?? .infinity
            let rightF = fScore[rhs] ?? .infinity
            if leftF != rightF {
                return leftF < rightF
            }
            let leftG = gScore[lhs] ?? .infinity
            let rightG = gScore[rhs] ?? .infinity
            if leftG != rightG {
                return leftG < rightG
            }
            return lhs < rhs
        }
    }

    private func reconstructPath(
        cameFrom: [SpatialNodeID: SpatialNodeID],
        current: SpatialNodeID
    ) -> [SpatialNodeID] {
        var path = [current]
        var cursor = current
        while let predecessor = cameFrom[cursor] {
            path.append(predecessor)
            cursor = predecessor
        }
        return path.reversed()
    }

    private enum CodingKeys: String, CodingKey {
        case nodes
        case edges
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                validatingNodes: container.decode(
                    [SpatialNodeID: NavigationNode].self,
                    forKey: .nodes
                ),
                edges: container.decode(
                    [NavigationEdgeKey: NavigationEdge].self,
                    forKey: .edges
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .edges,
                in: container,
                debugDescription: "Navigation graph contains inconsistent nodes or edges."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(edges, forKey: .edges)
    }
}
