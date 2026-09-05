import Foundation
import VispaceCore
import XCTest

@testable import Vispace

@MainActor
final class ObservedSpatialRelationPersistenceTests: XCTestCase {
    func testRealNavigationDerivationPersistsReloadsAndAnswersRelationQuery() async throws {
        let fixture = try ObservedGraphFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SceneGraphRepository(directoryURL: directory)
        let graph = try fixture.derive()
        XCTAssertFalse(graph.relations().isEmpty)
        try await SpatialSceneGraphService(repository: repository).replaceObservedRelations(
            mapID: fixture.mapID, coordinateFrameID: fixture.frameID, graph: graph, at: 1_000)
        let saved = try await SceneGraphRepository(directoryURL: directory).load(mapID: fixture.mapID)
        let restored = try XCTUnwrap(saved)
        XCTAssertEqual(
            restored.graph.relations(includeProvisional: true), graph.relations(includeProvisional: true))
        let result = try DeterministicSpatialRelationQueryEngine().query(
            "table accessible from chair", records: fixture.records, graph: restored.graph, at: 1_000.25)
        XCTAssertEqual(result.isAffirmative, true)
        XCTAssertTrue(result.matches.allSatisfy { $0.predicate == .accessibleFrom })
    }

    func testNewSurfaceAndEmptyObservationArchivePriorLeaseWithOriginalProvenance() async throws {
        let fixture = try ObservedGraphFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SceneGraphRepository(directoryURL: directory)
        let service = SpatialSceneGraphService(repository: repository)
        try await service.replaceObservedRelations(
            mapID: fixture.mapID, coordinateFrameID: fixture.frameID,
            graph: fixture.derive(), at: 1_000)
        try await service.replaceObservedRelations(
            mapID: fixture.mapID, coordinateFrameID: fixture.frameID,
            graph: fixture.derive(revision: 43, observedAt: 100.1, wallTime: 1_000.1), at: 1_000.1)
        let next = try await repository.load(mapID: fixture.mapID)
        XCTAssertTrue(
            next?.graph.relations().allSatisfy { $0.observationSource?.surfaceRevision == 43 } == true)
        let previous = try XCTUnwrap(next?.expiredRelationHistory)
        XCTAssertFalse(previous.isEmpty)
        XCTAssertTrue(
            previous.allSatisfy { $0.observationSource?.surfaceRevision == 42 && $0.validUntil == 1_000.1 })
        try await service.replaceObservedRelations(
            mapID: fixture.mapID, coordinateFrameID: fixture.frameID,
            graph: SceneGraph(), at: 1_000.2)
        let cold = try await SceneGraphRepository(directoryURL: directory).load(mapID: fixture.mapID)
        XCTAssertTrue(cold?.graph.relations().isEmpty == true)
        let archived = try XCTUnwrap(cold?.expiredRelationHistory)
        XCTAssertTrue(
            archived.contains { $0.observationSource?.surfaceRevision == 43 && $0.validUntil == 1_000.2 })
        XCTAssertTrue(archived.allSatisfy { $0.observationSource?.segmentID == fixture.segmentID })
        let result = try DeterministicSpatialRelationQueryEngine().query(
            "table accessible from chair",
            records: fixture.records, graph: try XCTUnwrap(cold?.graph), at: 1_000.25)
        XCTAssertNil(result.isAffirmative)
    }

