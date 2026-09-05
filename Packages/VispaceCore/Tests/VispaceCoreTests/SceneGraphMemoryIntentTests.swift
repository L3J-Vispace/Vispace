import XCTest

@testable import VispaceCore

final class SceneGraphMemoryIntentTests: XCTestCase {
    func testProvisionalRelationDoesNotPolluteConfirmedQueries() throws {
        let key = RelationKey(
            subject: .object(objectID(1)),
            predicate: .on,
            object: .object(objectID(2))
        )
        let provisional = try SpatialRelation(
            key: key,
            confidence: score(0.7),
            certainty: .provisional,
            validFrom: 1
        )
        var graph = SceneGraph()
        try graph.upsert(provisional)

        XCTAssertTrue(graph.relations().isEmpty)
        XCTAssertEqual(graph.relations(includeProvisional: true), [provisional])
    }

    func testConfirmedRelationRequiresHighConfidenceAndCannotBeDowngraded() throws {
        let key = RelationKey(
            subject: .object(objectID(1)),
            predicate: .near,
            object: .spatialNode(nodeID(1))
        )
        let insufficient = try SpatialRelation(
            key: key,
            confidence: score(0.799),
            certainty: .confirmed,
            validFrom: 1
        )
        var graph = SceneGraph()
        XCTAssertThrowsError(try graph.upsert(insufficient)) { error in
            XCTAssertEqual(error as? SceneGraphError, .insufficientConfidence(key))
        }

        let confirmed = try SpatialRelation(
            key: key,
            confidence: score(0.8),
            certainty: .confirmed,
            validFrom: 2
        )
        try graph.upsert(confirmed)
        XCTAssertEqual(graph.relations(), [confirmed])

        let downgrade = try SpatialRelation(
            key: key,
            confidence: score(0.7),
            certainty: .provisional,
            validFrom: 3
        )
        XCTAssertThrowsError(try graph.upsert(downgrade)) { error in
            XCTAssertEqual(error as? SceneGraphError, .cannotDowngradeConfirmedRelation(key))
        }
        XCTAssertEqual(graph.relations(), [confirmed])
    }

    func testRelationValidityAndOutOfOrderUpdates() throws {
        let key = RelationKey(
            subject: .object(objectID(1)),
            predicate: .inside,
            object: .spatialNode(nodeID(1))
        )
        let current = try SpatialRelation(
            key: key,
            confidence: .one,
            certainty: .confirmed,
            validFrom: 10,
            validUntil: 20
        )
        var graph = SceneGraph()
        try graph.upsert(current)
        XCTAssertEqual(graph.relations(validAt: 10), [current])
        XCTAssertEqual(graph.relations(validAt: 20), [current])
        XCTAssertTrue(graph.relations(validAt: 20.001).isEmpty)

        let older = try SpatialRelation(
            key: key,
            confidence: .one,
            certainty: .confirmed,
            validFrom: 9
        )
        XCTAssertThrowsError(try graph.upsert(older)) { error in
            XCTAssertEqual(error as? SceneGraphError, .outOfOrderRelation(key))
        }
    }

    func testRelationDerivationUsesYUpAxisAlignedGeometry() {
        let table = box(minX: 0, minY: 0, minZ: 0, maxX: 2, maxY: 1, maxZ: 2)
        let laptop = box(minX: 0.5, minY: 1, minZ: 0.5, maxX: 1.5, maxY: 1.2, maxZ: 1.5)
        let predicates = SpatialRelationDeriver().predicates(subject: laptop, object: table)
        XCTAssertTrue(predicates.contains(.on))
        XCTAssertTrue(predicates.contains(.near))
        XCTAssertFalse(predicates.contains(.inside))

        let container = box(minX: -1, minY: -1, minZ: -1, maxX: 3, maxY: 3, maxZ: 3)
        XCTAssertTrue(
            SpatialRelationDeriver().predicates(subject: laptop, object: container).contains(.inside)
        )
    }

