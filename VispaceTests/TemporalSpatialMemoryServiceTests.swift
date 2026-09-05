import VispaceCore
import XCTest

@testable import Vispace

final class TemporalSpatialMemoryServiceTests: XCTestCase {
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

    func testOutOfOrderPoseTimeIsRejectedWithoutJournalMutation() async throws {
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
                    capturedAt: 99,
                    sessionTimestamp: 11,
                    sequence: 11
                )
            )
            XCTFail("Expected out-of-order timestamp rejection")
        } catch {
            XCTAssertEqual(
                error as? TemporalSpatialMemoryError,
                .outOfOrderTimestamp(previous: 100, incoming: 99)
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
                guard metadata.object.stateUpdatedAt > existing.object.stateUpdatedAt else {
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
