import CoreVideo
import VispaceCore
import XCTest
import simd

@testable import Vispace

@MainActor
final class UserObjectRegistrationControllerTests: XCTestCase {
    func testRawCenterDepthSavesNamedLastSeenPointAfterIndependentFrames() async throws {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let writer = RegistrationWriter()
        let controller = UserObjectRegistrationController(
            frameStreamProvider: { channel.stream }, confirmedIdentityProvider: { _ in identity },
            metadataWriter: { try await writer.write($0) }, monotonicNow: { 10.5 }
        )
        controller.activate()
        controller.start(name: "스피커")
        for (index, offset) in [0.0, 0.15, 0.31].enumerated() {
            channel.send(try frame(identity: identity, offset: offset))
            if index < 2 {
                try await waitUntil {
                    controller.state == .collecting(name: "스피커", sampleCount: index + 1)
                }
            }
        }
        try await waitUntil { if case .saved = controller.state { return true }; return false }
        guard case .saved(let saved) = controller.state else { return XCTFail("Expected saved metadata") }
        XCTAssertEqual(saved.object.semanticLabel, "user_registered_object")
        XCTAssertEqual(saved.object.displayName, "스피커")
        XCTAssertEqual(saved.object.presence, .lastSeen)
        XCTAssertNil(saved.object.bounds)
        XCTAssertNil(saved.object.detectorSemanticLabel)
        let records = await writer.values()
        XCTAssertEqual(records.count, 1)
        await controller.cancelAndWait()
    }

    func testTimeoutWorksWithoutAnyFrameArrival() async throws {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let controller = UserObjectRegistrationController(
            frameStreamProvider: { channel.stream }, confirmedIdentityProvider: { _ in nil },
            metadataWriter: { _ in XCTFail("No frame may produce no write") },
            timeout: .milliseconds(30)
        )
        controller.activate()
        controller.start(name: "스피커")
        try await waitUntil { if case .unavailable = controller.state { return true }; return false }
        await controller.cancelAndWait()
    }

    func testCancelAndWaitDrainsAnAlreadyStartedNoncooperativeWriteWithoutPublishingCompletion() async throws {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let gate = RegistrationWriteGate()
        let controller = UserObjectRegistrationController(
            frameStreamProvider: { channel.stream }, confirmedIdentityProvider: { _ in identity },
            metadataWriter: { await gate.write($0) }, monotonicNow: { 10.5 }
        )
        controller.activate()
        controller.start(name: "열쇠")
        try await offerThreeFrames(channel, identity: identity, controller: controller, name: "열쇠")
        try await waitUntil { controller.state == .saving }
        while !(await gate.hasStarted()) { await Task.yield() }
        let drained = RegistrationDrainFlag()
        controller.deactivate()
        let drainTask = Task { @MainActor in
            await controller.cancelAndWait()
            drained.value = true
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(drained.value, "Deletion must wait for the writer to finish")
        XCTAssertEqual(controller.state, .idle)
        await gate.release()
        await drainTask.value
        XCTAssertTrue(drained.value)
        XCTAssertEqual(controller.state, .idle, "Cancelled save must not publish stale success")
    }

    func testWriteFailureIsNotReportedAsSaved() async throws {
        let channel = LatestValueChannel<ARFrameSnapshot>()
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let controller = UserObjectRegistrationController(
            frameStreamProvider: { channel.stream }, confirmedIdentityProvider: { _ in identity },
            metadataWriter: { _ in throw RegistrationTestError.writeFailed }, monotonicNow: { 10.5 }
        )
        controller.activate()
        controller.start(name: "열쇠")
        try await offerThreeFrames(channel, identity: identity, controller: controller, name: "열쇠")
        try await waitUntil { if case .unavailable = controller.state { return true }; return false }
        await controller.cancelAndWait()
    }

    func testInactiveOrInvalidNameNeverSubscribesToFrames() {
        var subscriptions = 0
        let controller = UserObjectRegistrationController(
            frameStreamProvider: { subscriptions += 1; return AsyncStream { $0.finish() } },
            confirmedIdentityProvider: { _ in nil }, metadataWriter: { _ in }
        )
        controller.start(name: "스피커")
        controller.activate()
        controller.start(name: "")
        XCTAssertEqual(subscriptions, 0)
        guard case .unavailable = controller.state else { return XCTFail("Expected unavailable") }
    }

    func testReticleUsesInverseDisplayTransformAndRejectsMissingOrSingularGeometry() throws {
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let transformed = try frame(identity: identity, offset: 0,
            transform: CGAffineTransform(a: 2, b: 0, c: 0, d: 1, tx: 0, ty: 0))
        let sample = try XCTUnwrap(UserObjectRegistrationController.locateReticleSample(in: transformed))
        XCTAssertEqual(sample.depthPixel, SIMD2<Int>(2, 5))
        XCTAssertEqual(sample.source, .raw)
        XCTAssertNil(UserObjectRegistrationController.locateReticleSample(in:
            try frame(identity: identity, offset: 0, transform: nil)))
        XCTAssertNil(UserObjectRegistrationController.locateReticleSample(in:
            try frame(identity: identity, offset: 0,
                      transform: CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0))))
    }

