import VispaceCore
import XCTest

@testable import Vispace

final class TemporalSpatialMemoryServiceTests: XCTestCase {
    func testUserCorrectionJournalsCurrentNameAndSurvivesServiceRestart() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(91), frameID = temporalTestFrameID(91)
        let objectID = temporalTestObjectID(91)
        let store = TemporalMetadataStore(
            document: SpatialMetadataDocument(
                maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)]))
        let journal = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let service = TemporalSpatialMemoryService(
            journalRepository: journal, policy: temporalTestPolicy(),
            metadataProvider: { try await store.snapshot() }, metadataWriter: { try await store.upsert($0) })
        _ = try await service.process(
            TemporalSpatialRecognitionBatch(
                sequence: 1,
                observations: [
                    temporalTestNewObservation(
                        mapID: mapID, coordinateFrameID: frameID,
                        objectID: objectID, at: 100)
                ], expectedVisibleObjectIDs: []),
            pose: temporalTestPose(
                mapID: mapID, coordinateFrameID: frameID,
                capturedAt: 100, sessionTimestamp: 1, sequence: 1))
        let values = await store.allObjects()
        let old = try XCTUnwrap(values.first)
        try await store.renameAnnotation(expected: old, displayName: "내 책상")
        _ = try await service.correctClassification(
            objectID: objectID, semanticLabel: "table",
            expectedTemporalRevision: old.object.temporalRevision,
            pose: temporalTestPose(
                mapID: mapID, coordinateFrameID: frameID,
                capturedAt: 101, sessionTimestamp: 2, sequence: 2))
        let cold = TemporalSpatialMemoryService(
            journalRepository: journal, policy: temporalTestPolicy(),
            metadataProvider: { try await store.snapshot() }, metadataWriter: { try await store.upsert($0) })
        let restored = try await cold.recover(mapID: mapID, coordinateFrameID: frameID)
        let corrected = try XCTUnwrap(restored.metadata(for: objectID))
        XCTAssertEqual(corrected.object.displayName, "내 책상")
        XCTAssertEqual(corrected.object.semanticLabel, "table")
        XCTAssertEqual(corrected.position, old.position)
        XCTAssertEqual(corrected.object.firstSeenAt, old.object.firstSeenAt)
        XCTAssertEqual(corrected.object.temporalRevision, 2)
        XCTAssertTrue(
            restored.recentDeltas.flatMap(\.changes).contains(
                .reclassified(objectID: objectID, from: old.object.semanticLabel, to: "table", at: 101)))
        do {
            _ = try await cold.correctClassification(
                objectID: objectID, semanticLabel: "cup",
                expectedTemporalRevision: old.object.temporalRevision,
                pose: temporalTestPose(
                    mapID: mapID, coordinateFrameID: frameID,
                    capturedAt: 102, sessionTimestamp: 3, sequence: 3))
            XCTFail("A correction to an outdated selected record must fail")
        } catch {
            XCTAssertEqual(error as? TemporalSpatialMemoryError, .staleClassificationCorrection(objectID))
        }
    }

    func testColdRecoveryUsesOneCompleteBatchAndKeepsDeltaWriterContract() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(70)
        let frameID = temporalTestFrameID(70)
        let objects = (0..<32).map { index in
            temporalTestMetadata(mapID: mapID, coordinateFrameID: frameID,
                objectID: temporalTestObjectID(700 + index), at: 100)
        }
        let store = TemporalMetadataStore(document: SpatialMetadataDocument(
            maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)], objects: objects))
        let journal = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let batches = TemporalBatchProjectionRecorder()
        let batchWriter: TemporalSpatialMemoryService.MetadataBatchWriter = { metadata in
            await batches.record(metadata)
            for object in metadata { try await store.upsert(object) }
        }
        let service = TemporalSpatialMemoryService(journalRepository: journal,
            policy: temporalTestPolicy(), metadataProvider: { try await store.snapshot() },
            metadataWriter: { try await store.upsert($0) }, metadataBatchWriter: batchWriter)
        let recovered = try await service.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertEqual(recovered.objects.count, 32)
        let initialBatches = await batches.objectIDs
        XCTAssertEqual(initialBatches, [objects.map(\.object.id).sorted()])
        _ = try await service.recover(mapID: mapID, coordinateFrameID: frameID)
        let cachedBatches = await batches.objectIDs
        XCTAssertEqual(cachedBatches, initialBatches)
        _ = try await service.process(TemporalSpatialRecognitionBatch(sequence: 1,
            observations: [temporalTestNewObservation(mapID: mapID, coordinateFrameID: frameID,
                objectID: temporalTestObjectID(799), at: 101)], expectedVisibleObjectIDs: []),
            pose: temporalTestPose(mapID: mapID, coordinateFrameID: frameID,
                capturedAt: 101, sessionTimestamp: 1, sequence: 1))
        let afterDelta = await batches.objectIDs
        XCTAssertEqual(afterDelta, initialBatches, "Normal observations retain their existing single-object writer")
        let cold = TemporalSpatialMemoryService(journalRepository: journal,
            policy: temporalTestPolicy(), metadataProvider: { try await store.snapshot() },
            metadataWriter: { try await store.upsert($0) }, metadataBatchWriter: batchWriter)
        let restarted = try await cold.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertEqual(restarted.objects.count, 33)
        let restartedBatches = await batches.objectIDs
        XCTAssertEqual(restartedBatches.count, 2)
        XCTAssertEqual(restartedBatches.last, restarted.objects.keys.sorted(),
            "Matching durable metadata still requires one complete downstream projection replay after restart")
    }

    func testCancelledBatchRecoveryRetainsPendingProjectionAndContinues() async throws {
        try await exerciseCancelledBatchRecovery(resetWhilePaused: false)
    }

    func testResetDuringBatchRecoveryDoesNotRepopulateDeletedState() async throws {
        try await exerciseCancelledBatchRecovery(resetWhilePaused: true)
    }

    private func exerciseCancelledBatchRecovery(resetWhilePaused: Bool) async throws {
        executionTimeAllowance = 60
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(71)
        let frameID = temporalTestFrameID(71)
        let objectID = temporalTestObjectID(71)
        let store = TemporalMetadataStore(document: SpatialMetadataDocument(
            maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)]))
        let journal = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let gate = TemporalBatchRecoveryGate()
        let batches = TemporalBatchProjectionRecorder()
        let service = TemporalSpatialMemoryService(journalRepository: journal,
            policy: temporalTestPolicy(), metadataProvider: { try await store.snapshot() },
            metadataWriter: { try await store.upsert($0) }, metadataBatchWriter: { metadata in
                for object in metadata { try await store.upsert(object) }
                await batches.record(metadata)
                // Metadata is durable; dependent projection has not returned.
                await gate.pauseOnce()
                try Task.checkCancellation()
            })
        await store.failAfterNextWrites(1)
        await assertThrowsServiceError({
            try await service.process(TemporalSpatialRecognitionBatch(sequence: 1,
                observations: [temporalTestNewObservation(mapID: mapID, coordinateFrameID: frameID,
                    objectID: objectID, at: 100)], expectedVisibleObjectIDs: [objectID]),
                pose: temporalTestPose(mapID: mapID, coordinateFrameID: frameID,
                    capturedAt: 100, sessionTimestamp: 1, sequence: 1))
        }, equals: .committedJournalProjectionPending)
        let recovery = Task {
            do {
                let snapshot = try await service.recover(mapID: mapID, coordinateFrameID: frameID)
                await gate.finished()
                return snapshot
            } catch {
                await gate.finished()
                throw error
            }
        }
        do {
            guard await gate.waitUntilPausedOrFinished() else {
                _ = try await recovery.value
                throw TemporalMetadataStoreError.batchProjectionWasNotReached
            }
            recovery.cancel()
            if resetWhilePaused {
                await service.reset()
                try await journal.deleteMap(mapID: mapID)
                await store.clearObjects()
            }
            await gate.resume()
            do { _ = try await recovery.value; XCTFail("Cancelled batch recovery must not clear pending state") }
            catch is CancellationError { }
            let recovered = try await service.recover(mapID: mapID, coordinateFrameID: frameID)
            XCTAssertEqual(recovered.revision, resetWhilePaused ? 0 : 1)
            let calls = await batches.objectIDs
            XCTAssertEqual(calls.count, resetWhilePaused ? 1 : 2)
            let durableObjects = await store.allObjects()
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: durableObjects.map { ($0.object.id, $0) }), recovered.objects)
            _ = try await service.recover(mapID: mapID, coordinateFrameID: frameID)
            let repeatedCalls = await batches.objectIDs
            XCTAssertEqual(repeatedCalls, calls, "Pending clears only after the entire batch writer returns successfully")
            let next = try await service.process(TemporalSpatialRecognitionBatch(sequence: 2,
                observations: [], expectedVisibleObjectIDs: []),
                pose: temporalTestPose(mapID: mapID, coordinateFrameID: frameID,
                    capturedAt: 101, sessionTimestamp: 2, sequence: 2))
            guard case .applied(let delta) = next else { throw TemporalMetadataStoreError.batchProjectionWasNotReached }
            XCTAssertEqual(delta.newRevision, resetWhilePaused ? 1 : 2)
            let committed = try await journal.recover(mapID: mapID, coordinateFrameID: frameID)
            let cached = try await service.recover(mapID: mapID, coordinateFrameID: frameID)
            XCTAssertEqual(committed?.snapshot, cached)
        } catch {
            recovery.cancel()
            await gate.resume()
            _ = try? await recovery.value
            throw error
        }
    }

    func testCancellationAfterDurableAppendRecoversAndContinuesOnSameService() async throws {
        try await exerciseCommittedCancellation(pauseAfterAppend: true, resetBeforeReturn: false)
    }

    func testCancellationInsideProjectionRecoversAndContinuesOnSameService() async throws {
        try await exerciseCommittedCancellation(pauseAfterAppend: false, resetBeforeReturn: false)
    }

    func testResetAfterDurableAppendPreventsCancelledWorkFromRestoringDeletedState() async throws {
        try await exerciseCommittedCancellation(pauseAfterAppend: true, resetBeforeReturn: true)
    }

    func testResetDuringProjectionPreventsCancelledWorkFromRestoringDeletedState() async throws {
        try await exerciseCommittedCancellation(pauseAfterAppend: false, resetBeforeReturn: true)
    }

    func testResetAfterAppendFencesUncancelledOldTask() async throws {
        try await exerciseCommittedCancellation(pauseAfterAppend: true, resetBeforeReturn: true, cancelTask: false)
    }

    private func exerciseCommittedCancellation(
        pauseAfterAppend: Bool,
        resetBeforeReturn: Bool,
        cancelTask: Bool = true
    ) async throws {
        executionTimeAllowance = 60
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(60)
        let frameID = temporalTestFrameID(60)
        let objectID = temporalTestObjectID(60)
        let store = TemporalMetadataStore(document: SpatialMetadataDocument(
            maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)]
        ))
        let gate = TemporalOneShotCommitGate()
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        if pauseAfterAppend {
            await repository.setAfterNextCommitForTesting { await gate.pauseOnce() }
        }
        let service = TemporalSpatialMemoryService(
            journalRepository: repository, policy: temporalTestPolicy(),
            metadataProvider: { try await store.snapshot() },
            metadataWriter: { metadata in
                if !pauseAfterAppend { await gate.pauseOnce() }
                try Task.checkCancellation()
                try await store.upsert(metadata)
            }
        )
        let batch = TemporalSpatialRecognitionBatch(
            sequence: 1,
            observations: [temporalTestNewObservation(
                mapID: mapID, coordinateFrameID: frameID, objectID: objectID, at: 100
            )], expectedVisibleObjectIDs: [objectID]
        )
        let pose = temporalTestPose(
            mapID: mapID, coordinateFrameID: frameID,
            capturedAt: 100, sessionTimestamp: 1, sequence: 1
        )
        let task = Task { try await service.process(batch, pose: pose) }
        do {
        for _ in 0..<200 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let paused = await gate.isWaiting
        guard paused else {
            task.cancel()
            await gate.resume()
            _ = try? await task.value
            return XCTFail("The real committed write did not reach its gate")
        }
        let durableBeforeCancellation = try await repository.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertEqual(durableBeforeCancellation?.snapshot.revision, 1)
        if cancelTask { task.cancel() }
        if resetBeforeReturn {
            await service.reset()
            try await repository.deleteMap(mapID: mapID)
            await store.clearObjects()
        }
        await gate.resume()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation after the durable commit")
        } catch is CancellationError {
            // The cancellation reaches the caller without losing recovery bookkeeping.
        }
        let recovered = try await service.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertEqual(recovered.revision, resetBeforeReturn ? 0 : 1)
        let durableObjects = await store.allObjects()
        if resetBeforeReturn {
            XCTAssertTrue(recovered.objects.isEmpty)
            XCTAssertTrue(durableObjects.isEmpty)
        } else {
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: durableObjects.map { ($0.object.id, $0) }), recovered.objects)
            XCTAssertNotNil(recovered.metadata(for: objectID))
        }
        let following = try await service.process(TemporalSpatialRecognitionBatch(
            sequence: 2, observations: [], expectedVisibleObjectIDs: []
        ), pose: temporalTestPose(
            mapID: mapID, coordinateFrameID: frameID,
            capturedAt: 101, sessionTimestamp: 2, sequence: 2
        ))
        guard case .applied(let delta) = following else { return XCTFail("Next observation must commit") }
        XCTAssertEqual(delta.newRevision, resetBeforeReturn ? 1 : 2)
        let finalJournal = try await repository.recover(mapID: mapID, coordinateFrameID: frameID)
        let finalCache = try await service.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertEqual(finalJournal?.snapshot, finalCache)
        } catch {
            task.cancel()
            await gate.resume()
            _ = try? await task.value
            throw error
        }
    }

    func testLiveAuthorityRejectsStaleWorkAfterAwaitAndAfterRestart() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(43)
        let frameID = temporalTestFrameID(43)
        let oldSegment = CaptureSegmentID()
        let currentSegment = CaptureSegmentID()
        let authority = TemporalPoseAuthority(segmentID: oldSegment)
        let gate = TemporalMetadataReadGate()
        let store = TemporalMetadataStore(document: SpatialMetadataDocument(
            maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)]
        ))
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let oldService = TemporalSpatialMemoryService(
            journalRepository: repository, policy: temporalTestPolicy(),
            metadataProvider: { await gate.pause(); return try await store.snapshot() },
            metadataWriter: { try await store.upsert($0) }, poseValidator: { authority.permits($0) }
        )
        let oldPose = temporalTestPose(
            mapID: mapID, coordinateFrameID: frameID, capturedAt: 1_000,
            sessionTimestamp: 100, sequence: 1, captureSegmentID: oldSegment
        )
        let stale = Task {
            try await oldService.process(TemporalSpatialRecognitionBatch(
                sequence: 1, observations: [], expectedVisibleObjectIDs: []
            ), pose: oldPose)
        }
        for _ in 0..<200 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let wasWaiting = await gate.isWaiting
        XCTAssertTrue(wasWaiting)
        authority.select(currentSegment)
        await gate.resume()
        do { _ = try await stale.value; XCTFail("Stale capture must not create an epoch after recovery awaits") }
        catch { XCTAssertEqual(error as? TemporalSpatialMemoryServiceError, .captureAuthorityMismatch) }
        let empty = try await repository.catalogSnapshot()
        XCTAssertTrue(empty.journals.isEmpty)

        let active = makeService(repository: repository, store: store, poseValidator: { authority.permits($0) })
        _ = try await active.process(TemporalSpatialRecognitionBatch(
            sequence: 1, observations: [], expectedVisibleObjectIDs: []
        ), pose: temporalTestPose(
            mapID: mapID, coordinateFrameID: frameID, capturedAt: 100,
            sessionTimestamp: 1, sequence: 2, captureSegmentID: currentSegment
        ))
        let restarted = makeService(repository: repository, store: store, poseValidator: { authority.permits($0) })
        let before = try await restarted.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertEqual(before.latestClock?.authorization, .currentCapture)
        XCTAssertTrue(before.retiredCaptureSegmentIDs.isEmpty)
        do {
            _ = try await restarted.process(TemporalSpatialRecognitionBatch(
                sequence: 50, observations: [], expectedVisibleObjectIDs: []
            ), pose: oldPose)
            XCTFail("Restart must not revive an old capture as a fresh epoch")
        } catch { XCTAssertEqual(error as? TemporalSpatialMemoryServiceError, .captureAuthorityMismatch) }
        let after = try await restarted.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertEqual(after, before)
        let withoutAuthority = makeService(repository: repository, store: store)
        do {
            _ = try await withoutAuthority.process(TemporalSpatialRecognitionBatch(
                sequence: 2, observations: [], expectedVisibleObjectIDs: []
            ), pose: temporalTestPose(
                mapID: mapID, coordinateFrameID: frameID, capturedAt: 101,
                sessionTimestamp: 2, sequence: 3, captureSegmentID: currentSegment
            ))
            XCTFail("An authority-backed journal must not downgrade to unverified segment admission")
        } catch { XCTAssertEqual(error as? TemporalSpatialMemoryServiceError, .captureAuthorityRequired) }
    }

    func testFutureLegacySeedReplaysProjectionAtRealTimeBeforeNewObservation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(42)
        let frameID = temporalTestFrameID(42)
        let objectID = temporalTestObjectID(42)
        let future = temporalTestMetadata(
            mapID: mapID, coordinateFrameID: frameID, objectID: objectID, at: 2_000
        )
        let store = TemporalMetadataStore(document: SpatialMetadataDocument(
            maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)], objects: [future]
        ))
        let graphRepository = SceneGraphRepository(directoryURL: root.appendingPathComponent("graph"))
        let graphService = SpatialSceneGraphService(repository: graphRepository)
        let service = TemporalSpatialMemoryService(
            journalRepository: TemporalSpatialMemoryJournalRepository(directoryURL: root.appendingPathComponent("journal")),
            policy: temporalTestPolicy(), metadataProvider: { try await store.snapshot() },
            metadataWriter: { metadata in
                try await store.upsert(metadata)
                _ = try await graphService.ingest(changed: metadata, allObjects: await store.allObjects(), at: 100)
            }
        )
        let seed = try await service.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertEqual(seed.metadata(for: objectID), future)
        let graph = try await graphRepository.load(mapID: mapID)
        XCTAssertNotNil(graph)
        XCTAssertTrue(graph?.graph.relations().isEmpty == true)
        let reobserved = try TemporalSpatialObservation(
            metadata: temporalTestMetadata(mapID: mapID, coordinateFrameID: frameID, objectID: objectID, at: 100),
            promotionEvidence: temporalTestPromotionEvidence(mapID: mapID, coordinateFrameID: frameID, at: 100),
            identityDecision: .confirmedExisting(PersistentObjectReidentificationCandidate(
                objectID: objectID, score: temporalTestScore(0.95), geometryScore: temporalTestScore(0.95),
                spatialContextScore: temporalTestScore(0.95), visualSimilarity: nil, positionDistance: 0
            ))
        )
        _ = try await service.process(TemporalSpatialRecognitionBatch(
            sequence: 1, observations: [reobserved], expectedVisibleObjectIDs: [objectID]
        ), pose: temporalTestPose(
            mapID: mapID, coordinateFrameID: frameID, capturedAt: 100, sessionTimestamp: 1, sequence: 1
        ))
        let updated = await store.metadata(for: objectID)
        XCTAssertEqual(updated?.object.firstSeenAt, future.object.firstSeenAt)
        XCTAssertEqual(updated?.object.lastSeenAt, 100)
        XCTAssertEqual(updated?.object.temporalRevision, 1)
    }

    func testRestartAfterClockRollbackPreservesDatesAndRejectsRetiredEpoch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(41)
        let frameID = temporalTestFrameID(41)
        let objectID = temporalTestObjectID(41)
        let oldSegment = CaptureSegmentID()
        let newSegment = CaptureSegmentID()
        let store = TemporalMetadataStore(document: SpatialMetadataDocument(
            maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)]
        ))
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let original = makeService(repository: repository, store: store)
        _ = try await original.process(TemporalSpatialRecognitionBatch(
            sequence: 5_000,
            observations: [temporalTestNewObservation(
                mapID: mapID, coordinateFrameID: frameID, objectID: objectID, at: 2_000
            )], expectedVisibleObjectIDs: [objectID]
        ), pose: temporalTestPose(
            mapID: mapID, coordinateFrameID: frameID, capturedAt: 2_000,
            sessionTimestamp: 1_000, sequence: 1, captureSegmentID: oldSegment
        ))
        let restarted = makeService(repository: repository, store: store)
        let reobserved = try TemporalSpatialObservation(
            metadata: temporalTestMetadata(mapID: mapID, coordinateFrameID: frameID, objectID: objectID, at: 100),
            promotionEvidence: temporalTestPromotionEvidence(mapID: mapID, coordinateFrameID: frameID, at: 100),
            identityDecision: .confirmedExisting(PersistentObjectReidentificationCandidate(
                objectID: objectID, score: temporalTestScore(0.95), geometryScore: temporalTestScore(0.95),
                spatialContextScore: temporalTestScore(0.95), visualSimilarity: nil, positionDistance: 0
            ))
        )
        _ = try await restarted.process(TemporalSpatialRecognitionBatch(
            sequence: 1, observations: [reobserved], expectedVisibleObjectIDs: [objectID]
        ), pose: temporalTestPose(
            mapID: mapID, coordinateFrameID: frameID, capturedAt: 100,
            sessionTimestamp: 1, sequence: 2, captureSegmentID: newSegment
        ))
        let durable = await store.metadata(for: objectID)
        XCTAssertEqual(durable?.object.firstSeenAt, 1_999.6)
        XCTAssertEqual(durable?.object.lastSeenAt, 100)
        XCTAssertEqual(durable?.object.stateUpdatedAt, 100)
        XCTAssertEqual(durable?.object.temporalRevision, 2)
        let cold = makeService(repository: repository, store: store)
        let recovered = try await cold.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertEqual(recovered.latestSequence, 5_001)
        XCTAssertEqual(recovered.latestClock?.epoch, 2)
        XCTAssertEqual(recovered.metadata(for: objectID), durable)
        do {
            _ = try await cold.process(TemporalSpatialRecognitionBatch(
                sequence: 6_000, observations: [], expectedVisibleObjectIDs: []
            ), pose: temporalTestPose(
                mapID: mapID, coordinateFrameID: frameID, capturedAt: 2_001,
                sessionTimestamp: 1_001, sequence: 3, captureSegmentID: oldSegment
            ))
            XCTFail("A retired epoch must not be reborn after service restart")
        } catch {
            XCTAssertEqual(error as? TemporalSpatialMemoryError, .clockEpochConflict)
        }
        let after = try await cold.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertEqual(after, recovered)
    }

    func testRecognitionAndPoseCommitThenRestartRecoverExactState() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(21)
        let frameID = temporalTestFrameID(21)
        let objectID = temporalTestObjectID(21)
        let store = TemporalMetadataStore(
            document: SpatialMetadataDocument(
                maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)]
            )
        )
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let service = makeService(repository: repository, store: store)
        let pose = temporalTestPose(
            mapID: mapID,
            coordinateFrameID: frameID,
            capturedAt: 100,
            sessionTimestamp: 1,
            sequence: 1
        )
        let batch = TemporalSpatialRecognitionBatch(
            id: temporalTestDeltaID(21),
            sequence: 1,
            observations: [
                temporalTestNewObservation(
                    mapID: mapID,
                    coordinateFrameID: frameID,
                    objectID: objectID,
                    at: 100
                )
            ],
            expectedVisibleObjectIDs: [objectID]
        )

        guard case .applied(let delta) = try await service.process(batch, pose: pose) else {
            return XCTFail("Expected committed temporal update")
        }
        XCTAssertEqual(delta.newRevision, 1)
        let committedMetadata = await store.metadata(for: objectID)
        XCTAssertEqual(committedMetadata?.object.lastSeenAt, 100)

        let restarted = makeService(repository: repository, store: store)
        let restored = try await restarted.recover(
            mapID: mapID,
            coordinateFrameID: frameID
        )
        XCTAssertEqual(restored.revision, 1)
        XCTAssertEqual(restored.metadata(for: objectID)?.position.value, temporalTestPosition())
        let recoveredMetadata = await store.metadata(for: objectID)
        XCTAssertEqual(restored.metadata(for: objectID), recoveredMetadata)
    }

    func testExactBatchRetryIsIdempotentAcrossPoseWithSameFrame() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(22)
        let frameID = temporalTestFrameID(22)
        let store = TemporalMetadataStore(
            document: SpatialMetadataDocument(
                maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)]
            )
        )
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let service = makeService(repository: repository, store: store)
        let pose = temporalTestPose(
            mapID: mapID,
            coordinateFrameID: frameID,
            capturedAt: 100,
            sessionTimestamp: 1,
            sequence: 1
        )
        let batch = TemporalSpatialRecognitionBatch(
            id: temporalTestDeltaID(22),
            sequence: 1,
            observations: [],
            expectedVisibleObjectIDs: []
        )
        _ = try await service.process(batch, pose: pose)
        let url = root.appendingPathComponent(
            TemporalSpatialMemoryJournalRepository.catalogFileName
        )
        let firstBytes = try Data(contentsOf: url)

        guard
            case .alreadyProcessed(let snapshot) = try await service.process(
                batch,
                pose: pose
            )
        else {
            return XCTFail("Expected idempotent retry")
        }
        XCTAssertEqual(snapshot.revision, 1)
        XCTAssertEqual(try Data(contentsOf: url), firstBytes)
    }

    func testOutOfOrderMonotonicPoseTimeIsRejectedWithoutJournalMutation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(23)
        let frameID = temporalTestFrameID(23)
        let store = TemporalMetadataStore(
            document: SpatialMetadataDocument(
                maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)]
            )
        )
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let service = makeService(repository: repository, store: store)
        _ = try await service.process(
            TemporalSpatialRecognitionBatch(
                id: temporalTestDeltaID(23),
                sequence: 10,
                observations: [],
                expectedVisibleObjectIDs: []
            ),
            pose: temporalTestPose(
                mapID: mapID,
                coordinateFrameID: frameID,
                capturedAt: 100,
                sessionTimestamp: 10,
                sequence: 10
            )
        )
        let before = try await repository.catalogSnapshot()

        do {
            _ = try await service.process(
                TemporalSpatialRecognitionBatch(
                    id: temporalTestDeltaID(24),
                    sequence: 11,
                    observations: [],
                    expectedVisibleObjectIDs: []
                ),
                pose: temporalTestPose(
                    mapID: mapID,
                    coordinateFrameID: frameID,
                    capturedAt: 101,
                    sessionTimestamp: 9,
                    sequence: 11
                )
            )
            XCTFail("Expected out-of-order timestamp rejection")
        } catch {
            XCTAssertEqual(
                error as? TemporalSpatialMemoryError,
                .outOfOrderTimestamp(previous: 10, incoming: 9)
            )
        }
        let after = try await repository.catalogSnapshot()
        XCTAssertEqual(after, before)
    }

    func testCommittedJournalRecoversAfterMetadataProjectionFailure() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(24)
        let frameID = temporalTestFrameID(24)
        let objectID = temporalTestObjectID(24)
        let store = TemporalMetadataStore(
            document: SpatialMetadataDocument(
                maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)]
            )
        )
        await store.failNextWrite()
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let service = makeService(repository: repository, store: store)
        let batch = TemporalSpatialRecognitionBatch(
            id: temporalTestDeltaID(25),
            sequence: 1,
            observations: [
                temporalTestNewObservation(
                    mapID: mapID,
                    coordinateFrameID: frameID,
                    objectID: objectID,
                    at: 100
                )
            ],
            expectedVisibleObjectIDs: [objectID]
        )
        do {
            _ = try await service.process(
                batch,
                pose: temporalTestPose(
                    mapID: mapID,
                    coordinateFrameID: frameID,
                    capturedAt: 100,
                    sessionTimestamp: 1,
                    sequence: 1
                )
            )
            XCTFail("Expected projection-pending result")
        } catch {
            XCTAssertEqual(
                error as? TemporalSpatialMemoryServiceError,
                .committedJournalProjectionPending
            )
        }
        let metadataBeforeRecovery = await store.metadata(for: objectID)
        XCTAssertNil(metadataBeforeRecovery)
        let committedRecovery = try await repository.recover(
            mapID: mapID,
            coordinateFrameID: frameID
        )
        XCTAssertEqual(committedRecovery?.snapshot.revision, 1)

        let restarted = makeService(repository: repository, store: store)
        let restored = try await restarted.recover(
            mapID: mapID,
            coordinateFrameID: frameID
        )
        XCTAssertEqual(restored.revision, 1)
        let repairedMetadata = await store.metadata(for: objectID)
        XCTAssertEqual(repairedMetadata, restored.metadata(for: objectID))
    }

    func testRecoverRetriesMatchingDurableProjectionUntilWriterSucceeds() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(28)
        let frameID = temporalTestFrameID(28)
        let objectID = temporalTestObjectID(28)
        let store = TemporalMetadataStore(
            document: SpatialMetadataDocument(
                maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)]
            )
        )
        await store.failAfterNextWrites(2)
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let service = makeService(repository: repository, store: store)
        let batch = TemporalSpatialRecognitionBatch(
            id: temporalTestDeltaID(28),
            sequence: 1,
            observations: [
                temporalTestNewObservation(
                    mapID: mapID,
                    coordinateFrameID: frameID,
                    objectID: objectID,
                    at: 100
                )
            ],
            expectedVisibleObjectIDs: [objectID]
        )

        await assertThrowsServiceError(
            {
                try await service.process(
                    batch,
                    pose: temporalTestPose(
                        mapID: mapID,
                        coordinateFrameID: frameID,
                        capturedAt: 100,
                        sessionTimestamp: 1,
                        sequence: 1
                    )
                )
            },
            equals: .committedJournalProjectionPending
        )

        let committedRecovery = try await repository.recover(
            mapID: mapID,
            coordinateFrameID: frameID
        )
        let committed = try XCTUnwrap(committedRecovery)
        let durableAfterCommit = await store.metadata(for: objectID)
        let attemptsAfterCommit = await store.writeAttemptCount()
        XCTAssertEqual(durableAfterCommit, committed.snapshot.metadata(for: objectID))
        XCTAssertEqual(attemptsAfterCommit, 1)

        do {
            _ = try await service.recover(
                mapID: mapID,
                coordinateFrameID: frameID
            )
            XCTFail("Expected the first projection retry to fail")
        } catch {
            XCTAssertEqual(
                error as? TemporalMetadataStoreError,
                .injectedPostWriteFailure
            )
        }
        let attemptsAfterFailedRetry = await store.writeAttemptCount()
        XCTAssertEqual(attemptsAfterFailedRetry, 2)

        let restored = try await service.recover(
            mapID: mapID,
            coordinateFrameID: frameID
        )
        let attemptsAfterSuccessfulRetry = await store.writeAttemptCount()
        XCTAssertEqual(restored, committed.snapshot)
        XCTAssertEqual(attemptsAfterSuccessfulRetry, 3)

        _ = try await service.recover(
            mapID: mapID,
            coordinateFrameID: frameID
        )
        let attemptsAfterClearedPending = await store.writeAttemptCount()
        XCTAssertEqual(attemptsAfterClearedPending, 3)
    }

    func testColdRecoveryReplaysWriterAfterObjectCommitBeforeDependentProjection() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(29)
        let frameID = temporalTestFrameID(29)
        let objectID = temporalTestObjectID(29)
        let store = TemporalMetadataStore(document: SpatialMetadataDocument(
            maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)]
        ))
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let service = makeService(repository: repository, store: store)
        await store.failAfterNextWrites(1)
        await assertThrowsServiceError({
            try await service.process(
                TemporalSpatialRecognitionBatch(
                    sequence: 1,
                    observations: [temporalTestNewObservation(
                        mapID: mapID, coordinateFrameID: frameID, objectID: objectID, at: 100
                    )],
                    expectedVisibleObjectIDs: [objectID]
                ),
                pose: temporalTestPose(
                    mapID: mapID, coordinateFrameID: frameID,
                    capturedAt: 100, sessionTimestamp: 1, sequence: 1
                )
            )
        }, equals: .committedJournalProjectionPending)
        let durableBeforeRestart = await store.metadata(for: objectID)
        XCTAssertNotNil(durableBeforeRestart)

        // A fresh actor has lost the in-memory projectionPending flag.
        let restarted = makeService(repository: repository, store: store)
        let restored = try await restarted.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertEqual(restored.metadata(for: objectID), durableBeforeRestart)
        let attemptsAfterRestart = await store.writeAttemptCount()
        XCTAssertEqual(attemptsAfterRestart, 2)
        _ = try await restarted.recover(mapID: mapID, coordinateFrameID: frameID)
        let attemptsAfterCachedRecovery = await store.writeAttemptCount()
        XCTAssertEqual(attemptsAfterCachedRecovery, 2)
    }

    func testResetDropsPreviouslySeededMapObjects() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(30)
        let frameID = temporalTestFrameID(30)
        let objectID = temporalTestObjectID(30)
        let store = TemporalMetadataStore(document: SpatialMetadataDocument(
            maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)],
            objects: [temporalTestMetadata(
                mapID: mapID, coordinateFrameID: frameID, objectID: objectID, at: 100
            )]
        ))
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let service = makeService(repository: repository, store: store)
        let before = try await service.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertNotNil(before.metadata(for: objectID))
        await service.reset()
        await store.clearObjects()
        let after = try await service.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertTrue(after.objects.isEmpty)
        XCTAssertEqual(after.revision, 0)
        let writes = await store.writeAttemptCount()
        XCTAssertEqual(writes, 1)
    }

    func testResetInvalidatesRecoverySuspendedInsideMetadataProvider() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(31)
        let frameID = temporalTestFrameID(31)
        let store = TemporalMetadataStore(document: SpatialMetadataDocument(
            maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)]
        ))
        let gate = TemporalMetadataReadGate()
        let service = TemporalSpatialMemoryService(
            journalRepository: TemporalSpatialMemoryJournalRepository(directoryURL: root),
            metadataProvider: {
                await gate.pause()
                return try await store.snapshot()
            },
            metadataWriter: { try await store.upsert($0) }
        )
        let recovery = Task { try await service.recover(mapID: mapID, coordinateFrameID: frameID) }
        for _ in 0..<100 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let isWaiting = await gate.isWaiting
        XCTAssertTrue(isWaiting)
        await service.reset()
        await gate.resume()
        do {
            _ = try await recovery.value
            XCTFail("Reset must invalidate the suspended recovery")
        } catch is CancellationError {
            // Expected: old durable state must not be cached after a reset.
        }
    }

    func testExistingCheckpointMetadataSeedsFirstTemporalJournal() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(25)
        let frameID = temporalTestFrameID(25)
        let objectID = temporalTestObjectID(25)
        let existing = temporalTestMetadata(
            mapID: mapID,
            coordinateFrameID: frameID,
            objectID: objectID,
            at: 90
        )
        let store = TemporalMetadataStore(
            document: SpatialMetadataDocument(
                maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)],
                objects: [existing]
            )
        )
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let service = makeService(repository: repository, store: store)

        let snapshot = try await service.recover(
            mapID: mapID,
            coordinateFrameID: frameID
        )
        XCTAssertEqual(snapshot.revision, 0)
        XCTAssertEqual(snapshot.metadata(for: objectID), existing)
        let journalRecovery = try await repository.recover(
            mapID: mapID,
            coordinateFrameID: frameID
        )
        XCTAssertNil(journalRecovery)
    }

    func testUnreliablePoseAndUnknownMapNeverCreateJournal() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(26)
        let frameID = temporalTestFrameID(26)
        let store = TemporalMetadataStore(
            document: SpatialMetadataDocument(
                maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)]
            )
        )
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let service = makeService(repository: repository, store: store)
        let batch = TemporalSpatialRecognitionBatch(
            id: temporalTestDeltaID(26),
            sequence: 1,
            observations: [],
            expectedVisibleObjectIDs: []
        )

        await assertThrowsServiceError(
            {
                try await service.process(
                    batch,
                    pose: temporalTestPose(
                        mapID: mapID,
                        coordinateFrameID: frameID,
                        capturedAt: 100,
                        sessionTimestamp: 1,
                        sequence: 1,
                        trackingState: .limited(.relocalizing)
                    )
                )
            },
            equals: .trackingIsNotNormal
        )
        let unknownMap = temporalTestMapID(99)
        await assertThrowsServiceError(
            {
                try await service.process(
                    batch,
                    pose: temporalTestPose(
                        mapID: unknownMap,
                        coordinateFrameID: frameID,
                        capturedAt: 100,
                        sessionTimestamp: 1,
                        sequence: 1
                    )
                )
            },
            equals: .unknownOrQuarantinedMap(unknownMap)
        )
        let catalog = try await repository.catalogSnapshot()
        XCTAssertTrue(catalog.journals.isEmpty)
    }

    func testCancelledProcessDoesNotPublishJournalOrMetadata() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(27)
        let frameID = temporalTestFrameID(27)
        let store = TemporalMetadataStore(
            document: SpatialMetadataDocument(
                maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)]
            )
        )
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let service = makeService(repository: repository, store: store)
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await service.process(
                TemporalSpatialRecognitionBatch(
                    id: temporalTestDeltaID(27),
                    sequence: 1,
                    observations: [],
                    expectedVisibleObjectIDs: []
                ),
                pose: temporalTestPose(
                    mapID: mapID,
                    coordinateFrameID: frameID,
                    capturedAt: 100,
                    sessionTimestamp: 1,
                    sequence: 1
                )
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let catalog = try await repository.catalogSnapshot()
        let objects = await store.allObjects()
        XCTAssertTrue(catalog.journals.isEmpty)
        XCTAssertTrue(objects.isEmpty)
    }

    private func makeService(
        repository: TemporalSpatialMemoryJournalRepository,
        store: TemporalMetadataStore,
        poseValidator: TemporalSpatialMemoryService.PoseValidator? = nil
    ) -> TemporalSpatialMemoryService {
        TemporalSpatialMemoryService(
            journalRepository: repository,
            policy: temporalTestPolicy(),
            metadataProvider: {
                try await store.snapshot()
            },
            metadataWriter: { metadata in
                try await store.upsert(metadata)
            },
            poseValidator: poseValidator
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "vispace-temporal-service-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private final class TemporalPoseAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var segmentID: CaptureSegmentID

    init(segmentID: CaptureSegmentID) { self.segmentID = segmentID }

    func select(_ segmentID: CaptureSegmentID) {
        lock.lock()
        self.segmentID = segmentID
        lock.unlock()
    }

    func permits(_ pose: ARPoseSnapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pose.segmentID == segmentID
    }
}

private actor TemporalMetadataReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func pause() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor TemporalOneShotCommitGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var used = false
    var isWaiting: Bool { continuation != nil }

    func pauseOnce() async {
        guard !used else { return }
        used = true
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        // A timeout can release the gate before the writer reaches pauseOnce.
        used = true
        continuation?.resume()
        continuation = nil
    }
}