    func testCommittedMetadataRevisionFencesCachedNavigationRelationAtController() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = ARCaptureIdentity(status: .confirmed)
        let source = WorldMapCheckpointRepository(
            directoryURL: directory,
            blobStore: ARWorldMapBlobStore(
                directoryURL: directory.appendingPathComponent("WorldMaps"),
                maximumArchiveBytes: ARWorldMapArchiveCodec.maximumArchiveBytes, archiveValidator: { _ in }))
        let map = try await source.saveCheckpoint(
            archive: Data("test-world-map".utf8), captureIdentity: identity)
        let fixture = try ObservedGraphFixture(mapID: map.mapID, frameID: identity.coordinateFrameID)
        _ = try await source.upsertObjectMetadataBatch(fixture.objects)
        let repository = SceneGraphRepository(directoryURL: directory)
        try await SpatialSceneGraphService(repository: repository).replaceObservedRelations(
            mapID: fixture.mapID,
            coordinateFrameID: fixture.frameID, graph: fixture.derive(), at: 1_000)
        let current = ARCaptureIdentity(
            coordinateFrameID: fixture.frameID, segmentID: fixture.segmentID,
            mapID: fixture.mapID, status: .confirmed)
        let controller = SpatialRelationQueryController(
            snapshotProvider: { mapID in
                let document = try await source.metadataSnapshot()
                let graph = try await repository.load(mapID: mapID)
                return SpatialRelationQuerySnapshot(
                    mapID: mapID, coordinateFrameID: fixture.frameID,
                    records: document.objects.map {
                        StoredSpatialObjectRecord(metadata: $0, memoryTier: .longTerm)
                    },
                    graph: graph?.graph ?? SceneGraph())
            }, currentIdentityProvider: { current })
        controller.submit("table accessible from chair", now: 1_000.1)
        try await waitForQuery(controller)
        XCTAssertEqual(controller.latestPresentation?.result.isAffirmative, true)
        let old = try XCTUnwrap(fixture.objects.first)
        var object = old.object
        object.temporalRevision = 3
        object.lastSeenAt = 1_000.2
        object.stateUpdatedAt = 1_000.2
        let update = try SpatialObjectMetadata(
            mapID: old.mapID, object: object,
            position: FramedPosition(
                coordinateFrameID: old.position.coordinateFrameID, value: old.position.value,
                observedAt: 1_000.2, trackingQuality: .normal, uncertainty: .highConfidenceDepth))
        _ = try await source.upsertObjectMetadataBatch([update])
        controller.submit("table accessible from chair", now: 1_000.3)
        try await waitForQuery(controller)
        XCTAssertNil(controller.latestPresentation?.result.isAffirmative)
        XCTAssertNotEqual(controller.latestPresentation?.result.status, .answered)
    }

    func testInvalidObservationCannotReplaceCommittedGraph() async throws {
        let fixture = try ObservedGraphFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SceneGraphRepository(directoryURL: directory)
        let service = SpatialSceneGraphService(repository: repository)
        let graph = try fixture.derive()
        try await service.replaceObservedRelations(
            mapID: fixture.mapID, coordinateFrameID: fixture.frameID,
            graph: graph, at: 1_000)
        do {
            try await service.replaceObservedRelations(
                mapID: fixture.mapID, coordinateFrameID: fixture.frameID,
                graph: graph, at: 1_001)
            XCTFail("Expired observation must not be committed")
        } catch { XCTAssertEqual(error as? SpatialSceneGraphServiceError, .outOfOrderObservation) }
        let record = try await repository.load(mapID: fixture.mapID)
        XCTAssertEqual(
            record?.graph.relations(includeProvisional: true), graph.relations(includeProvisional: true))
        XCTAssertTrue(record?.expiredRelationHistory.isEmpty == true)
    }

    func testCapacityFailureNeverPublishesUncommittedPositiveGraph() async throws {
        let fixture = try ObservedGraphFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SceneGraphRepository(directoryURL: directory, catalogByteLimit: 1_024)
        let service = SpatialSceneGraphService(repository: repository)
        do {
            try await service.replaceObservedRelations(
                mapID: fixture.mapID, coordinateFrameID: fixture.frameID,
                graph: fixture.derive(), at: 1_000)
            XCTFail("The observed graph exceeds the deliberately tiny catalog budget")
        } catch {
            guard let repositoryError = error as? SceneGraphRepositoryError,
                case .catalogTooLarge = repositoryError
            else {
                return XCTFail("Unexpected persistence error: \(error)")
            }
        }
        let saved = try await repository.load(mapID: fixture.mapID)
        XCTAssertNil(saved)
    }

    private func waitForQuery(_ controller: SpatialRelationQueryController) async throws {
        for _ in 0..<400 where controller.isProcessingForTesting {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(controller.isProcessingForTesting)
        if controller.isProcessingForTesting { await controller.invalidateAndWaitForPendingWork() }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "ObservedRelations.\(UUID().uuidString)")
    }
}

private struct ObservedGraphFixture: Sendable {
    let mapID: MapID
    let frameID: CoordinateFrameID
    let segmentID = CaptureSegmentID()
    let objects: [SpatialObjectMetadata]
    var records: [StoredSpatialObjectRecord] {
        objects.map { StoredSpatialObjectRecord(metadata: $0, memoryTier: .longTerm) }
    }

    init(mapID: MapID = MapID(), frameID: CoordinateFrameID = CoordinateFrameID()) throws {
        self.mapID = mapID
        self.frameID = frameID
        objects = try [("chair", 0.0), ("table", 6.0)].map { label, x in
            let point = try Vec3(x: x, y: 0, z: 0)
            return try SpatialObjectMetadata(
                mapID: mapID,
                object: SpatialObject(
                    semanticLabel: label, position: point, certainty: .confirmed, presence: .visible,
                    confidence: ConfidenceVector(
                        semantic: .one, geometry: .one, tracking: .one, place: .one,
                        identity: .one, objectState: .one, relation: .one),
                    firstSeenAt: 1, lastSeenAt: 1_000, temporalRevision: 2),
                position: FramedPosition(
                    coordinateFrameID: frameID, value: point, observedAt: 1_000,
                    trackingQuality: .normal, uncertainty: .highConfidenceDepth))
        }
    }

    func derive(revision: UInt64 = 42, observedAt: TimeInterval = 100, wallTime: TimeInterval = 1_000) throws
        -> SceneGraph
    {
        let cells = (0...6).map { IndoorNavigationCell(column: $0, row: 0) }
        let evidence = try IndoorNavigationEvidence(
            mapID: mapID, coordinateFrameID: frameID,
            revision: revision, observedAt: observedAt, gridOrigin: Vec3(x: 0, y: 0, z: 0), cellSize: 1,
            floors: cells.map {
                try IndoorNavigationFloorEvidence(
                    cell: $0, zoneIdentifier: "room", elevation: 0, confidence: .one)
            },
            mesh: cells.map { IndoorNavigationMeshEvidence(cell: $0, occupancy: .free, confidence: .one) },
            completeness: .complete)
        let scope = try XCTUnwrap(
            DeterministicSpatialRelationQueryEngine().targetScope(
                for: "table accessible from chair", records: records))
        return try ObservedNavigationRelationDeriver().derive(
            scope: scope, objects: objects, evidence: evidence,
            cameraStart: FramedPosition(
                coordinateFrameID: frameID, value: Vec3(x: 0, y: 0, z: 0),
                observedAt: observedAt, trackingQuality: .normal, uncertainty: .highConfidenceDepth),
            segmentID: segmentID, evaluatedAt: observedAt, wallTime: wallTime)
    }
}
