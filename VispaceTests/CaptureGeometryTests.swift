import CoreGraphics
import VispaceCore
import XCTest
import simd

@testable import Vispace

final class CaptureGeometryTests: XCTestCase {
    func testColumnMajorARTransformConvertsToCoreWithoutTransposition() throws {
        var matrix = matrix_identity_float4x4
        matrix.columns.0 = SIMD4<Float>(0, 1, 0, 0)
        matrix.columns.1 = SIMD4<Float>(-1, 0, 0, 0)
        matrix.columns.3 = SIMD4<Float>(1, 2, 3, 1)

        let transform = try Matrix4x4Snapshot(matrix).coreTransform()

        XCTAssertEqual(transform[0, 0], 0)
        XCTAssertEqual(transform[0, 1], -1)
        XCTAssertEqual(transform[1, 0], 1)
        XCTAssertEqual(transform.translation, try Vec3(x: 1, y: 2, z: 3))
        XCTAssertEqual(
            try transform.transformed(Vec3(x: 1, y: 0, z: 0)),
            try Vec3(x: 1, y: 3, z: 3)
        )
    }

    func testPoseAdapterPreservesCoordinateProvenance() throws {
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let frameID = ARFrameID()
        let pose = ARPoseSnapshot(
            id: frameID,
            sessionToken: ARSessionFrameToken(
                sessionRunGeneration: 1,
                attachmentEpoch: 1
            ),
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: identity.mapID,
            coordinateFrameStatus: identity.status,
            capturedAt: 1_700_000_003,
            timestamp: 3,
            cameraTransform: Matrix4x4Snapshot(matrix_identity_float4x4),
            trackingState: .limited(.insufficientFeatures),
            worldMappingStatus: .extending
        )

        let adapted = try ARPoseCoreAdapter().adapt(pose)

        XCTAssertEqual(adapted.coordinateFrameID, identity.coordinateFrameID)
        XCTAssertEqual(adapted.segmentID, identity.segmentID)
        XCTAssertEqual(adapted.mapID, identity.mapID)
        XCTAssertEqual(adapted.coordinateFrameStatus, .confirmed)
        XCTAssertEqual(adapted.sample.frameID.rawValue, frameID.rawValue)
        XCTAssertEqual(adapted.sample.trackingConfidence.value, 0.35, accuracy: 0.0001)
    }

    func testDisplayAffineSnapshotRoundTripsNormalizedPoint() {
        let original = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        let snapshot = AffineTransformSnapshot(original)
        let point = CGPoint(x: 0.2, y: 0.7)

        let viewportPoint = point.applying(snapshot.cgAffineTransform)
        let restored = viewportPoint.applying(snapshot.cgAffineTransform.inverted())

        XCTAssertEqual(restored.x, point.x, accuracy: 0.000_001)
        XCTAssertEqual(restored.y, point.y, accuracy: 0.000_001)
    }

    func testInvalidViewportCannotProduceDisplayGeometry() {
        XCTAssertFalse(ViewportSizeSnapshot(width: 0, height: 800).isUsable)
        XCTAssertFalse(ViewportSizeSnapshot(width: .nan, height: 800).isUsable)
        XCTAssertTrue(ViewportSizeSnapshot(width: 390, height: 844).isUsable)
    }

    func testVisionBoundingBoxCenterConvertsToRawCameraCoordinates() throws {
        let box = NormalizedBoundingBox(x: 0.1, y: 0.2, width: 0.2, height: 0.4)
        let expected: [FrameImageOrientation: SIMD2<Float>] = [
            .up: SIMD2<Float>(0.2, 0.6),
            .upMirrored: SIMD2<Float>(0.8, 0.6),
            .down: SIMD2<Float>(0.8, 0.4),
            .downMirrored: SIMD2<Float>(0.2, 0.4),
            .right: SIMD2<Float>(0.6, 0.8),
            .rightMirrored: SIMD2<Float>(0.6, 0.2),
            .left: SIMD2<Float>(0.4, 0.2),
            .leftMirrored: SIMD2<Float>(0.4, 0.8),
        ]

        for orientation in FrameImageOrientation.allCases {
            let actual = try XCTUnwrap(
                box.cameraImageTopLeftCenter(for: orientation),
                "Missing conversion for \(orientation)"
            )
            let target = try XCTUnwrap(expected[orientation])
            XCTAssertEqual(actual.x, target.x, accuracy: 0.000_001)
            XCTAssertEqual(actual.y, target.y, accuracy: 0.000_001)
        }
    }

    func testInvalidVisionBoundingBoxCannotReachDepthSampler() {
        let invalid = NormalizedBoundingBox(x: 0.9, y: 0, width: 0.2, height: 0.2)
        let empty = NormalizedBoundingBox(x: 0.2, y: 0.2, width: 0, height: 0.2)

        XCTAssertNil(invalid.cameraImageTopLeftCenter(for: .right))
        XCTAssertNil(empty.cameraImageTopLeftCenter(for: .right))
    }

    func testDetectionConfidenceCombinesObjectnessAndLabelProbability() throws {
        let combined = try XCTUnwrap(
            ObjectDetectionConfidence.combined(object: 0.8, label: 0.5)
        )
        XCTAssertEqual(
            combined,
            0.4,
            accuracy: 0.000_001
        )
        XCTAssertNil(ObjectDetectionConfidence.combined(object: .nan, label: 0.8))
        XCTAssertNil(ObjectDetectionConfidence.combined(object: 1.1, label: 0.8))
    }
}