private actor TemporalMetadataStore {
    private var document: SpatialMetadataDocument
    private var shouldFailNextWrite = false
    private var postWriteFailuresRemaining = 0
    private var writeAttempts = 0

    init(document: SpatialMetadataDocument) {
        self.document = document
    }

    func snapshot() throws -> SpatialMetadataDocument {
        document
    }

    func metadata(for objectID: ObjectID) -> SpatialObjectMetadata? {
        document.objects.first { $0.object.id == objectID }
    }

    func allObjects() -> [SpatialObjectMetadata] {
        document.objects
    }

    func clearObjects() {
        document.objects.removeAll()
    }

    func failNextWrite() {
        shouldFailNextWrite = true
    }

    func failAfterNextWrites(_ count: Int) {
        postWriteFailuresRemaining = count
    }

    func writeAttemptCount() -> Int {
        writeAttempts
    }

    /// Mirrors the repository's separate user-annotation mutation. A rename
    /// does not claim a newer sensor observation or temporal revision.
    func renameAnnotation(expected: SpatialObjectMetadata, displayName: String?) throws {
        guard let index = document.objects.firstIndex(where: {
            $0.mapID == expected.mapID && $0.object.id == expected.object.id
        }), document.objects[index] == expected else {
            throw TemporalMetadataStoreError.staleWrite
        }
        var object = expected.object
        try object.setDisplayName(displayName)
        document.objects[index] = try SpatialObjectMetadata(mapID: expected.mapID,
            object: object, position: expected.position)
    }

    func upsert(_ metadata: SpatialObjectMetadata) throws {
        writeAttempts += 1
        if shouldFailNextWrite {
            shouldFailNextWrite = false
            throw TemporalMetadataStoreError.injectedFailure
        }
        if let index = document.objects.firstIndex(where: {
            $0.mapID == metadata.mapID && $0.object.id == metadata.object.id
        }) {
            let existing = document.objects[index]
            if existing != metadata {
                let newer: Bool
                switch (metadata.object.temporalRevision, existing.object.temporalRevision) {
                case (.some(let incoming), .some(let previous)): newer = incoming > previous
                case (.some, .none): newer = true
                case (.none, .some): newer = false
                case (.none, .none): newer = metadata.object.stateUpdatedAt > existing.object.stateUpdatedAt
                }
                guard newer else {
                    throw TemporalMetadataStoreError.staleWrite
                }
                document.objects[index] = metadata
            }
        } else {
            document.objects.append(metadata)
        }
        if postWriteFailuresRemaining > 0 {
            postWriteFailuresRemaining -= 1
            throw TemporalMetadataStoreError.injectedPostWriteFailure
        }
    }
}

