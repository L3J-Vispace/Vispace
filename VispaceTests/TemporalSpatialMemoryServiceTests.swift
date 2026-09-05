import VispaceCore
import XCTest

@testable import Vispace

final class TemporalSpatialMemoryServiceTests: XCTestCase {
    func testFutureLegacySeedReplaysProjectionAtRealTimeBeforeNewObservation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(42)
        let frameID = temporalTestFrameID(42)
        let objectID = temporalTestObjectID(42)
        let future = try temporalTestMetadata(
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
        store: TemporalMetadataStore
    ) -> TemporalSpatialMemoryService {
        TemporalSpatialMemoryService(
            journalRepository: repository,
            policy: temporalTestPolicy(),
            metadataProvider: {
                try await store.snapshot()
            },
            metadataWriter: { metadata in
                try await store.upsert(metadata)
            }
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "vispace-temporal-service-tests-\(UUID().uuidString)",
            isDirectory: true
        )
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
