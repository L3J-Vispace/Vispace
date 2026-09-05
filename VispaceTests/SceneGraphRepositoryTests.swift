import Foundation
import VispaceCore
import XCTest

@testable import Vispace

final class SceneGraphRepositoryTests: XCTestCase {
    @MainActor
    func testClockRollbackRebuildsRelationsAtRealTimeAndFencesOlderEndpointRevisions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SceneGraphRepository(directoryURL: directory)
        let service = SpatialSceneGraphService(repository: repository)
        let context = MetadataContext()
        func observed(_ original: SpatialObjectMetadata, at time: TimeInterval, revision: UInt64) throws -> SpatialObjectMetadata {
            var object = original.object
            object.lastSeenAt = time
            object.stateUpdatedAt = time
            object.temporalRevision = revision
            return try SpatialObjectMetadata(mapID: original.mapID, object: object, position: FramedPosition(
                coordinateFrameID: original.position.coordinateFrameID, value: original.position.value,
                observedAt: time, trackingQuality: .normal, uncertainty: .highConfidenceDepth
            ))
        }
        let oldTable = try observed(context.box(label: "table", x: 0, time: 1_000), at: 1_000, revision: 1)
        let oldCup = try observed(context.box(label: "cup", x: 0.8, time: 1_000), at: 1_000, revision: 1)
        _ = try await service.ingest(changed: oldCup, allObjects: [oldTable, oldCup], at: 1_000)
        let oldRecord = try await repository.load(mapID: context.mapID)
        let oldGraph = try XCTUnwrap(oldRecord?.graph)
        // Cold projection after clock correction succeeds while removing the
        // old future-dated relations; it does not need a fabricated timestamp.
        _ = try await service.ingest(changed: oldCup, allObjects: [oldTable, oldCup], at: 99)
        let coldProjection = try await repository.load(mapID: context.mapID)
        XCTAssertTrue(coldProjection?.graph.relations().isEmpty == true)
        let table = try observed(oldTable, at: 100, revision: 2)
        let cup = try observed(oldCup, at: 101, revision: 3)
        let records = [
            StoredSpatialObjectRecord(metadata: table, memoryTier: .localMap, semanticAliases: ["테이블"]),
            StoredSpatialObjectRecord(metadata: cup, memoryTier: .localMap, semanticAliases: ["컵"]),
        ]
        let identity = ARCaptureIdentity(coordinateFrameID: context.frameID, mapID: context.mapID, status: .confirmed)
        let staleController = SpatialRelationQueryController(
            snapshotProvider: { _ in SpatialRelationQuerySnapshot(
                mapID: context.mapID, coordinateFrameID: context.frameID, records: records, graph: oldGraph
            ) }, currentIdentityProvider: { identity }
        )
        staleController.submit("테이블 근처 뭐가 있어?", now: 1_001)
        for _ in 0..<200 where staleController.isProcessingForTesting {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotEqual(staleController.latestPresentation?.result.status, .answered)

        _ = try await service.ingest(changed: table, allObjects: [table, oldCup], at: 100)
        let whileOtherIsFuture = try await repository.load(mapID: context.mapID)
        XCTAssertTrue(whileOtherIsFuture?.graph.relations().isEmpty == true)
        _ = try await service.ingest(changed: cup, allObjects: [table, cup], at: 101)
        let rebuiltRecord = try await SceneGraphRepository(directoryURL: directory).load(mapID: context.mapID)
        let rebuilt = try XCTUnwrap(rebuiltRecord)
        // A stale writer argument cannot replace the authoritative durable
        // geometry/revision used to derive relations.
        _ = try await service.ingest(changed: oldCup, allObjects: [table, cup], at: 102)
        let afterStaleArgument = try await repository.load(mapID: context.mapID)
        XCTAssertEqual(afterStaleArgument?.graph, rebuilt.graph)
        XCTAssertTrue(rebuilt.graph.relations().allSatisfy { $0.validFrom == 101 })
        let controller = SpatialRelationQueryController(
            snapshotProvider: { _ in SpatialRelationQuerySnapshot(
                mapID: context.mapID, coordinateFrameID: context.frameID, records: records, graph: rebuilt.graph
            ) }, currentIdentityProvider: { identity }
        )
        controller.submit("테이블 근처 뭐가 있어?", now: 102)
        for _ in 0..<200 where controller.isProcessingForTesting {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.latestPresentation?.result.status, .answered)
        XCTAssertEqual(controller.latestPresentation?.result.matches.map(\.subject.objectID), [cup.object.id])
    }