    func testMemoryRejectsProvisionalObjects() throws {
        let candidate = makeObject(id: objectID(1), certainty: .provisional)
        XCTAssertThrowsError(
            try HierarchicalSpatialMemory(realtime: [candidate.id: candidate])
        ) { error in
            XCTAssertEqual(error as? SpatialMemoryError, .provisionalObject(candidate.id))
        }
    }

    func testMemoryStopsAtFirstTierAndRanksCurrentBeforeLastSeen() throws {
        let l1LastSeen = makeObject(
            id: objectID(2),
            position: vec(2),
            presence: .lastSeen,
            lastSeenAt: 20
        )
        let l1Current = makeObject(
            id: objectID(1),
            position: vec(1),
            presence: .visible,
            lastSeenAt: 10
        )
        let strongerL3 = makeObject(
            id: objectID(3),
            position: vec(3),
            confidence: vector(objectState: 1),
            lastSeenAt: 30
        )
        let memory = try HierarchicalSpatialMemory(
            realtime: [l1LastSeen.id: l1LastSeen, l1Current.id: l1Current],
            longTerm: [strongerL3.id: strongerL3]
        )

        let hits = memory.search(semanticLabel: "  노트북 ")
        XCTAssertEqual(hits.map(\.object.id), [l1Current.id, l1LastSeen.id])
        XCTAssertTrue(hits.allSatisfy { $0.tier == .realtime })
        XCTAssertEqual(hits.first?.locationKind, .current)
    }

    func testMemoryExcludesRemovedUnlessRequested() throws {
        let removed = makeObject(id: objectID(1), presence: .removed)
        let memory = try HierarchicalSpatialMemory(longTerm: [removed.id: removed])
        XCTAssertTrue(memory.search(semanticLabel: "노트북").isEmpty)
        XCTAssertEqual(
            memory.search(semanticLabel: "노트북", includeRemoved: true).first?.locationKind,
            .removed
        )
    }

    func testIntentRoutingHasExplicitPrecedenceAndFallback() {
        let router = DeterministicIntentRouter()

        let composite = router.route("프린터 마지막 위치로 안내해줘")
        XCTAssertEqual(composite.kind, .lastSeen)
        XCTAssertFalse(composite.requiresLLM)

        XCTAssertEqual(router.route("프린터까지 어떻게 가?").kind, .navigate)
        XCTAssertEqual(router.route("가방이 책상 아래 있어?").kind, .relationQuery)
        XCTAssertEqual(router.route("what is on the desk?").kind, .relationQuery)
        XCTAssertEqual(router.route("chair connected to table").kind, .relationQuery)
        XCTAssertEqual(router.route("where is my phone?").kind, .searchObject)
        XCTAssertEqual(router.route("내 노트북 어디 있어?").kind, .searchObject)

        let unknown = router.route("이 의자를 여기 둬도 괜찮을까?")
        XCTAssertEqual(unknown.kind, .complexAsk)
        XCTAssertTrue(unknown.requiresLLM)
    }

    func testSceneGraphRestoreValidatesPartitionsAndRoundTrips() throws {
        let key = RelationKey(
            subject: .object(objectID(1)),
            predicate: .connectedTo,
            object: .spatialNode(nodeID(1))
        )
        let confirmed = try SpatialRelation(
            key: key,
            confidence: .one,
            certainty: .confirmed,
            validFrom: 1
        )
        XCTAssertThrowsError(
            try SceneGraph(
                validatingConfirmedRelations: [:],
                provisionalRelations: [key: confirmed]
            )
        ) { error in
            XCTAssertEqual(error as? SceneGraphError, .relationCertaintyMismatch(key))
        }

        var graph = SceneGraph()
        try graph.upsert(confirmed)
        let data = try JSONEncoder().encode(graph)
        let restored = try JSONDecoder().decode(SceneGraph.self, from: data)
        XCTAssertEqual(restored.relations(), [confirmed])
    }
}
