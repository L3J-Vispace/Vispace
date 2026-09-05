import CoreVideo
import VispaceCore
import XCTest
import simd

@testable import Vispace

@MainActor
final class SpatialPerceptionControllerTests: XCTestCase {
    func testNewCadenceArrivalReleasesSupersededCameraBuffer() async throws {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = RecordingObjectDetector()
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(detector: detector, availability: .available),
            admissionPolicy: try FrameAdmissionPolicy(minimumStartInterval: 2, maximumFrameAge: 5),
            detectorInterval: 0.1,
            confirmedIdentityProvider: { _ in identity }, metadataWriter: { _ in }
        )
        controller.activate()
        defer { controller.deactivate() }
        channel.send(try makeSnapshot(identity: identity, runGeneration: 1))
        try await waitForDetector(detector, expectedCount: 1)
        try await waitForIdle(controller)
        channel.send(try makeSnapshot(identity: identity, runGeneration: 1))
        for _ in 0..<100 where controller.bufferedFrameCountForTesting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.bufferedFrameCountForTesting, 1)
        try await Task.sleep(for: .milliseconds(2_100))
        channel.send(try makeSnapshot(identity: identity, runGeneration: 1))
        try await waitForDetector(detector, expectedCount: 2)
        try await waitForIdle(controller)
        XCTAssertEqual(controller.bufferedFrameCountForTesting, 0)
        XCTAssertEqual(controller.metrics.framesSuperseded, 1)
        XCTAssertEqual(controller.metrics.framesStarted, 2)
    }

    func testDeactivateThenReactivateContinuesReceivingFrames() async throws {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = RecordingObjectDetector()
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(
                detector: detector,
                availability: .available
            ),
            confirmedIdentityProvider: { _ in identity },
            metadataWriter: { _ in }
        )

        controller.activate()
        XCTAssertNotEqual(
            channel.send(try makeSnapshot(identity: identity, runGeneration: 1)),
            .terminated
        )
        try await waitForDetector(detector, expectedCount: 1)

        controller.deactivate()
        XCTAssertNotEqual(
            channel.send(try makeSnapshot(identity: identity, runGeneration: 1)),
            .terminated
        )
        try await Task.sleep(for: .milliseconds(20))
        let inactiveCallCount = await detector.callCount()
        XCTAssertEqual(inactiveCallCount, 1)

        controller.activate()
        XCTAssertNotEqual(
            channel.send(try makeSnapshot(identity: identity, runGeneration: 2)),
            .terminated
        )
        try await waitForDetector(detector, expectedCount: 2)
        XCTAssertEqual(controller.metrics.framesStarted, 2)
        controller.deactivate()
    }

    func testUnavailableDetectorFailsHonestlyWithoutConsumingStream() throws {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(
                detector: NoOpObjectDetector(reason: "missing test model"),
                availability: .unavailable(reason: "missing test model")
            ),
            confirmedIdentityProvider: { _ in identity },
            metadataWriter: { _ in }
        )

        controller.activate()

        XCTAssertEqual(controller.state, .unavailable(reason: "missing test model"))
        XCTAssertFalse(controller.isDetectorAvailable)
    }

    func testObjectStaysMemoryOnlyUntilMapExistsThenPersistsAfterRepeatedEvidence() async throws {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = RecordingObjectDetector(detections: [makeDetection()])
        let writer = RecordingMetadataWriter()
        let mapID = MapID()
        var currentIdentity = ARCaptureIdentity(mapID: nil, status: .confirmed)
        let baseUptime = ProcessInfo.processInfo.systemUptime
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(
                detector: detector,
                availability: .available
            ),
            detectorInterval: 0.1,
            confirmedIdentityProvider: { _ in currentIdentity },
            metadataWriter: { metadata in
                try await writer.write(metadata)
            }
        )
        controller.activate()
        let baseTime = Date().timeIntervalSince1970

        channel.send(
            try makeSnapshot(
                identity: currentIdentity,
                runGeneration: 1,
                capturedAt: baseTime,
                timestamp: baseUptime,
                includesDepth: true
            )
        )
        try await waitForDetector(detector, expectedCount: 1)
        try await waitForIdle(controller)
        let initialAttemptCount = await writer.attemptCount()
        XCTAssertEqual(initialAttemptCount, 0)

        currentIdentity = ARCaptureIdentity(
            coordinateFrameID: currentIdentity.coordinateFrameID,
            segmentID: currentIdentity.segmentID,
            mapID: mapID,
            status: .confirmed
        )
        for index in 1...2 {
            channel.send(
                try makeSnapshot(
                    identity: currentIdentity,
                    runGeneration: 1,
                    capturedAt: baseTime + (Double(index) * 0.20),
                    timestamp: baseUptime + (Double(index) * 0.20),
                    includesDepth: true
                )
            )
            try await waitForDetector(detector, expectedCount: index + 1)
            try await waitForIdle(controller)
        }

        let stored = await writer.successfulMetadata()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.mapID, mapID)
        XCTAssertEqual(
            stored.first?.position.coordinateFrameID,
            currentIdentity.coordinateFrameID
        )
        XCTAssertEqual(stored.first?.object.lastSeenAt, baseTime + 0.40)
        XCTAssertEqual(controller.metrics.promotedObjects, 1)
        controller.deactivate()
    }

    func testTransientWriterFailureRetriesTheSamePromotedObjectID() async throws {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = RecordingObjectDetector(detections: [makeDetection()])
        let writer = RecordingMetadataWriter(failFirstAttempt: true)
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let baseUptime = ProcessInfo.processInfo.systemUptime
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(
                detector: detector,
                availability: .available
            ),
            detectorInterval: 0.1,
            confirmedIdentityProvider: { _ in identity },
            metadataWriter: { metadata in
                try await writer.write(metadata)
            }
        )
        controller.activate()
        let baseTime = Date().timeIntervalSince1970

        for index in 0..<3 {
            channel.send(
                try makeSnapshot(
                    identity: identity,
                    runGeneration: 1,
                    capturedAt: baseTime + (Double(index) * 0.20),
                    timestamp: baseUptime + (Double(index) * 0.20),
                    includesDepth: true
                )
            )
            try await waitForDetector(detector, expectedCount: index + 1)
            try await waitForIdle(controller)
        }
        let failedAttemptCount = await writer.attemptCount()
        let successfulBeforeRetry = await writer.successfulMetadata()
        XCTAssertEqual(failedAttemptCount, 1)
        XCTAssertTrue(successfulBeforeRetry.isEmpty)

        channel.send(
            try makeSnapshot(
                identity: identity,
                runGeneration: 1,
                capturedAt: baseTime + 0.60,
                timestamp: baseUptime + 0.60,
                includesDepth: true
            )
        )
        try await waitForDetector(detector, expectedCount: 4)
        try await waitForIdle(controller)

        let attemptedIDs = await writer.attemptedObjectIDs()
        let stored = await writer.successfulMetadata()
        XCTAssertEqual(attemptedIDs.count, 2)
        XCTAssertEqual(Set(attemptedIDs).count, 1)
        XCTAssertEqual(stored.map(\.object.id), [attemptedIDs[0]])
        XCTAssertEqual(controller.metrics.promotedObjects, 1)
        controller.deactivate()
    }

    func testDetectorSeedsTrackThenTrackerRunsBetweenDetectorPasses() async throws {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = RecordingObjectDetector(detections: [makeDetection()])
        let tracker = RecordingObjectTracker()
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(
                detector: detector,
                availability: .available
            ),
            tracker: tracker,
            detectorInterval: 10,
            confirmedIdentityProvider: { _ in identity },
            metadataWriter: { _ in }
        )
        controller.activate()
        let baseUptime = ProcessInfo.processInfo.systemUptime

        channel.send(
            try makeSnapshot(
                identity: identity,
                runGeneration: 1,
                timestamp: baseUptime
            )
        )
        try await waitForDetector(detector, expectedCount: 1)
        try await waitForIdle(controller)

        channel.send(
            try makeSnapshot(
                identity: identity,
                runGeneration: 1,
                timestamp: baseUptime + 0.20
            )
        )
        try await waitForTracker(tracker, expectedCount: 1)
        try await waitForIdle(controller)

        let detectorCount = await detector.callCount()
        let seedCount = await tracker.seedCount()
        XCTAssertEqual(detectorCount, 1)
        XCTAssertEqual(seedCount, 1)
        XCTAssertEqual(controller.latestDetections.map(\.label), ["chair"])
        controller.deactivate()
    }

    func testRepeatedObservationReusesExistingPersistentObjectIdentity() async throws {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = RecordingObjectDetector(detections: [makeDetection()])
        let writer = RecordingMetadataWriter()
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let existingChairID = ObjectID()
        let existing = [
            try makeExistingMetadata(
                id: existingChairID,
                label: "chair",
                position: Vec3(x: 0, y: 0, z: -2),
                identity: identity
            ),
            try makeExistingMetadata(
                id: ObjectID(),
                label: "table",
                position: Vec3(x: 1, y: 0, z: -2),
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
                try await writer.write(metadata)
            }
        )
        controller.activate()
        let baseUptime = ProcessInfo.processInfo.systemUptime
        let baseTime = Date().timeIntervalSince1970

        for index in 0..<3 {
            channel.send(
                try makeSnapshot(
                    identity: identity,
                    runGeneration: 1,
                    capturedAt: baseTime + (Double(index) * 0.20),
                    timestamp: baseUptime + (Double(index) * 0.20),
                    includesDepth: true
                )
            )
            try await waitForDetector(detector, expectedCount: index + 1)
            try await waitForIdle(controller)
        }

        let stored = await writer.successfulMetadata()
        XCTAssertEqual(stored.map(\.object.id), [existingChairID])
        XCTAssertEqual(controller.metrics.reidentifiedObjects, 1)
        XCTAssertEqual(controller.metrics.genuinelyNewObjects, 0)
        controller.deactivate()
    }

    func testDeletionBarrierJoinsSupersededAndCurrentMetadataWrites() async throws {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let detector = RecordingObjectDetector(detections: [makeDetection()])
        let writer = SuspendedMetadataWriter()
        let completion = PerceptionDeletionBarrierCompletion()
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let baseUptime = ProcessInfo.processInfo.systemUptime
        let baseTime = Date().timeIntervalSince1970
        let controller = SpatialPerceptionController(
            frames: channel.stream,
            detectorResolution: ObjectDetectorResolution(
                detector: detector,
                availability: .available
            ),
            detectorInterval: 0.1,
            confirmedIdentityProvider: { _ in identity },
            metadataWriter: { metadata in
                try await writer.write(metadata)
            }
        )

        controller.activate()
        for index in 0..<3 {
            channel.send(
                try makeSnapshot(
                    identity: identity,
                    runGeneration: 1,
                    capturedAt: baseTime + (Double(index) * 0.20),
                    timestamp: baseUptime + (Double(index) * 0.20),
                    includesDepth: true
                )
            )
            try await waitForDetector(detector, expectedCount: index + 1)
            if index < 2 {
                try await waitForIdle(controller)
            }
        }
        try await waitForWriter(writer, expectedCount: 1)

        controller.deactivate()
        XCTAssertFalse(controller.isProcessingForTesting)
        XCTAssertEqual(controller.pendingProcessingTaskCountForTesting, 1)

        controller.activate()
        for index in 0..<3 {
            channel.send(
                try makeSnapshot(
                    identity: identity,
                    runGeneration: 2,
                    capturedAt: baseTime + 1 + (Double(index) * 0.20),
                    timestamp: baseUptime + 1 + (Double(index) * 0.20),
                    includesDepth: true
                )
            )
            try await waitForDetector(detector, expectedCount: index + 4)
            if index < 2 {
                try await waitForIdle(controller)
            }
        }
        try await waitForWriter(writer, expectedCount: 2)
        XCTAssertTrue(controller.isProcessingForTesting)
        XCTAssertEqual(controller.pendingProcessingTaskCountForTesting, 2)

        let barrierTask = Task { @MainActor in
            await controller.deactivateAndWaitForPendingWork()
            await completion.markFinished()
        }
        for _ in 0..<100 where controller.isProcessingForTesting {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(controller.isProcessingForTesting)
        let finishedWhileBothWritesWereBlocked = await completion.isFinished
        XCTAssertFalse(finishedWhileBothWritesWereBlocked)

        await writer.resume(index: 0)
        try await waitForPendingProcessingTasks(controller, expectedCount: 1)
        let finishedWithCurrentWriteStillBlocked = await completion.isFinished
        XCTAssertFalse(finishedWithCurrentWriteStillBlocked)

        await writer.resume(index: 1)
        await barrierTask.value

        let finishedAfterEveryWriteUnwound = await completion.isFinished
        XCTAssertTrue(finishedAfterEveryWriteUnwound)
        XCTAssertEqual(controller.pendingProcessingTaskCountForTesting, 0)
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertTrue(controller.latestDetections.isEmpty)
        XCTAssertEqual(controller.metrics.promotedObjects, 0)
    }

    private func waitForDetector(
        _ detector: RecordingObjectDetector,
        expectedCount: Int
    ) async throws {
        for _ in 0..<100 {
            if await detector.callCount() == expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Detector did not receive \(expectedCount) frames before timeout.")
    }

    private func waitForIdle(_ controller: SpatialPerceptionController) async throws {
        for _ in 0..<100 where controller.isProcessingForTesting {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isProcessingForTesting)
        XCTAssertLessThanOrEqual(controller.bufferedFrameCountForTesting, 1)
    }

    private func waitForWriter(
        _ writer: SuspendedMetadataWriter,
        expectedCount: Int
    ) async throws {
        for _ in 0..<200 {
            if await writer.requestCount == expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Metadata writer did not receive \(expectedCount) writes before timeout.")
    }

    private func waitForPendingProcessingTasks(
        _ controller: SpatialPerceptionController,
        expectedCount: Int
    ) async throws {
        for _ in 0..<200 {
            if controller.pendingProcessingTaskCountForTesting == expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Pending perception tasks did not reach \(expectedCount) before timeout.")
    }

    private func waitForTracker(
        _ tracker: RecordingObjectTracker,
        expectedCount: Int
    ) async throws {
        for _ in 0..<100 {
            if await tracker.trackCount() == expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Tracker did not receive \(expectedCount) frames before timeout.")
    }

    private func makeDetection() -> DetectedObject {
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

    private func makeExistingMetadata(
        id: ObjectID,
        label: String,
        position: Vec3,
        identity: ARCaptureIdentity
    ) throws -> SpatialObjectMetadata {
        let object = try SpatialObject(
            id: id,
            semanticLabel: label,
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
            mapID: try XCTUnwrap(identity.mapID),
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

    private func makeSnapshot(
        identity: ARCaptureIdentity,
        runGeneration: UInt64,
        capturedAt: TimeInterval = Date().timeIntervalSince1970,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
        includesDepth: Bool = false
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
        XCTAssertEqual(status, kCVReturnSuccess)
        let image = try XCTUnwrap(pixelBuffer)
        let pose = ARPoseSnapshot(
            id: ARFrameID(),
            sessionToken: ARSessionFrameToken(
                sessionRunGeneration: runGeneration,
                attachmentEpoch: 1
            ),
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: identity.mapID,
            coordinateFrameStatus: .confirmed,
            capturedAt: capturedAt,
            timestamp: timestamp,
            cameraTransform: Matrix4x4Snapshot(matrix_identity_float4x4),
            trackingState: .normal,
            worldMappingStatus: .mapped
        )
        return ARFrameSnapshot(
            pose: pose,
            imageOrientation: .up,
            capturedImage: ImmutablePixelBuffer(pixelBuffer: image),
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
                ? ARDepthSnapshot(
                    dimensions: dimensions,
                    depthMeters: Array(repeating: 2, count: 100),
                    confidence: Array(
                        repeating: ARDepthConfidence.high.rawValue,
                        count: 100
                    )
                )
                : nil,
            smoothedSceneDepth: nil
        )
    }
}

private actor RecordingObjectDetector: ObjectDetector {
    private var receivedFrameIDs: [ARFrameID] = []
    private let detections: [DetectedObject]

    init(detections: [DetectedObject] = []) {
        self.detections = detections
    }

    func detect(in frame: ARFrameSnapshot) async throws -> [DetectedObject] {
        receivedFrameIDs.append(frame.pose.id)
        return detections
    }

    func callCount() -> Int {
        receivedFrameIDs.count
    }
}

private enum RecordingMetadataWriterError: Error {
    case simulatedFailure
}

private actor RecordingMetadataWriter {
    private let failFirstAttempt: Bool
    private var attempted: [SpatialObjectMetadata] = []
    private var successful: [SpatialObjectMetadata] = []

    init(failFirstAttempt: Bool = false) {
        self.failFirstAttempt = failFirstAttempt
    }

    func write(_ metadata: SpatialObjectMetadata) throws {
        attempted.append(metadata)
        if failFirstAttempt, attempted.count == 1 {
            throw RecordingMetadataWriterError.simulatedFailure
        }
        successful.append(metadata)
    }

    func attemptCount() -> Int {
        attempted.count
    }

    func attemptedObjectIDs() -> [ObjectID] {
        attempted.map(\.object.id)
    }

    func successfulMetadata() -> [SpatialObjectMetadata] {
        successful
    }
}

private actor RecordingObjectTracker: ObjectTracking {
    private var seeds: [TrackingSeed] = []
    private var trackedFrameCount = 0
    private var seededFrameCount = 0

    func seed(_ seeds: [TrackingSeed]) async {
        self.seeds = seeds
        seededFrameCount += 1
    }

    func track(in frame: ARFrameSnapshot) async throws -> [TrackedObject] {
        _ = frame
        trackedFrameCount += 1
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

    func seedCount() -> Int {
        seededFrameCount
    }

    func trackCount() -> Int {
        trackedFrameCount
    }
}

private actor SuspendedMetadataWriter {
    private var continuations: [CheckedContinuation<Void, Error>] = []

    var requestCount: Int {
        continuations.count
    }

    func write(_ metadata: SpatialObjectMetadata) async throws {
        _ = metadata
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(index: Int) {
        continuations[index].resume(returning: ())
    }
}

private actor PerceptionDeletionBarrierCompletion {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}
