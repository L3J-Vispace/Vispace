import Foundation
import XCTest

@testable import VispaceCore

final class ObservedNavigationRelationTests: XCTestCase {
    func testObservedRoutesProduceAccessibleAndConnectedRelationsWithProvenanceAndExpiry() throws {
        let fixture = RelationFixture()
        let chair = try fixture.object("chair", x: 0)
        let table = try fixture.object("table", x: 6)
        for predicate in ["accessible from", "connected to"] {
            let graph = try fixture.derive("table \(predicate) chair", objects: [chair, table])
            let relation = try XCTUnwrap(
                graph.relations(subject: .object(table.object.id), object: .object(chair.object.id)).first)
            XCTAssertEqual(relation.certainty, .confirmed)
            XCTAssertEqual(relation.observationSource?.mapID, fixture.mapID)
            XCTAssertEqual(relation.observationSource?.coordinateFrameID, fixture.frameID)
            XCTAssertEqual(relation.observationSource?.segmentID, fixture.segmentID)
            XCTAssertEqual(relation.observationSource?.surfaceRevision, 42)
            XCTAssertEqual(relation.observationSource?.observedAt, 100)
            XCTAssertEqual(relation.subjectTemporalRevision, table.object.temporalRevision)
            XCTAssertEqual(relation.objectTemporalRevision, chair.object.temporalRevision)
            XCTAssertEqual(relation.validUntil, 1_000.75)
            XCTAssertFalse(graph.relations(validAt: 1_000.5).isEmpty)
            XCTAssertTrue(graph.relations(validAt: 1_001).isEmpty)
            let records = [chair, table].map {
                StoredSpatialObjectRecord(metadata: $0, memoryTier: .longTerm)
            }
            let query = try DeterministicSpatialRelationQueryEngine().query(
                "table \(predicate) chair", records: records, graph: graph, at: 1_000.5)
            XCTAssertEqual(query.isAffirmative, true)
        }
    }

    func testApproachAcrossWallDoesNotCreateAccessibility() throws {
        let fixture = RelationFixture()
        let chair = try fixture.object("chair", x: 0.9)
        let table = try fixture.object("table", x: -3)
        let wall = try IndoorNavigationWallEvidence(
            identifier: "separator",
            start: Vec3(x: 0.5, y: 0, z: -2), end: Vec3(x: 0.5, y: 0, z: 2),
            thickness: 0.1, confidence: .one)
        let evidence = try fixture.evidence(columns: -3...0, walls: [wall])
        let graph = try fixture.derive(
            "table accessible from chair", objects: [chair, table], evidence: evidence)
        XCTAssertTrue(graph.relations().isEmpty)
    }

    func testObservedBlockerIsAttributedOnlyWhenRemovingItRestoresKnownRoute() throws {
        let fixture = RelationFixture()
        let bounds = try AABB(min: Vec3(x: 2.5, y: 0, z: -0.5), max: Vec3(x: 3.5, y: 1, z: 0.5))
        let chair = try fixture.object("chair", x: 3, bounds: bounds)
        let table = try fixture.object("table", x: 6)
        let obstacle = try IndoorNavigationObstacleEvidence(
            identifier: "chair-depth",
            objectID: chair.object.id, bounds: bounds, confidence: .one)
        let evidence = try fixture.evidence(blocked: [3], obstacles: [obstacle])
        let actual = try IndoorARNavigationEngine().route(
            from: fixture.start(), to: table, using: evidence, evaluatedAt: 100)
        XCTAssertEqual(actual.status, .unreachable)
        let graph = try fixture.derive("chair blocking table", objects: [chair, table], evidence: evidence)
        let relation = try XCTUnwrap(
            graph.relations(
                subject: .object(chair.object.id), predicate: .blocking,
                object: .object(table.object.id)
            ).first)
        XCTAssertEqual(relation.observationSource?.surfaceRevision, 42)
        // A counterfactual never escapes as a positive accessible relation.
        XCTAssertTrue(
            try fixture.derive("table accessible from chair", objects: [chair, table], evidence: evidence)
                .relations().isEmpty)
    }

    func testUnknownCellsUnidentifiedOrOverlappingObstaclesCannotAttributeBlockage() throws {
        let fixture = RelationFixture()
        let bounds = try AABB(min: Vec3(x: 2.5, y: 0, z: -0.5), max: Vec3(x: 3.5, y: 1, z: 0.5))
        let chair = try fixture.object("chair", x: 3, bounds: bounds)
        let table = try fixture.object("table", x: 6)
        let identified = try IndoorNavigationObstacleEvidence(
            identifier: "chair-depth",
            objectID: chair.object.id, bounds: bounds, confidence: .one)
        let unowned = try IndoorNavigationObstacleEvidence(
            identifier: "unowned", bounds: bounds, confidence: .one)
        let evidences = try [
            fixture.evidence(unknown: [3], obstacles: [identified]),
            fixture.evidence(blocked: [3], obstacles: [unowned]),
            fixture.evidence(blocked: [3], obstacles: [identified, unowned]),
            fixture.evidence(blocked: [3, 5], obstacles: [identified]),
        ]
        for evidence in evidences {
            XCTAssertTrue(
                try fixture.derive("chair blocking table", objects: [chair, table], evidence: evidence)
                    .relations().isEmpty)
        }
    }

