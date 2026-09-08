import VispaceCore
import XCTest
import simd

@testable import Vispace

final class ARGuidanceProjectorTests: XCTestCase {
    private let projector = ARGuidanceProjector()

    func testARKitNegativeZIsStraightAhead() throws {
        let projection = try XCTUnwrap(
            projector.project(
                target: Vec3(x: 0, y: 0, z: -2),
                cameraTransform: Matrix4x4Snapshot(matrix_identity_float4x4)
            )
        )

        XCTAssertEqual(projection.distanceMeters, 2, accuracy: 1e-12)
        XCTAssertEqual(projection.bearingRadians, 0, accuracy: 1e-12)
        XCTAssertEqual(projection.direction, .ahead)
        XCTAssertTrue(projection.isWithinForwardView)
        XCTAssertFalse(projection.hasArrived)
    }

    func testRightLeftAndBehindOctantsAreDeterministic() throws {
        let camera = Matrix4x4Snapshot(matrix_identity_float4x4)

        XCTAssertEqual(
            try XCTUnwrap(projector.project(target: Vec3(x: 2, y: 0, z: 0), cameraTransform: camera))
                .direction,
            .right
        )
        XCTAssertEqual(
            try XCTUnwrap(projector.project(target: Vec3(x: -2, y: 0, z: 0), cameraTransform: camera))
                .direction,
            .left
        )
        XCTAssertEqual(
            try XCTUnwrap(projector.project(target: Vec3(x: 0, y: 0, z: 2), cameraTransform: camera))
                .direction,
            .behind
        )
    }

    func testCameraTranslationAndVerticalOffsetAffectDistanceNotBearing() throws {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(10, 1, 5, 1)

        let projection = try XCTUnwrap(
            projector.project(
                target: Vec3(x: 10, y: 3, z: 2),
                cameraTransform: Matrix4x4Snapshot(transform)
            )
        )

        XCTAssertEqual(projection.horizontalDistanceMeters, 3, accuracy: 1e-12)
        XCTAssertEqual(projection.verticalOffsetMeters, 2, accuracy: 1e-12)
        XCTAssertEqual(projection.distanceMeters, 13.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(projection.bearingRadians, 0, accuracy: 1e-12)
    }

    func testRotatedCameraUsesItsOwnForwardAndRightAxes() throws {
        let yawRight = simd_float4x4(
            SIMD4<Float>(0, 0, -1, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        let ahead = try XCTUnwrap(
            projector.project(
                target: Vec3(x: -2, y: 0, z: 0),
                cameraTransform: Matrix4x4Snapshot(yawRight)
            )
        )
        let right = try XCTUnwrap(
            projector.project(
                target: Vec3(x: 0, y: 0, z: -2),
                cameraTransform: Matrix4x4Snapshot(yawRight)
            )
        )

        XCTAssertEqual(ahead.direction, .ahead)
        XCTAssertEqual(right.direction, .right)
    }

    func testArrivalAndVerticalOnlyTarget() throws {
        let projection = try XCTUnwrap(
            projector.project(
                target: Vec3(x: 0, y: 0.2, z: 0),
                cameraTransform: Matrix4x4Snapshot(matrix_identity_float4x4)
            )
        )

        XCTAssertTrue(projection.hasArrived)
        XCTAssertEqual(projection.direction, .ahead)
        XCTAssertEqual(projection.bearingRadians, 0)
    }

    func testPortraitHeadingSurvivesForwardBackwardTiltAndWorldYaw() throws {
        for yaw in [-Double.pi / 2, 0, .pi / 3, .pi] {
            for pitch in [-20.0, 0, 20] {
                let transform = portraitCamera(yaw: yaw, pitch: pitch * .pi / 180)
                let snapshot = Matrix4x4Snapshot(transform)
                let forward = (x: sin(yaw), z: -cos(yaw))
                let right = (x: cos(yaw), z: sin(yaw))
                for (offset, direction, bearing) in [
                    (forward, ARGuidanceDirection.ahead, 0.0),
                    (right, .right, .pi / 2),
                    ((x: -right.x, z: -right.z), .left, -.pi / 2),
                ] {
                    let result = try XCTUnwrap(
                        projector.project(
                            target: Vec3(x: 10 + 2 * offset.x, y: 1, z: 5 + 2 * offset.z),
                            cameraTransform: snapshot
                        ))
                    XCTAssertEqual(result.direction, direction, "yaw=\(yaw), pitch=\(pitch)")
                    XCTAssertEqual(result.bearingRadians, bearing, accuracy: 1e-6)
                    XCTAssertEqual(result.distanceMeters, 2, accuracy: 1e-6)
                }
                // The same raw pose remains available for image/depth transforms.
                XCTAssertEqual(snapshot.simdValue, transform)
            }
        }
    }

    func testCameraPointingVerticallyHasNoStableHorizontalHeading() throws {
        for pitch in [-Double.pi / 2, .pi / 2] {
            XCTAssertNil(
                projector.project(
                    target: try Vec3(x: 10, y: 1, z: 3),
                    cameraTransform: Matrix4x4Snapshot(portraitCamera(yaw: 0, pitch: pitch))
                ))
        }
    }

    private func portraitCamera(yaw: Double, pitch: Double) -> simd_float4x4 {
        let portrait = simd_float4x4(
            columns: (
                SIMD4<Float>(0, -1, 0, 0), SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, 0, 0, 1)
            ))
        let heading = simd_float4x4(simd_quatf(angle: Float(-yaw), axis: SIMD3<Float>(0, 1, 0)))
        let tilt = simd_float4x4(simd_quatf(angle: Float(pitch), axis: SIMD3<Float>(1, 0, 0)))
        var transform = heading * tilt * portrait
        transform.columns.3 = SIMD4<Float>(10, 1, 5, 1)
        return transform
    }

    func testDegenerateOrNonFiniteCameraPoseFailsClosed() throws {
        let degenerate = simd_float4x4(
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        XCTAssertNil(
            projector.project(
                target: try Vec3(x: 0, y: 0, z: -1),
                cameraTransform: Matrix4x4Snapshot(degenerate)
            )
        )

        var nonFinite = matrix_identity_float4x4
        nonFinite.columns.3.x = .nan
        XCTAssertNil(
            projector.project(
                target: try Vec3(x: 0, y: 0, z: -1),
                cameraTransform: Matrix4x4Snapshot(nonFinite)
            )
        )

        nonFinite = matrix_identity_float4x4
        nonFinite.columns.0.y = .nan
        XCTAssertNil(
            projector.project(
                target: try Vec3(x: 0, y: 0, z: -1),
                cameraTransform: Matrix4x4Snapshot(nonFinite)
            ))
    }
}
