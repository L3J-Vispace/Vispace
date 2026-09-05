import CoreVideo
import VispaceCore
import XCTest
import simd

@testable import Vispace

final class ObjectDepthLocatorTests: XCTestCase {
    private let imageDimensions = ImageDimensions(width: 10, height: 10)
    private let intrinsics = simd_float3x3(
        SIMD3<Float>(100, 0, 0),
        SIMD3<Float>(0, 100, 0),
        SIMD3<Float>(5, 5, 1)
    )

    func testCoherentSamplesProduceLocatedObjectAndPreserveCaptureWallClock() throws {
        let capturedAt = 1_725_000_123.456
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let snapshot = try makeSnapshot(
            identity: identity,
            capturedAt: capturedAt,
            timestamp: 42,
            depthMeters: Array(repeating: 2, count: 100)
        )

        let result = makeLocator().locate(
            makeDetection(),
            in: snapshot,
            currentIdentity: identity
        )

        guard case .located(let located) = result else {
            return XCTFail("Expected a coherent five-sample depth cluster, received \(result).")
        }
        XCTAssertEqual(located.supportingSampleCount, 5)
        XCTAssertEqual(located.depthSource, .raw)
        XCTAssertEqual(located.position.coordinateFrameID, identity.coordinateFrameID)
        XCTAssertEqual(located.position.observedAt, capturedAt)
        XCTAssertNotEqual(located.position.observedAt, snapshot.pose.timestamp)
        XCTAssertEqual(located.position.trackingQuality, .normal)
        XCTAssertEqual(located.position.uncertainty, .highConfidenceDepth)
        XCTAssertEqual(located.position.value.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(located.position.value.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(located.position.value.z, -2, accuracy: 0.000_001)
        XCTAssertEqual(located.boundingBox, try makeCoreBoundingBox())
        XCTAssertGreaterThanOrEqual(located.geometryConfidence.value, 0.8)
        XCTAssertLessThanOrEqual(located.bounds.min.x, located.position.value.x)
        XCTAssertLessThanOrEqual(located.bounds.min.y, located.position.value.y)
        XCTAssertLessThanOrEqual(located.bounds.min.z, located.position.value.z)
        XCTAssertGreaterThanOrEqual(located.bounds.max.x, located.position.value.x)
        XCTAssertGreaterThanOrEqual(located.bounds.max.y, located.position.value.y)
        XCTAssertGreaterThanOrEqual(located.bounds.max.z, located.position.value.z)
        XCTAssertGreaterThan(located.bounds.max.x - located.bounds.min.x, 0.1)
        XCTAssertGreaterThan(located.bounds.max.y - located.bounds.min.y, 0.1)
        XCTAssertGreaterThan(located.bounds.max.z - located.bounds.min.z, 0.1)
    }

    func testOutlierIsRejectedAndRepresentativeIsAnObservedMedoid() throws {
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        var depths = Array(repeating: Float.nan, count: 100)
        // Sample order for the test box is center, top-left, top-right,
        // bottom-left, bottom-right. The center is a distant background point,
        // three foreground samples form a coherent cluster, and the final hole
        // has no depth. The unique medoid is the 2.0 m top-right sample.
        depths[index(x: 5, y: 5)] = 8
        depths[index(x: 3, y: 3)] = 1.9
        depths[index(x: 6, y: 3)] = 2.0
        depths[index(x: 3, y: 6)] = 2.1

        let snapshot = try makeSnapshot(
            identity: identity,
            intrinsics: simd_float3x3(
                SIMD3<Float>(1_000, 0, 0),
                SIMD3<Float>(0, 1_000, 0),
                SIMD3<Float>(5, 5, 1)
            ),
            depthMeters: depths
        )
        let locator = ObjectDepthLocator(
            policy: ObjectDepthLocatorPolicy(
                minimumValidSamples: 2,
                maximumWorldSpread: 0.25
            ),
            depthSampler: ARDepthSampler(neighborhoodRadius: 0)
        )

        let result = locator.locate(
            makeDetection(),
            in: snapshot,
            currentIdentity: identity
        )

        guard case .located(let located) = result else {
            return XCTFail("Expected the foreground cluster to survive, received \(result).")
        }
        XCTAssertEqual(located.supportingSampleCount, 3)
        XCTAssertEqual(located.position.value.x, 0.002, accuracy: 0.000_001)
        XCTAssertEqual(located.position.value.y, 0.004, accuracy: 0.000_001)
        XCTAssertEqual(located.position.value.z, -2, accuracy: 0.000_001)
        XCTAssertNotEqual(located.position.value.z, -8)
    }

    func testInsufficientValidDepthFailsWithExactSampleCount() throws {
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        var depths = Array(repeating: Float.nan, count: 100)
        depths[index(x: 5, y: 5)] = 2
        let snapshot = try makeSnapshot(identity: identity, depthMeters: depths)

        let result = makeLocator().locate(
            makeDetection(),
            in: snapshot,
            currentIdentity: identity
        )

        XCTAssertEqual(
            result,
            .unavailable(.insufficientDepthSamples(required: 2, actual: 1))
        )
    }

    func testRepeatedReadsOfOneDepthTexelCountAsOneSample() throws {
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let snapshot = try makeSnapshot(
            identity: identity,
            depthDimensions: ImageDimensions(width: 1, height: 1),
            depthMeters: [2]
        )

        XCTAssertEqual(
            makeLocator().locate(
                makeDetection(),
                in: snapshot,
                currentIdentity: identity
            ),
            .unavailable(.insufficientDepthSamples(required: 2, actual: 1))
        )
    }

    func testInvalidBoundingBoxFailsBeforeDepthSampling() throws {
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let snapshot = try makeSnapshot(
            identity: identity,
            depthMeters: Array(repeating: 2, count: 100)
        )
        let invalidDetection = DetectedObject(
            label: "chair",
            confidence: 0.9,
            boundingBox: NormalizedBoundingBox(
                x: 0.9,
                y: 0.1,
                width: 0.2,
                height: 0.2
            )
        )

        XCTAssertEqual(
            makeLocator().locate(
                invalidDetection,
                in: snapshot,
                currentIdentity: identity
            ),
            .unavailable(.invalidBoundingBox)
        )
    }

    func testIdentityMismatchCannotProduceCoordinates() throws {
        let frameIdentity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let currentIdentity = ARCaptureIdentity(
            coordinateFrameID: frameIdentity.coordinateFrameID,
            segmentID: CaptureSegmentID(),
            mapID: frameIdentity.mapID,
            status: .confirmed
        )
        let snapshot = try makeSnapshot(
            identity: frameIdentity,
            depthMeters: Array(repeating: 2, count: 100)
        )

        XCTAssertEqual(
            makeLocator().locate(
                makeDetection(),
                in: snapshot,
                currentIdentity: currentIdentity
            ),
            .unavailable(.identityMismatch)
        )
    }

    private func makeLocator() -> ObjectDepthLocator {
        ObjectDepthLocator(
            policy: ObjectDepthLocatorPolicy(
                minimumValidSamples: 2,
                maximumWorldSpread: 0.30
            ),
            depthSampler: ARDepthSampler(neighborhoodRadius: 0)
        )
    }

    private func makeDetection() -> DetectedObject {
        DetectedObject(
            label: "chair",
            confidence: 0.9,
            boundingBox: NormalizedBoundingBox(
                x: 0.1,
                y: 0.1,
                width: 0.8,
                height: 0.8
            )
        )
    }

    private func makeCoreBoundingBox() throws -> NormalizedBoundingBox2D {
        try NormalizedBoundingBox2D(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    }

    private func index(x: Int, y: Int) -> Int {
        y * imageDimensions.width + x
    }

    private func makeSnapshot(
        identity: ARCaptureIdentity,
        capturedAt: TimeInterval = 1_725_000_000,
        timestamp: TimeInterval = 7,
        intrinsics: simd_float3x3? = nil,
        depthDimensions: ImageDimensions? = nil,
        depthMeters: [Float]
    ) throws -> ARFrameSnapshot {
        let depthDimensions = depthDimensions ?? imageDimensions
        XCTAssertEqual(depthMeters.count, depthDimensions.width * depthDimensions.height)
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            imageDimensions.width,
            imageDimensions.height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        XCTAssertEqual(result, kCVReturnSuccess)
        let image = try XCTUnwrap(pixelBuffer)
        let pose = ARPoseSnapshot(
            id: ARFrameID(),
            sessionToken: ARSessionFrameToken(
                sessionRunGeneration: 1,
                attachmentEpoch: 1
            ),
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: identity.mapID,
            coordinateFrameStatus: identity.status,
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
            cameraIntrinsics: Matrix3x3Snapshot(intrinsics ?? self.intrinsics),
            cameraImageDimensions: imageDimensions,
            displayTransform: nil,
            sceneDepth: ARDepthSnapshot(
                dimensions: depthDimensions,
                depthMeters: depthMeters,
                confidence: Array(
                    repeating: ARDepthConfidence.high.rawValue,
                    count: depthMeters.count
                )
            ),
            smoothedSceneDepth: nil
        )
    }
}
