import XCTest

@testable import VispaceCore

final class NavigationTests: XCTestCase {
    func testAStarFindsShortestPath() throws {
        let start = nodeID(1)
        let middle = nodeID(2)
        let goal = nodeID(3)
        var graph = NavigationGraph()
        try graph.addNode(NavigationNode(id: start, position: vec(0)))
        try graph.addNode(NavigationNode(id: middle, position: vec(1)))
        try graph.addNode(NavigationNode(id: goal, position: vec(2)))
        try graph.addEdge(from: start, to: middle)
        try graph.addEdge(from: middle, to: goal)
        try graph.addEdge(from: start, to: goal, cost: 3)

        let path = try graph.shortestPath(from: start, to: goal)
        XCTAssertEqual(path?.nodes, [start, middle, goal])
        XCTAssertEqual(path?.totalCost, 2)
    }

    func testBlockedDirectEdgeUsesTraversableDetour() throws {
        let start = nodeID(1)
        let direct = nodeID(2)
        let detour = nodeID(3)
        let goal = nodeID(4)
        var graph = NavigationGraph()
        try graph.addNode(NavigationNode(id: start, position: vec(0, 0, 0)))
        try graph.addNode(NavigationNode(id: direct, position: vec(1, 0, 0)))
        try graph.addNode(NavigationNode(id: detour, position: vec(0, 0, 1)))
        try graph.addNode(NavigationNode(id: goal, position: vec(2, 0, 0)))
        try graph.addEdge(from: start, to: direct)
        try graph.addEdge(from: direct, to: goal)
        try graph.addEdge(from: start, to: detour)
        try graph.addEdge(from: detour, to: goal)
        try graph.setEdgeBlocked(from: direct, to: goal, blocked: true)

        let path = try graph.shortestPath(from: start, to: goal)
        XCTAssertEqual(path?.nodes, [start, detour, goal])
        XCTAssertFalse(path?.nodes.contains(direct) ?? true)
    }

    func testBlockedNodeAndFullyBlockedRouteReturnNoPath() throws {
        let start = nodeID(1)
        let middle = nodeID(2)
        let goal = nodeID(3)
        var graph = NavigationGraph()
        try graph.addNode(NavigationNode(id: start, position: vec(0)))
        try graph.addNode(NavigationNode(id: middle, position: vec(1)))
        try graph.addNode(NavigationNode(id: goal, position: vec(2)))
        try graph.addEdge(from: start, to: middle)
        try graph.addEdge(from: middle, to: goal)
        try graph.setNodeBlocked(middle, blocked: true)
        XCTAssertNil(try graph.shortestPath(from: start, to: goal))

        try graph.setNodeBlocked(middle, blocked: false)
        try graph.setEdgeBlocked(from: start, to: middle, blocked: true)
        XCTAssertNil(try graph.shortestPath(from: start, to: goal))
    }

    func testEqualCostTieUsesStableIdentifierOrder() throws {
        let start = nodeID(1)
        let first = nodeID(2)
        let second = nodeID(3)
        let goal = nodeID(4)
        var graph = NavigationGraph()
        try graph.addNode(NavigationNode(id: start, position: vec(0, 0, 0)))
        try graph.addNode(NavigationNode(id: first, position: vec(1, 0, 1)))
        try graph.addNode(NavigationNode(id: second, position: vec(1, 0, -1)))
        try graph.addNode(NavigationNode(id: goal, position: vec(2, 0, 0)))
        try graph.addEdge(from: start, to: second)
        try graph.addEdge(from: second, to: goal)
        try graph.addEdge(from: start, to: first)
        try graph.addEdge(from: first, to: goal)

        let path = try graph.shortestPath(from: start, to: goal)
        XCTAssertEqual(path?.nodes, [start, first, goal])
    }

    func testCostBelowEuclideanDistanceIsRejected() throws {
        let start = nodeID(1)
        let goal = nodeID(2)
        var graph = NavigationGraph()
        try graph.addNode(NavigationNode(id: start, position: vec(0)))
        try graph.addNode(NavigationNode(id: goal, position: vec(2)))
        XCTAssertThrowsError(try graph.addEdge(from: start, to: goal, cost: 1)) { error in
            XCTAssertEqual(error as? NavigationError, .costBelowEuclideanDistance)
        }
    }

    func testMissingAndBlockedEndpointsAreHandled() throws {
        let start = nodeID(1)
        let blockedGoal = nodeID(2)
        let missing = nodeID(99)
        var graph = NavigationGraph()
        try graph.addNode(NavigationNode(id: start, position: vec(0)))
        try graph.addNode(NavigationNode(id: blockedGoal, position: vec(1), isBlocked: true))
        XCTAssertNil(try graph.shortestPath(from: start, to: blockedGoal))
        XCTAssertThrowsError(try graph.shortestPath(from: start, to: missing)) { error in
            XCTAssertEqual(error as? NavigationError, .nodeNotFound(missing))
        }
    }

    func testBidirectionalBlockFailureIsAtomicWhenReverseEdgeIsMissing() throws {
        let start = nodeID(1)
        let goal = nodeID(2)
        var graph = NavigationGraph()
        try graph.addNode(NavigationNode(id: start, position: vec(0)))
        try graph.addNode(NavigationNode(id: goal, position: vec(1)))
        try graph.addEdge(from: start, to: goal, bidirectional: false)

        XCTAssertThrowsError(
            try graph.setEdgeBlocked(from: start, to: goal, blocked: true, bidirectional: true)
        ) { error in
            XCTAssertEqual(
                error as? NavigationError,
                .edgeNotFound(from: goal, to: start)
            )
        }
        let key = NavigationEdgeKey(from: start, to: goal)
        XCTAssertEqual(graph.edges[key]?.isBlocked, false)
    }

    func testGraphValidationRejectsMismatchedEdgeDictionaryKey() throws {
        let start = nodeID(1)
        let goal = nodeID(2)
        let nodes = [
            start: NavigationNode(id: start, position: vec(0)),
            goal: NavigationNode(id: goal, position: vec(1)),
        ]
        let storedKey = NavigationEdgeKey(from: start, to: goal)
        let incorrectKey = NavigationEdgeKey(from: goal, to: start)
        let edge = try NavigationEdge(key: storedKey, cost: 1)

        XCTAssertThrowsError(
            try NavigationGraph(validatingNodes: nodes, edges: [incorrectKey: edge])
        ) { error in
            XCTAssertEqual(error as? NavigationError, .edgeKeyMismatch(incorrectKey))
        }
    }

    func testNavigationGraphCodableRoundTripPreservesPath() throws {
        let start = nodeID(1)
        let goal = nodeID(2)
        var graph = NavigationGraph()
        try graph.addNode(NavigationNode(id: start, position: vec(0)))
        try graph.addNode(NavigationNode(id: goal, position: vec(1)))
        try graph.addEdge(from: start, to: goal)

        let data = try JSONEncoder().encode(graph)
        let restored = try JSONDecoder().decode(NavigationGraph.self, from: data)
        XCTAssertEqual(try restored.shortestPath(from: start, to: goal)?.nodes, [start, goal])
    }
}