    func testLowConfidenceOrSmoothedOnlyDepthCannotRegister() throws {
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        XCTAssertNil(UserObjectRegistrationController.locateReticleSample(in:
            try frame(identity: identity, offset: 0, confidence: 1)))
        XCTAssertNil(UserObjectRegistrationController.locateReticleSample(in:
            try frame(identity: identity, offset: 0, rawDepth: false)))
    }

    func testStaleAndFutureFramesCannotProduceARegistration() async throws {
        // Preserve every frame and their order so a dropped invalid frame
        // cannot make this freshness test pass without being examined.
        let channel = AsyncStream<ARFrameSnapshot>.makeStream(bufferingPolicy: .unbounded)
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let writer = RegistrationWriter()
        let controlFrame = try frame(identity: identity, offset: 0)
        var identityCheckedFrameIDs: [ARFrameID] = []
        let controller = UserObjectRegistrationController(
            frameStreamProvider: { channel.stream },
            confirmedIdentityProvider: {
                identityCheckedFrameIDs.append($0.pose.id)
                return identity
            },
            metadataWriter: { try await writer.write($0) },
            timeout: .seconds(30), monotonicNow: { 10.5 }
        )
        defer { channel.continuation.finish(); controller.cancel() }
        controller.activate()
        controller.start(name: "스피커")
        for offset in [-2.0, -1.8, -1.6, 1.0, 1.2, 1.4] {
            channel.continuation.yield(try frame(identity: identity, offset: offset))
        }
        channel.continuation.yield(controlFrame)
        // Reaching this final fresh frame proves all six earlier frames were
        // consumed. Also identify the control explicitly so an intermediate
        // invalid sampleCount == 1 cannot accidentally satisfy the barrier.
        try await waitUntil {
            identityCheckedFrameIDs.contains(controlFrame.pose.id)
                && controller.state == .collecting(name: "스피커", sampleCount: 1)
        }
        XCTAssertEqual(identityCheckedFrameIDs, [controlFrame.pose.id])
        let records = await writer.values()
        XCTAssertTrue(records.isEmpty)
        channel.continuation.finish()
        try await waitUntil { if case .unavailable = controller.state { return true }; return false }
        await controller.cancelAndWait()
    }

    private func offerThreeFrames(_ channel: LatestValueChannel<ARFrameSnapshot>,
                                   identity: ARCaptureIdentity,
                                   controller: UserObjectRegistrationController, name: String) async throws {
        for (index, offset) in [0.0, 0.15, 0.31].enumerated() {
            channel.send(try frame(identity: identity, offset: offset))
            if index < 2 {
                try await waitUntil { controller.state == .collecting(name: name, sampleCount: index + 1) }
            }
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for registration state")
        throw RegistrationTestError.timedOut
    }

    private func frame(identity: ARCaptureIdentity, offset: TimeInterval,
                       transform: CGAffineTransform? = .identity,
                       confidence: UInt8 = 2, rawDepth: Bool = true) throws -> ARFrameSnapshot {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 10, 10,
            kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let dimensions = ImageDimensions(width: 10, height: 10)
        let depth = ARDepthSnapshot(dimensions: dimensions,
            depthMeters: Array(repeating: 1, count: 100),
            confidence: Array(repeating: confidence, count: 100))
        return ARFrameSnapshot(
            pose: ARPoseSnapshot(id: ARFrameID(),
                sessionToken: ARSessionFrameToken(sessionRunGeneration: 1, attachmentEpoch: 1),
                coordinateFrameID: identity.coordinateFrameID, segmentID: identity.segmentID,
                mapID: identity.mapID, coordinateFrameStatus: identity.status,
                capturedAt: 1_000 + offset, timestamp: 10 + offset,
                cameraTransform: Matrix4x4Snapshot(matrix_identity_float4x4),
                trackingState: .normal, worldMappingStatus: .mapped),
            imageOrientation: .up, capturedImage: ImmutablePixelBuffer(pixelBuffer: try XCTUnwrap(pixelBuffer)),
            cameraIntrinsics: Matrix3x3Snapshot(simd_float3x3(
                SIMD3<Float>(100, 0, 0), SIMD3<Float>(0, 100, 0), SIMD3<Float>(5, 5, 1))),
            cameraImageDimensions: dimensions,
            displayTransform: transform.map { ARDisplayTransformSnapshot(imageToViewport: $0,
                geometry: FrameDisplayGeometry(orientation: .portrait,
                    viewportSize: ViewportSizeSnapshot(width: 100, height: 200))) },
            sceneDepth: rawDepth ? depth : nil,
            smoothedSceneDepth: depth
        )
    }
}

private enum RegistrationTestError: Error { case writeFailed, timedOut }

private actor RegistrationWriter {
    private var records: [SpatialObjectMetadata] = []
    func write(_ metadata: SpatialObjectMetadata) throws { records.append(metadata) }
    func values() -> [SpatialObjectMetadata] { records }
}

private actor RegistrationWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func write(_ metadata: SpatialObjectMetadata) async {
        await withCheckedContinuation { continuation = $0 }
    }
    func hasStarted() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class RegistrationDrainFlag { var value = false }
