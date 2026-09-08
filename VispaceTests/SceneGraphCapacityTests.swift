import Foundation
import VispaceCore
import XCTest

@testable import Vispace

final class SceneGraphCapacityTests: XCTestCase {
    @MainActor
    func testDenseEncryptedImportRecoversAndCommitsWithCompleteScopedQueries() async throws {
        executionTimeAllowance = 120
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = GraphCapacityFixture()
        let objects = try (0..<256).map { index in
            try fixture.object(label: index == 0 ? "table" : index == 1 ? "cup" : "item\(index)")
        }
        let source = makeSourceRepository(root)
        let candidate = WorldMapRestoreCandidate(
            metadata: temporalTestMapMetadata(mapID: fixture.mapID, coordinateFrameID: fixture.frameID),
            archive: Data("validated-archive-fixture".utf8), objects: objects
        )
        // AR archive validation itself has separate codec tests; exercise real
        // authenticated transport, import, object repository and graph journal here.
        let codec = SpatialPlaceArchiveCodec(archiveValidator: { _ in })
        let encrypted = try codec.seal(candidate)
        let imported = try codec.open(encrypted.encryptedData, recoveryKey: encrypted.recoveryKey)
        _ = try await source.importPortableCheckpoint(imported)
        let graphRepository = SceneGraphRepository(directoryURL: root)
        let graphService = SpatialSceneGraphService(repository: graphRepository)
        let journal = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let temporal = makeTemporal(source: source, journal: journal, graph: graphService)
        let recovered = try await temporal.recover(mapID: fixture.mapID, coordinateFrameID: fixture.frameID)
        XCTAssertEqual(recovered.objects.count, 256)
        let record = try await graphRepository.load(mapID: fixture.mapID)
        XCTAssertEqual(record?.geometryProjection, .onDemand)
        XCTAssertTrue(record?.graph.relations(includeProvisional: true).isEmpty == true)
        let firstRebuildCount = await graphService.rebuildObjectProjectionCount
        XCTAssertEqual(firstRebuildCount, 1, "Dense recovery should project the batch once, not reload each object")
        let bytes = try Data(contentsOf: root.appendingPathComponent(SceneGraphRepository.catalogFileName))
        XCTAssertLessThanOrEqual(bytes.count, SceneGraphRepository.maximumCatalogBytes)

        let next = try await temporal.process(TemporalSpatialRecognitionBatch(
            sequence: 1, observations: [temporalTestNewObservation(
                mapID: fixture.mapID, coordinateFrameID: fixture.frameID,
                objectID: ObjectID(), at: 11
            )], expectedVisibleObjectIDs: []
        ), pose: temporalTestPose(mapID: fixture.mapID, coordinateFrameID: fixture.frameID,
            capturedAt: 11, sessionTimestamp: 1, sequence: 1))
        guard case .applied(let delta) = next else { return XCTFail("Source observation must keep committing") }
        XCTAssertEqual(delta.newRevision, 1)
        let coldGraph = SpatialSceneGraphService(repository: SceneGraphRepository(directoryURL: root))
        let cold = makeTemporal(source: source, journal: journal, graph: coldGraph)
        let afterRestart = try await cold.recover(mapID: fixture.mapID, coordinateFrameID: fixture.frameID)
        XCTAssertEqual(afterRestart.objects.count, 257)
        XCTAssertEqual(afterRestart.revision, 1)
        let coldRebuildCount = await coldGraph.rebuildObjectProjectionCount
        XCTAssertEqual(coldRebuildCount, 1)

        let query = SpatialRelationQueryController(
            objectRepository: SpatialObjectQueryRepository(worldMapRepository: source,
                coordinateAlignmentRepository: CoordinateAlignmentRepository(directoryURL: root)),
            sceneGraphRepository: SceneGraphRepository(directoryURL: root),
            currentIdentityProvider: { fixture.identity }
        )
        query.submit("컵은 테이블 근처 있어?", now: 12)
        try await waitForQuery(query)
        XCTAssertEqual(query.latestPresentation?.result.isAffirmative, true)
        XCTAssertEqual(query.latestPresentation?.result.status, .answered)
    }

