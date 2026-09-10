import Foundation
import VispaceCore
import XCTest

@testable import Vispace

final class WorldMapCheckpointRepositoryTests: XCTestCase {
    func testCheckpointCanReplaceAtQuotaWhileKeepingTwoVerifiedRestorePoints() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let identity = ARCaptureIdentity(status: .confirmed)
        let first = try await repository.saveCheckpoint(archive: Data(repeating: 1, count: 512 * 1_024), captureIdentity: identity, savedAt: Date(timeIntervalSince1970: 1))
        let continued = ARCaptureIdentity(coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID, mapID: first.mapID, status: .confirmed)
        var previous: [SpatialMapMetadata] = [first]
        for number in 2...4 {
            previous.append(try await repository.saveCheckpoint(archive: Data(repeating: UInt8(number), count: 512 * 1_024),
                captureIdentity: continued, savedAt: Date(timeIntervalSince1970: Double(number))))
        }
        let usage = try await repository.storageUsageByMap()
        XCTAssertGreaterThan(usage[first.mapID]?.checkpointBytes ?? 0, 2 * 1_024 * 1_024)
        XCTAssertGreaterThan(usage[first.mapID]?.olderCheckpointBytes ?? 0, 1_024 * 1_024)
        let current = try SpatialStorageDirectory.totalBytes(at: root)
        let filler = root.appendingPathComponent("unrelated-retained-file")
        try Data().write(to: filler)
        let handle = try FileHandle(forWritingTo: filler)
        try handle.truncate(atOffset: UInt64(SpatialStorageDirectory.maximumTotalBytes - current - 100))
        try handle.close()
        let latest = try await repository.saveCheckpoint(archive: Data(repeating: 5, count: 512 * 1_024),
            captureIdentity: continued, savedAt: Date(timeIntervalSince1970: 5))
        let after = try await repository.metadataSnapshot()
        XCTAssertEqual(Set(after.maps.map(\.worldMapBlobID)), Set([previous[2].worldMapBlobID, previous[3].worldMapBlobID, latest.worldMapBlobID]))
        XCTAssertLessThanOrEqual(try SpatialStorageDirectory.totalBytes(at: root), SpatialStorageDirectory.maximumTotalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: filler.path), "Unrelated files must never be reclaimed")
        let damaged = root.appendingPathComponent("WorldMaps/\(latest.worldMapBlobID.uuidString.lowercased()).vispacemap")
        try Data("corrupt".utf8).write(to: damaged)
        let restored = try await makeRepository(root: root).loadLatestValidCheckpoint(mapID: first.mapID)
        XCTAssertEqual(restored?.archive, Data(repeating: 4, count: 512 * 1_024))
    }

    func testCheckpointQuotaFailureDoesNotPruneLastTwoRestorePoints() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let identity = ARCaptureIdentity(status: .confirmed)
        let first = try await repository.saveCheckpoint(archive: Data(repeating: 1, count: 64 * 1_024), captureIdentity: identity)
        let continued = ARCaptureIdentity(coordinateFrameID: identity.coordinateFrameID, segmentID: identity.segmentID, mapID: first.mapID, status: .confirmed)
        _ = try await repository.saveCheckpoint(archive: Data(repeating: 2, count: 64 * 1_024), captureIdentity: continued)
        let current = try SpatialStorageDirectory.totalBytes(at: root)
        let filler = root.appendingPathComponent("unrelated-retained-file")
        try Data().write(to: filler)
        let handle = try FileHandle(forWritingTo: filler)
        try handle.truncate(atOffset: UInt64(SpatialStorageDirectory.maximumTotalBytes - current - 100))
        try handle.close()
        let primary = root.appendingPathComponent("spatial-metadata-v1.json")
        let before = try Data(contentsOf: primary)
        do {
            _ = try await repository.saveCheckpoint(archive: Data(repeating: 3, count: 64 * 1_024), captureIdentity: continued)
            XCTFail("Insufficient room without redundant history must fail closed")
        } catch let error as SpatialStorageError {
            XCTAssertEqual(error, .capacityExceeded(maximumBytes: SpatialStorageDirectory.maximumTotalBytes))
        }
        XCTAssertEqual(try Data(contentsOf: primary), before)
        let remaining = try await repository.metadataSnapshot()
        XCTAssertEqual(remaining.maps.count, 2)
    }

    func testManualRegistrationRetryAndExplicitMovePreserveOneIdentity() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let identity = ARCaptureIdentity(status: .confirmed)
        let map = try await repository.saveCheckpoint(archive: Data("world-map".utf8), captureIdentity: identity)
        let original = try manualRegistration(mapID: map.mapID, frameID: identity.coordinateFrameID, id: ObjectID(), time: 2)
        _ = try await repository.commitUserObjectRegistration(original)
        let before = try Data(contentsOf: root.appendingPathComponent("spatial-metadata-v1.json"))
        _ = try await repository.commitUserObjectRegistration(original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("spatial-metadata-v1.json")), before)
        let moved = try manualRegistration(mapID: map.mapID, frameID: identity.coordinateFrameID, id: original.object.id, time: 3)
        let updated = try await repository.commitUserObjectRegistration(moved, replacing: original)
        XCTAssertEqual(updated.objects, [moved])
        let restarted = makeRepository(root: root)
        let retried = try await restarted.commitUserObjectRegistration(moved, replacing: original)
        XCTAssertEqual(retried.objects, [moved])
        XCTAssertEqual(moved.object.firstSeenAt, original.object.firstSeenAt)
        // Same-name distinct objects are deliberately not merged.
        let distinct = try manualRegistration(mapID: map.mapID, frameID: identity.coordinateFrameID, id: ObjectID(), time: 4)
        let both = try await restarted.commitUserObjectRegistration(distinct)
        XCTAssertEqual(Set(both.objects), Set([moved, distinct]))
    }

    func testManualMoveRejectsStaleSelectionAfterRenameOrDeletion() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let identity = ARCaptureIdentity(status: .confirmed)
        let map = try await repository.saveCheckpoint(archive: Data("world-map".utf8), captureIdentity: identity)
        let original = try manualRegistration(mapID: map.mapID, frameID: identity.coordinateFrameID, id: ObjectID(), time: 2)
        _ = try await repository.commitUserObjectRegistration(original)
        let renamed = try await repository.renameObject(expected: original, displayName: "다른 지갑")
        let moved = try manualRegistration(mapID: map.mapID, frameID: identity.coordinateFrameID, id: original.object.id, time: 3)
        do {
            _ = try await repository.commitUserObjectRegistration(moved, replacing: original)
            XCTFail("A stale selection cannot undo an intervening name change")
        } catch { XCTAssertEqual(error as? WorldMapCheckpointRepositoryError, .objectAnnotationConflict(original.object.id)) }
        let current = try await repository.metadataSnapshot()
        XCTAssertEqual(current.objects, [renamed])
        try await repository.deleteMap(mapID: map.mapID)
        do {
            _ = try await repository.commitUserObjectRegistration(moved, replacing: original)
            XCTFail("Deleted records must not be recreated by a pending move")
        } catch { XCTAssertEqual(error as? WorldMapCheckpointRepositoryError, .objectAnnotationConflict(original.object.id)) }
    }

    func testRemovedMetadataReclamationIsAtomicAndSurvivesPrimaryLoss() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let identity = ARCaptureIdentity(status: .confirmed)
        let map = try await repository.saveCheckpoint(archive: Data("world-map".utf8), captureIdentity: identity)
        let first = try removedMetadata(mapID: map.mapID, frameID: identity.coordinateFrameID, id: ObjectID())
        let second = try removedMetadata(mapID: map.mapID, frameID: identity.coordinateFrameID, id: ObjectID())
        let live = try manualRegistration(mapID: map.mapID, frameID: identity.coordinateFrameID, id: ObjectID(), time: 2)
        _ = try await repository.upsertObjectMetadataBatch([first, second, live])
        let primary = root.appendingPathComponent("spatial-metadata-v1.json")
        let before = try Data(contentsOf: primary)
        do {
            try await repository.removeObjectMetadataIfMatching([first, live])
            XCTFail("An invalid last record must prevent all deletions")
        } catch { XCTAssertEqual(error as? WorldMapCheckpointRepositoryError, .objectAnnotationConflict(live.object.id)) }
        XCTAssertEqual(try Data(contentsOf: primary), before)
        try await repository.removeObjectMetadataIfMatching([first, second])
        try await repository.removeObjectMetadataIfMatching([first, second])
        try FileManager.default.removeItem(at: primary)
        let recovered = try await makeRepository(root: root).metadataSnapshot()
        XCTAssertEqual(recovered.objects, [live], "The backup cannot resurrect reclaimed object history")
    }

    private func manualRegistration(mapID: MapID, frameID: CoordinateFrameID, id: ObjectID, time: TimeInterval) throws -> SpatialObjectMetadata {
        let object = try SpatialObject(id: id, semanticLabel: UserObjectRegistrationAccumulator.semanticLabel,
            position: Vec3(x: time, y: 0, z: -2), certainty: .confirmed, presence: .lastSeen,
            confidence: ConfidenceVector(semantic: .one, geometry: .one, tracking: .one, place: .one, identity: .one, objectState: .one),
            firstSeenAt: 1, lastSeenAt: time, displayName: "내 지갑")
        return try SpatialObjectMetadata(mapID: mapID, object: object,
            position: FramedPosition(coordinateFrameID: frameID, value: object.position, observedAt: time,
                trackingQuality: .normal, uncertainty: .highConfidenceDepth))
    }

    private func removedMetadata(mapID: MapID, frameID: CoordinateFrameID, id: ObjectID) throws -> SpatialObjectMetadata {
        let object = try SpatialObject(id: id, semanticLabel: "chair", position: .zero,
            certainty: .confirmed, presence: .removed,
            confidence: ConfidenceVector(semantic: .one, geometry: .one, tracking: .one, place: .one, identity: .one, objectState: .one),
            firstSeenAt: 1, lastSeenAt: 2, stateUpdatedAt: 10, temporalRevision: 4)
        return try SpatialObjectMetadata(mapID: mapID, object: object,
            position: FramedPosition(coordinateFrameID: frameID, value: .zero, observedAt: 2,
                trackingQuality: .normal, uncertainty: .highConfidenceDepth))
    }

    func testBatchUpsertPublishesOnceAndPreservesNamesAcrossClockRollback() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = BatchMetadataWriteState()
        let repository = makeRepository(root: root, batchWrites: writes)
        let identity = ARCaptureIdentity(status: .confirmed)
        let map = try await repository.saveCheckpoint(archive: Data("batch-map".utf8), captureIdentity: identity)
        let original = try (0..<64).map { _ in
            try batchMetadata(mapID: map.mapID, frameID: identity.coordinateFrameID,
                objectID: ObjectID(), time: 100, revision: 1)
        }
        _ = try await repository.upsertObjectMetadataBatch(original)
        _ = try await repository.renameObject(expected: original[0], displayName: "창가 의자")
        let before = try await repository.metadataSnapshot()
        let next = try original.map {
            try batchMetadata(mapID: map.mapID, frameID: identity.coordinateFrameID,
                objectID: $0.object.id, time: 10, revision: 2)
        }
        writes.reset()
        let committed = try await repository.upsertObjectMetadataBatch(next)
        XCTAssertEqual(writes.count, 2, "One previous-catalog write and one primary publication for the whole batch")
        XCTAssertEqual(committed.objects.count, 64)
        XCTAssertEqual(committed.objects.first?.object.displayName, "창가 의자")
        XCTAssertTrue(committed.objects.allSatisfy { $0.object.temporalRevision == 2 && $0.object.lastSeenAt == 10 })
        XCTAssertEqual(committed.objects.map(\.position), next.map(\.position))
        let backup = try SpatialMetadataMigrator.decodeAndMigrate(
            Data(contentsOf: root.appendingPathComponent("spatial-metadata-v1.previous.json")))
        XCTAssertEqual(backup, before, "Recovery contains the complete prior transaction, never a partial batch")
        let cold = try await makeRepository(root: root).metadataSnapshot()
        XCTAssertEqual(cold, committed)
        writes.reset()
        let replayed = try await repository.upsertObjectMetadataBatch(next)
        XCTAssertEqual(replayed, committed)
        XCTAssertEqual(writes.count, 0, "An equal replay must still return authoritative names without rewriting storage")
    }

    func testBatchRejectsInvalidLastObjectWithoutPublishingEarlierObjects() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = BatchMetadataWriteState()
        let repository = makeRepository(root: root, batchWrites: writes)
        let identity = ARCaptureIdentity(status: .confirmed)
        let map = try await repository.saveCheckpoint(archive: Data("batch-map".utf8), captureIdentity: identity)
        let existing = try batchMetadata(mapID: map.mapID, frameID: identity.coordinateFrameID,
            objectID: ObjectID(), time: 10, revision: 2)
        try await repository.upsertObjectMetadata(existing)
        let primaryURL = root.appendingPathComponent("spatial-metadata-v1.json")
        let backupURL = root.appendingPathComponent("spatial-metadata-v1.previous.json")
        let primary = try Data(contentsOf: primaryURL)
        let backup = try Data(contentsOf: backupURL)
        let valid = try batchMetadata(mapID: map.mapID, frameID: identity.coordinateFrameID,
            objectID: ObjectID(), time: 20, revision: 3)
        let invalid: [(SpatialObjectMetadata, WorldMapCheckpointRepositoryError)] = [
            (try batchMetadata(mapID: map.mapID, frameID: identity.coordinateFrameID,
                objectID: existing.object.id, time: 200, revision: 1), .staleObjectUpdate(existing.object.id)),
            (try batchMetadata(mapID: map.mapID, frameID: CoordinateFrameID(),
                objectID: ObjectID(), time: 20, revision: 3), .coordinateFrameMismatch),
            (try batchMetadata(mapID: MapID(), frameID: identity.coordinateFrameID,
                objectID: ObjectID(), time: 20, revision: 3), .unknownOrQuarantinedMap),
        ]
        for (metadata, expected) in invalid {
            writes.reset()
            await assertThrowsErrorAsync {
                try await repository.upsertObjectMetadataBatch([valid, metadata])
            } verify: { XCTAssertEqual($0 as? WorldMapCheckpointRepositoryError, expected) }
            XCTAssertEqual(writes.count, 0)
            XCTAssertEqual(try Data(contentsOf: primaryURL), primary)
            XCTAssertEqual(try Data(contentsOf: backupURL), backup)
        }
    }

    func testBatchPrimaryPublicationFailurePreservesPreviousTransactionAndAllowsRetry() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = BatchMetadataWriteState()
        let repository = makeRepository(root: root, batchWrites: writes)
        let identity = ARCaptureIdentity(status: .confirmed)
        let map = try await repository.saveCheckpoint(archive: Data("batch-map".utf8), captureIdentity: identity)
        let before = try await repository.metadataSnapshot()
        let primaryURL = root.appendingPathComponent("spatial-metadata-v1.json")
        let originalBytes = try Data(contentsOf: primaryURL)
        let incoming = try (0..<2).map { _ in
            try batchMetadata(mapID: map.mapID, frameID: identity.coordinateFrameID,
                objectID: ObjectID(), time: 10, revision: 1)
        }
        writes.reset(failAt: 2)
        await assertThrowsErrorAsync {
            try await repository.upsertObjectMetadataBatch(incoming)
        } verify: { error in
            guard let storageError = error as? SpatialStorageError,
                case .insufficientFreeSpace = storageError else {
                return XCTFail("Expected publication admission failure after the backup write: \(error)")
            }
        }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(try Data(contentsOf: primaryURL), originalBytes)
        let backup = try SpatialMetadataMigrator.decodeAndMigrate(
            Data(contentsOf: root.appendingPathComponent("spatial-metadata-v1.previous.json")))
        XCTAssertEqual(backup, before)
        writes.reset()
        let retried = try await repository.upsertObjectMetadataBatch(incoming)
        XCTAssertEqual(retried.objects, incoming)
        let restored = try await repository.loadLatestValidCheckpoint()
        XCTAssertEqual(restored?.archive, Data("batch-map".utf8))
        XCTAssertEqual(restored?.objects, incoming)
    }

    func testCancelledBatchDoesNotPublishOrAcquireAWriteBudget() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = BatchMetadataWriteState()
        let repository = makeRepository(root: root, batchWrites: writes)
        let identity = ARCaptureIdentity(status: .confirmed)
        let map = try await repository.saveCheckpoint(archive: Data("batch-map".utf8), captureIdentity: identity)
        let incoming = try batchMetadata(mapID: map.mapID, frameID: identity.coordinateFrameID,
            objectID: ObjectID(), time: 10, revision: 1)
        let before = try await repository.metadataSnapshot()
        writes.reset()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.upsertObjectMetadataBatch([incoming])
        }
        do { _ = try await task.value; XCTFail("A cancelled batch must not publish") }
        catch is CancellationError { }
        XCTAssertEqual(writes.count, 0)
        let after = try await repository.metadataSnapshot()
        XCTAssertEqual(after, before)
    }

    func testUserNameSurvivesColdJournalRecoveryAndFollowingObservation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = makeRepository(root: directory)
        let identity = ARCaptureIdentity(status: .confirmed)
        let map = try await repository.saveCheckpoint(archive: Data("named-map".utf8), captureIdentity: identity)
        let id = ObjectID()
        let journal = TemporalSpatialMemoryJournalRepository(directoryURL: directory)
        let service = TemporalSpatialMemoryService(
            checkpointRepository: repository, journalRepository: journal, policy: temporalTestPolicy()
        )
        _ = try await service.process(TemporalSpatialRecognitionBatch(
            sequence: 1, observations: [temporalTestNewObservation(
                mapID: map.mapID, coordinateFrameID: identity.coordinateFrameID, objectID: id, at: 100
            )], expectedVisibleObjectIDs: [id]
        ), pose: temporalTestPose(
            mapID: map.mapID, coordinateFrameID: identity.coordinateFrameID,
            capturedAt: 100, sessionTimestamp: 1, sequence: 1, captureSegmentID: identity.segmentID
        ))
        let beforeRename = try await repository.metadataSnapshot()
        let object = try XCTUnwrap(beforeRename.objects.first)
        _ = try await repository.renameObject(expected: object, displayName: "창가 의자")
        let restartedRepository = makeRepository(root: directory)
        let restarted = TemporalSpatialMemoryService(
            checkpointRepository: restartedRepository,
            journalRepository: TemporalSpatialMemoryJournalRepository(directoryURL: directory),
            policy: temporalTestPolicy()
        )
        _ = try await restarted.recover(mapID: map.mapID, coordinateFrameID: identity.coordinateFrameID)
        let recovered = try await restartedRepository.metadataSnapshot()
        XCTAssertEqual(recovered.objects.first?.object.displayName, "창가 의자")
        let observation = try TemporalSpatialObservation(
            metadata: temporalTestMetadata(mapID: map.mapID, coordinateFrameID: identity.coordinateFrameID, objectID: id, at: 101),
            promotionEvidence: temporalTestPromotionEvidence(mapID: map.mapID, coordinateFrameID: identity.coordinateFrameID, at: 101),
            identityDecision: .confirmedExisting(PersistentObjectReidentificationCandidate(
                objectID: id, score: temporalTestScore(0.95), geometryScore: temporalTestScore(0.95),
                spatialContextScore: temporalTestScore(0.95), visualSimilarity: nil, positionDistance: 0
            ))
        )
        _ = try await restarted.process(TemporalSpatialRecognitionBatch(
            sequence: 2, observations: [observation], expectedVisibleObjectIDs: [id]
        ), pose: temporalTestPose(
            mapID: map.mapID, coordinateFrameID: identity.coordinateFrameID,
            capturedAt: 101, sessionTimestamp: 2, sequence: 2, captureSegmentID: identity.segmentID
        ))
        let updated = try await restartedRepository.metadataSnapshot()
        XCTAssertEqual(updated.objects.first?.object.displayName, "창가 의자")
        XCTAssertEqual(updated.objects.first?.object.lastSeenAt, 101)
        XCTAssertEqual(updated.objects.first?.object.temporalRevision, 2)
    }

    func testTemporalRevisionAllowsRealClockRollbackAndRejectsOlderRevisionsAfterRestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = makeRepository(root: directory)
        let identity = ARCaptureIdentity(status: .confirmed)
        let map = try await repository.saveCheckpoint(archive: Data("clock-map".utf8), captureIdentity: identity)
        let id = ObjectID()
        func value(at time: TimeInterval, revision: UInt64?) throws -> SpatialObjectMetadata {
            let object = try SpatialObject(
                id: id, semanticLabel: "chair", position: Vec3.zero, certainty: .confirmed,
                confidence: ConfidenceVector(semantic: .one, geometry: .one, tracking: .one, identity: .one, objectState: .one),
                firstSeenAt: 999, lastSeenAt: time, temporalRevision: revision
            )
            return try SpatialObjectMetadata(mapID: map.mapID, object: object, position: FramedPosition(
                coordinateFrameID: identity.coordinateFrameID, value: .zero,
                observedAt: time, trackingQuality: .normal, uncertainty: .highConfidenceDepth
            ))
        }
        let legacy = try value(at: 1_000, revision: nil)
        try await repository.upsertObjectMetadata(legacy)
        let corrected = try value(at: 100, revision: 2)
        try await repository.upsertObjectMetadata(corrected)
        let restarted = makeRepository(root: directory)
        let snapshot = try await restarted.metadataSnapshot()
        XCTAssertEqual(snapshot.schemaVersion, 2)
        XCTAssertEqual(snapshot.objects, [corrected])
        for stale in [try value(at: 2_000, revision: 1), try value(at: 2_001, revision: nil)] {
            await assertThrowsErrorAsync { try await restarted.upsertObjectMetadata(stale) } verify: { error in
                XCTAssertEqual(error as? WorldMapCheckpointRepositoryError, .staleObjectUpdate(id))
            }
        }
        let after = try await restarted.metadataSnapshot()
        XCTAssertEqual(after.objects, [corrected])
    }

    func testFutureWorldMapEnvelopeIsNotQuarantinedOrUnpublished() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let metadata = try await repository.saveCheckpoint(archive: Data("first".utf8), captureIdentity: ARCaptureIdentity(status: .confirmed))
        let url = root.appendingPathComponent("WorldMaps/\(metadata.worldMapBlobID.uuidString.lowercased()).vispacemap")
        let original = try PropertyListDecoder().decode(ARWorldMapBlobStore.Envelope.self, from: Data(contentsOf: url))
        let future = ARWorldMapBlobStore.Envelope(
            magic: original.magic, version: original.version + 1, id: original.id,
            createdAt: original.createdAt, archive: original.archive, sha256: original.sha256
        )
        let bytes = try PropertyListEncoder().encode(future)
        try bytes.write(to: url)
        await assertThrowsErrorAsync { try await repository.loadLatestValidCheckpoint() } verify: { error in
            XCTAssertEqual(error as? WorldMapBlobStoreError, .unsupportedEnvelopeVersion(future.version))
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let catalog = try await repository.metadataSnapshot()
        XCTAssertEqual(catalog.maps.first?.availability, .active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("WorldMaps/Quarantine").path))
    }
    func testCorruptCatalogRecoversVerifiedPreviousRevision() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let identity = ARCaptureIdentity(status: .confirmed)
        let first = try await repository.saveCheckpoint(archive: Data("first".utf8), captureIdentity: identity)
        _ = try await repository.saveCheckpoint(archive: Data("second".utf8), captureIdentity: ARCaptureIdentity(
            coordinateFrameID: identity.coordinateFrameID, segmentID: identity.segmentID,
            mapID: first.mapID, status: .confirmed
        ))
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("spatial-metadata-v1.json"))
        let recovered = try await makeRepository(root: root).loadLatestValidCheckpoint()
        XCTAssertEqual(recovered?.metadata, first)
        XCTAssertEqual(recovered?.archive, Data("first".utf8))
    }

    func testDeletePlaceUpdatesRecoveryCopyAndAllowsSelectingAnotherPlace() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let first = try await repository.saveCheckpoint(archive: Data("first".utf8), captureIdentity: ARCaptureIdentity(status: .confirmed))
        let second = try await repository.saveCheckpoint(archive: Data("second".utf8), captureIdentity: ARCaptureIdentity(status: .confirmed))
        let selected = try await repository.loadLatestValidCheckpoint(mapID: first.mapID)
        XCTAssertEqual(selected?.metadata.mapID, first.mapID)
        try await repository.deleteMap(mapID: first.mapID)
        let missing = try await repository.loadLatestValidCheckpoint(mapID: first.mapID)
        XCTAssertNil(missing)
        let backup = try SpatialMetadataMigrator.decodeAndMigrate(Data(contentsOf: root.appendingPathComponent("spatial-metadata-v1.previous.json")))
        XCTAssertFalse(backup.maps.contains { $0.mapID == first.mapID })
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("spatial-metadata-v1.json"))
        let recovered = try await makeRepository(root: root).loadLatestValidCheckpoint()
        XCTAssertEqual(recovered?.metadata.mapID, second.mapID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("WorldMaps/\(first.worldMapBlobID.uuidString.lowercased()).vispacemap").path))
    }
    func testCheckpointIsRestoredWithCoordinateIdentity() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let identity = ARCaptureIdentity(status: .confirmed)
        let archive = Data("world-map".utf8)

        let saved = try await repository.saveCheckpoint(
            archive: archive,
            captureIdentity: identity,
            savedAt: Date(timeIntervalSince1970: 10)
        )
        try assertSpatialDirectoryPolicy(at: root)
        try assertSpatialDirectoryPolicy(
            at: root.appendingPathComponent("WorldMaps", isDirectory: true)
        )
        let restored = try await repository.loadLatestValidCheckpoint()

        XCTAssertEqual(restored?.archive, archive)
        XCTAssertEqual(restored?.metadata, saved)
        XCTAssertEqual(restored?.metadata.coordinateFrameID, identity.coordinateFrameID)
        XCTAssertTrue(restored?.objects.isEmpty == true)
    }

    func testSubsequentCheckpointsRetainLogicalMapIDWithoutLosingHistory() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let initialIdentity = ARCaptureIdentity(status: .confirmed)
        let first = try await repository.saveCheckpoint(
            archive: Data("first".utf8),
            captureIdentity: initialIdentity,
            savedAt: Date(timeIntervalSince1970: 10)
        )
        let continuedIdentity = ARCaptureIdentity(
            coordinateFrameID: initialIdentity.coordinateFrameID,
            segmentID: initialIdentity.segmentID,
            mapID: first.mapID,
            status: .confirmed
        )

        let second = try await repository.saveCheckpoint(
            archive: Data("second".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 20)
        )
        let snapshot = try await repository.metadataSnapshot()

        XCTAssertEqual(second.mapID, first.mapID)
        XCTAssertEqual(second.createdAt, first.createdAt)
        XCTAssertEqual(snapshot.maps.count, 2)
        XCTAssertTrue(snapshot.maps.allSatisfy { $0.mapID == first.mapID })
    }

    func testUnconfirmedCoordinateFrameCannotBePersisted() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)

        await assertThrowsErrorAsync {
            _ = try await repository.saveCheckpoint(
                archive: Data("world-map".utf8),
                captureIdentity: ARCaptureIdentity(status: .relocalizing)
            )
        } verify: { error in
            XCTAssertEqual(
                error as? WorldMapCheckpointRepositoryError,
                .unconfirmedCoordinateFrame
            )
        }
    }

    func testCorruptedNewestBlobIsQuarantinedAndOlderCheckpointRestores() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let identity = ARCaptureIdentity(status: .confirmed)
        let olderArchive = Data("older-map".utf8)
        let older = try await repository.saveCheckpoint(
            archive: olderArchive,
            captureIdentity: identity,
            savedAt: Date(timeIntervalSince1970: 10)
        )
        let continuedIdentity = ARCaptureIdentity(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: older.mapID,
            status: .confirmed
        )
        let newest = try await repository.saveCheckpoint(
            archive: Data("newer-map".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 20)
        )
        let newestURL =
            root
            .appendingPathComponent("WorldMaps", isDirectory: true)
            .appendingPathComponent(
                "\(newest.worldMapBlobID.uuidString.lowercased()).vispacemap"
            )
        try Data("corrupted".utf8).write(to: newestURL, options: .atomic)

        let restored = try await repository.loadLatestValidCheckpoint()
        let metadata = try await repository.metadataSnapshot()

        XCTAssertEqual(restored?.archive, olderArchive)
        XCTAssertEqual(
            metadata.maps.first {
                $0.worldMapBlobID == newest.worldMapBlobID
            }?.availability,
            .quarantined
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: newestURL.path))
        let quarantine =
            root
            .appendingPathComponent("WorldMaps", isDirectory: true)
            .appendingPathComponent("Quarantine", isDirectory: true)
        let quarantinedFiles = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(quarantinedFiles.count, 2)
    }

    func testFailedBlobQuarantineLeavesMetadataActiveForRetry() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let saved = try await repository.saveCheckpoint(
            archive: Data("world-map".utf8),
            captureIdentity: ARCaptureIdentity(status: .confirmed)
        )
        let worldMaps = root.appendingPathComponent("WorldMaps", isDirectory: true)
        let blobURL = worldMaps.appendingPathComponent(
            "\(saved.worldMapBlobID.uuidString.lowercased()).vispacemap"
        )
        try Data("corrupted".utf8).write(to: blobURL, options: .atomic)
        let quarantinePath = worldMaps.appendingPathComponent("Quarantine")
        try Data("blocks-directory-creation".utf8).write(to: quarantinePath)

        await assertThrowsErrorAsync {
            try await repository.loadLatestValidCheckpoint()
        } verify: { _ in
        }
        let snapshot = try await repository.metadataSnapshot()

        XCTAssertEqual(snapshot.maps.first?.availability, .active)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobURL.path))
    }

    func testConcurrentCheckpointsSerializeCatalogUpdates() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root, maximumCheckpointsPerMap: 16)
        let initialIdentity = ARCaptureIdentity(status: .confirmed)
        let first = try await repository.saveCheckpoint(
            archive: Data("map-0".utf8),
            captureIdentity: initialIdentity,
            savedAt: Date(timeIntervalSince1970: 1)
        )
        let continuedIdentity = ARCaptureIdentity(
            coordinateFrameID: initialIdentity.coordinateFrameID,
            segmentID: initialIdentity.segmentID,
            mapID: first.mapID,
            status: .confirmed
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 1...8 {
                group.addTask {
                    _ = try await repository.saveCheckpoint(
                        archive: Data("map-\(index)".utf8),
                        captureIdentity: continuedIdentity,
                        savedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
                    )
                }
            }
            try await group.waitForAll()
        }
        let snapshot = try await repository.metadataSnapshot()

        XCTAssertEqual(snapshot.maps.count, 9)
        XCTAssertTrue(snapshot.maps.allSatisfy { $0.mapID == first.mapID })
        XCTAssertEqual(Set(snapshot.maps.map(\.worldMapBlobID)).count, 9)
    }

    func testCheckpointRetentionRollsForwardWithoutUnboundedBlobGrowth() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root, maximumCheckpointsPerMap: 2)
        let identity = ARCaptureIdentity(status: .confirmed)
        let first = try await repository.saveCheckpoint(
            archive: Data("map-1".utf8),
            captureIdentity: identity,
            savedAt: Date(timeIntervalSince1970: 1)
        )
        let continuedIdentity = ARCaptureIdentity(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: first.mapID,
            status: .confirmed
        )
        _ = try await repository.saveCheckpoint(
            archive: Data("map-2".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 2)
        )
        _ = try await repository.saveCheckpoint(
            archive: Data("map-3".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 3)
        )

        let snapshot = try await repository.metadataSnapshot()
        let restored = try await repository.loadLatestValidCheckpoint()
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("WorldMaps", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(snapshot.maps.count, 2)
        XCTAssertFalse(snapshot.maps.contains { $0.worldMapBlobID == first.worldMapBlobID })
        XCTAssertEqual(restored?.archive, Data("map-3".utf8))
        XCTAssertEqual(files.filter { $0.pathExtension == "vispacemap" }.count, 2)
    }

    func testCheckpointOrderingRemainsMonotonicWhenDeviceClockMovesBackward() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root, maximumCheckpointsPerMap: 2)
        let identity = ARCaptureIdentity(status: .confirmed)
        let first = try await repository.saveCheckpoint(
            archive: Data("map-1".utf8),
            captureIdentity: identity,
            savedAt: Date(timeIntervalSince1970: 10)
        )
        let continuedIdentity = ARCaptureIdentity(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: first.mapID,
            status: .confirmed
        )
        let second = try await repository.saveCheckpoint(
            archive: Data("map-2".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 5)
        )
        let third = try await repository.saveCheckpoint(
            archive: Data("map-3".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 5)
        )

        let snapshot = try await repository.metadataSnapshot()
        let restored = try await repository.loadLatestValidCheckpoint()

        XCTAssertGreaterThan(second.updatedAt, first.updatedAt)
        XCTAssertGreaterThan(third.updatedAt, second.updatedAt)
        XCTAssertTrue(snapshot.maps.contains { $0.worldMapBlobID == third.worldMapBlobID })
        XCTAssertEqual(restored?.archive, Data("map-3".utf8))
    }

    func testCorruptedSupersededCheckpointIsQuarantinedInsteadOfDeleted() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root, maximumCheckpointsPerMap: 2)
        let identity = ARCaptureIdentity(status: .confirmed)
        let first = try await repository.saveCheckpoint(
            archive: Data("map-1".utf8),
            captureIdentity: identity,
            savedAt: Date(timeIntervalSince1970: 1)
        )
        let continuedIdentity = ARCaptureIdentity(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: first.mapID,
            status: .confirmed
        )
        _ = try await repository.saveCheckpoint(
            archive: Data("map-2".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 2)
        )
        let firstURL =
            root
            .appendingPathComponent("WorldMaps", isDirectory: true)
            .appendingPathComponent(
                "\(first.worldMapBlobID.uuidString.lowercased()).vispacemap"
            )
        try Data("corrupted".utf8).write(to: firstURL, options: .atomic)

        _ = try await repository.saveCheckpoint(
            archive: Data("map-3".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 3)
        )
        let snapshot = try await repository.metadataSnapshot()

        XCTAssertEqual(
            snapshot.maps.first { $0.worldMapBlobID == first.worldMapBlobID }?.availability,
            .quarantined
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        let quarantine =
            root
            .appendingPathComponent("WorldMaps", isDirectory: true)
            .appendingPathComponent("Quarantine", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: quarantine,
                includingPropertiesForKeys: nil
            ).count,
            2
        )
    }

    func testDeferredQuarantineFailureDoesNotBlockNewestValidCheckpoint() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root, maximumCheckpointsPerMap: 2)
        let identity = ARCaptureIdentity(status: .confirmed)
        let first = try await repository.saveCheckpoint(
            archive: Data("map-1".utf8),
            captureIdentity: identity,
            savedAt: Date(timeIntervalSince1970: 1)
        )
        let continuedIdentity = ARCaptureIdentity(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: first.mapID,
            status: .confirmed
        )
        _ = try await repository.saveCheckpoint(
            archive: Data("map-2".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 2)
        )
        let worldMaps = root.appendingPathComponent("WorldMaps", isDirectory: true)
        let firstURL = worldMaps.appendingPathComponent(
            "\(first.worldMapBlobID.uuidString.lowercased()).vispacemap"
        )
        try Data("corrupted".utf8).write(to: firstURL, options: .atomic)
        try Data("blocks-quarantine".utf8).write(
            to: worldMaps.appendingPathComponent("Quarantine")
        )

        let newest = try await repository.saveCheckpoint(
            archive: Data("map-3".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 3)
        )
        let restored = try await repository.loadLatestValidCheckpoint()

        XCTAssertEqual(restored?.metadata.worldMapBlobID, newest.worldMapBlobID)
        XCTAssertEqual(restored?.archive, Data("map-3".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
    }

    func testDetachedBlobFromInterruptedCommitIsPreservedInQuarantine() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let worldMaps = root.appendingPathComponent("WorldMaps", isDirectory: true)
        let blobStore = ARWorldMapBlobStore(
            directoryURL: worldMaps,
            maximumArchiveBytes: ARWorldMapArchiveCodec.maximumArchiveBytes,
            archiveValidator: { _ in }
        )
        let orphan = try await blobStore.saveArchive(Data("orphan".utf8))
        let repository = WorldMapCheckpointRepository(
            directoryURL: root,
            blobStore: blobStore
        )

        let restored = try await repository.loadLatestValidCheckpoint()

        XCTAssertNil(restored)
        let remainsActive = await blobStore.contains(id: orphan.id)
        XCTAssertFalse(remainsActive)
        let quarantine = worldMaps.appendingPathComponent("Quarantine", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: quarantine,
                includingPropertiesForKeys: nil
            ).count,
            2
        )
    }

    func testQuarantinedMapsDoNotConsumeActiveLogicalMapCapacity() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(
            root: root,
            maximumCheckpointsPerMap: 2,
            maximumLogicalMaps: 2
        )
        let first = try await repository.saveCheckpoint(
            archive: Data("map-1".utf8),
            captureIdentity: ARCaptureIdentity(status: .confirmed),
            savedAt: Date(timeIntervalSince1970: 1)
        )
        let second = try await repository.saveCheckpoint(
            archive: Data("map-2".utf8),
            captureIdentity: ARCaptureIdentity(status: .confirmed),
            savedAt: Date(timeIntervalSince1970: 2)
        )
        let worldMaps = root.appendingPathComponent("WorldMaps", isDirectory: true)
        for metadata in [first, second] {
            let url = worldMaps.appendingPathComponent(
                "\(metadata.worldMapBlobID.uuidString.lowercased()).vispacemap"
            )
            try Data("corrupted".utf8).write(to: url, options: .atomic)
        }
        let quarantinedRestore = try await repository.loadLatestValidCheckpoint()
        XCTAssertNil(quarantinedRestore)

        let third = try await repository.saveCheckpoint(
            archive: Data("map-3".utf8),
            captureIdentity: ARCaptureIdentity(status: .confirmed),
            savedAt: Date(timeIntervalSince1970: 3)
        )
        let snapshot = try await repository.metadataSnapshot()

        XCTAssertEqual(
            snapshot.maps.filter { $0.availability == .quarantined }.count,
            2
        )
        XCTAssertEqual(
            snapshot.maps.filter { $0.availability == .active }.map(\.mapID),
            [third.mapID]
        )
    }

    func testMalformedMetadataCatalogIsPreservedInQuarantine() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadataURL = root.appendingPathComponent("spatial-metadata-v1.json")
        let malformed = Data("not-json".utf8)
        try malformed.write(to: metadataURL)
        let repository = makeRepository(root: root)

        let snapshot = try await repository.metadataSnapshot()

        XCTAssertTrue(snapshot.maps.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
        let quarantine = root.appendingPathComponent("Quarantine", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 2)
        let preservedURL = try XCTUnwrap(
            files.first { $0.lastPathComponent.hasSuffix("json.quarantined") }
        )
        XCTAssertEqual(try Data(contentsOf: preservedURL), malformed)
    }

    func testObjectMetadataRequiresMatchingActiveCoordinateFrame() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let identity = ARCaptureIdentity(status: .confirmed)
        let map = try await repository.saveCheckpoint(
            archive: Data("world-map".utf8),
            captureIdentity: identity
        )
        let object = try SpatialObject(
            semanticLabel: "chair",
            position: Vec3(x: 1, y: 0, z: -2),
            certainty: .confirmed,
            confidence: ConfidenceVector(
                semantic: ConfidenceScore(clamping: 0.9),
                geometry: ConfidenceScore(clamping: 0.9),
                tracking: ConfidenceScore(clamping: 0.9),
                place: ConfidenceScore(clamping: 0.9),
                identity: ConfidenceScore(clamping: 0.9),
                objectState: ConfidenceScore(clamping: 0.9),
                relation: ConfidenceScore(clamping: 0.9)
            ),
            firstSeenAt: 1,
            lastSeenAt: 2
        )
        let position = try FramedPosition(
            coordinateFrameID: identity.coordinateFrameID,
            value: object.position,
            observedAt: object.lastSeenAt,
            trackingQuality: .normal,
            uncertainty: .highConfidenceDepth
        )
        let metadata = try SpatialObjectMetadata(
            mapID: map.mapID,
            object: object,
            position: position
        )

        try await repository.upsertObjectMetadata(metadata)
        let saved = try await repository.metadataSnapshot()
        let restored = try await repository.loadLatestValidCheckpoint()

        XCTAssertEqual(saved.objects, [metadata])
        XCTAssertEqual(restored?.objects, [metadata])
    }

    func testOlderObjectMetadataCannotOverwriteNewerState() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let identity = ARCaptureIdentity(status: .confirmed)
        let map = try await repository.saveCheckpoint(
            archive: Data("world-map".utf8),
            captureIdentity: identity
        )
        let objectID = ObjectID()

        func metadata(at timestamp: TimeInterval, x: Double) throws -> SpatialObjectMetadata {
            let positionValue = try Vec3(x: x, y: 0, z: -2)
            let object = try SpatialObject(
                id: objectID,
                semanticLabel: "chair",
                position: positionValue,
                certainty: .confirmed,
                confidence: ConfidenceVector(
                    semantic: ConfidenceScore(clamping: 0.9),
                    geometry: ConfidenceScore(clamping: 0.9),
                    tracking: ConfidenceScore(clamping: 0.9),
                    place: ConfidenceScore(clamping: 0.9),
                    identity: ConfidenceScore(clamping: 0.9),
                    objectState: ConfidenceScore(clamping: 0.9)
                ),
                firstSeenAt: 1,
                lastSeenAt: timestamp
            )
            let position = try FramedPosition(
                coordinateFrameID: identity.coordinateFrameID,
                value: positionValue,
                observedAt: timestamp,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            )
            return try SpatialObjectMetadata(mapID: map.mapID, object: object, position: position)
        }

        let newer = try metadata(at: 3, x: 3)
        let older = try metadata(at: 2, x: 2)
        try await repository.upsertObjectMetadata(newer)

        do {
            try await repository.upsertObjectMetadata(older)
            XCTFail("Expected stale object update to be rejected")
        } catch {
            XCTAssertEqual(
                error as? WorldMapCheckpointRepositoryError,
                .staleObjectUpdate(objectID)
            )
        }
        let snapshot = try await repository.metadataSnapshot()
        XCTAssertEqual(snapshot.objects, [newer])
    }

    func testRenamePersistsOnlyOneObjectWithoutChangingObservationOrdering() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = makeRepository(root: directory)
        let identity = ARCaptureIdentity(status: .confirmed)
        let map = try await repository.saveCheckpoint(archive: Data("world-map".utf8), captureIdentity: identity)
        func makeRecord(_ index: Int, timestamp: TimeInterval = 2) throws -> SpatialObjectMetadata {
            let object = try SpatialObject(
                id: ObjectID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 990 + index))!),
                semanticLabel: "chair", position: Vec3(x: Double(index), y: 0, z: -2),
                certainty: .confirmed, confidence: ConfidenceVector(semantic: .one, geometry: .one,
                    tracking: .one, place: .one, identity: .one, objectState: .one),
                firstSeenAt: 1, lastSeenAt: timestamp)
            return try SpatialObjectMetadata(mapID: map.mapID, object: object,
                position: FramedPosition(coordinateFrameID: identity.coordinateFrameID, value: object.position,
                    observedAt: timestamp, trackingQuality: .normal, uncertainty: .highConfidenceDepth))
        }
        let original = try (0..<3).map { try makeRecord($0) }
        for record in original { try await repository.upsertObjectMetadata(record) }
        let renamed = try await repository.renameObject(expected: original[1], displayName: "창가 의자")
        XCTAssertEqual(renamed.object.semanticLabel, "chair")
        XCTAssertEqual(renamed.position, original[1].position)
        XCTAssertEqual(renamed.object.stateUpdatedAt, original[1].object.stateUpdatedAt)
        let reloaded = makeRepository(root: directory)
        let snapshot = try await reloaded.metadataSnapshot()
        XCTAssertEqual(snapshot.objects.first { $0.object.id == original[1].object.id }?.object.displayName, "창가 의자")
        XCTAssertEqual(snapshot.objects.filter { $0.object.id != original[1].object.id }, [original[0], original[2]])
        let queryRepository = SpatialObjectQueryRepository(metadataProvider: { try await reloaded.metadataSnapshot() },
            alignmentCatalogProvider: { try CoordinateAlignmentCatalogSnapshot() })
        let records = try await queryRepository.loadSnapshot(currentMapID: map.mapID).records
        let result = DeterministicSpatialObjectSearchEngine().search(utterance: "창가 의자 찾아줘", records: records,
            context: try SpatialObjectSearchContext(currentMapID: map.mapID, now: 10))
        XCTAssertEqual(result.selectedCandidate?.record.metadata.object.id, original[1].object.id)
        // A new camera observation without the annotation cannot erase a name.
        try await reloaded.upsertObjectMetadata(makeRecord(1, timestamp: 3))
        let afterObservation = try await reloaded.metadataSnapshot()
        XCTAssertEqual(afterObservation.objects.first { $0.object.id == original[1].object.id }?.object.displayName, "창가 의자")
        XCTAssertEqual(afterObservation.objects.first { $0.object.id == original[1].object.id }?.object.lastSeenAt, 3)
    }

    private func makeRepository(
        root: URL,
        maximumCheckpointsPerMap: Int = WorldMapCheckpointRepository
            .defaultMaximumCheckpointsPerMap,
        maximumLogicalMaps: Int = WorldMapCheckpointRepository.defaultMaximumLogicalMaps,
        batchWrites: BatchMetadataWriteState? = nil
    ) -> WorldMapCheckpointRepository {
        let blobStore = ARWorldMapBlobStore(
            directoryURL: root.appendingPathComponent("WorldMaps", isDirectory: true),
            maximumArchiveBytes: ARWorldMapArchiveCodec.maximumArchiveBytes,
            archiveValidator: { _ in }
        )
        if let batchWrites {
            return WorldMapCheckpointRepository(
                directoryURL: root, blobStore: blobStore,
                maximumCheckpointsPerMap: maximumCheckpointsPerMap,
                maximumLogicalMaps: maximumLogicalMaps,
                fileManager: BatchMetadataFileManager(state: batchWrites)
            )
        }
        return WorldMapCheckpointRepository(
            directoryURL: root,
            blobStore: blobStore,
            maximumCheckpointsPerMap: maximumCheckpointsPerMap,
            maximumLogicalMaps: maximumLogicalMaps
        )
    }

    private func batchMetadata(mapID: MapID, frameID: CoordinateFrameID,
        objectID: ObjectID, time: TimeInterval, revision: UInt64) throws -> SpatialObjectMetadata {
        let object = try SpatialObject(id: objectID, semanticLabel: "chair",
            position: Vec3(x: time / 10, y: 0, z: -2), certainty: .confirmed,
            confidence: ConfidenceVector(semantic: .one, geometry: .one, tracking: .one,
                identity: .one, objectState: .one),
            firstSeenAt: 100, lastSeenAt: time, temporalRevision: revision)
        return try SpatialObjectMetadata(mapID: mapID, object: object,
            position: FramedPosition(coordinateFrameID: frameID, value: object.position,
                observedAt: time, trackingQuality: .normal, uncertainty: .highConfidenceDepth))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vispace-checkpoint-tests-\(UUID().uuidString)")
    }
}

private final class BatchMetadataWriteState: @unchecked Sendable {
    private let lock = NSLock()
    private var admissions = 0
    private var failureOrdinal: Int?
    var count: Int { lock.withLock { admissions } }

    func reset(failAt ordinal: Int? = nil) {
        lock.withLock { admissions = 0; failureOrdinal = ordinal }
    }

    func nextAvailableBytes() -> Int64 {
        lock.withLock {
            admissions += 1
            return admissions == failureOrdinal ? 0 : Int64.max
        }
    }
}

private final class BatchMetadataFileManager: FileManager, @unchecked Sendable {
    private let state: BatchMetadataWriteState
    init(state: BatchMetadataWriteState) { self.state = state; super.init() }
    override func attributesOfFileSystem(forPath path: String) throws -> [FileAttributeKey: Any] {
        var attributes = try super.attributesOfFileSystem(forPath: path)
        attributes[.systemFreeSize] = NSNumber(value: state.nextAvailableBytes())
        return attributes
    }
}

private func assertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    verify: (any Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
        verify(error)
    }
}
