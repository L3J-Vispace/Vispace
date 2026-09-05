import VispaceCore
import XCTest
import simd

@testable import Vispace

@MainActor
final class ARGuidanceControllerTests: XCTestCase {
    func testExplicitLastSeenMarkerAllowsUnchangedRemovedSourceRecord() async throws {
        let (stream, continuation) = AsyncStream<ARPoseSnapshot>.makeStream()
        let context = ContextFixture()
        let source = try context.metadata(presence: .removed)
        let controller = ARGuidanceController(poses: stream,
            sourceMetadataProvider: { _, _ in source }, nowProvider: { 10 })
        controller.activate()
        controller.show(try context.target(sourceMetadata: source, representsLastSeenLocation: true))
        continuation.yield(context.pose())
        for _ in 0..<25 {
            if controller.renderableWorldPosition != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNotNil(controller.renderableWorldPosition)
        XCTAssertTrue(controller.target?.representsLastSeenLocation == true)
        await controller.deactivateAndWaitForPendingWork()
    }

    func testTargetExpiresWithoutAnotherPose() async throws {
        let (stream, continuation) = AsyncStream<ARPoseSnapshot>.makeStream()
        let context = ContextFixture()
        let controller = ARGuidanceController(poses: stream, maximumTargetAge: 0.05, nowProvider: { 10 })
        var invalidations = 0
        controller.onTargetInvalidated = { invalidations += 1 }
        controller.activate()
        controller.show(try context.target())
        continuation.yield(context.pose())
        await settle()
        XCTAssertNotNil(controller.renderableWorldPosition)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertNil(controller.target)
        XCTAssertNil(controller.latestProjection)
        XCTAssertEqual(invalidations, 1)
        await controller.deactivateAndWaitForPendingWork()
    }

    func testRemovedMovedOrDegradedRecordRevokesMarkerWithoutPose() async throws {
        let context = ContextFixture()
        let source = try context.metadata()
        for change in 0..<3 {
            let (stream, continuation) = AsyncStream<ARPoseSnapshot>.makeStream()
            let records = GuidanceRecordStore(source)
            let controller = ARGuidanceController(poses: stream,
                sourceMetadataProvider: { _, _ in await records.current }, nowProvider: { 10 })
            controller.activate()
            controller.show(try context.target(sourceMetadata: source))
            continuation.yield(context.pose())
            for _ in 0..<50 {
                if controller.renderableWorldPosition != nil { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            XCTAssertNotNil(controller.renderableWorldPosition)
            if change == 0 {
                await records.set(nil)
            } else {
                await records.set(try context.metadata(
                    position: change == 1 ? Vec3(x: 1, y: 0, z: -2) : nil,
                    confidence: change == 2 ? 0.2 : 0.9
                ))
            }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertNil(controller.target)
            XCTAssertNil(controller.renderableWorldPosition)
            await controller.deactivateAndWaitForPendingWork()
        }
    }

    func testGuidesOnlyAfterConfirmedNormalPoseInExactContext() async throws {
        let (stream, continuation) = AsyncStream<ARPoseSnapshot>.makeStream()
        let context = ContextFixture()
        let controller = ARGuidanceController(poses: stream, nowProvider: { 11 })
        controller.activate()
        controller.show(try context.target())

        continuation.yield(context.pose(status: .newSegment, tracking: .normal))
        await settle()
        XCTAssertEqual(controller.state, .waitingForStableTracking)
        XCTAssertNil(controller.latestProjection)

        continuation.yield(context.pose(status: .confirmed, tracking: .normal))
        await settle()
        XCTAssertEqual(controller.state, .guiding)
        XCTAssertEqual(
            try XCTUnwrap(controller.latestProjection).distanceMeters,
            2,
            accuracy: 1e-12
        )
        XCTAssertEqual(controller.renderableWorldPosition, try Vec3(x: 0, y: 0, z: -2))
    }

    func testRejectsDifferentFrameSegmentAndMap() async throws {
        for mismatch in Mismatch.allCases {
            let (stream, continuation) = AsyncStream<ARPoseSnapshot>.makeStream()
            let context = ContextFixture()
            let controller = ARGuidanceController(poses: stream, nowProvider: { 11 })
            controller.activate()
            controller.show(try context.target())
            continuation.yield(context.pose(mismatch: mismatch))
            await settle()

            XCTAssertEqual(
                controller.state,
                .incompatibleCoordinateContext,
                "Expected \(mismatch) to fail closed"
            )
            XCTAssertNil(controller.latestProjection)
            controller.deactivate()
            continuation.finish()
        }
    }

    func testLimitedTrackingClearsPriorRenderablePosition() async throws {
        let (stream, continuation) = AsyncStream<ARPoseSnapshot>.makeStream()
        let context = ContextFixture()
        let controller = ARGuidanceController(poses: stream, nowProvider: { 11 })
        controller.activate()
        controller.show(try context.target())
        continuation.yield(context.pose(status: .confirmed, tracking: .normal))
        await settle()
        XCTAssertNotNil(controller.renderableWorldPosition)

        continuation.yield(
            context.pose(
                status: .confirmed,
                tracking: .limited(.excessiveMotion)
            )
        )
        await settle()
        XCTAssertEqual(controller.state, .waitingForStableTracking)
        XCTAssertNil(controller.latestProjection)
        XCTAssertNil(controller.renderableWorldPosition)
    }

    func testClearAndDeactivateCannotPublishBufferedPose() async throws {
        let (stream, continuation) = AsyncStream<ARPoseSnapshot>.makeStream()
        let context = ContextFixture()
        let controller = ARGuidanceController(poses: stream, nowProvider: { 11 })
        controller.activate()
        controller.show(try context.target())
        controller.clear()
        continuation.yield(context.pose())
        await settle()
        XCTAssertEqual(controller.state, .waitingForTarget)
        XCTAssertNil(controller.latestProjection)

        controller.show(try context.target())
        controller.deactivate()
        continuation.yield(context.pose())
        await settle()
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertNil(controller.latestProjection)
    }

    func testArrivalIsPublishedAtTarget() async throws {
        let (stream, continuation) = AsyncStream<ARPoseSnapshot>.makeStream()
        let context = ContextFixture(targetPosition: try Vec3(x: 0, y: 0, z: -0.2))
        let controller = ARGuidanceController(poses: stream, nowProvider: { 11 })
        controller.activate()
        controller.show(try context.target())
        continuation.yield(context.pose())
        await settle()

        XCTAssertEqual(controller.state, .arrived)
        XCTAssertTrue(try XCTUnwrap(controller.latestProjection).hasArrived)
    }

    func testTargetValidationRejectsUnsafeLabelsAndTimes() throws {
        let context = ContextFixture()
        XCTAssertThrowsError(try context.target(label: "   ")) {
            XCTAssertEqual($0 as? ARGuidanceTargetError, .emptySemanticLabel)
        }
        XCTAssertThrowsError(
            try context.target(
                label: String(repeating: "a", count: ARGuidanceTarget.maximumSemanticLabelLength + 1)
            )
        ) {
            XCTAssertEqual(
                $0 as? ARGuidanceTargetError,
                .semanticLabelTooLong(maximum: ARGuidanceTarget.maximumSemanticLabelLength)
            )
        }
        XCTAssertThrowsError(try context.target(resolvedAt: .nan)) {
            XCTAssertEqual($0 as? ARGuidanceTargetError, .invalidResolutionTime)
        }
    }

    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}

private enum Mismatch: CaseIterable {
    case frame
    case segment
    case map
}

private struct ContextFixture {
    let objectID = ObjectID()
    let frameID = CoordinateFrameID()
    let segmentID = CaptureSegmentID()
    let mapID = MapID()
    let targetPosition: Vec3

    init(targetPosition: Vec3 = try! Vec3(x: 0, y: 0, z: -2)) {
        self.targetPosition = targetPosition
    }

    func target(
        label: String = "sofa",
        resolvedAt: TimeInterval = 10,
        sourceMetadata: SpatialObjectMetadata? = nil,
        representsLastSeenLocation: Bool = false
    ) throws -> ARGuidanceTarget {
        try ARGuidanceTarget(
            objectID: objectID,
            semanticLabel: label,
            activeMapID: mapID,
            activeSegmentID: segmentID,
            position: FramedPosition(
                coordinateFrameID: frameID,
                value: targetPosition,
                observedAt: 9,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            ),
            confidenceGrade: .high,
            representsLastSeenLocation: representsLastSeenLocation,
            resolvedAt: resolvedAt,
            sourceMetadata: sourceMetadata
        )
    }

    func metadata(position: Vec3? = nil, confidence: Double = 0.9,
                  presence: ObjectPresence = .visible) throws -> SpatialObjectMetadata {
        let position = position ?? targetPosition
        return try SpatialObjectMetadata(
            mapID: mapID,
            object: SpatialObject(id: objectID, semanticLabel: "sofa", position: position,
                certainty: .confirmed, presence: presence, confidence: ConfidenceVector(
                    semantic: ConfidenceScore(clamping: confidence), geometry: ConfidenceScore(clamping: confidence)),
                firstSeenAt: 1, lastSeenAt: 9),
            position: FramedPosition(coordinateFrameID: frameID, value: position, observedAt: 9,
                trackingQuality: .normal, uncertainty: .highConfidenceDepth)
        )
    }

    func pose(
        status: ARCaptureIdentity.Status = .confirmed,
        tracking: ARTrackingStateSnapshot = .normal,
        mismatch: Mismatch? = nil
    ) -> ARPoseSnapshot {
        ARPoseSnapshot(
            id: ARFrameID(),
            sessionToken: ARSessionFrameToken(
                sessionRunGeneration: 1,
                attachmentEpoch: 1
            ),
            coordinateFrameID: mismatch == .frame ? CoordinateFrameID() : frameID,
            segmentID: mismatch == .segment ? CaptureSegmentID() : segmentID,
            mapID: mismatch == .map ? MapID() : mapID,
            coordinateFrameStatus: status,
            capturedAt: 11,
            timestamp: 1,
            cameraTransform: Matrix4x4Snapshot(matrix_identity_float4x4),
            trackingState: tracking,
            worldMappingStatus: .mapped
        )
    }
}

private actor GuidanceRecordStore {
    private(set) var current: SpatialObjectMetadata?
    init(_ current: SpatialObjectMetadata?) { self.current = current }
    func set(_ current: SpatialObjectMetadata?) { self.current = current }
}
