import CoreVideo
import VispaceCore
import XCTest
import simd

@testable import Vispace

final class ARDepthSamplerTests: XCTestCase {
    func testMalformedDepthDimensionsFailWithoutIntegerOverflow() throws {
        for dimensions in [
            ImageDimensions(width: Int.max, height: 2),
            ImageDimensions(width: -1, height: 1),
            ImageDimensions(width: 0, height: 1),
        ] {
            let snapshot = try makeSnapshot(
                sceneDepth: ARDepthSnapshot(dimensions: dimensions, depthMeters: [], confidence: [])
            )
            XCTAssertEqual(
                ARDepthSampler().sample(normalizedImagePoint: SIMD2<Float>(0.5, 0.5), in: snapshot),
                .unavailable(.malformedDepthGrid)
            )
        }
    }

    func testExtremeNeighborhoodRadiusClipsToAvailableGrid() throws {
        let snapshot = try makeSnapshot(
            sceneDepth: ARDepthSnapshot(
                dimensions: ImageDimensions(width: 2, height: 2),
                depthMeters: [2, 2, 2, 2], confidence: [2, 2, 2, 2]
            )
        )
        guard
            case .sample(let sample) = ARDepthSampler(neighborhoodRadius: Int.max).sample(
                normalizedImagePoint: SIMD2<Float>(0.75, 0.75), in: snapshot
            )
        else { return XCTFail("A clipped radius must still sample valid depth") }
        XCTAssertEqual(sample.depthMeters, 2)
    }

    func testNegativeFocalLengthAndOverflowAfterHomogeneousDivisionFailClosed() throws {
        let depth = ARDepthSnapshot(
            dimensions: ImageDimensions(width: 1, height: 1), depthMeters: [1], confidence: [2]
        )
        var negativeFocalLength = matrix_identity_float3x3
        negativeFocalLength.columns.0.x = -1
        let invalidIntrinsics = try makeSnapshot(sceneDepth: depth, intrinsics: negativeFocalLength)
        var overflowingTransform = matrix_identity_float4x4
        overflowingTransform.columns.3 = SIMD4<Float>(Float.greatestFiniteMagnitude, 0, 0, 0.5)
        let overflowingWorld = try makeSnapshot(sceneDepth: depth, cameraTransform: overflowingTransform)
        for snapshot in [invalidIntrinsics, overflowingWorld] {
            XCTAssertEqual(
                ARDepthSampler(neighborhoodRadius: 0).sample(
                    normalizedImagePoint: SIMD2<Float>(0.5, 0.5), in: snapshot
                ),
                .unavailable(.invalidIntrinsics)
            )
        }
    }

    func testHighConfidenceDepthUnprojectsIntoExplicitCoordinateFrame() throws {
        let identity = ARCaptureIdentity(status: .confirmed)
        let snapshot = try makeSnapshot(
            identity: identity,
            sceneDepth: ARDepthSnapshot(
                dimensions: ImageDimensions(width: 2, height: 2),
                depthMeters: [2, 2, 2, 2],
                confidence: [2, 2, 2, 2]
            )
        )

        let result = ARDepthSampler(neighborhoodRadius: 0).sample(
            normalizedImagePoint: SIMD2<Float>(0.1, 0.1),
            in: snapshot
        )

        guard case .sample(let sample) = result else {
            return XCTFail("Expected a depth sample, received \(result).")
        }
        XCTAssertEqual(sample.coordinateFrameID, identity.coordinateFrameID)
        XCTAssertEqual(sample.segmentID, identity.segmentID)
        XCTAssertEqual(sample.mapID, identity.mapID)
        XCTAssertEqual(sample.depthMeters, 2, accuracy: 0.0001)
        XCTAssertEqual(sample.cameraPosition.x, -1, accuracy: 0.0001)
        XCTAssertEqual(sample.cameraPosition.y, 1, accuracy: 0.0001)
        XCTAssertEqual(sample.cameraPosition.z, -2, accuracy: 0.0001)
        XCTAssertEqual(sample.worldPosition, sample.cameraPosition)
        XCTAssertEqual(sample.uncertainty, .highConfidenceDepth)
    }

    func testNeighborhoodMedianRejectsFiniteOutlier() throws {
        let snapshot = try makeSnapshot(
            sceneDepth: ARDepthSnapshot(
                dimensions: ImageDimensions(width: 3, height: 3),
                depthMeters: [2, 2, 2, 2, 100, 2, 2, 2, 2],
                confidence: Array(repeating: 2, count: 9)
            ),
            imageDimensions: ImageDimensions(width: 3, height: 3),
            intrinsics: simd_float3x3(
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0),
                SIMD3<Float>(1.5, 1.5, 1)
            )
        )

        let result = ARDepthSampler(neighborhoodRadius: 1).sample(
            normalizedImagePoint: SIMD2<Float>(0.5, 0.5),
            in: snapshot
        )