    func testGlobalBudgetEvictsOnlyGeometryAndMigratesLegacySchema() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SceneGraphRepository(directoryURL: root, catalogByteLimit: 3_000)
        var opaque: [MapID: SpatialRelation] = [:]
        for _ in 0..<2 {
            let mapID = MapID()
            var graph = SceneGraph()
            let retained = try relation(.blocking)
            opaque[mapID] = retained
            try graph.upsert(retained)
            for _ in 0..<3 { try graph.upsert(relation(.near)) }
            _ = try await repository.apply(SceneGraphMapUpdate(
                mapID: mapID, coordinateFrameID: CoordinateFrameID(), baseRevision: 0,
                graph: graph, expiredRelationHistory: [], timestamp: 10
            ))
        }
        let catalog = try await repository.catalogSnapshot()
        XCTAssertTrue(catalog.records.contains { $0.geometryProjection == .onDemand })
        for record in catalog.records {
            XCTAssertTrue(record.graph.relations().contains(try XCTUnwrap(opaque[record.mapID])))
        }
        XCTAssertLessThanOrEqual(try Data(contentsOf: root.appendingPathComponent(SceneGraphRepository.catalogFileName)).count, 3_000)

        let record = try SceneGraphMapRecord(mapID: MapID(), coordinateFrameID: CoordinateFrameID(),
            revision: 1, graph: SceneGraph(), createdAt: 1, updatedAt: 1)
        let current = try JSONEncoder().encode(SceneGraphCatalogSnapshot(records: [record]))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        var rows = try XCTUnwrap(legacy["records"] as? [[String: Any]])
        rows[0]["schemaVersion"] = 1
        rows[0].removeValue(forKey: "geometryProjection")
        legacy["schemaVersion"] = 1
        legacy["records"] = rows
        let migrated = try JSONDecoder().decode(SceneGraphCatalogSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.records.first?.geometryProjection, .materialized)
        rows[0]["schemaVersion"] = 2
        legacy["schemaVersion"] = 2
        legacy["records"] = rows
        XCTAssertThrowsError(try JSONDecoder().decode(SceneGraphCatalogSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacy)))
        // A v1 reader must reject the new contract rather than answer from the empty cache.
        XCTAssertThrowsError(try SpatialStorageDirectory.validateJSONSchemas(current, maximumSchemaVersion: 1))

        let url = root.appendingPathComponent(SceneGraphRepository.catalogFileName)
        let future = Data("{\"schemaVersion\":3,\"records\":[]}".utf8)
        try future.write(to: url)
        do { _ = try await repository.catalogSnapshot(); XCTFail("Future schema must be preserved") }
        catch { XCTAssertEqual(error as? SpatialStorageError, .unsupportedSchema(actual: 3)) }
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    @MainActor
    func testOpaqueCapacityDeferralPreservesEvidenceAndSurvivesRestartWithoutFalseNegative() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = GraphCapacityFixture()
        let source = makeSourceRepository(root)
        let objects = try [fixture.object(label: "table"), fixture.object(label: "cup")]
        _ = try await source.importPortableCheckpoint(WorldMapRestoreCandidate(
            metadata: temporalTestMapMetadata(mapID: fixture.mapID, coordinateFrameID: fixture.frameID),
            archive: Data("archive".utf8), objects: objects
        ))
        let fullRepository = SceneGraphRepository(directoryURL: root)
        let opaqueMapID = MapID()
        var opaqueGraph = SceneGraph()
        for _ in 0..<10 { try opaqueGraph.upsert(relation(.blocking)) }
        _ = try await fullRepository.apply(SceneGraphMapUpdate(
            mapID: opaqueMapID, coordinateFrameID: CoordinateFrameID(), baseRevision: 0,
            graph: opaqueGraph, expiredRelationHistory: [], timestamp: 10
        ))
        let catalogURL = root.appendingPathComponent(SceneGraphRepository.catalogFileName)
        let originalBytes = try Data(contentsOf: catalogURL)
        // Lower the configured budget to simulate a catalog filled by evidence
        // that cannot be reconstructed from bounds or discarded as cache.
        let limited = SceneGraphRepository(directoryURL: root, catalogByteLimit: 1_024)
        let graph = SpatialSceneGraphService(repository: limited)
        let journal = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let temporal = makeTemporal(source: source, journal: journal, graph: graph)
        _ = try await temporal.recover(mapID: fixture.mapID, coordinateFrameID: fixture.frameID)
        _ = try await temporal.process(TemporalSpatialRecognitionBatch(sequence: 1,
            observations: [temporalTestNewObservation(mapID: fixture.mapID, coordinateFrameID: fixture.frameID,
                objectID: ObjectID(), at: 11)], expectedVisibleObjectIDs: []),
            pose: temporalTestPose(mapID: fixture.mapID, coordinateFrameID: fixture.frameID,
                capturedAt: 11, sessionTimestamp: 1, sequence: 1))
        let committed = try await journal.recover(mapID: fixture.mapID, coordinateFrameID: fixture.frameID)
        XCTAssertEqual(committed?.snapshot.revision, 1)
        XCTAssertEqual(try Data(contentsOf: catalogURL), originalBytes)
        let deferrals = await graph.capacityDeferralCount
        XCTAssertEqual(deferrals, 2, "A deferred batch rebuild should stop after one projection; later observations still retry")
        let restarted = SceneGraphRepository(directoryURL: root, catalogByteLimit: 1_024)
        let deferred = try await restarted.isProjectionDeferred(mapID: fixture.mapID)
        XCTAssertTrue(deferred)
        let controller = SpatialRelationQueryController(
            objectRepository: SpatialObjectQueryRepository(worldMapRepository: source,
                coordinateAlignmentRepository: CoordinateAlignmentRepository(directoryURL: root)),
            sceneGraphRepository: restarted, currentIdentityProvider: { fixture.identity }
        )
        controller.submit("cup near table", now: 12)
        try await waitForQuery(controller)
        XCTAssertEqual(controller.latestPresentation?.result.isAffirmative, true)
        controller.submit("cup blocking table", now: 12)
        try await waitForQuery(controller)
        guard case .unavailable(let message) = controller.state else { return XCTFail("Incomplete opaque evidence must not produce a negative answer") }
        XCTAssertTrue(message.contains("저장 공간"))
        XCTAssertNil(controller.latestPresentation)
        do {
            try await limited.deleteMap(mapID: fixture.mapID)
            XCTFail("The remaining opaque catalog is still over this configured budget")
        } catch let error as SceneGraphRepositoryError {
            guard case .catalogTooLarge = error else { throw error }
        }
        let stillDeferred = try await restarted.isProjectionDeferred(mapID: fixture.mapID)
        XCTAssertTrue(stillDeferred, "A failed catalog deletion must not erase the incomplete-coverage receipt")
        XCTAssertEqual(try Data(contentsOf: catalogURL), originalBytes)
        try await fullRepository.deleteMap(mapID: opaqueMapID)
        _ = try await graph.ingest(changed: objects[0], allObjects: objects, at: 12)
        let cleared = try await restarted.isProjectionDeferred(mapID: fixture.mapID)
        XCTAssertFalse(cleared)
    }

    func testDeferralAcknowledgementRequiresARevisionAfterFailedProjection() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SceneGraphRepository(directoryURL: root)
        let mapID = MapID()
        let frameID = CoordinateFrameID()
        let first = SceneGraphMapUpdate(mapID: mapID, coordinateFrameID: frameID, baseRevision: 0,
            graph: SceneGraph(), expiredRelationHistory: [], timestamp: 10)
        _ = try await repository.apply(first)
        try await repository.recordCapacityDeferral(mapID: mapID, baseRevision: 1)
        _ = try await repository.apply(first)
        let deferredAfterOldRetry = try await repository.isProjectionDeferred(mapID: mapID)
        XCTAssertTrue(deferredAfterOldRetry)
        let next = SceneGraphMapUpdate(mapID: mapID, coordinateFrameID: frameID, baseRevision: 1,
            graph: SceneGraph(), expiredRelationHistory: [], timestamp: 11)
        _ = try await repository.apply(next)
        let acknowledged = try await repository.isProjectionDeferred(mapID: mapID)
        XCTAssertFalse(acknowledged)
        // Simulate the receipt update being interrupted after revision two was
        // durable. An idempotent retry can now safely complete acknowledgement.
        try await repository.recordCapacityDeferral(mapID: mapID, baseRevision: 1)
        _ = try await repository.apply(next)
        let acknowledgedAfterRetry = try await repository.isProjectionDeferred(mapID: mapID)
        XCTAssertFalse(acknowledgedAfterRetry)
    }

    func testLowSpaceAllowsDeferralCleanupAndDeletionButDoesNotAdmitNewDeferrals() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SceneGraphRepository(directoryURL: root)
        let mapID = MapID()
        _ = try await repository.apply(SceneGraphMapUpdate(mapID: mapID,
            coordinateFrameID: CoordinateFrameID(), baseRevision: 0,
            graph: SceneGraph(), expiredRelationHistory: [], timestamp: 10))
        try await repository.recordCapacityDeferral(mapID: mapID, baseRevision: 0)
        let lowSpace = SceneGraphRepository(directoryURL: root,
            fileManager: GraphCapacityFileManager(freeBytes: 32_768))
        try await lowSpace.acknowledgeCurrentProjection(mapID: mapID)
        let acknowledged = try await lowSpace.isProjectionDeferred(mapID: mapID)
        XCTAssertFalse(acknowledged)
        do {
            try await lowSpace.recordCapacityDeferral(mapID: mapID, baseRevision: 1)
            XCTFail("New deferrals still require normal write admission")
        } catch let error as SpatialStorageError {
            guard case .insufficientFreeSpace = error else { throw error }
        }
        try await repository.recordCapacityDeferral(mapID: mapID, baseRevision: 1)
        let noSpace = SceneGraphRepository(directoryURL: root,
            fileManager: GraphCapacityFileManager(freeBytes: 0))
        do {
            try await noSpace.deleteMap(mapID: mapID)
            XCTFail("Deletion still needs room for atomic publication")
        } catch let error as SpatialStorageError {
            guard case .insufficientFreeSpace = error else { throw error }
        }
        let retainedAfterFailure = try await repository.isProjectionDeferred(mapID: mapID)
        XCTAssertTrue(retainedAfterFailure)
        try await lowSpace.deleteMap(mapID: mapID)
        let deleted = try await repository.load(mapID: mapID)
        let receiptDeleted = try await repository.isProjectionDeferred(mapID: mapID)
        XCTAssertNil(deleted)
        XCTAssertFalse(receiptDeleted)
    }

    func testDeferralReceiptCapacityAndRejectedFormatsPreserveOriginalBytes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SceneGraphRepository(directoryURL: root)
        let ids = (0..<64).map { temporalTestMapID(200 + $0) }
        for (index, mapID) in ids.enumerated() {
            try await repository.recordCapacityDeferral(mapID: mapID, baseRevision: UInt64(index))
        }
        let receiptURL = root.appendingPathComponent("scene-graph-projection-deferrals-v1.json")
        let original = try Data(contentsOf: receiptURL)
        let lastAccepted = try await repository.isProjectionDeferred(mapID: ids[63])
        XCTAssertTrue(lastAccepted)
        do {
            try await repository.recordCapacityDeferral(mapID: temporalTestMapID(264), baseRevision: 0)
            XCTFail("A sixty-fifth receipt must not be admitted")
        } catch {
            XCTAssertEqual(error as? SceneGraphRepositoryError, .mapCapacityReached(maximum: 64))
        }
        XCTAssertEqual(try Data(contentsOf: receiptURL), original)

        let future = Data("{\"schemaVersion\":2,\"entries\":[]}".utf8)
        try future.write(to: receiptURL)
        do {
            _ = try await repository.isProjectionDeferred(mapID: ids[0])
            XCTFail("Unknown coverage must not be read as complete")
        } catch {
            XCTAssertEqual(error as? SpatialStorageError, .unsupportedSchema(actual: 2))
        }
        XCTAssertEqual(try Data(contentsOf: receiptURL), future)

        let oversized = Data(repeating: 0, count: 16_385)
        try oversized.write(to: receiptURL)
        do {
            _ = try await repository.isProjectionDeferred(mapID: ids[0])
            XCTFail("Oversized receipt must be rejected before decoding")
        } catch {
            XCTAssertEqual(error as? SceneGraphRepositoryError, .invalidProjectionMode)
        }
        XCTAssertEqual(try Data(contentsOf: receiptURL), oversized)
    }

    func testScopedGeometryUsesAllEligibleObjectsAndSharesAmbiguityRules() throws {
        let fixture = GraphCapacityFixture()
        let table = try fixture.object(label: "table")
        let cup = try fixture.object(label: "cup")
        let future = try fixture.object(label: "future", time: 20)
        let low = try fixture.object(label: "low", confidence: 0.1)
        let removalSource = try fixture.object(label: "removed")
        var removedObject = removalSource.object
        removedObject.presence = .removed
        let removed = try SpatialObjectMetadata(mapID: removalSource.mapID,
            object: removedObject, position: removalSource.position)
        let objects = [table, cup, future, low, removed]
        let records = objects.map { StoredSpatialObjectRecord(metadata: $0, memoryTier: .localMap,
            semanticAliases: $0.object.semanticLabel == "table" ? ["테이블"] : []) }
        let engine = DeterministicSpatialRelationQueryEngine()
        let scope = try XCTUnwrap(engine.geometryScope(for: "테이블 근처 뭐가 있어?", records: records))
        XCTAssertEqual(scope.objectIDs, [table.object.id])
        let graph = try SpatialSceneGraphService.geometryGraphForQuery(scope: scope, objects: objects, at: 11)
        let actual = graph.relations()
        XCTAssertEqual(actual.count, 2)
        XCTAssertTrue(actual.allSatisfy { $0.validFrom == 10 })
        XCTAssertTrue(actual.allSatisfy {
            Set([$0.key.subject, $0.key.object]) == Set([.object(table.object.id), .object(cup.object.id)])
        })
        let duplicate = StoredSpatialObjectRecord(metadata: try fixture.object(label: "table"), memoryTier: .localMap)
        XCTAssertNil(engine.geometryScope(for: "table near cup", records: records + [duplicate]))
        XCTAssertNil(engine.geometryScope(for: "table near cup and future", records: records))
        XCTAssertNil(engine.geometryScope(for: "table blocking cup", records: records))
        XCTAssertNil(engine.geometryScope(for: "unknown near", records: records))
    }

    @MainActor
    private func waitForQuery(_ controller: SpatialRelationQueryController) async throws {
        for _ in 0..<400 where controller.isProcessingForTesting {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(controller.isProcessingForTesting)
        if controller.isProcessingForTesting { await controller.invalidateAndWaitForPendingWork() }
    }

    private func makeTemporal(source: WorldMapCheckpointRepository,
        journal: TemporalSpatialMemoryJournalRepository, graph: SpatialSceneGraphService) -> TemporalSpatialMemoryService {
        TemporalSpatialMemoryService(journalRepository: journal,
            metadataProvider: { try await source.metadataSnapshot() },
            metadataWriter: { metadata in
                try await source.upsertObjectMetadata(metadata)
                let objects = try await source.metadataSnapshot().objects
                _ = try await graph.ingest(changed: metadata, allObjects: objects, at: 12)
            },
            metadataBatchWriter: { metadata in
                let document = try await source.upsertObjectMetadataBatch(metadata)
                guard let first = metadata.first else { return }
                try await graph.rebuild(mapID: first.mapID,
                    coordinateFrameID: first.position.coordinateFrameID,
                    allObjects: document.objects, at: 12)
            })
    }

    private func makeSourceRepository(_ directory: URL) -> WorldMapCheckpointRepository {
        WorldMapCheckpointRepository(directoryURL: directory,
            blobStore: ARWorldMapBlobStore(directoryURL: directory.appendingPathComponent("WorldMaps"),
                maximumArchiveBytes: ARWorldMapArchiveCodec.maximumArchiveBytes, archiveValidator: { _ in }))
    }

    private func relation(_ predicate: SpatialRelationPredicate) throws -> SpatialRelation {
        try SpatialRelation(key: RelationKey(subject: .object(ObjectID()), predicate: predicate,
            object: .object(ObjectID())), confidence: .one, certainty: .confirmed, validFrom: 10)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SceneGraphCapacityTests.\(UUID().uuidString)")
    }
}

