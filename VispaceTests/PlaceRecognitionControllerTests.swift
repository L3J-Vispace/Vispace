import VispaceCore
import XCTest
import simd

@testable import Vispace

@MainActor
final class PlaceRecognitionControllerTests: XCTestCase {
    func testMappedPlacePersistsFingerprintOnceAndPublishesKnown() async throws {
        let channel = LatestValueChannel<ARSurfaceStateSnapshot>()
        let store = try RecordingPlaceStore()
        let checkpoint = CheckpointCounter()
        let frameID = CoordinateFrameID()
        let mapID = MapID()
        let controller = makeController(
            channel: channel,
            store: store,
            objects: [],
            checkpoint: checkpoint
        )
        controller.activate()

        channel.send(makeSnapshot(frameID: frameID, mapID: mapID, revision: 1))
        try await waitForIdle(controller, persistedFingerprints: 1)

        XCTAssertEqual(controller.state, .known(mapID: mapID, confidence: .one))
        let firstWriteCount = await store.fingerprintWriteCount()
        XCTAssertEqual(firstWriteCount, 1)

        channel.send(makeSnapshot(frameID: frameID, mapID: mapID, revision: 2))
        try await waitForIdle(controller)

        let finalWriteCount = await store.fingerprintWriteCount()
        XCTAssertEqual(finalWriteCount, 1)
        XCTAssertEqual(checkpoint.count, 0)
        controller.deactivate()
    }

    func testSparseMappedRevisitDoesNotReplaceRicherFingerprint() async throws {
        let channel = LatestValueChannel<ARSurfaceStateSnapshot>()
        let store = try RecordingPlaceStore()
        let checkpoint = CheckpointCounter()
        let frameID = CoordinateFrameID()
        let segmentID = CaptureSegmentID()
        let mapID = MapID()
        let controller = makeController(
            channel: channel,
            store: store,
            objects: [],
            checkpoint: checkpoint
        )
        controller.activate()

        channel.send(
            makeSnapshot(
                frameID: frameID,
                segmentID: segmentID,
                mapID: mapID,
                revision: 1,
                includeWall: true
            )
        )
        try await waitForIdle(
            controller,
            persistedFingerprints: 1,
            receivedSnapshots: 1
        )
        let storedRichFingerprint = await store.fingerprint(mapID: mapID)
        let richFingerprint = try XCTUnwrap(storedRichFingerprint)

        channel.send(
            makeSnapshot(
                frameID: frameID,
                segmentID: segmentID,
                mapID: mapID,
                revision: 2,
                includeWall: false
            )
        )
        try await waitForIdle(controller, receivedSnapshots: 2)

        let writeCount = await store.fingerprintWriteCount()
        let persistedFingerprint = await store.fingerprint(mapID: mapID)
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(persistedFingerprint, richFingerprint)
        controller.deactivate()
    }