        guard case .sample(let sample) = result else {
            return XCTFail("Expected median depth sample.")
        }
        XCTAssertEqual(sample.depthMeters, 2, accuracy: 0.0001)
    }

    func testLowConfidenceAndUnavailableDepthFailExplicitly() throws {
        let lowConfidence = try makeSnapshot(
            sceneDepth: ARDepthSnapshot(
                dimensions: ImageDimensions(width: 1, height: 1),
                depthMeters: [1],
                confidence: [0]
            ),
            imageDimensions: ImageDimensions(width: 1, height: 1),
            intrinsics: matrix_identity_float3x3
        )
        XCTAssertEqual(
            ARDepthSampler(minimumConfidence: .medium, neighborhoodRadius: 0).sample(
                normalizedImagePoint: SIMD2<Float>(0.5, 0.5),
                in: lowConfidence
            ),
            .unavailable(.insufficientConfidence)
        )

        let noDepth = try makeSnapshot(sceneDepth: nil)
        XCTAssertEqual(
            ARDepthSampler().sample(
                normalizedImagePoint: SIMD2<Float>(0.5, 0.5),
                in: noDepth
            ),
            .unavailable(.depthNotSupportedOrUnavailable)
        )
    }

    func testSmoothedDepthIsPreferredButRawCanBeRequested() throws {
        let raw = ARDepthSnapshot(
            dimensions: ImageDimensions(width: 1, height: 1),
            depthMeters: [1],
            confidence: [2]
        )
        let smoothed = ARDepthSnapshot(
            dimensions: ImageDimensions(width: 1, height: 1),
            depthMeters: [3],
            confidence: [2]
        )
        let snapshot = try makeSnapshot(
            sceneDepth: raw,
            smoothedDepth: smoothed,
            imageDimensions: ImageDimensions(width: 1, height: 1),
            intrinsics: matrix_identity_float3x3
        )

        guard
            case .sample(let preferred) = ARDepthSampler(neighborhoodRadius: 0).sample(
                normalizedImagePoint: SIMD2<Float>(0.5, 0.5),
                in: snapshot
            )
        else {
            return XCTFail("Expected smoothed depth.")
        }
        guard
            case .sample(let rawOnly) = ARDepthSampler(neighborhoodRadius: 0).sample(
                normalizedImagePoint: SIMD2<Float>(0.5, 0.5),
                in: snapshot,
                prefersSmoothedDepth: false
            )
        else {
            return XCTFail("Expected raw depth.")
        }
        XCTAssertEqual(preferred.source, .smoothed)
        XCTAssertEqual(preferred.depthMeters, 3)
        XCTAssertEqual(rawOnly.source, .raw)
        XCTAssertEqual(rawOnly.depthMeters, 1)
    }

    func testUnconfirmedFrameAndLimitedTrackingCannotProduceWorldCoordinates() throws {
        let depth = ARDepthSnapshot(
            dimensions: ImageDimensions(width: 1, height: 1),
            depthMeters: [1],
            confidence: [2]
        )
        let relocalizing = try makeSnapshot(
            identity: ARCaptureIdentity(status: .relocalizing),
            sceneDepth: depth,
            imageDimensions: ImageDimensions(width: 1, height: 1),
            intrinsics: matrix_identity_float3x3
        )
        let limited = try makeSnapshot(
            sceneDepth: depth,
            imageDimensions: ImageDimensions(width: 1, height: 1),
            intrinsics: matrix_identity_float3x3,
            trackingState: .limited(.relocalizing)
        )

        XCTAssertEqual(
            ARDepthSampler(neighborhoodRadius: 0).sample(
                normalizedImagePoint: SIMD2<Float>(0.5, 0.5),
                in: relocalizing
            ),
            .unavailable(.coordinateFrameUnconfirmed)
        )
        XCTAssertEqual(
            ARDepthSampler(neighborhoodRadius: 0).sample(
                normalizedImagePoint: SIMD2<Float>(0.5, 0.5),
                in: limited
            ),
            .unavailable(.trackingNotNormal)
        )
    }

    func testNeighborDepthUsesNeighborRayRatherThanCenterRay() throws {
        let snapshot = try makeSnapshot(
            sceneDepth: ARDepthSnapshot(
                dimensions: ImageDimensions(width: 3, height: 1),
                depthMeters: [1, .nan, 3],
                confidence: [2, 2, 2]
            ),
            imageDimensions: ImageDimensions(width: 3, height: 1),
            intrinsics: simd_float3x3(
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0),
                SIMD3<Float>(1, 0, 1)
            )
        )

        guard
            case .sample(let sample) = ARDepthSampler(neighborhoodRadius: 1).sample(
                normalizedImagePoint: SIMD2<Float>(0.5, 0.5),
                in: snapshot
            )
        else {
            return XCTFail("Expected a neighboring depth sample.")
        }
        XCTAssertEqual(sample.depthPixel, SIMD2<Int>(2, 0))
        XCTAssertEqual(sample.cameraPosition.x, 3, accuracy: 0.0001)
    }

    private func makeSnapshot(
        identity: ARCaptureIdentity = ARCaptureIdentity(status: .confirmed),
        sceneDepth: ARDepthSnapshot?,
        smoothedDepth: ARDepthSnapshot? = nil,
        imageDimensions: ImageDimensions = ImageDimensions(width: 2, height: 2),
        intrinsics: simd_float3x3 = simd_float3x3(
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0.5, 0.5, 1)
        ),
        trackingState: ARTrackingStateSnapshot = .normal,
        cameraTransform: simd_float4x4 = matrix_identity_float4x4
    ) throws -> ARFrameSnapshot {
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            max(1, imageDimensions.width),
            max(1, imageDimensions.height),
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
            capturedAt: 1_700_000_001,
            timestamp: 1,
            cameraTransform: Matrix4x4Snapshot(cameraTransform),
            trackingState: trackingState,
            worldMappingStatus: .mapped
        )
        return ARFrameSnapshot(
            pose: pose,
            imageOrientation: .right,
            capturedImage: ImmutablePixelBuffer(pixelBuffer: image),
            cameraIntrinsics: Matrix3x3Snapshot(intrinsics),
            cameraImageDimensions: imageDimensions,
            displayTransform: nil,
            sceneDepth: sceneDepth,
            smoothedSceneDepth: smoothedDepth
        )
    }
}
