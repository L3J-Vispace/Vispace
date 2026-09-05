import RealityKit
import VispaceCore
import XCTest
import simd

@testable import Vispace

@MainActor
final class FurniturePlacementRenderingTests: XCTestCase {
    func testRenderedBoxCornersMatchEvaluatedFootprintAtBothDiagonalYaws() throws {
        let dimensions = try FurnitureDimensions(kind: .sofa, width: 2, depth: 0.9, height: 0.8)
        let position = try Vec3(x: 1.2, y: 0.3, z: -2.4)
        for yaw in [-Double.pi / 4, Double.pi / 4] {
            let candidate = try FurniturePlacementCandidate(
                position: position, yawRadians: yaw, furniture: dimensions
            )
            let parent = Entity()
            parent.position = SIMD3<Float>(Float(position.x), Float(position.y), Float(position.z))
            let preview = FurniturePlacementRendering.makePreview(dimensions: dimensions, yawRadians: yaw)
            parent.addChild(preview)
            let bounds = try XCTUnwrap(preview.model).mesh.bounds
            let transform = preview.transformMatrix(relativeTo: nil)
            var actual: [SIMD3<Float>] = []
            for x in [bounds.min.x, bounds.max.x] {
                for y in [bounds.min.y, bounds.max.y] {
                    for z in [bounds.min.z, bounds.max.z] {
                        let point = transform * SIMD4<Float>(x, y, z, 1)
                        actual.append(SIMD3<Float>(point.x, point.y, point.z))
                    }
                }
            }
            let expected = try candidate.footprintCorners().flatMap { corner in
                [0.0, dimensions.height].map { height in
                    SIMD3<Float>(Float(corner.x), Float(corner.y + height), Float(corner.z))
                }
            }
            XCTAssertEqual(actual.count, expected.count)
            for corner in expected {
                XCTAssertTrue(actual.contains { simd_distance($0, corner) < 0.000_01 },
                    "Missing evaluated corner at yaw \(yaw): \(corner)")
            }
        }
    }
}