    func testSustainedUpdatesRollDeduplicationWindowAndRejectEvictedReplay() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SceneGraphRepository(directoryURL: directory)
        let mapID = MapID()
        let frameID = CoordinateFrameID()
        var updates: [SceneGraphMapUpdate] = []
        for index in 0..<520 {
            let update = SceneGraphMapUpdate(
                mapID: mapID, coordinateFrameID: frameID, baseRevision: UInt64(index),
                graph: SceneGraph(), expiredRelationHistory: [], timestamp: Double(index + 1)
            )
            updates.append(update)
            _ = try await repository.apply(update)
        }
        let loaded = try await SceneGraphRepository(directoryURL: directory).load(mapID: mapID)
        let record = try XCTUnwrap(loaded)
        XCTAssertEqual(record.revision, 520)
        XCTAssertEqual(record.appliedUpdateIDs.count, 512)
        XCTAssertEqual(record.appliedUpdateOrder, updates.suffix(512).map(\.id))
        guard case .alreadyApplied = try await repository.apply(updates[519]) else {
            return XCTFail("Recent replay should be idempotent")
        }
        await assertThrowsErrorAsync(try await repository.apply(updates[0])) {
            XCTAssertEqual($0 as? SceneGraphRepositoryError, .revisionConflict(expected: 520, actual: 0))
        }
        let after = try await repository.load(mapID: mapID)
        XCTAssertEqual(after?.revision, 520)
    }

    func testLegacyCatalogMigratesDeduplicationOrderAndRejectsInconsistentOrder() throws {
        let ids: Set<UUID> = [UUID(), UUID()]
        let record = try SceneGraphMapRecord(
            mapID: MapID(), coordinateFrameID: CoordinateFrameID(), revision: 2,
            graph: SceneGraph(), appliedUpdateIDs: ids, createdAt: 1, updatedAt: 2
        )
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json.removeValue(forKey: "appliedUpdateOrder")
        let migrated = try JSONDecoder().decode(
            SceneGraphMapRecord.self, from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertEqual(migrated.appliedUpdateIDs, ids)
        XCTAssertEqual(migrated.appliedUpdateOrder, ids.sorted { $0.uuidString < $1.uuidString })
        json["appliedUpdateOrder"] = [UUID().uuidString, UUID().uuidString]
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SceneGraphMapRecord.self, from: JSONSerialization.data(withJSONObject: json)
            ))
    }

    func testRepositoryRoundTripsAndReplaysUpdateIDIdempotently() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SceneGraphRepository(directoryURL: directory)
        let mapID = MapID()
        let frameID = CoordinateFrameID()
        let relation = try makeRelation()
        var graph = SceneGraph()
        try graph.upsert(relation)
        let updateID = UUID()
        let update = SceneGraphMapUpdate(
            id: updateID,
            mapID: mapID,
            coordinateFrameID: frameID,
            baseRevision: 0,
            graph: graph,
            expiredRelationHistory: [],
            timestamp: 10
        )

        guard case .applied(let applied) = try await repository.apply(update) else {
            return XCTFail("Expected first update to apply")
        }
        try assertSpatialDirectoryPolicy(at: directory)
        guard case .alreadyApplied(let replayed) = try await repository.apply(update) else {
            return XCTFail("Expected replay to be idempotent")
        }

        XCTAssertEqual(applied.revision, 1)
        XCTAssertEqual(replayed.revision, 1)
        XCTAssertEqual(replayed.appliedUpdateIDs, [updateID])
        let loadedRelationKeys = try await repository.load(mapID: mapID)?
            .graph.relations().map(\.key)
        XCTAssertEqual(loadedRelationKeys, [relation.key])
    }

    func testRepositoryRejectsRevisionFrameAndCapacityConflicts() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SceneGraphRepository(
            directoryURL: directory,
            maximumMapCount: 1
        )
        let mapID = MapID()
        let frameID = CoordinateFrameID()
        _ = try await repository.apply(
            SceneGraphMapUpdate(
                mapID: mapID,
                coordinateFrameID: frameID,
                baseRevision: 0,
                graph: SceneGraph(),
                expiredRelationHistory: [],
                timestamp: 1
            )
        )

        await assertThrowsErrorAsync(
            try await repository.apply(
                SceneGraphMapUpdate(
                    mapID: mapID,
                    coordinateFrameID: frameID,
                    baseRevision: 0,
                    graph: SceneGraph(),
                    expiredRelationHistory: [],
                    timestamp: 2
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneGraphRepositoryError,
                .revisionConflict(expected: 1, actual: 0)
            )
        }
        await assertThrowsErrorAsync(
            try await repository.apply(
                SceneGraphMapUpdate(
                    mapID: mapID,
                    coordinateFrameID: CoordinateFrameID(),
                    baseRevision: 1,
                    graph: SceneGraph(),
                    expiredRelationHistory: [],
                    timestamp: 2
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneGraphRepositoryError,
                .mapCoordinateFrameConflict(mapID)
            )
        }
        await assertThrowsErrorAsync(
            try await repository.apply(
                SceneGraphMapUpdate(
                    mapID: MapID(),
                    coordinateFrameID: CoordinateFrameID(),
                    baseRevision: 0,
                    graph: SceneGraph(),
                    expiredRelationHistory: [],
                    timestamp: 2
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SceneGraphRepositoryError,
                .mapCapacityReached(maximum: 1)
            )
        }
    }

    func testMaximumRevisionRejectsUpdateWithoutOverflowOrChangingCatalog() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mapID = MapID()
        let frameID = CoordinateFrameID()
        let record = try SceneGraphMapRecord(
            mapID: mapID,
            coordinateFrameID: frameID,
            revision: .max,
            graph: SceneGraph(),
            createdAt: 1,
            updatedAt: 1
        )
        let catalogURL = directory.appendingPathComponent(SceneGraphRepository.catalogFileName)
        let original = try JSONEncoder().encode(SceneGraphCatalogSnapshot(records: [record]))
        try original.write(to: catalogURL)
        let repository = SceneGraphRepository(directoryURL: directory)

        await assertThrowsErrorAsync(
            try await repository.apply(
                SceneGraphMapUpdate(
                    mapID: mapID,
                    coordinateFrameID: frameID,
                    baseRevision: .max,
                    graph: SceneGraph(),
                    expiredRelationHistory: [],
                    timestamp: 2
                )
            )
        ) { error in
            XCTAssertEqual(error as? SceneGraphRepositoryError, .invalidRevision)
        }
        XCTAssertEqual(try Data(contentsOf: catalogURL), original)
    }

    func testCorruptCatalogIsQuarantinedAndReturnsEmptySnapshot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent(SceneGraphRepository.catalogFileName)
        )
        let repository = SceneGraphRepository(directoryURL: directory)

        let snapshot = try await repository.catalogSnapshot()

        XCTAssertTrue(snapshot.records.isEmpty)
        let quarantine = directory.appendingPathComponent("Quarantine")
        let files = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(files.contains { $0.pathExtension == "quarantined" })
        XCTAssertTrue(files.contains { $0.lastPathComponent.hasSuffix(".reason.txt") })
    }

    func testServiceDerivesDirtyRelationsAndDoesNotRewriteUnchangedGraph() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SceneGraphRepository(directoryURL: directory)
        let service = SpatialSceneGraphService(repository: repository)
        let context = MetadataContext()
        let table = try context.metadata(
            id: ObjectID(),
            label: "table",
            position: Vec3(x: 0, y: 0.5, z: 0),
            bounds: AABB(
                min: Vec3(x: -1, y: 0, z: -0.6),
                max: Vec3(x: 1, y: 1, z: 0.6)
            ),
            time: 10
        )
        let book = try context.metadata(
            id: ObjectID(),
            label: "book",
            position: Vec3(x: 0, y: 1.1, z: 0),
            bounds: AABB(
                min: Vec3(x: -0.2, y: 1, z: -0.15),
                max: Vec3(x: 0.2, y: 1.2, z: 0.15)
            ),
            time: 10
        )

        guard
            case .updated(let first) = try await service.ingest(
                changed: book,
                allObjects: [table, book],
                at: 10
            )
        else {
            return XCTFail("Expected initial graph")
        }
        guard
            case .unchanged(let second) = try await service.ingest(
                changed: book,
                allObjects: [table, book],
                at: 11
            )
        else {
            return XCTFail("Expected unchanged graph")
        }

        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(second.revision, 1)
        let predicates = Set(first.graph.relations().map(\.key.predicate))
        XCTAssertTrue(predicates.contains(.on))
        XCTAssertTrue(predicates.contains(.under))
        XCTAssertTrue(predicates.contains(.near))
    }

    func testMovedObjectExpiresPriorRelationsAndKeepsInspectableHistory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SceneGraphRepository(directoryURL: directory)
        let service = SpatialSceneGraphService(repository: repository)
        let context = MetadataContext()
        let table = try context.box(label: "table", x: 0, time: 10)
        let original = try context.box(label: "cup", x: 0.1, time: 10)
        _ = try await service.ingest(
            changed: original,
            allObjects: [table, original],
            at: 10
        )
        let moved = try context.box(
            id: original.object.id,
            label: "cup",
            x: 5,
            time: 30
        )

        guard
            case .updated(let updated) = try await service.ingest(
                changed: moved,
                allObjects: [table, moved],
                at: 30
            )
        else {
            return XCTFail("Expected relation change")
        }

        XCTAssertFalse(updated.expiredRelationHistory.isEmpty)
        XCTAssertTrue(updated.expiredRelationHistory.allSatisfy { $0.validUntil != nil })
        XCTAssertFalse(
            updated.graph.relations().contains { $0.key.predicate == .near }
        )
    }

    func testNewObjectStateRefreshesUnchangedRelationsFreshness() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SceneGraphRepository(directoryURL: directory)
        let service = SpatialSceneGraphService(repository: repository)
        let context = MetadataContext()
        let table = try context.box(label: "table", x: 0, time: 10)
        let cup = try context.box(label: "cup", x: 0.1, time: 10)

        guard
            case .updated(let first) = try await service.ingest(
                changed: cup,
                allObjects: [table, cup],
                at: 10
            )
        else {
            return XCTFail("Expected initial graph")
        }
        let refreshedCup = try context.box(
            id: cup.object.id,
            label: "cup",
            x: 0.1,
            time: 30
        )

        guard
            case .updated(let refreshed) = try await service.ingest(
                changed: refreshedCup,
                allObjects: [table, refreshedCup],
                at: 30
            )
        else {
            return XCTFail("A newer object state must refresh touching relations")
        }

        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(refreshed.revision, 2)
        XCTAssertFalse(refreshed.graph.relations().isEmpty)
        XCTAssertTrue(
            refreshed.graph.relations().allSatisfy {
                $0.validFrom >= refreshedCup.object.stateUpdatedAt
            }
        )
        XCTAssertFalse(refreshed.expiredRelationHistory.isEmpty)
    }

    func testMediumEvidenceStaysProvisionalAndCrossFrameFailsClosed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SceneGraphRepository(directoryURL: directory)
        let service = SpatialSceneGraphService(repository: repository)
        let context = MetadataContext()
        let table = try context.box(label: "table", x: 0, time: 10, confidence: 0.65)
        let cup = try context.box(label: "cup", x: 0.1, time: 10, confidence: 0.65)

        guard
            case .updated(let record) = try await service.ingest(
                changed: cup,
                allObjects: [table, cup],
                at: 10
            )
        else {
            return XCTFail("Expected provisional graph")
        }
        XCTAssertTrue(record.graph.confirmedRelations.isEmpty)
        XCTAssertFalse(record.graph.provisionalRelations.isEmpty)

        let wrongFrame = try MetadataContext(
            mapID: context.mapID,
            frameID: CoordinateFrameID()
        ).box(id: cup.object.id, label: "cup", x: 0.1, time: 11)
        await assertThrowsErrorAsync(
            try await service.ingest(
                changed: cup,
                allObjects: [table, wrongFrame, cup],
                at: 11
            )
        ) { error in
            XCTAssertEqual(
                error as? SpatialSceneGraphServiceError,
                .mapCoordinateFrameMismatch
            )
        }
    }

    private func makeRelation() throws -> SpatialRelation {
        try SpatialRelation(
            key: RelationKey(
                subject: .object(ObjectID()),
                predicate: .near,
                object: .object(ObjectID())
            ),
            confidence: ConfidenceScore(clamping: 0.95),
            certainty: .confirmed,
            validFrom: 1
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "SceneGraphRepositoryTests.\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private struct MetadataContext {
    let mapID: MapID
    let frameID: CoordinateFrameID

    init(mapID: MapID = MapID(), frameID: CoordinateFrameID = CoordinateFrameID()) {
        self.mapID = mapID
        self.frameID = frameID
    }

    func box(
        id: ObjectID = ObjectID(),
        label: String,
        x: Double,
        time: TimeInterval,
        confidence: Double = 0.95
    ) throws -> SpatialObjectMetadata {
        try metadata(
            id: id,
            label: label,
            position: Vec3(x: x, y: 0.5, z: 0),
            bounds: AABB(
                min: Vec3(x: x - 0.25, y: 0, z: -0.25),
                max: Vec3(x: x + 0.25, y: 1, z: 0.25)
            ),
            time: time,
            confidence: confidence
        )
    }

    func metadata(
        id: ObjectID,
        label: String,
        position: Vec3,
        bounds: AABB,
        time: TimeInterval,
        confidence: Double = 0.95
    ) throws -> SpatialObjectMetadata {
        let score = ConfidenceScore(clamping: confidence)
        let object = try SpatialObject(
            id: id,
            semanticLabel: label,
            position: position,
            bounds: bounds,
            certainty: .confirmed,
            confidence: ConfidenceVector(
                semantic: score,
                geometry: score,
                tracking: score,
                place: score,
                identity: score,
                objectState: score,
                relation: score
            ),
            firstSeenAt: time,
            lastSeenAt: time,
            stateUpdatedAt: time
        )
        return try SpatialObjectMetadata(
            mapID: mapID,
            object: object,
            position: FramedPosition(
                coordinateFrameID: frameID,
                value: position,
                observedAt: time,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            )
        )
    }
}

private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