    func testNewerSurfaceRevisionRejectsSlowOlderFingerprintResult() async throws {
        let channel = LatestValueChannel<ARSurfaceStateSnapshot>()
        let store = try RecordingPlaceStore()
        let checkpoint = CheckpointCounter()
        let frameID = CoordinateFrameID()
        let segmentID = CaptureSegmentID()
        let mapID = MapID()
        let controller = PlaceRecognitionController(
            surfaces: channel.stream,
            objectMetadataProvider: {
                try await Task.sleep(for: .milliseconds(80))
                return []
            },
            catalogProvider: { try await store.catalog() },
            fingerprintWriter: { await store.writeFingerprint($0) },
            associationWriter: { await store.writeAssociation($0) },
            checkpointRetryInterval: .seconds(60),
            checkpointRequester: { checkpoint.increment() }
        )
        controller.activate()

        channel.send(
            makeSnapshot(
                frameID: frameID,
                segmentID: segmentID,
                mapID: mapID,
                revision: 1,
                includeWall: false
            )
        )
        for _ in 0..<100 where !controller.isProcessingForTesting {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(controller.isProcessingForTesting)

        channel.send(
            makeSnapshot(
                frameID: frameID,
                segmentID: segmentID,
                mapID: mapID,
                revision: 2,
                includeWall: true
            )
        )
        try await waitForIdle(
            controller,
            persistedFingerprints: 1,
            receivedSnapshots: 2
        )

        let writeCount = await store.fingerprintWriteCount()
        XCTAssertEqual(writeCount, 1)
        XCTAssertGreaterThanOrEqual(controller.metrics.staleResultsRejected, 1)
        let persistedValue = await store.fingerprint(mapID: mapID)
        let persisted = try XCTUnwrap(persistedValue)
        let expected = try ARPlaceFingerprintBuilder().makeFingerprint(
            from: makeSnapshot(
                frameID: frameID,
                segmentID: segmentID,
                mapID: mapID,
                revision: 2,
                includeWall: true
            ),
            objects: []
        )
        XCTAssertEqual(persisted, expected)
        controller.deactivate()
    }

    func testRepeatedHighConfidenceAbsenceRequestsOneNewMapCheckpoint() async throws {
        let channel = LatestValueChannel<ARSurfaceStateSnapshot>()
        let store = try RecordingPlaceStore()
        let checkpoint = CheckpointCounter()
        let frameID = CoordinateFrameID()
        let segmentID = CaptureSegmentID()
        let controller = makeController(
            channel: channel,
            store: store,
            objects: [],
            checkpoint: checkpoint
        )
        controller.activate()

        channel.send(
            makeSnapshot(
                frameID: frameID,
                segmentID: segmentID,
                mapID: nil,
                revision: 1
            )
        )
        try await waitForIdle(controller, persistedAssociations: 1)
        guard case .ambiguous = controller.state else {
            return XCTFail("The first absence observation must remain ambiguous.")
        }

        channel.send(
            makeSnapshot(
                frameID: frameID,
                segmentID: segmentID,
                mapID: nil,
                revision: 2
            )
        )
        try await waitForIdle(controller, persistedAssociations: 2)

        guard case .newPlaceAwaitingCheckpoint(let confidence) = controller.state else {
            return XCTFail("Repeated absence must request a new checkpoint.")
        }
        XCTAssertEqual(confidence, .one)
        XCTAssertEqual(checkpoint.count, 1)

        channel.send(
            makeSnapshot(
                frameID: frameID,
                segmentID: segmentID,
                mapID: nil,
                revision: 3
            )
        )
        try await Task.sleep(for: .milliseconds(30))
        let associationWriteCount = await store.associationWriteCount()
        XCTAssertEqual(associationWriteCount, 2)
        XCTAssertEqual(checkpoint.count, 1)
        controller.deactivate()
    }

    func testCheckpointRequestRetriesWithoutAddingDuplicateEvidence() async throws {
        let channel = LatestValueChannel<ARSurfaceStateSnapshot>()
        let store = try RecordingPlaceStore()
        let checkpoint = CheckpointCounter()
        let frameID = CoordinateFrameID()
        let segmentID = CaptureSegmentID()
        let controller = makeController(
            channel: channel,
            store: store,
            objects: [],
            checkpoint: checkpoint,
            checkpointRetryInterval: .milliseconds(20)
        )
        controller.activate()

        channel.send(
            makeSnapshot(
                frameID: frameID,
                segmentID: segmentID,
                mapID: nil,
                revision: 1,
                timestamp: 1
            )
        )
        try await waitForIdle(controller, persistedAssociations: 1)
        channel.send(
            makeSnapshot(
                frameID: frameID,
                segmentID: segmentID,
                mapID: nil,
                revision: 2,
                timestamp: 2
            )
        )
        try await waitForIdle(controller, persistedAssociations: 2)
        XCTAssertEqual(checkpoint.count, 1)

        for _ in 0..<100 where checkpoint.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(checkpoint.count, 2)
        let associationWriteCount = await store.associationWriteCount()
        XCTAssertEqual(associationWriteCount, 2)
        controller.deactivate()
    }

    func testKnownPlaceInSameFrameAssociatesExistingMapWithoutCheckpoint() async throws {
        let channel = LatestValueChannel<ARSurfaceStateSnapshot>()
        let frameID = CoordinateFrameID()
        let segmentID = CaptureSegmentID()
        let mapID = MapID()
        let referenceSnapshot = makeSnapshot(
            frameID: frameID,
            segmentID: segmentID,
            mapID: mapID,
            revision: 1
        )
        let fingerprint = try ARPlaceFingerprintBuilder().makeFingerprint(
            from: referenceSnapshot,
            objects: []
        )
        let saved = try PlaceFingerprintRecord(
            mapID: mapID,
            coordinateFrameID: frameID,
            fingerprint: fingerprint,
            createdAt: 1,
            updatedAt: 1
        )
        let store = try RecordingPlaceStore(fingerprints: [saved])
        let checkpoint = CheckpointCounter()
        let association = ExistingMapAssociationRecorder(result: true)
        let controller = makeController(
            channel: channel,
            store: store,
            objects: [],
            checkpoint: checkpoint,
            existingMapAssociator: { mapID, coordinateFrameID in
                association.record(mapID: mapID, coordinateFrameID: coordinateFrameID)
            }
        )
        controller.activate()

        for revision in 2...3 {
            channel.send(
                makeSnapshot(
                    frameID: frameID,
                    segmentID: segmentID,
                    mapID: nil,
                    revision: UInt64(revision)
                )
            )
            try await waitForIdle(
                controller,
                persistedAssociations: UInt64(revision - 1)
            )
        }

        XCTAssertEqual(association.calls, 1)
        XCTAssertEqual(association.lastMapID, mapID)
        XCTAssertEqual(association.lastCoordinateFrameID, frameID)
        XCTAssertEqual(checkpoint.count, 0)
        switch controller.state {
        case .known(let selectedMapID, _), .overlapping(let selectedMapID, _):
            XCTAssertEqual(selectedMapID, mapID)
        default:
            XCTFail("A repeated same-frame match must select the existing map.")
        }
        controller.deactivate()
    }

    func testMappedOverlapCommitsValidatedCrossFrameMergeOnlyOnThirdObservation() async throws {
        let channel = LatestValueChannel<ARSurfaceStateSnapshot>()
        let sourceMapID = MapID()
        let targetMapID = MapID()
        let sourceFrameID = CoordinateFrameID()
        let targetFrameID = CoordinateFrameID()
        let segmentID = CaptureSegmentID()
        let labels = ["chair", "lamp", "table"]
        let sourcePositions = [
            try Vec3(x: 0, y: 0.4, z: 0),
            try Vec3(x: 1.2, y: 0.4, z: 0.2),
            try Vec3(x: 0.1, y: 0.4, z: 1.4),
        ]
        let offset = try Vec3(x: 2.5, y: 0.1, z: -1.75)
        let sourceObjects = try zip(labels, sourcePositions).map { label, position in
            try makeObject(
                label: label,
                position: position,
                frameID: sourceFrameID,
                mapID: sourceMapID
            )
        }
        let targetObjects = try zip(labels, sourcePositions).map { label, position in
            try makeObject(
                label: label,
                position: position + offset,
                frameID: targetFrameID,
                mapID: targetMapID,
                presence: .lastSeen
            )
        }
        let targetSnapshot = makeSnapshot(
            frameID: targetFrameID,
            segmentID: CaptureSegmentID(),
            mapID: targetMapID,
            revision: 1
        )
        let targetFingerprint = try ARPlaceFingerprintBuilder().makeFingerprint(
            from: targetSnapshot,
            objects: targetObjects
        )
        let targetRecord = try PlaceFingerprintRecord(
            mapID: targetMapID,
            coordinateFrameID: targetFrameID,
            fingerprint: targetFingerprint,
            createdAt: 1,
            updatedAt: 1
        )
        let store = try RecordingPlaceStore(fingerprints: [targetRecord])
        let checkpoint = CheckpointCounter()
        let mergeRecorder = LogicalMergeRecorder()
        // This fixture supplies physical identity independently of the shared
        // class labels; production must remain unresolved without that proof.
        let verifiedTargetBySource = Dictionary(uniqueKeysWithValues:
            zip(sourceObjects, targetObjects).map { ($0.object.id, $1.object.id) }
        )
        let resolver = PlaceCoordinateAlignmentResolver(identityVerifier: {
            verifiedTargetBySource[$0.source.objectID] == $0.target.objectID
        })
        let controller = PlaceRecognitionController(
            surfaces: channel.stream,
            objectMetadataProvider: { sourceObjects + targetObjects },
            catalogProvider: { try await store.catalog() },
            fingerprintWriter: { await store.writeFingerprint($0) },
            associationWriter: { await store.writeAssociation($0) },
            coordinateCompatibilityProvider: { snapshot, candidate, objects in
                resolver.resolve(current: snapshot, candidate: candidate, objects: objects)
            },
            logicalMergeWriter: { await mergeRecorder.write($0) },
            checkpointRetryInterval: .seconds(60),
            checkpointRequester: { checkpoint.increment() }
        )
        controller.activate()

        for revision in 1...2 {
            channel.send(
                makeSnapshot(
                    frameID: sourceFrameID,
                    segmentID: segmentID,
                    mapID: sourceMapID,
                    revision: UInt64(revision)
                )
            )
            try await waitForIdle(
                controller,
                persistedAssociations: UInt64(revision),
                receivedSnapshots: UInt64(revision)
            )
        }
        let mergeCountAfterTwoObservations = await mergeRecorder.count()
        XCTAssertEqual(mergeCountAfterTwoObservations, 0)

        channel.send(
            makeSnapshot(
                frameID: sourceFrameID,
                segmentID: segmentID,
                mapID: sourceMapID,
                revision: 3
            )
        )
        try await waitForIdle(
            controller,
            persistedAssociations: 3,
            receivedSnapshots: 3
        )

        let commits = await mergeRecorder.snapshot()
        guard let commit = commits.first else {
            return XCTFail(
                "Expected a merge commit after three observations; latest decision: "
                    + String(describing: controller.latestDecision)
            )
        }
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commit.sourceMapID, sourceMapID)
        XCTAssertEqual(commit.targetMapID, targetMapID)
        XCTAssertEqual(commit.sourceCoordinateFrameID, sourceFrameID)
        XCTAssertEqual(commit.targetCoordinateFrameID, targetFrameID)
        XCTAssertNotNil(commit.validatedAlignment)
        XCTAssertLessThan(
            try commit.sourceToTarget.transformed(sourcePositions[0]).distance(
                to: targetObjects[0].position.value
            ),
            1e-9
        )
        XCTAssertEqual(controller.metrics.logicalMergesCommitted, 1)

        channel.send(
            makeSnapshot(
                frameID: sourceFrameID,
                segmentID: segmentID,
                mapID: sourceMapID,
                revision: 4
            )
        )
        try await waitForIdle(controller, receivedSnapshots: 4)
        let finalMergeCount = await mergeRecorder.count()
        XCTAssertEqual(finalMergeCount, 1)
        XCTAssertEqual(checkpoint.count, 0)
        controller.deactivate()
    }

