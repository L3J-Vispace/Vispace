import VispaceCore
import XCTest
import simd

@testable import Vispace

final class ARDepthNavigationOccupancyTests: XCTestCase {
    func testVisibleHighConfidenceEmptyVolumeIsFree() throws {
        var checks = 0
        let occupancy = try makeOccupancy(depth: 5)
        XCTAssertEqual(occupancy.occupancy(centerX: 0, centerZ: -3, floorElevation: 0,
            halfWidth: 0.25, remainingChecks: &checks), .free)
        XCTAssertGreaterThan(checks, 0)
    }

    func testCurrentUnclassifiedDepthObstacleBlocksPreviouslyEmptyVolume() throws {
        var checks = 0
        let occupancy = try makeOccupancy(depth: 3)
        XCTAssertEqual(occupancy.occupancy(centerX: 0, centerZ: -3, floorElevation: 0,
            halfWidth: 0.25, remainingChecks: &checks), .blocked)
    }

    func testOccludedLowConfidenceAndOutOfViewCellsStayUnknown() throws {
        for (depth, confidence) in [(Float(1), UInt8(2)), (Float(5), UInt8(1)), (.nan, UInt8(2))] {
            var checks = 0
            let occupancy = try makeOccupancy(depth: depth, confidence: confidence)
            XCTAssertEqual(occupancy.occupancy(centerX: 0, centerZ: -3, floorElevation: 0,
                halfWidth: 0.25, remainingChecks: &checks), .unknown)
        }
        var checks = 0
        XCTAssertEqual(try makeOccupancy(depth: 5).occupancy(centerX: 8, centerZ: -3,
            floorElevation: 0, halfWidth: 0.25, remainingChecks: &checks), .unknown)
    }

    func testExhaustedWorkBudgetCannotInventFreeCells() throws {
        var checks = 1_000_000
        XCTAssertEqual(try makeOccupancy(depth: 5).occupancy(centerX: 0, centerZ: -3,
            floorElevation: 0, halfWidth: 0.25, remainingChecks: &checks), .unknown)
    }

    func testPartialRangeVolumeStillReportsCurrentBlocker() throws {
        var checks = 0
        // The far corners exceed the 5 m free-space attestation range, while
        // this current obstacle is inside the near half of the walking volume.
        XCTAssertEqual(try makeOccupancy(depth: 4.8).occupancy(centerX: 0, centerZ: -4.9,
            floorElevation: 0, halfWidth: 0.25, remainingChecks: &checks), .blocked)
        checks = 0
        XCTAssertEqual(try makeOccupancy(depth: 7).occupancy(centerX: 0, centerZ: -4.9,
            floorElevation: 0, halfWidth: 0.25, remainingChecks: &checks), .unknown)
    }

    func testInvalidWorkBudgetCannotOverflowOrAttestFreeSpace() throws {
        for initial in [Int.min, -1, Int.max] {
            var checks = initial
            XCTAssertEqual(try makeOccupancy(depth: 5).occupancy(centerX: 0, centerZ: -3,
                floorElevation: 0, halfWidth: 0.25, remainingChecks: &checks), .unknown)
        }
    }

    private func makeOccupancy(depth: Float, confidence: UInt8 = 2) throws -> ARDepthNavigationOccupancy {
        var transform = matrix_identity_float4x4
        transform.columns.3.y = 1
        let pose = ARPoseSnapshot(
            id: ARFrameID(), sessionToken: ARSessionFrameToken(sessionRunGeneration: 1, attachmentEpoch: 1),
            coordinateFrameID: CoordinateFrameID(), segmentID: CaptureSegmentID(), mapID: MapID(),
            coordinateFrameStatus: .confirmed, capturedAt: 100, timestamp: 10,
            cameraTransform: Matrix4x4Snapshot(transform), trackingState: .normal, worldMappingStatus: .mapped
        )
        let intrinsics = simd_float3x3(columns: (SIMD3<Float>(50, 0, 0), SIMD3<Float>(0, 50, 0), SIMD3<Float>(50, 50, 1)))
        return try XCTUnwrap(ARDepthNavigationOccupancy(
            pose: pose, intrinsics: Matrix3x3Snapshot(intrinsics),
            imageDimensions: ImageDimensions(width: 100, height: 100),
            depth: ARDepthSnapshot(dimensions: ImageDimensions(width: 100, height: 100),
                depthMeters: Array(repeating: depth, count: 10_000),
                confidence: Array(repeating: confidence, count: 10_000))
        ))
    }
}