    func testStaleMissingAndIncompatibleEvidenceDoesNotProduceFacts() throws {
        let fixture = RelationFixture()
        let chair = try fixture.object("chair", x: 0)
        let table = try fixture.object("table", x: 6)
        XCTAssertTrue(
            try fixture.derive("table accessible from chair", objects: [chair, table], evaluatedAt: 100.8)
                .relations().isEmpty)
        XCTAssertTrue(
            try fixture.derive("table accessible from chair", objects: [chair, table], wallTime: 1_004)
                .relations().isEmpty)
        XCTAssertTrue(
            try fixture.derive(
                "table accessible from chair", objects: [chair, table],
                evidence: fixture.evidence(unknown: [3])
            ).relations().isEmpty)
        XCTAssertTrue(
            try fixture.derive(
                "table accessible from chair", objects: [chair, table],
                evidence: fixture.evidence(complete: false)
            ).relations().isEmpty)
        let otherRoom = try fixture.object("chair", x: 0, mapID: MapID())
        XCTAssertTrue(
            try fixture.derive("table accessible from chair", objects: [otherRoom, table]).relations().isEmpty
        )
    }

    func testClosedAndUnknownDoorRevokeConnectedRelationWhileOpenLeaseBoundsExpiry() throws {
        let fixture = RelationFixture()
        let objects = try [fixture.object("chair", x: 0), fixture.object("table", x: 6)]
        for state in [IndoorNavigationDoorState.open, .closed, .unknown] {
            let door = try IndoorNavigationDoorEvidence(
                identifier: "portal", firstCell: .init(column: 3, row: 0),
                secondCell: .init(column: 4, row: 0), state: state, confidence: .one,
                clearWidth: 1, observedAt: 100, validUntil: 100.4)
            let graph = try fixture.derive(
                "table connected to chair", objects: objects,
                evidence: fixture.evidence(doors: [door]))
            if state == .open {
                XCTAssertFalse(graph.relations().isEmpty)
                XCTAssertEqual(try XCTUnwrap(graph.relations().first?.validUntil), 1_000.4, accuracy: 1e-8)
            } else {
                XCTAssertTrue(graph.relations().isEmpty)
            }
        }
    }
}

private struct RelationFixture {
    let mapID = MapID()
    let frameID = CoordinateFrameID()
    let segmentID = CaptureSegmentID()

    func derive(
        _ utterance: String, objects: [SpatialObjectMetadata], evidence: IndoorNavigationEvidence? = nil,
        evaluatedAt: TimeInterval = 100, wallTime: TimeInterval = 1_000
    ) throws -> SceneGraph {
        let records = objects.map { StoredSpatialObjectRecord(metadata: $0, memoryTier: .longTerm) }
        let scope = try XCTUnwrap(
            DeterministicSpatialRelationQueryEngine().targetScope(for: utterance, records: records))
        return try ObservedNavigationRelationDeriver().derive(
            scope: scope, objects: objects,
            evidence: evidence ?? self.evidence(), cameraStart: start(), segmentID: segmentID,
            evaluatedAt: evaluatedAt, wallTime: wallTime)
    }

    func object(_ label: String, x: Double, bounds: AABB? = nil, mapID: MapID? = nil) throws
        -> SpatialObjectMetadata
    {
        let position = try Vec3(x: x, y: 0, z: 0)
        return try SpatialObjectMetadata(
            mapID: mapID ?? self.mapID,
            object: SpatialObject(
                semanticLabel: label, position: position, bounds: bounds,
                certainty: .confirmed, presence: .visible,
                confidence: ConfidenceVector(
                    semantic: .one, geometry: .one, tracking: .one, place: .one,
                    identity: .one, objectState: .one, relation: .one),
                firstSeenAt: 1, lastSeenAt: 1_000, temporalRevision: 2),
            position: FramedPosition(
                coordinateFrameID: frameID, value: position, observedAt: 1_000,
                trackingQuality: .normal, uncertainty: .highConfidenceDepth))
    }

    func start() throws -> FramedPosition {
        try FramedPosition(
            coordinateFrameID: frameID, value: Vec3(x: 0, y: 0, z: 0), observedAt: 100,
            trackingQuality: .normal, uncertainty: .highConfidenceDepth)
    }

    func evidence(
        columns: ClosedRange<Int> = 0...6, blocked: Set<Int> = [], unknown: Set<Int> = [],
        walls: [IndoorNavigationWallEvidence] = [], obstacles: [IndoorNavigationObstacleEvidence] = [],
        doors: [IndoorNavigationDoorEvidence] = [], complete: Bool = true
    ) throws -> IndoorNavigationEvidence {
        let cells = columns.map { IndoorNavigationCell(column: $0, row: 0) }
        return try IndoorNavigationEvidence(
            mapID: mapID, coordinateFrameID: frameID,
            revision: 42, observedAt: 100, gridOrigin: Vec3(x: 0, y: 0, z: 0), cellSize: 1,
            floors: cells.map {
                try IndoorNavigationFloorEvidence(
                    cell: $0,
                    zoneIdentifier: doors.isEmpty || $0.column <= 3 ? "first" : "second", elevation: 0,
                    confidence: .one)
            },
            mesh: cells.map {
                IndoorNavigationMeshEvidence(
                    cell: $0,
                    occupancy: blocked.contains($0.column)
                        ? .blocked : (unknown.contains($0.column) ? .unknown : .free),
                    confidence: .one)
            },
            doors: doors, walls: walls, obstacles: obstacles,
            completeness: complete ? .complete : .unavailable)
    }
}