    func testPerfectFingerprintInDifferentFrameStaysAmbiguousWithoutAlignment() async throws {
        let channel = LatestValueChannel<ARSurfaceStateSnapshot>()
        let currentFrameID = CoordinateFrameID()
        let savedFrameID = CoordinateFrameID()
        let savedMapID = MapID()
        let savedObject = try makeObject(frameID: savedFrameID, mapID: savedMapID)
        let savedFingerprint = try ARPlaceFingerprintBuilder().makeFingerprint(
            from: makeSnapshot(frameID: savedFrameID, mapID: savedMapID, revision: 1),
            objects: [savedObject]
        )
        let savedRecord = try PlaceFingerprintRecord(
            mapID: savedMapID,
            coordinateFrameID: savedFrameID,
            fingerprint: savedFingerprint,
            createdAt: 1,
            updatedAt: 1
        )
        let store = try RecordingPlaceStore(fingerprints: [savedRecord])
        let checkpoint = CheckpointCounter()
        let currentObject = try makeObject(frameID: currentFrameID, mapID: MapID())
        let controller = makeController(
            channel: channel,
            store: store,
            objects: [currentObject],
            checkpoint: checkpoint
        )
        controller.activate()

        for revision in 1...2 {
            channel.send(
                makeSnapshot(
                    frameID: currentFrameID,
                    mapID: nil,
                    revision: UInt64(revision)
                )
            )
            try await waitForIdle(
                controller,
                persistedAssociations: UInt64(revision)
            )
        }

        guard case .ambiguous(let candidates, let reason) = controller.state else {
            return XCTFail("Cross-frame lookalikes must remain ambiguous.")
        }
        XCTAssertEqual(candidates, [savedMapID])
        XCTAssertEqual(reason, .coordinateCompatibilityUnresolved)
        XCTAssertEqual(checkpoint.count, 0)
        controller.deactivate()
    }

