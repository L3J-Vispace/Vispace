import CoreVideo
import VispaceCore
import XCTest
import simd

@testable import Vispace

@MainActor
final class SpatialPerceptionTemporalMemoryTests: XCTestCase {
    func testNewlyStoredObjectKeepsOneIdentityAcrossRollingObservationsAndMovement() async throws {
        executionTimeAllowance = 60
        try await withNewObjectTemporalHarness(includesLandmark: true) { harness in
            let baseTime = Date().timeIntervalSince1970
            let baseUptime = ProcessInfo.processInfo.systemUptime
            var firstStored: SpatialObjectMetadata?
            let movementStart = 45
            let movement: Float = 0.205

            for index in 0..<48 {
                try await sendNewObjectFrame(
                    harness, index: index, baseTime: baseTime, baseUptime: baseUptime,
                    cameraOffsetX: index >= movementStart ? movement : 0
                )
                let storedObjects = await harness.store.objects()
                let chairs = storedObjects.filter { $0.object.semanticLabel == "chair" }
                if index < 2 {
                    XCTAssertTrue(chairs.isEmpty, "Fewer than three frames must not create an identity")
                    continue
                }
                XCTAssertEqual(chairs.count, 1, "Transient comparison IDs must never become extra durable objects")
                let current = try XCTUnwrap(chairs.first)
                if firstStored == nil { firstStored = current }
                let original = try XCTUnwrap(firstStored)
                XCTAssertEqual(current.object.id, original.object.id)
                XCTAssertEqual(current.object.firstSeenAt, original.object.firstSeenAt)
                if index < movementStart || index == 47 {
                    XCTAssertEqual(current.object.lastSeenAt, baseTime + Double(index) * 0.2)
                } else {
                    XCTAssertEqual(current.position.value, original.position.value,
                        "A single moved observation cannot bypass the temporal movement gate")
                }
            }

            let original = try XCTUnwrap(firstStored)
            let objects = await harness.store.objects()
            XCTAssertEqual(objects.count, 2)
            let latest = try XCTUnwrap(objects.first { $0.object.id == original.object.id })
            XCTAssertEqual(latest.position.value.x, original.position.value.x + Double(movement), accuracy: 0.000_001)
            let journalRecovery = try await harness.journal.recover(
                mapID: harness.identity.mapID!, coordinateFrameID: harness.identity.coordinateFrameID
            )
            let recovery = try XCTUnwrap(journalRecovery)
            XCTAssertEqual(recovery.snapshot.revision, 46)
            XCTAssertEqual(recovery.snapshot.metadata(for: latest.object.id), latest)
            let movedIDs = recovery.snapshot.recentDeltas.flatMap(\.changes).compactMap { change -> ObjectID? in
                if case .moved(let objectID, _, _, _, _) = change { return objectID }
                return nil
            }
            XCTAssertEqual(movedIDs, [original.object.id])

            let batches = await harness.recorder.batches()
            XCTAssertEqual(batches.count, 46)
            let firstObservation = try XCTUnwrap(batches.first?.observations.first)
            XCTAssertEqual(firstObservation.identityDecision, .genuinelyNew)
            for batch in batches.dropFirst() {
                let observation = try XCTUnwrap(batch.observations.first)
                guard case .confirmedExisting(let candidate) = observation.identityDecision else {
                    throw TemporalMemoryProcessorRecorderError.identityWasNotReconfirmed
                }
                XCTAssertEqual(candidate.objectID, original.object.id)
                XCTAssertGreaterThanOrEqual(candidate.geometryScore, ConfidencePolicy.default.highThreshold)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(candidate.spatialContextScore), ConfidencePolicy.default.highThreshold)
                XCTAssertEqual(batch.observations.count, 1)
                XCTAssertEqual(observation.metadata.object.id, original.object.id)
            }
            let finalEvidence = try XCTUnwrap(batches.last?.observations.first?.promotionEvidence)
            XCTAssertEqual(finalEvidence.observations.count, ObjectReidentificationPromotionEvidence.maximumObservationCount)
            XCTAssertEqual(Set(finalEvidence.frameIDs).count, finalEvidence.frameIDs.count)
            XCTAssertGreaterThan(finalEvidence.firstObservedAt, baseTime)
            XCTAssertEqual(finalEvidence.lastObservedAt, latest.object.lastSeenAt)
            XCTAssertEqual(harness.controller.metrics.promotedObjects, 1)
            XCTAssertEqual(harness.controller.metrics.genuinelyNewObjects, 1)
            XCTAssertNil(harness.controller.persistenceFailureMessage)
        }
    }

    func testNewlyStoredObjectDoesNotReuseTrackIdentityWithoutIndependentContext() async throws {
        executionTimeAllowance = 60
        try await withNewObjectTemporalHarness(includesLandmark: false) { harness in
            let baseTime = Date().timeIntervalSince1970
            let baseUptime = ProcessInfo.processInfo.systemUptime
            var firstStored: SpatialObjectMetadata?
            for index in 0..<12 {
                try await sendNewObjectFrame(harness, index: index, baseTime: baseTime, baseUptime: baseUptime)
                let objects = await harness.store.objects()
                if index == 2 { firstStored = try XCTUnwrap(objects.first) }
                if index >= 3 {
                    XCTAssertEqual(objects, [try XCTUnwrap(firstStored)],
                        "Repeated boxes and depth alone must not fabricate confirmedExisting evidence")
                }
            }
            let batches = await harness.recorder.batches()
            XCTAssertEqual(batches.count, 1)
            XCTAssertEqual(batches.first?.observations.first?.identityDecision, .genuinelyNew)
            XCTAssertGreaterThanOrEqual(harness.controller.metrics.ambiguousReidentifications, 9)
            XCTAssertEqual(harness.controller.metrics.promotedObjects, 1)
            XCTAssertNil(harness.controller.persistenceFailureMessage)
            let recovery = try await harness.journal.recover(
                mapID: harness.identity.mapID!, coordinateFrameID: harness.identity.coordinateFrameID
            )
            XCTAssertEqual(recovery?.snapshot.revision, 1)
            XCTAssertEqual(recovery?.snapshot.objects.count, 1)
        }
    }

    func testClockRollbackWarningSurvivesAFrameWithoutAStorageAttempt() async throws {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = TemporalSequenceObjectDetector(
            outputs: [[temporalDetection()], [temporalDetection()], [temporalDetection()], []]
        )
        let identity = ARCaptureIdentity(
            coordinateFrameID: temporalTestFrameID(81), segmentID: CaptureSegmentID(),
            mapID: temporalTestMapID(81), status: .confirmed
        )
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(detector: detector, availability: .available),
            detectorInterval: 0.1,
            confirmedIdentityProvider: { _ in identity }, metadataWriter: { _ in },
            temporalMemoryProcessor: { _, pose in
                throw TemporalSpatialMemoryError.outOfOrderTimestamp(
                    previous: pose.capturedAt + 3_600, incoming: pose.capturedAt
                )
            },
            processingBudgetProvider: { .normal }
        )
        controller.activate()
        defer { controller.deactivate() }
        let baseTime = Date().timeIntervalSince1970
        let baseUptime = ProcessInfo.processInfo.systemUptime
        for index in 0..<4 {
            channel.send(try temporalSnapshot(
                identity: identity, capturedAt: baseTime + Double(index) * 0.2,
                timestamp: baseUptime + Double(index) * 0.2, includesDepth: true
            ))
            try await waitForTemporalDetector(detector, expectedCount: index + 1)
            try await waitForTemporalIdle(controller)
            if index >= 2 {
                XCTAssertTrue(controller.persistenceFailureMessage?.contains("자동 설정") == true)
                XCTAssertEqual(controller.metrics.promotedObjects, 0)
            }
        }
        XCTAssertEqual(controller.state, .scanning)
        controller.resetPersistenceStatus()
        XCTAssertNil(controller.persistenceFailureMessage)
    }

    func testDeferredNewIdentityIsNotMarkedPersistedAndRetriesWithoutIdentityConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vispace-capacity-pipeline-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(82)
        let frameID = temporalTestFrameID(82)
        let identity = ARCaptureIdentity(
            coordinateFrameID: frameID, segmentID: CaptureSegmentID(),
            mapID: mapID, status: .confirmed
        )
        let existing = temporalTestMetadata(
            mapID: mapID, coordinateFrameID: frameID, objectID: temporalTestObjectID(82),
            at: 100, position: temporalTestPosition(10)
        )
        let store = TemporalControllerMetadataStore(document: SpatialMetadataDocument(
            maps: [temporalTestMapMetadata(mapID: mapID, coordinateFrameID: frameID)],
            objects: [existing]
        ))
        let journal = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let service = TemporalSpatialMemoryService(
            journalRepository: journal,
            policy: try TemporalSpatialMemoryPolicy(maximumObjectCount: 1),
            metadataProvider: { await store.snapshot() },
            metadataWriter: { await store.upsert($0) }
        )
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = TemporalSequenceObjectDetector(outputs: Array(repeating: [temporalDetection()], count: 4))
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(detector: detector, availability: .available),
            detectorInterval: 0.1, confirmedIdentityProvider: { _ in identity },
            metadataProvider: { await store.objects() }, metadataWriter: { _ in },
            temporalMemoryProcessor: { try await service.process($0, pose: $1) },
            processingBudgetProvider: { .normal }
        )
        controller.activate()
        defer { controller.deactivate() }
        let baseTime = Date().timeIntervalSince1970
        let baseUptime = ProcessInfo.processInfo.systemUptime
        for index in 0..<4 {
            channel.send(try temporalSnapshot(
                identity: identity, capturedAt: baseTime + Double(index) * 0.2,
                timestamp: baseUptime + Double(index) * 0.2, includesDepth: true
            ))
            try await waitForTemporalDetector(detector, expectedCount: index + 1)
            try await waitForTemporalIdle(controller)
        }
        let restored = try await service.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertEqual(restored.objects.count, 1)
        XCTAssertEqual(restored.revision, 2)
        XCTAssertEqual(controller.metrics.promotedObjects, 0)
        XCTAssertTrue(controller.objectCapacityReached)
        XCTAssertNil(controller.persistenceFailureMessage)
    }

    func testControllerProcessorSeamCommitsThroughTemporalServiceAndJournal()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vispace-controller-temporal-integration-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(59)
        let coordinateFrameID = temporalTestFrameID(59)
        let identity = ARCaptureIdentity(
            coordinateFrameID: coordinateFrameID,
            segmentID: CaptureSegmentID(rawValue: temporalTestUUID(959_000)),
            mapID: mapID,
            status: .confirmed
        )
        let store = TemporalControllerMetadataStore(
            document: SpatialMetadataDocument(
                maps: [
                    temporalTestMapMetadata(
                        mapID: mapID,
                        coordinateFrameID: coordinateFrameID,
                        number: 59
                    )
                ]
            )
        )
        let journal = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let service = TemporalSpatialMemoryService(
            journalRepository: journal,
            metadataProvider: {
                await store.snapshot()
            },
            metadataWriter: { metadata in
                await store.upsert(metadata)
            }
        )
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = TemporalSequenceObjectDetector(
            outputs: Array(repeating: [temporalDetection()], count: 3)
        )
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(
                detector: detector,
                availability: .available
            ),
            detectorInterval: 0.1,
            confirmedIdentityProvider: { _ in identity },
            metadataWriter: { _ in },
            temporalMemoryProcessor: { batch, pose in
                try await service.process(batch, pose: pose)
            }
        )
        controller.activate()
        defer { controller.deactivate() }

        let baseUptime = ProcessInfo.processInfo.systemUptime
        let baseTime = Date().timeIntervalSince1970
        for index in 0..<3 {
            channel.send(
                try temporalSnapshot(
                    identity: identity,
                    capturedAt: baseTime + Double(index) * 0.2,
                    timestamp: baseUptime + Double(index) * 0.2,
                    includesDepth: true
                )
            )
            try await waitForTemporalDetector(detector, expectedCount: index + 1)
            try await waitForTemporalIdle(controller)
        }

        let objects = await store.objects()
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects[0].object.lastSeenAt, baseTime + 0.4)
        let recovery = try await journal.recover(
            mapID: mapID,
            coordinateFrameID: coordinateFrameID
        )
        XCTAssertEqual(recovery?.snapshot.revision, 1)
        XCTAssertEqual(recovery?.snapshot.metadata(for: objects[0].object.id), objects[0])
        XCTAssertEqual(controller.metrics.promotedObjects, 1)
    }

    func testTemporalProcessorReceivesPromotedEvidenceReidentificationAndExactPose()
        async throws
    {
        let frameCount = 40
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = TemporalSequenceObjectDetector(
            outputs: Array(repeating: [temporalDetection()], count: frameCount)
        )
        let processor = TemporalMemoryProcessorRecorder()
        let directWriter = TemporalDirectWriterRecorder()
        let mapID = temporalTestMapID(60)
        let coordinateFrameID = temporalTestFrameID(60)
        let identity = ARCaptureIdentity(
            coordinateFrameID: coordinateFrameID,
            segmentID: CaptureSegmentID(rawValue: temporalTestUUID(960_000)),
            mapID: mapID,
            status: .confirmed
        )
        let existingChairID = temporalTestObjectID(60)
        let existing = [
            try temporalExistingMetadata(
                id: existingChairID,
                label: "chair",
                position: temporalTestPosition(),
                identity: identity
            ),
            try temporalExistingMetadata(
                id: temporalTestObjectID(61),
                label: "table",
                position: try Vec3(x: 1, y: 0, z: -2),
                identity: identity
            ),
        ]
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(
                detector: detector,
                availability: .available
            ),
            detectorInterval: 0.1,
            confirmedIdentityProvider: { _ in identity },
            metadataProvider: { existing },
            metadataWriter: { metadata in
                await directWriter.write(metadata)
            },
            temporalMemoryProcessor: { batch, pose in
                try await processor.process(batch, pose: pose)
            }
        )
        controller.activate()
        defer { controller.deactivate() }

        let baseUptime = ProcessInfo.processInfo.systemUptime
        let baseTime = Date().timeIntervalSince1970
        var frames: [ARFrameSnapshot] = []
        for index in 0..<3 {
            let frame = try temporalSnapshot(
                identity: identity,
                capturedAt: baseTime + Double(index) * 0.2,
                timestamp: baseUptime + Double(index) * 0.2,
                includesDepth: true
            )
            frames.append(frame)
            channel.send(frame)
            try await waitForTemporalDetector(detector, expectedCount: index + 1)
            try await waitForTemporalIdle(controller)
            if index < 2 {
                let callCount = await processor.callCount()
                XCTAssertEqual(callCount, 0, "One frame must never create a permanent ID")
            }
        }

        try await waitForTemporalProcessor(processor, expectedCount: 1)
        let calls = await processor.recordedCalls()
        let call = try XCTUnwrap(calls.first)
        let observation = try XCTUnwrap(call.batch.observations.first)
        XCTAssertEqual(call.pose, frames[2].pose)
        XCTAssertEqual(call.batch.id.rawValue, frames[2].pose.id.rawValue)
        XCTAssertEqual(call.batch.observations.count, 1)
        XCTAssertEqual(observation.metadata.object.id, existingChairID)
        XCTAssertNotNil(observation.metadata.object.bounds)
        XCTAssertEqual(
            Set(observation.promotionEvidence.frameIDs).count,
            ObjectReidentificationPromotionEvidence.minimumDistinctObservationCount
        )
        XCTAssertEqual(observation.promotionEvidence.lastObservedAt, frames[2].pose.capturedAt)
        guard case .confirmedExisting(let candidate) = observation.identityDecision else {
            return XCTFail("Expected the real persistent Re-ID decision")
        }
        XCTAssertEqual(candidate.objectID, existingChairID)
        XCTAssertEqual(call.batch.expectedVisibleObjectIDs, [existingChairID])
        let directWriteCount = await directWriter.writeCount()
        XCTAssertEqual(directWriteCount, 0)

        // Keep the established identity visible beyond the promoter's rolling
        // evidence capacity. Its first retained sample must advance while the
        // durable object's original firstSeenAt remains unchanged.
        for index in 3..<frameCount {
            let frame = try temporalSnapshot(
                identity: identity,
                capturedAt: baseTime + Double(index) * 0.2,
                timestamp: baseUptime + Double(index) * 0.2,
                includesDepth: true
            )
            frames.append(frame)
            channel.send(frame)
            try await waitForTemporalDetector(detector, expectedCount: index + 1)
            try await waitForTemporalIdle(controller)
        }

        let rollingCalls = await processor.recordedCalls()
        XCTAssertEqual(rollingCalls.count, frameCount - 2)
        for (index, rollingCall) in rollingCalls.enumerated() {
            let current = try XCTUnwrap(rollingCall.batch.observations.first)
            XCTAssertEqual(rollingCall.batch.observations.count, 1)
            XCTAssertEqual(current.metadata.object.id, existingChairID)
            XCTAssertEqual(current.metadata.object.firstSeenAt, existing[0].object.firstSeenAt)
            XCTAssertEqual(current.metadata.object.lastSeenAt, frames[index + 2].pose.capturedAt)
        }
        let lastObservation = try XCTUnwrap(rollingCalls.last?.batch.observations.first)
        let evidenceCapacity = ObjectReidentificationPromotionEvidence.maximumObservationCount
        XCTAssertEqual(lastObservation.promotionEvidence.observations.count, evidenceCapacity)
        XCTAssertEqual(
            lastObservation.promotionEvidence.firstObservedAt,
            frames[frameCount - evidenceCapacity].pose.capturedAt
        )
        XCTAssertEqual(lastObservation.metadata.object.lastSeenAt, frames[frameCount - 1].pose.capturedAt)
    }

    func testTrackerCadenceCannotCreateMissButEmptyDetectorPassCan() async throws {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = TemporalSequenceObjectDetector(
            outputs: [
                [temporalDetection()],
                [temporalDetection()],
                [temporalDetection()],
                [],
            ]
        )
        let tracker = TemporalRecordingObjectTracker()
        let processor = TemporalMemoryProcessorRecorder()
        let mapID = temporalTestMapID(62)
        let coordinateFrameID = temporalTestFrameID(62)
        let identity = ARCaptureIdentity(
            coordinateFrameID: coordinateFrameID,
            segmentID: CaptureSegmentID(rawValue: temporalTestUUID(962_000)),
            mapID: mapID,
            status: .confirmed
        )
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(
                detector: detector,
                availability: .available
            ),
            tracker: tracker,
            detectorInterval: 0.1,
            confirmedIdentityProvider: { _ in identity },
            metadataWriter: { _ in },
            temporalMemoryProcessor: { batch, pose in
                try await processor.process(batch, pose: pose)
            }
        )
        controller.activate()
        defer { controller.deactivate() }

        let baseUptime = ProcessInfo.processInfo.systemUptime
        let baseTime = Date().timeIntervalSince1970
        for index in 0..<3 {
            channel.send(
                try temporalSnapshot(
                    identity: identity,
                    capturedAt: baseTime + Double(index) * 0.2,
                    timestamp: baseUptime + Double(index) * 0.2,
                    includesDepth: true
                )
            )
            try await waitForTemporalDetector(detector, expectedCount: index + 1)
            try await waitForTemporalIdle(controller)
        }
        try await waitForTemporalProcessor(processor, expectedCount: 1)
        let initialCalls = await processor.recordedCalls()
        let initialCall = try XCTUnwrap(initialCalls.first)
        let persistentID = try XCTUnwrap(
            initialCall.batch.observations.first?.metadata.object.id
        )

        // Detector interval has not elapsed, so this is a tracker-only frame.
        // It must not manufacture negative detector coverage.
        channel.send(
            try temporalSnapshot(
                identity: identity,
                capturedAt: baseTime + 0.45,
                timestamp: baseUptime + 0.45,
                includesDepth: true
            )
        )
        try await waitForTemporalTracker(tracker, expectedCount: 1)
        try await waitForTemporalIdle(controller)
        let afterTrackerCount = await processor.callCount()
        XCTAssertEqual(afterTrackerCount, 1)

        // The next cadence-qualified frame executes the detector. Its empty
        // full-frame result and raw depth beyond the former object surface can
        // safely contribute one miss for the previously committed object.
        channel.send(
            try temporalSnapshot(
                identity: identity,
                capturedAt: baseTime + 0.65,
                timestamp: baseUptime + 0.65,
                includesDepth: true,
                rawDepth: temporalDepth(meters: 3)
            )
        )
        try await waitForTemporalDetector(detector, expectedCount: 4)
        try await waitForTemporalProcessor(processor, expectedCount: 2)
        try await waitForTemporalIdle(controller)

        let calls = await processor.recordedCalls()
        XCTAssertEqual(calls[1].batch.observations, [])
        XCTAssertEqual(calls[1].batch.expectedVisibleObjectIDs, [persistentID])
        XCTAssertEqual(calls[1].pose.capturedAt, baseTime + 0.65)
    }

    func testSameClassDetectorHitWithoutDepthDoesNotBecomeFalseMissingEvidence()
        async throws
    {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = TemporalSequenceObjectDetector(
            outputs: Array(repeating: [temporalDetection()], count: 4)
        )
        let processor = TemporalMemoryProcessorRecorder()
        let identity = ARCaptureIdentity(
            coordinateFrameID: temporalTestFrameID(63),
            segmentID: CaptureSegmentID(rawValue: temporalTestUUID(963_000)),
            mapID: temporalTestMapID(63),
            status: .confirmed
        )
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(
                detector: detector,
                availability: .available
            ),
            detectorInterval: 0.1,
            confirmedIdentityProvider: { _ in identity },
            metadataWriter: { _ in },
            temporalMemoryProcessor: { batch, pose in
                try await processor.process(batch, pose: pose)
            }
        )
        controller.activate()
        defer { controller.deactivate() }

        let baseUptime = ProcessInfo.processInfo.systemUptime
        let baseTime = Date().timeIntervalSince1970
        for index in 0..<3 {
            channel.send(
                try temporalSnapshot(
                    identity: identity,
                    capturedAt: baseTime + Double(index) * 0.2,
                    timestamp: baseUptime + Double(index) * 0.2,
                    includesDepth: true
                )
            )
            try await waitForTemporalDetector(detector, expectedCount: index + 1)
            try await waitForTemporalIdle(controller)
        }
        try await waitForTemporalProcessor(processor, expectedCount: 1)

        channel.send(
            try temporalSnapshot(
                identity: identity,
                capturedAt: baseTime + 0.6,
                timestamp: baseUptime + 0.6,
                includesDepth: false
            )
        )
        try await waitForTemporalDetector(detector, expectedCount: 4)
        try await waitForTemporalIdle(controller)
        let callCount = await processor.callCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertGreaterThan(controller.metrics.depthFailures, 0)
    }

    func testRestartAndForegroundReloadDurableObjectsForNegativeEvidence()
        async throws
    {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = TemporalSequenceObjectDetector(outputs: [[], []])
        let processor = TemporalMemoryProcessorRecorder()
        let identity = ARCaptureIdentity(
            coordinateFrameID: temporalTestFrameID(64),
            segmentID: CaptureSegmentID(rawValue: temporalTestUUID(964_000)),
            mapID: temporalTestMapID(64),
            status: .confirmed
        )
        let durableObject = try temporalExistingMetadata(
            id: temporalTestObjectID(64),
            label: "chair",
            position: temporalTestPosition(),
            identity: identity
        )
        let wrongMapIdentity = ARCaptureIdentity(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: temporalTestMapID(65),
            status: .confirmed
        )
        let wrongFrameIdentity = ARCaptureIdentity(
            coordinateFrameID: temporalTestFrameID(65),
            segmentID: identity.segmentID,
            mapID: identity.mapID,
            status: .confirmed
        )
        let ineligibleDurableObjects = [
            try temporalExistingMetadata(
                id: temporalTestObjectID(65),
                label: "lamp",
                position: temporalTestPosition(),
                identity: wrongMapIdentity
            ),
            try temporalExistingMetadata(
                id: temporalTestObjectID(66),
                label: "table",
                position: temporalTestPosition(),
                identity: wrongFrameIdentity
            ),
            try temporalExistingMetadata(
                id: temporalTestObjectID(67),
                label: "sofa",
                position: try Vec3(x: 0, y: 0, z: -9),
                identity: identity
            ),
            try temporalExistingMetadata(
                id: temporalTestObjectID(68),
                label: "shelf",
                position: temporalTestPosition(),
                identity: identity,
                presence: .removed
            ),
            try temporalExistingMetadata(
                id: temporalTestObjectID(69),
                label: "desk",
                position: temporalTestPosition(),
                identity: identity,
                certainty: .provisional
            ),
        ]
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(
                detector: detector,
                availability: .available
            ),
            detectorInterval: 0.1,
            confirmedIdentityProvider: { _ in identity },
            metadataProvider: { [durableObject] + ineligibleDurableObjects },
            metadataWriter: { _ in },
            temporalMemoryProcessor: { batch, pose in
                try await processor.process(batch, pose: pose)
            }
        )
        let baseUptime = ProcessInfo.processInfo.systemUptime
        let baseTime = Date().timeIntervalSince1970

        // A newly constructed controller has no current-session observation
        // cache. The first real detector frame must still load the durable
        // confirmed object and emit safe negative coverage.
        controller.activate()
        channel.send(
            try temporalSnapshot(
                identity: identity,
                capturedAt: baseTime,
                timestamp: baseUptime,
                includesDepth: true,
                rawDepth: temporalDepth(meters: 3)
            )
        )
        try await waitForTemporalDetector(detector, expectedCount: 1)
        try await waitForTemporalProcessor(processor, expectedCount: 1)
        try await waitForTemporalIdle(controller)

        controller.deactivate()
        controller.activate()

        // Foreground reactivation resets all temporal coverage caches. Durable
        // metadata must therefore be consulted again on the next detector pass.
        channel.send(
            try temporalSnapshot(
                identity: identity,
                capturedAt: baseTime + 0.2,
                timestamp: baseUptime + 0.2,
                includesDepth: true,
                rawDepth: temporalDepth(meters: 3)
            )
        )
        try await waitForTemporalDetector(detector, expectedCount: 2)
        try await waitForTemporalProcessor(processor, expectedCount: 2)
        try await waitForTemporalIdle(controller)
        controller.deactivate()

        let calls = await processor.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].batch.observations, [])
        XCTAssertEqual(calls[0].batch.expectedVisibleObjectIDs, [durableObject.object.id])
        XCTAssertEqual(calls[1].batch.observations, [])
        XCTAssertEqual(calls[1].batch.expectedVisibleObjectIDs, [durableObject.object.id])
    }

    func testNegativeEvidenceRequiresUnobstructedReliableRawDepthOnExactRay() async throws {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = TemporalSequenceObjectDetector(outputs: [])
        let processor = TemporalMemoryProcessorRecorder()
        let identity = ARCaptureIdentity(
            coordinateFrameID: temporalTestFrameID(80),
            segmentID: CaptureSegmentID(),
            mapID: temporalTestMapID(80),
            status: .confirmed
        )
        let stored = try temporalExistingMetadata(
            id: temporalTestObjectID(80), label: "chair",
            position: temporalTestPosition(), identity: identity
        )
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(detector: detector, availability: .available),
            detectorInterval: 0.1,
            confirmedIdentityProvider: { _ in identity },
            metadataProvider: { [stored] }, metadataWriter: { _ in },
            temporalMemoryProcessor: { batch, pose in
                try await processor.process(batch, pose: pose)
            }
        )
        controller.activate()
        defer { controller.deactivate() }
        var occluderDepths = Array(repeating: Float(3), count: 100)
        occluderDepths[55] = 1
        let exactRayOccluder = ARDepthSnapshot(
            dimensions: ImageDimensions(width: 10, height: 10),
            depthMeters: occluderDepths,
            confidence: Array(repeating: ARDepthConfidence.high.rawValue, count: 100)
        )
        let cases: [(String, ARDepthSnapshot?, ARDepthSnapshot?)] = [
            ("no depth", nil, nil),
            ("smoothed depth alone", nil, temporalDepth(meters: 3)),
            ("occluded", temporalDepth(meters: 1), nil),
            ("object surface remains", temporalDepth(meters: 2), nil),
            ("uncertainty margin", temporalDepth(meters: 2.05), nil),
            ("invalid raw with valid smoothed", temporalDepth(meters: .nan), temporalDepth(meters: 3)),
            ("infinite", temporalDepth(meters: .infinity), nil),
            ("zero", temporalDepth(meters: 0), nil),
            ("low confidence", temporalDepth(meters: 3, confidence: .low), nil),
            ("medium confidence", temporalDepth(meters: 3, confidence: .medium), nil),
            ("nearer raw overrides smoothed", temporalDepth(meters: 1), temporalDepth(meters: 3)),
            ("neighbors cannot hide center occluder", exactRayOccluder, nil),
            (
                "missing confidence",
                ARDepthSnapshot(
                    dimensions: ImageDimensions(width: 10, height: 10),
                    depthMeters: Array(repeating: 3, count: 100), confidence: nil
                ), nil
            ),
            (
                "malformed grid",
                ARDepthSnapshot(
                    dimensions: ImageDimensions(width: 10, height: 10),
                    depthMeters: [3], confidence: [ARDepthConfidence.high.rawValue]
                ), nil
            ),
        ]
        let baseTime = Date().timeIntervalSince1970
        let baseUptime = ProcessInfo.processInfo.systemUptime
        for (index, fixture) in cases.enumerated() {
            channel.send(
                try temporalSnapshot(
                    identity: identity, capturedAt: baseTime + Double(index) * 0.2,
                    timestamp: baseUptime + Double(index) * 0.2,
                    includesDepth: fixture.1 != nil, rawDepth: fixture.1, smoothedDepth: fixture.2
                ))
            try await waitForTemporalDetector(detector, expectedCount: index + 1)
            try await waitForTemporalIdle(controller)
            let calls = await processor.callCount()
            XCTAssertEqual(calls, 0, fixture.0)
        }
        channel.send(
            try temporalSnapshot(
                identity: identity, capturedAt: baseTime + Double(cases.count) * 0.2,
                timestamp: baseUptime + Double(cases.count) * 0.2, includesDepth: true,
                rawDepth: temporalDepth(meters: 3), smoothedDepth: temporalDepth(meters: 1)
            ))
        try await waitForTemporalDetector(detector, expectedCount: cases.count + 1)
        try await waitForTemporalProcessor(processor, expectedCount: 1)
        try await waitForTemporalIdle(controller)
        let calls = await processor.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.batch.expectedVisibleObjectIDs, [stored.object.id])
        XCTAssertTrue(calls.first?.batch.observations.isEmpty == true)
    }

    private func withNewObjectTemporalHarness(
        includesLandmark: Bool,
        body: @MainActor (NewObjectTemporalHarness) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vispace-new-object-reobservation-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let landmarks = includesLandmark ? [try temporalExistingMetadata(
            id: ObjectID(), label: "table", position: Vec3(x: 1, y: 0, z: -2), identity: identity
        )] : []
        let store = TemporalControllerMetadataStore(document: SpatialMetadataDocument(
            maps: [temporalTestMapMetadata(mapID: identity.mapID!, coordinateFrameID: identity.coordinateFrameID)],
            objects: landmarks
        ))
        let journal = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let service = TemporalSpatialMemoryService(
            journalRepository: journal,
            metadataProvider: { await store.snapshot() }, metadataWriter: { await store.upsert($0) }
        )
        let recorder = TemporalCommittedBatchRecorder()
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = TemporalSequenceObjectDetector(outputs: Array(repeating: [temporalDetection()], count: 48))
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(detector: detector, availability: .available),
            detectorInterval: 0.1, confirmedIdentityProvider: { _ in identity },
            metadataProvider: { await store.objects() }, metadataWriter: { _ in },
            temporalMemoryProcessor: { batch, pose in
                let result = try await service.process(batch, pose: pose)
                await recorder.record(batch)
                return result
            }, processingBudgetProvider: { .normal }
        )
        let harness = NewObjectTemporalHarness(
            identity: identity, channel: channel, detector: detector, controller: controller,
            store: store, journal: journal, recorder: recorder
        )
        controller.activate()
        do {
            try await body(harness)
        } catch {
            await controller.deactivateAndWaitForPendingWork()
            throw error
        }
        await controller.deactivateAndWaitForPendingWork()
    }

    private func sendNewObjectFrame(
        _ harness: NewObjectTemporalHarness, index: Int, baseTime: TimeInterval,
        baseUptime: TimeInterval, cameraOffsetX: Float = 0
    ) async throws {
        var transform = matrix_identity_float4x4
        transform.columns.3.x = cameraOffsetX
        harness.channel.send(try temporalSnapshot(
            identity: harness.identity, capturedAt: baseTime + Double(index) * 0.2,
            timestamp: baseUptime + Double(index) * 0.2, includesDepth: true,
            cameraTransform: transform
        ))
        while await harness.detector.callCount() < index + 1 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        await harness.controller.waitForProcessingCompletionForTesting()
        try Task.checkCancellation()
        if case .failed(let message) = harness.controller.state {
            throw TemporalMemoryProcessorRecorderError.processingFailed(frame: index + 1, message: message)
        }
        let count = await harness.detector.callCount()
        XCTAssertEqual(count, index + 1)
        XCTAssertEqual(harness.controller.pendingProcessingTaskCountForTesting, 0)
    }

    private func waitForTemporalDetector(
        _ detector: TemporalSequenceObjectDetector,
        expectedCount: Int
    ) async throws {
        for _ in 0..<100 {
            if await detector.callCount() == expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Detector did not receive \(expectedCount) frames.")
    }

    private func waitForTemporalProcessor(
        _ processor: TemporalMemoryProcessorRecorder,
        expectedCount: Int
    ) async throws {
        for _ in 0..<100 {
            if await processor.callCount() == expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Temporal processor did not receive \(expectedCount) batches.")
    }

    private func waitForTemporalTracker(
        _ tracker: TemporalRecordingObjectTracker,
        expectedCount: Int
    ) async throws {
        for _ in 0..<100 {
            if await tracker.trackCount() == expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Tracker did not receive \(expectedCount) frames.")
    }

    private func waitForTemporalIdle(
        _ controller: SpatialPerceptionController
    ) async throws {
        for _ in 0..<100 where controller.isProcessingForTesting {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isProcessingForTesting)
    }
}

private struct TemporalMemoryProcessorCall: Sendable {
    let batch: TemporalSpatialRecognitionBatch
    let pose: ARPoseSnapshot
}

private enum TemporalMemoryProcessorRecorderError: Error {
    case missingMap
    case identityWasNotReconfirmed
    case processingFailed(frame: Int, message: String)
}

private struct NewObjectTemporalHarness: Sendable {
    let identity: ARCaptureIdentity
    let channel: LatestValueChannel<ARFrameSnapshot>
    let detector: TemporalSequenceObjectDetector
    let controller: SpatialPerceptionController
    let store: TemporalControllerMetadataStore
    let journal: TemporalSpatialMemoryJournalRepository
    let recorder: TemporalCommittedBatchRecorder
}

private actor TemporalCommittedBatchRecorder {
    private var recorded: [TemporalSpatialRecognitionBatch] = []
    func record(_ batch: TemporalSpatialRecognitionBatch) { recorded.append(batch) }
    func batches() -> [TemporalSpatialRecognitionBatch] { recorded }
}

private actor TemporalMemoryProcessorRecorder {
    private var calls: [TemporalMemoryProcessorCall] = []
    private var metadataByObjectID: [ObjectID: SpatialObjectMetadata] = [:]

    func process(
        _ batch: TemporalSpatialRecognitionBatch,
        pose: ARPoseSnapshot
    ) throws -> TemporalSpatialMemoryServiceResult {
        guard let mapID = pose.mapID else {
            throw TemporalMemoryProcessorRecorderError.missingMap
        }
        calls.append(TemporalMemoryProcessorCall(batch: batch, pose: pose))
        for observation in batch.observations {
            metadataByObjectID[observation.metadata.object.id] = observation.metadata
        }
        let coordinator = try TemporalSpatialMemoryCoordinator(
            mapID: mapID,
            coordinateFrameID: pose.coordinateFrameID,
            restoringDurableObjects: metadataByObjectID.values.sorted {
                $0.object.id < $1.object.id
            }
        )
        return .alreadyProcessed(coordinator.snapshot)
    }

    func callCount() -> Int {
        calls.count
    }

    func recordedCalls() -> [TemporalMemoryProcessorCall] {
        calls
    }
}

private actor TemporalControllerMetadataStore {
    private var document: SpatialMetadataDocument

    init(document: SpatialMetadataDocument) {
        self.document = document
    }

    func snapshot() -> SpatialMetadataDocument {
        document
    }

    func upsert(_ metadata: SpatialObjectMetadata) {
        if let index = document.objects.firstIndex(where: {
            $0.mapID == metadata.mapID && $0.object.id == metadata.object.id
        }) {
            document.objects[index] = metadata
        } else {
            document.objects.append(metadata)
        }
    }

    func objects() -> [SpatialObjectMetadata] {
        document.objects
    }
}

private actor TemporalDirectWriterRecorder {
    private var writes: [SpatialObjectMetadata] = []

    func write(_ metadata: SpatialObjectMetadata) {
        writes.append(metadata)
    }

    func writeCount() -> Int {
        writes.count
    }
}

private actor TemporalSequenceObjectDetector: ObjectDetector {
    private let outputs: [[DetectedObject]]
    private var invocationCount = 0

    init(outputs: [[DetectedObject]]) {
        self.outputs = outputs
    }

    func detect(in frame: ARFrameSnapshot) async throws -> [DetectedObject] {
        _ = frame
        let index = invocationCount
        invocationCount += 1
        guard index < outputs.count else {
            return []
        }
        return outputs[index]
    }

    func callCount() -> Int {
        invocationCount
    }
}

private actor TemporalRecordingObjectTracker: ObjectTracking {
    private var seeds: [TrackingSeed] = []
    private var invocations = 0

    func seed(_ seeds: [TrackingSeed]) async {
        self.seeds = seeds
    }

    func track(in frame: ARFrameSnapshot) async throws -> [TrackedObject] {
        _ = frame
        invocations += 1
        return seeds.map {
            TrackedObject(
                id: $0.id,
                confidence: 0.95,
                boundingBox: $0.boundingBox
            )
        }
    }

    func reset() async {
        seeds = []
    }

    func trackCount() -> Int {
        invocations
    }
}

private func temporalDetection() -> DetectedObject {
    DetectedObject(
        label: "chair",
        confidence: 0.95,
        boundingBox: NormalizedBoundingBox(
            x: 0.1,
            y: 0.1,
            width: 0.8,
            height: 0.8
        )
    )
}

private func temporalExistingMetadata(
    id: ObjectID,
    label: String,
    position: Vec3,
    identity: ARCaptureIdentity,
    presence: ObjectPresence = .visible,
    certainty: ObjectCertainty = .confirmed
) throws -> SpatialObjectMetadata {
    guard let mapID = identity.mapID else {
        throw TemporalMemoryProcessorRecorderError.missingMap
    }
    let object = try SpatialObject(
        id: id,
        semanticLabel: label,
        position: position,
        certainty: certainty,
        presence: presence,
        confidence: temporalTestVector(),
        firstSeenAt: 1,
        lastSeenAt: 1
    )
    return try SpatialObjectMetadata(
        mapID: mapID,
        object: object,
        position: FramedPosition(
            coordinateFrameID: identity.coordinateFrameID,
            value: position,
            observedAt: 1,
            trackingQuality: .normal,
            uncertainty: .highConfidenceDepth
        )
    )
}

private func temporalSnapshot(
    identity: ARCaptureIdentity,
    capturedAt: TimeInterval,
    timestamp: TimeInterval,
    includesDepth: Bool,
    rawDepth: ARDepthSnapshot? = nil,
    smoothedDepth: ARDepthSnapshot? = nil,
    cameraTransform: simd_float4x4 = matrix_identity_float4x4
) throws -> ARFrameSnapshot {
    let dimensions = ImageDimensions(width: 10, height: 10)
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        dimensions.width,
        dimensions.height,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw TemporalMemoryProcessorRecorderError.missingMap
    }
    let pose = ARPoseSnapshot(
        id: ARFrameID(),
        sessionToken: ARSessionFrameToken(
            sessionRunGeneration: 1,
            attachmentEpoch: 1
        ),
        coordinateFrameID: identity.coordinateFrameID,
        segmentID: identity.segmentID,
        mapID: identity.mapID,
        coordinateFrameStatus: .confirmed,
        capturedAt: capturedAt,
        timestamp: timestamp,
        cameraTransform: Matrix4x4Snapshot(cameraTransform),
        trackingState: .normal,
        worldMappingStatus: .mapped
    )
    return ARFrameSnapshot(
        pose: pose,
        imageOrientation: .up,
        capturedImage: ImmutablePixelBuffer(pixelBuffer: pixelBuffer),
        cameraIntrinsics: Matrix3x3Snapshot(
            simd_float3x3(
                SIMD3<Float>(100, 0, 0),
                SIMD3<Float>(0, 100, 0),
                SIMD3<Float>(5, 5, 1)
            )
        ),
        cameraImageDimensions: dimensions,
        displayTransform: nil,
        sceneDepth: includesDepth
            ? rawDepth
                ?? ARDepthSnapshot(
                    dimensions: dimensions,
                    depthMeters: Array(repeating: 2, count: 100),
                    confidence: Array(
                        repeating: ARDepthConfidence.high.rawValue,
                        count: 100
                    )
                )
            : nil,
        smoothedSceneDepth: smoothedDepth
    )
}

private func temporalDepth(
    meters: Float,
    confidence: ARDepthConfidence = .high
) -> ARDepthSnapshot {
    ARDepthSnapshot(
        dimensions: ImageDimensions(width: 10, height: 10),
        depthMeters: Array(repeating: meters, count: 100),
        confidence: Array(repeating: confidence.rawValue, count: 100)
    )
}