private struct GraphCapacityFixture: Sendable {
    let mapID = MapID()
    let frameID = CoordinateFrameID()
    let segmentID = CaptureSegmentID()
    var identity: ARCaptureIdentity {
        ARCaptureIdentity(coordinateFrameID: frameID, segmentID: segmentID, mapID: mapID, status: .confirmed)
    }

    func object(label: String, time: TimeInterval = 10, confidence: Double = 0.95) throws -> SpatialObjectMetadata {
        let position = try Vec3(x: 0, y: 0.5, z: 0)
        let score = ConfidenceScore(clamping: confidence)
        let object = try SpatialObject(id: ObjectID(), semanticLabel: label, position: position,
            bounds: AABB(min: Vec3(x: -0.1, y: 0, z: -0.1), max: Vec3(x: 0.1, y: 1, z: 0.1)),
            certainty: .confirmed,
            confidence: ConfidenceVector(semantic: score, geometry: score, tracking: score,
                place: score, identity: score, objectState: score, relation: score),
            firstSeenAt: time, lastSeenAt: time)
        return try SpatialObjectMetadata(mapID: mapID, object: object,
            position: FramedPosition(coordinateFrameID: frameID, value: position, observedAt: time,
                trackingQuality: .normal, uncertainty: .highConfidenceDepth))
    }
}

private final class GraphCapacityFileManager: FileManager, @unchecked Sendable {
    private let freeBytes: Int64
    init(freeBytes: Int64) {
        self.freeBytes = freeBytes
        super.init()
    }

    override func attributesOfFileSystem(forPath path: String) throws -> [FileAttributeKey: Any] {
        [.systemFreeSize: NSNumber(value: freeBytes)]
    }
}