    func testSupersededDurableAssociationWriteResumesFromStoredRevision() async throws {
        try await assertSupersededDurableAssociationWriteResumes(seedHistoryCount: 0)
    }

    func testSupersededDurableAttemptRotationResumesFromReplacementHistory() async throws {
        try await assertSupersededDurableAssociationWriteResumes(seedHistoryCount: 63)
    }

    private func assertSupersededDurableAssociationWriteResumes(seedHistoryCount: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = PlaceMemoryRepository(directoryURL: directory, maximumAssociationStates: 1)
        let sourceFrameID = CoordinateFrameID()
        let targetFrameID = CoordinateFrameID()
        let targetMapID = MapID()
        let segmentID = CaptureSegmentID()
        let targetObject = try makeObject(frameID: targetFrameID, mapID: targetMapID)
        let fingerprint = try ARPlaceFingerprintBuilder().makeFingerprint(
            from: makeSnapshot(frameID: targetFrameID, mapID: targetMapID, revision: 1),
            objects: [targetObject]
        )
        try await repository.upsertFingerprint(PlaceFingerprintRecord(
            mapID: targetMapID, coordinateFrameID: targetFrameID,
            fingerprint: fingerprint, createdAt: 1, updatedAt: 1
        ))
        if seedHistoryCount > 0 {
            let candidate = PlaceMapCandidateEvidence(
                mapID: targetMapID, coordinateFrameID: targetFrameID,
                placeEvidence: PlaceEvidence(visual: .one, geometry: .one, structure: .one,
                    poseConsistency: .one, objectLayout: .one, spatialOverlap: .one),
                coordinateCompatibility: .unresolved
            )
            try await repository.upsertAssociationState(PlaceAssociationStateRecord(
                context: PlaceAssociationContext(sourceMapID: nil, sourceCoordinateFrameID: sourceFrameID),
                observations: (0..<seedHistoryCount).map {
                    PlaceAssociationObservation(id: ObservationID(), baseRevision: UInt64($0),
                        sequence: UInt64($0 + 1), candidates: [candidate])
                }, createdAt: 1, updatedAt: 2
            ))
        }
        let sourceObject = try makeObject(frameID: sourceFrameID, mapID: MapID())
        let channel = LatestValueChannel<ARSurfaceStateSnapshot>()
        let gate = PlaceAssociationWriteReturnGate()
        let controller = PlaceRecognitionController(
            surfaces: channel.stream,
            objectMetadataProvider: { [sourceObject] },
            catalogProvider: { try await repository.catalogSnapshot() },
            fingerprintWriter: { try await repository.upsertFingerprint($0) },
            associationWriter: {
                try await repository.upsertAssociationState($0, retention: .retireOlderDeferredAttempts)
                await gate.waitAfterDurableWrite()
            },
            minimumAssociationObservationInterval: 0,
            checkpointRequester: { XCTFail("Unresolved coordinates must not request a checkpoint") }
        )
        controller.activate()
        do {
            channel.send(makeSnapshot(frameID: sourceFrameID, segmentID: segmentID, mapID: nil, revision: 1))
            try await waitForIdle(controller, persistedAssociations: 1, receivedSnapshots: 1)
            await gate.pauseNextReturn()
            channel.send(makeSnapshot(frameID: sourceFrameID, segmentID: segmentID, mapID: nil, revision: 2))
            for _ in 0..<200 {
                if await gate.isPaused { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard await gate.isPaused else { throw PlaceControllerWaitError.writeDidNotPause }
            let before = try await repository.catalogSnapshot()
            let storedWhileBlocked = try XCTUnwrap(before.associationStates.first)

            // The newer surface must be offered while the completed disk write
            // has not returned. This deterministically supersedes its UI result.
            channel.send(makeSnapshot(frameID: sourceFrameID, segmentID: segmentID, mapID: nil, revision: 3))
            for _ in 0..<200 {
                if controller.metrics.snapshotsReceived >= 3 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard controller.metrics.snapshotsReceived == 3 else {
                throw PlaceControllerWaitError.newerSnapshotNotReceived
            }
            await gate.release()
            try await waitForIdle(controller, persistedAssociations: 2, receivedSnapshots: 3)
            let after = try await repository.catalogSnapshot()
            let resumed = try XCTUnwrap(after.associationStates.first)
            XCTAssertEqual(resumed.id, storedWhileBlocked.id)
            XCTAssertEqual(resumed.revision, storedWhileBlocked.revision + 1)
            XCTAssertEqual(resumed.latestSequence, (storedWhileBlocked.latestSequence ?? 0) + 1)
            XCTAssertTrue(resumed.observations.starts(with: storedWhileBlocked.observations))
            XCTAssertEqual(resumed.observations.count, seedHistoryCount == 0 ? 3 : 2)
            XCTAssertGreaterThanOrEqual(controller.metrics.staleResultsRejected, 1)

            channel.send(makeSnapshot(frameID: sourceFrameID, segmentID: segmentID, mapID: nil, revision: 4))
            try await waitForIdle(controller, persistedAssociations: 3, receivedSnapshots: 4)
            let continuedCatalog = try await repository.catalogSnapshot()
            let continued = try XCTUnwrap(continuedCatalog.associationStates.first)
            XCTAssertEqual(continued.revision, resumed.revision + 1)
            XCTAssertTrue(continued.observations.starts(with: resumed.observations))
            XCTAssertEqual(continuedCatalog.associationStates.count, 1)
            if case .ambiguous = controller.state {
                // Continued evidence remains deferred without an alignment.
            } else {
                XCTFail("Superseded durable writes must leave recognition operational")
            }
        } catch {
            await gate.release()
            await controller.deactivateAndWaitForPendingWork()
            throw error
        }
        await controller.deactivateAndWaitForPendingWork()
    }

    func testDeferredAttemptRotationWithRealRepositorySurvivesHistoryLimitAndBackwardClock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = PlaceMemoryRepository(directoryURL: directory, maximumAssociationStates: 1)
        let sourceFrameID = CoordinateFrameID()
        let targetFrameID = CoordinateFrameID()
        let targetMapID = MapID()
        let segmentID = CaptureSegmentID()
        let targetObject = try makeObject(frameID: targetFrameID, mapID: targetMapID)
        let fingerprint = try ARPlaceFingerprintBuilder().makeFingerprint(
            from: makeSnapshot(frameID: targetFrameID, mapID: targetMapID, revision: 1),
            objects: [targetObject]
        )
        try await repository.upsertFingerprint(
            PlaceFingerprintRecord(
                mapID: targetMapID, coordinateFrameID: targetFrameID,
                fingerprint: fingerprint, createdAt: 1, updatedAt: 1
            ))
        let candidate = PlaceMapCandidateEvidence(
            mapID: targetMapID, coordinateFrameID: targetFrameID,
            placeEvidence: PlaceEvidence(
                visual: .one, geometry: .one, structure: .one,
                poseConsistency: .one, objectLayout: .one, spatialOverlap: .one
            ), coordinateCompatibility: .unresolved
        )
        // A previously saved attempt is ahead of the current device clock.
        // Its replacement must use durable order, not regress to Date().
        let futureTime = Date().timeIntervalSince1970 + 10_000
        let seed = try PlaceAssociationStateRecord(
            context: PlaceAssociationContext(sourceMapID: nil, sourceCoordinateFrameID: sourceFrameID),
            observations: (0..<64).map {
                PlaceAssociationObservation(
                    id: ObservationID(), baseRevision: UInt64($0),
                    sequence: UInt64($0 + 1), candidates: [candidate])
            }, createdAt: futureTime, updatedAt: futureTime + 1
        )
        try await repository.upsertAssociationState(seed)
        let sourceObject = try makeObject(frameID: sourceFrameID, mapID: MapID())
        let channel = LatestValueChannel<ARSurfaceStateSnapshot>()
        let controller = PlaceRecognitionController(
            surfaces: channel.stream,
            objectMetadataProvider: { [sourceObject] },
            catalogProvider: { try await repository.catalogSnapshot() },
            fingerprintWriter: { try await repository.upsertFingerprint($0) },
            associationWriter: {
                try await repository.upsertAssociationState($0, retention: .retireOlderDeferredAttempts)
            },
            minimumAssociationObservationInterval: 0,
            checkpointRequester: { XCTFail("Unresolved coordinates must not request a checkpoint") }
        )
        controller.activate()
        defer { controller.deactivate() }
        for revision in 1...130 {
            channel.send(
                makeSnapshot(
                    frameID: sourceFrameID, segmentID: segmentID, mapID: nil,
                    revision: UInt64(revision)
                ))
            try await waitForIdle(
                controller, persistedAssociations: UInt64(revision),
                receivedSnapshots: UInt64(revision))
        }
        let catalog = try await PlaceMemoryRepository(
            directoryURL: directory, maximumAssociationStates: 1
        ).catalogSnapshot()
        XCTAssertEqual(catalog.associationStates.count, 1)
        let retained = try XCTUnwrap(catalog.associationStates.first)
        XCTAssertNotEqual(retained.id, seed.id)
        XCTAssertGreaterThan(retained.createdAt, futureTime + 1)
        XCTAssertEqual(retained.observations.count, 2)
        XCTAssertEqual(retained.latestDecision.mutation, .deferDecision)
        XCTAssertGreaterThan(try XCTUnwrap(catalog.retiredAssociationCreatedAtThrough), futureTime)
        guard case .ambiguous = controller.state else {
            return XCTFail("Sustained deferred recognition must remain operational")
        }
    }

    func testIncompleteSurfaceNeverReadsOrWritesPlaceMemory() async throws {
        let channel = LatestValueChannel<ARSurfaceStateSnapshot>()
        let store = try RecordingPlaceStore()
        let checkpoint = CheckpointCounter()
        let controller = makeController(
            channel: channel,
            store: store,
            objects: [],
            checkpoint: checkpoint
        )
        controller.activate()

        channel.send(
            makeSnapshot(
                frameID: CoordinateFrameID(),
                mapID: nil,
                revision: 1,
                isCurrentSessionData: false
            )
        )
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(controller.state, .waitingForCompleteSurface)
        let readCount = await store.catalogReadCount()
        let fingerprintWriteCount = await store.fingerprintWriteCount()
        let associationWriteCount = await store.associationWriteCount()
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(fingerprintWriteCount, 0)
        XCTAssertEqual(associationWriteCount, 0)
        controller.deactivate()
    }

    func testDeletionBarrierJoinsSupersededFingerprintWrites() async throws {
        try await assertDeletionBarrierJoinsSupersededWrites(mapped: true)
    }

    func testDeletionBarrierJoinsSupersededAssociationWrites() async throws {
        try await assertDeletionBarrierJoinsSupersededWrites(mapped: false)
    }

    func testDeletionBarrierJoinsCancelledCheckpointRetryAndAllowsReactivation() async throws {
        let channel = LatestValueChannel<ARSurfaceStateSnapshot>()
        let store = try RecordingPlaceStore()
        let checkpoint = CheckpointCounter()
        let frameID = CoordinateFrameID()
        let segmentID = CaptureSegmentID()
        let controller = makeController(
            channel: channel,
            store: store,
            objects: [],
            checkpoint: checkpoint,
            checkpointRetryInterval: .seconds(60)
        )
        controller.activate()
        for revision in 1...2 {
            channel.send(
                makeSnapshot(
                    frameID: frameID,
                    segmentID: segmentID,
                    mapID: nil,
                    revision: UInt64(revision)
                )
            )
            try await waitForIdle(controller, persistedAssociations: UInt64(revision))
        }
        XCTAssertEqual(checkpoint.count, 1)
        XCTAssertEqual(controller.pendingCheckpointRetryTaskCountForTesting, 1)

        // The retry is cancelled synchronously but has not had an actor turn
        // to finish; a second deactivation still needs to join that old task.
        controller.deactivate()
        XCTAssertEqual(controller.pendingCheckpointRetryTaskCountForTesting, 1)
        await controller.deactivateAndWaitForPendingWork()
        XCTAssertEqual(controller.pendingCheckpointRetryTaskCountForTesting, 0)
        XCTAssertEqual(controller.pendingProcessingTaskCountForTesting, 0)
        XCTAssertEqual(checkpoint.count, 1)

        controller.activate()
        let mapID = MapID()
        channel.send(makeSnapshot(frameID: frameID, mapID: mapID, revision: 3))
        try await waitForIdle(controller, persistedFingerprints: 1)
        XCTAssertEqual(controller.state, .known(mapID: mapID, confidence: .one))
        XCTAssertEqual(checkpoint.count, 1)
        await controller.deactivateAndWaitForPendingWork()
    }

    private func assertDeletionBarrierJoinsSupersededWrites(mapped: Bool) async throws {
        let channel = LatestValueChannel<ARSurfaceStateSnapshot>()
        let store = try RecordingPlaceStore()
        let writer = SuspendedPlaceWriter()
        let completion = PlaceDeletionBarrierCompletion()
        let controller = PlaceRecognitionController(
            surfaces: channel.stream,
            objectMetadataProvider: { [] },
            catalogProvider: { try await store.catalog() },
            fingerprintWriter: { _ in try await writer.write() },
            associationWriter: { _ in try await writer.write() },
            checkpointRetryInterval: .seconds(60),
            checkpointRequester: {}
        )
        controller.activate()
        channel.send(
            makeSnapshot(
                frameID: CoordinateFrameID(),
                mapID: mapped ? MapID() : nil,
                revision: 1
            )
        )
        try await waitForWriter(writer, expectedCount: 1)

        // An AR coordinate-frame replacement releases the active slot while
        // a non-cooperative old writer remains suspended.
        channel.send(
            makeSnapshot(
                frameID: CoordinateFrameID(),
                mapID: mapped ? MapID() : nil,
                revision: 2
            )
        )
        try await waitForWriter(writer, expectedCount: 2)
        XCTAssertEqual(controller.pendingProcessingTaskCountForTesting, 2)

        controller.deactivate()
        controller.activate()
        channel.send(
            makeSnapshot(
                frameID: CoordinateFrameID(),
                mapID: mapped ? MapID() : nil,
                revision: 3
            )
        )
        try await waitForWriter(writer, expectedCount: 3)
        XCTAssertEqual(controller.pendingProcessingTaskCountForTesting, 3)

        await writer.resume(index: 0)
        try await waitForPendingProcessingTasks(controller, expectedCount: 2)
        XCTAssertTrue(controller.isProcessingForTesting)

        let barrierTask = Task { @MainActor in
            await controller.deactivateAndWaitForPendingWork()
            await completion.markFinished()
        }
        for _ in 0..<100 where controller.isProcessingForTesting {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(controller.isProcessingForTesting)
        let finishedWhileWritesWereBlocked = await completion.isFinished
        XCTAssertFalse(finishedWhileWritesWereBlocked)

        // Finishing the newest writer first must not let the barrier forget
        // the superseded generation that no longer owns the active slot.
        await writer.resume(index: 2)
        try await waitForPendingProcessingTasks(controller, expectedCount: 1)
        let finishedWhileOldWriteWasBlocked = await completion.isFinished
        XCTAssertFalse(finishedWhileOldWriteWasBlocked)

        await writer.resume(index: 1)
        await barrierTask.value
        XCTAssertEqual(controller.pendingProcessingTaskCountForTesting, 0)
        XCTAssertEqual(controller.pendingCheckpointRetryTaskCountForTesting, 0)
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertEqual(controller.metrics.fingerprintsPersisted, 0)
        XCTAssertEqual(controller.metrics.associationObservationsPersisted, 0)
    }

    private func waitForWriter(_ writer: SuspendedPlaceWriter, expectedCount: Int) async throws {
        for _ in 0..<200 {
            if await writer.requestCount == expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Place writer did not receive \(expectedCount) writes before timeout.")
    }

    private func waitForPendingProcessingTasks(
        _ controller: PlaceRecognitionController,
        expectedCount: Int
    ) async throws {
        for _ in 0..<200 {
            if controller.pendingProcessingTaskCountForTesting == expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Pending place tasks did not reach \(expectedCount) before timeout.")
    }

    private func makeController(
        channel: LatestValueChannel<ARSurfaceStateSnapshot>,
        store: RecordingPlaceStore,
        objects: [SpatialObjectMetadata],
        checkpoint: CheckpointCounter,
        existingMapAssociator: @escaping PlaceRecognitionController.ExistingMapAssociator = {
            _, _ in false
        },
        checkpointRetryInterval: Duration = .seconds(60)
    ) -> PlaceRecognitionController {
        PlaceRecognitionController(
            surfaces: channel.stream,
            objectMetadataProvider: { objects },
            catalogProvider: { try await store.catalog() },
            fingerprintWriter: { await store.writeFingerprint($0) },
            associationWriter: { await store.writeAssociation($0) },
            existingMapAssociator: existingMapAssociator,
            checkpointRetryInterval: checkpointRetryInterval,
            checkpointRequester: { checkpoint.increment() }
        )
    }

    private func waitForIdle(
        _ controller: PlaceRecognitionController,
        persistedFingerprints: UInt64? = nil,
        persistedAssociations: UInt64? = nil,
        receivedSnapshots: UInt64? = nil
    ) async throws {
        for _ in 0..<200 {
            let fingerprintReady =
                persistedFingerprints.map {
                    controller.metrics.fingerprintsPersisted >= $0
                } ?? true
            let associationReady =
                persistedAssociations.map {
                    controller.metrics.associationObservationsPersisted >= $0
                } ?? true
            let snapshotReady =
                receivedSnapshots.map {
                    controller.metrics.snapshotsReceived >= $0
                } ?? true
            if !controller.isProcessingForTesting, snapshotReady,
                case .failed(let message) = controller.state {
                throw PlaceControllerWaitError.failed(
                    message: message,
                    metrics: controller.metrics,
                    expectedAssociations: persistedAssociations
                )
            }
            if !controller.isProcessingForTesting && fingerprintReady && associationReady
                && snapshotReady
            {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PlaceControllerWaitError.timedOut(
            state: controller.state,
            metrics: controller.metrics,
            expectedAssociations: persistedAssociations,
            expectedSnapshots: receivedSnapshots,
            pendingTasks: controller.pendingProcessingTaskCountForTesting
        )
    }

    private func makeSnapshot(
        frameID: CoordinateFrameID,
        segmentID: CaptureSegmentID = CaptureSegmentID(),
        mapID: MapID?,
        revision: UInt64,
        timestamp: TimeInterval? = nil,
        includeWall: Bool = true,
        isCurrentSessionData: Bool = true
    ) -> ARSurfaceStateSnapshot {
        let planeID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let wallID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let transform = Matrix4x4Snapshot(matrix_identity_float4x4)
        let floor = ARPlaneObservationSnapshot(
            anchorID: planeID,
            transform: transform,
            center: .zero,
            extent: SIMD3<Float>(4, 0, 4),
            extentRotationOnYAxis: 0,
            boundaryVertices: [
                SIMD3<Float>(-2, 0, -2), SIMD3<Float>(2, 0, -2),
                SIMD3<Float>(2, 0, 2), SIMD3<Float>(-2, 0, 2),
            ],
            alignment: .horizontal,
            classification: .floor
        )
        let wall = ARPlaneObservationSnapshot(
            anchorID: wallID,
            transform: transform,
            center: SIMD3<Float>(0, 1.25, -2),
            extent: SIMD3<Float>(4, 0, 2.5),
            extentRotationOnYAxis: 0,
            boundaryVertices: [
                SIMD3<Float>(-2, 0, 0), SIMD3<Float>(2, 0, 0),
                SIMD3<Float>(2, 2.5, 0), SIMD3<Float>(-2, 2.5, 0),
            ],
            alignment: .vertical,
            classification: .wall
        )
        var planes = [planeID: floor]
        if includeWall {
            planes[wallID] = wall
        }
        return ARSurfaceStateSnapshot(
            coordinateFrameID: frameID,
            segmentID: segmentID,
            mapID: mapID,
            coordinateFrameStatus: .confirmed,
            revision: revision,
            timestamp: timestamp ?? Double(revision),
            planes: planes,
            meshes: [:],
            unresolvedFailures: [],
            isCurrentSessionData: isCurrentSessionData
        )
    }

    private func makeObject(
        frameID: CoordinateFrameID,
        mapID: MapID
    ) throws -> SpatialObjectMetadata {
        let position = try Vec3(x: 0.5, y: 0.4, z: 0.5)
        let object = try SpatialObject(
            semanticLabel: "chair",
            position: position,
            certainty: .confirmed,
            confidence: ConfidenceVector(
                semantic: .one,
                geometry: .one,
                tracking: .one,
                identity: .one,
                objectState: .one
            ),
            firstSeenAt: 1,
            lastSeenAt: 1
        )
        return try SpatialObjectMetadata(
            mapID: mapID,
            object: object,
            position: FramedPosition(
                coordinateFrameID: frameID,
                value: position,
                observedAt: 1,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            )
        )
    }

    private func makeObject(
        label: String,
        position: Vec3,
        frameID: CoordinateFrameID,
        mapID: MapID,
        presence: ObjectPresence = .visible
    ) throws -> SpatialObjectMetadata {
        let object = try SpatialObject(
            semanticLabel: label,
            position: position,
            certainty: .confirmed,
            presence: presence,
            confidence: ConfidenceVector(
                semantic: .one,
                geometry: .one,
                tracking: .one,
                identity: .one,
                objectState: .one
            ),
            firstSeenAt: 1,
            lastSeenAt: 1
        )
        return try SpatialObjectMetadata(
            mapID: mapID,
            object: object,
            position: FramedPosition(
                coordinateFrameID: frameID,
                value: position,
                observedAt: 1,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            )
        )
    }
}

private enum PlaceControllerWaitError: Error {
    case writeDidNotPause
    case newerSnapshotNotReceived
    case failed(message: String, metrics: PlaceRecognitionMetrics, expectedAssociations: UInt64?)
    case timedOut(
        state: PlaceRecognitionControllerState, metrics: PlaceRecognitionMetrics,
        expectedAssociations: UInt64?, expectedSnapshots: UInt64?, pendingTasks: Int
    )
}

private actor PlaceAssociationWriteReturnGate {
    private var pausesNextReturn = false
    private var continuation: CheckedContinuation<Void, Never>?

    var isPaused: Bool { continuation != nil }

    func pauseNextReturn() { pausesNextReturn = true }

    func waitAfterDurableWrite() async {
        guard pausesNextReturn else { return }
        pausesNextReturn = false
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private actor RecordingPlaceStore {
    private var fingerprints: [PlaceFingerprintRecord]
    private var associations: [PlaceAssociationStateRecord]
    private var reads: UInt64 = 0
    private var fingerprintWrites: UInt64 = 0
    private var associationWrites: UInt64 = 0

    init(
        fingerprints: [PlaceFingerprintRecord] = [],
        associations: [PlaceAssociationStateRecord] = []
    ) throws {
        _ = try PlaceMemoryCatalogSnapshot(
            fingerprints: fingerprints,
            associationStates: associations
        )
        self.fingerprints = fingerprints
        self.associations = associations
    }

    func catalog() throws -> PlaceMemoryCatalogSnapshot {
        reads &+= 1
        return try PlaceMemoryCatalogSnapshot(
            fingerprints: fingerprints,
            associationStates: associations
        )
    }

    func writeFingerprint(_ record: PlaceFingerprintRecord) {
        fingerprintWrites &+= 1
        fingerprints.removeAll { $0.mapID == record.mapID }
        fingerprints.append(record)
    }

    func writeAssociation(_ record: PlaceAssociationStateRecord) {
        associationWrites &+= 1
        associations.removeAll { $0.id == record.id }
        associations.append(record)
    }

    func catalogReadCount() -> UInt64 { reads }
    func fingerprintWriteCount() -> UInt64 { fingerprintWrites }
    func associationWriteCount() -> UInt64 { associationWrites }
    func fingerprint(mapID: MapID) -> PlaceFingerprint? {
        fingerprints.first { $0.mapID == mapID }?.fingerprint
    }
}

@MainActor
private final class CheckpointCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@MainActor
private final class ExistingMapAssociationRecorder {
    private let result: Bool
    private(set) var calls = 0
    private(set) var lastMapID: MapID?
    private(set) var lastCoordinateFrameID: CoordinateFrameID?

    init(result: Bool) {
        self.result = result
    }

    func record(mapID: MapID, coordinateFrameID: CoordinateFrameID) -> Bool {
        calls += 1
        lastMapID = mapID
        lastCoordinateFrameID = coordinateFrameID
        return result
    }
}

private actor LogicalMergeRecorder {
    private var commits: [LogicalMapMergeCommit] = []

    func write(_ commit: LogicalMapMergeCommit) {
        commits.append(commit)
    }

    func count() -> Int {
        commits.count
    }

    func snapshot() -> [LogicalMapMergeCommit] {
        commits
    }
}

private actor SuspendedPlaceWriter {
    private var continuations: [CheckedContinuation<Void, Error>] = []

    var requestCount: Int { continuations.count }

    func write() async throws {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(index: Int) {
        continuations[index].resume(returning: ())
    }
}

private actor PlaceDeletionBarrierCompletion {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}