private enum TemporalMetadataStoreError: Error, Equatable {
    case injectedFailure
    case injectedPostWriteFailure
    case staleWrite
    case batchProjectionWasNotReached
}

private actor TemporalBatchProjectionRecorder {
    private(set) var objectIDs: [[ObjectID]] = []
    func record(_ metadata: [SpatialObjectMetadata]) { objectIDs.append(metadata.map(\.object.id).sorted()) }
}

/// Wait for an actual boundary or an early operation failure, rather than
/// imposing a per-write scheduler deadline inside the functional regression.
private actor TemporalBatchRecoveryGate {
    private var paused: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Bool, Never>?
    private var used = false
    private var completed = false

    func pauseOnce() async {
        guard !used else { return }
        used = true
        await withCheckedContinuation { continuation in
            paused = continuation
            arrival?.resume(returning: true)
            arrival = nil
        }
    }

    func waitUntilPausedOrFinished() async -> Bool {
        if paused != nil { return true }
        if completed { return false }
        return await withCheckedContinuation { arrival = $0 }
    }

    func finished() {
        completed = true
        arrival?.resume(returning: false)
        arrival = nil
    }

    func resume() {
        used = true
        paused?.resume()
        paused = nil
        finished()
    }
}

private func assertThrowsServiceError<T>(
    _ expression: () async throws -> T,
    equals expected: TemporalSpatialMemoryServiceError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
        XCTAssertEqual(
            error as? TemporalSpatialMemoryServiceError,
            expected,
            file: file,
            line: line
        )
    }
}
