import VispaceCore
import XCTest

@testable import Vispace

final class ARNavigationRibbonGeometryTests: XCTestCase {
    func testStraightRibbonUsesLocalCoordinatesAndSeparateLayers() throws {
        let geometry = try XCTUnwrap(ARNavigationRibbonGeometry.make(waypoints: [
            point(12, 3, -8), point(12, 3, -4),
        ]))
        XCTAssertEqual(geometry.origin, SIMD3<Float>(12, 3, -8))
        XCTAssertEqual(geometry.endpoint, SIMD3<Float>(0, 0, 4))
        XCTAssertEqual(geometry.halfWidth, 0.18)
        XCTAssertEqual(geometry.surface.positions.count, 4)
        XCTAssertEqual(geometry.surface.triangleIndices.count, 6)
        XCTAssertEqual(geometry.borders.positions.count, 8)
        XCTAssertTrue(geometry.surface.positions.allSatisfy { abs($0.x) <= 0.180001 && abs($0.y - 0.012) < 0.000001 })
        XCTAssertTrue(geometry.borders.positions.allSatisfy { abs($0.x) <= 0.180001 && abs($0.x) >= 0.167999 && abs($0.y - 0.014) < 0.000001 })
        XCTAssertTrue(geometry.chevrons.positions.allSatisfy { abs($0.y - 0.016) < 0.000001 })
        assertValidMeshes(geometry)
    }

    func testEveryTurnTriangleStaysInsideItsOriginalSegmentClearance() throws {
        let routes = [
            [point(0, 0, 0), point(0, 0, 1), point(1, 0, 1)],
            [point(0, 0, 0), point(0, 0, 1), point(-1, 0, 1)],
            [point(0, 0, 0), point(0, 0, 1), point(0.02, 0, 0)],
            [point(0, 0, 0), point(0, 0, 1), point(0, 0, 0)],
            [point(0, 0, 0), point(0, 0, 0.03), point(0.03, 0, 0.03), point(0.03, 0, 0.06)],
            [point(0, 0, 0), point(1, 0, 0), point(1, 0, 1), point(0, 0, 1), point(0, 0, 0)],
        ]
        for route in routes {
            let geometry = try XCTUnwrap(ARNavigationRibbonGeometry.make(waypoints: route))
            XCTAssertEqual(geometry.surface.positions.count, (route.count - 1) * 4)
            for segment in 0..<(route.count - 1) {
                let start = SIMD2<Double>(route[segment].x, route[segment].z)
                let end = SIMD2<Double>(route[segment + 1].x, route[segment + 1].z)
                let indices = Array(geometry.surface.triangleIndices[(segment * 6)..<(segment * 6 + 6)])
                for triangle in stride(from: 0, to: 6, by: 3) {
                    let vertices = indices[triangle..<(triangle + 3)].map { index in
                        let value = geometry.surface.positions[Int(index)]
                        return SIMD2<Double>(Double(value.x), Double(value.z))
                    }
                    // Test triangle interiors as well as endpoints: the path
                    // cannot visually cut across the inside of a right turn.
                    for a in 0...8 {
                        for b in 0...(8 - a) {
                            let sample = vertices[0] * (Double(a) / 8)
                                + vertices[1] * (Double(b) / 8)
                                + vertices[2] * (Double(8 - a - b) / 8)
                            XCTAssertLessThanOrEqual(distance(sample, toSegmentFrom: start, to: end), 0.180001)
                        }
                    }
                }
            }
            assertValidMeshes(geometry)
        }
    }

    func testCornerSectionsAreBoundedAndSharedWithoutMiterExtension() throws {
        let geometry = try XCTUnwrap(ARNavigationRibbonGeometry.make(waypoints: [
            point(0, 0, 0), point(0, 0, 1), point(1, 0, 1),
        ]))
        let vertices = geometry.surface.positions
        XCTAssertEqual(vertices[1], vertices[4])
        XCTAssertEqual(vertices[2], vertices[7])
        XCTAssertEqual(abs(vertices[1].x), 0.09, accuracy: 0.000001)
        XCTAssertEqual(abs(vertices[1].z - 1), 0.09, accuracy: 0.000001)
    }

    func testSampledFloorSlopeIsPreservedInAllRouteLayers() throws {
        let geometry = try XCTUnwrap(ARNavigationRibbonGeometry.make(waypoints: [
            point(0, 2, 0), point(0, 2.2, 1), point(0, 2.4, 2),
        ]))
        for vertex in geometry.surface.positions {
            XCTAssertEqual(vertex.y, vertex.z * 0.2 + 0.012, accuracy: 0.000001)
        }
        for vertex in geometry.borders.positions {
            XCTAssertEqual(vertex.y, vertex.z * 0.2 + 0.014, accuracy: 0.000001)
        }
        for vertex in geometry.chevrons.positions {
            XCTAssertEqual(vertex.y, vertex.z * 0.2 + 0.016, accuracy: 0.000001)
        }
        XCTAssertTrue(geometry.destination.positions.allSatisfy { abs($0.y - 0.416) < 0.000001 })
        XCTAssertEqual(geometry.endpoint.y, 0.4, accuracy: 0.000001)
    }

    func testConsecutiveDuplicatesDoNotMakeGapsOrChangeOrigin() throws {
        let duplicate = point(3, 1, 7)
        let geometry = try XCTUnwrap(ARNavigationRibbonGeometry.make(waypoints: [
            duplicate, duplicate, point(3, 1, 8), point(3, 1, 8),
        ]))
        XCTAssertEqual(geometry.origin, SIMD3<Float>(3, 1, 7))
        XCTAssertEqual(geometry.surface.positions.count, 4)
        XCTAssertEqual(geometry.endpoint, SIMD3<Float>(0, 0, 1))
    }

    func testOnePointProducesOnlyDestinationRing() throws {
        let geometry = try XCTUnwrap(ARNavigationRibbonGeometry.make(waypoints: [point(1, 2, 3)]))
        XCTAssertTrue(geometry.surface.positions.isEmpty)
        XCTAssertTrue(geometry.borders.positions.isEmpty)
        XCTAssertTrue(geometry.chevrons.positions.isEmpty)
        XCTAssertEqual(geometry.endpoint, .zero)
        XCTAssertEqual(geometry.destination.positions.count, 48 * 4)
        for vertex in geometry.destination.positions {
            XCTAssertLessThanOrEqual(hypot(vertex.x, vertex.z), 0.160001)
            XCTAssertGreaterThanOrEqual(hypot(vertex.x, vertex.z), 0.134399)
            XCTAssertEqual(vertex.y, 0.016, accuracy: 0.000001)
        }
        assertValidMeshes(geometry)
    }

    func testCollinearCellsRetainArclengthSpacedForwardChevrons() throws {
        let route = (0...8).map { point(0, 0, Double($0) / 2) }
        let geometry = try XCTUnwrap(ARNavigationRibbonGeometry.make(waypoints: route))
        XCTAssertEqual(geometry.surface.positions.count, 8 * 4)
        XCTAssertEqual(geometry.chevrons.positions.count, 5 * 8)
        for index in 0..<5 {
            let wing = geometry.chevrons.positions[index * 8]
            let tip = geometry.chevrons.positions[index * 8 + 1]
            XCTAssertGreaterThan(tip.z, wing.z)
            XCTAssertEqual((wing.z + tip.z) / 2, 0.375 + Float(index) * 0.75, accuracy: 0.000001)
            XCTAssertEqual(tip.z - wing.z, 0.18, accuracy: 0.000001)
        }
    }

    func testChevronsFollowReversedAndSidewaysRoutes() throws {
        for end in [point(0, 0, -3), point(-3, 0, 0), point(3, 0, 0)] {
            let geometry = try XCTUnwrap(ARNavigationRibbonGeometry.make(waypoints: [.zero, end]))
            XCTAssertFalse(geometry.chevrons.positions.isEmpty)
            let wing = geometry.chevrons.positions[0]
            let tip = geometry.chevrons.positions[1]
            let forwardProgress = Double(tip.x - wing.x) * end.x + Double(tip.z - wing.z) * end.z
            XCTAssertGreaterThan(forwardProgress, 0)
            assertValidMeshes(geometry)
        }
    }

    func testChevronsNeverBridgeACornerOrFloorSlopeChange() throws {
        for route in [
            [point(0, 0, 0), point(0, 0, 0.4), point(0.4, 0, 0.4)],
            [point(0, 0, 0), point(0, 0, 0.4), point(0, 0.1, 0.8)],
        ] {
            let geometry = try XCTUnwrap(ARNavigationRibbonGeometry.make(waypoints: route))
            // The only global marker centre would be at 0.375 m and its
            // 0.18 m glyph would straddle the verified corner at 0.4 m.
            XCTAssertTrue(geometry.chevrons.positions.isEmpty)
        }
    }

    func testNarrowPolicyScalesEveryFootprintWithoutExpandingClearance() throws {
        for width in [0.1, 0.015, 0.0001] {
            let geometry = try XCTUnwrap(ARNavigationRibbonGeometry.make(
                waypoints: [.zero, point(0, 0, 2)], maximumHalfWidth: width
            ))
            XCTAssertEqual(geometry.halfWidth, Float(width))
            for mesh in [geometry.surface, geometry.borders, geometry.chevrons] {
                XCTAssertTrue(mesh.positions.allSatisfy { abs(Double($0.x)) <= width + 0.000001 })
            }
            for vertex in geometry.destination.positions {
                XCTAssertLessThanOrEqual(hypot(Double(vertex.x), Double(vertex.z - 2)), width + 0.000001)
            }
        }
        let wide = try XCTUnwrap(ARNavigationRibbonGeometry.make(waypoints: [.zero], maximumHalfWidth: 1))
        XCTAssertEqual(wide.halfWidth, 0.18)
    }

    func testMalformedCoordinatesAndVerticalOnlySegmentsFailClosed() throws {
        var nonfinite = Vec3.zero
        for value in [Double.nan, .infinity, -.infinity] {
            nonfinite.x = value
            XCTAssertNil(ARNavigationRibbonGeometry.make(waypoints: [nonfinite]))
            XCTAssertNil(ARNavigationRibbonGeometry.make(waypoints: [.zero], maximumHalfWidth: value))
        }
        for width in [0.0, -0.18, 0.00001] {
            XCTAssertNil(ARNavigationRibbonGeometry.make(waypoints: [.zero], maximumHalfWidth: width))
        }
        XCTAssertNil(ARNavigationRibbonGeometry.make(waypoints: []))
        XCTAssertNil(ARNavigationRibbonGeometry.make(waypoints: [.zero, point(0, 1, 0)]))
        XCTAssertNil(ARNavigationRibbonGeometry.make(waypoints: [.zero, point(0, 0, 0.00001)]))
        XCTAssertNil(ARNavigationRibbonGeometry.make(waypoints: [point(Double.greatestFiniteMagnitude, 0, 0)]))
        XCTAssertNil(ARNavigationRibbonGeometry.make(waypoints: [point(10_001, 0, 0)]))
        XCTAssertNil(ARNavigationRibbonGeometry.make(waypoints: [.zero, point(1_001, 0, 0)]))
        XCTAssertNil(ARNavigationRibbonGeometry.make(waypoints: [.zero, point(1_000, 0, 0), .zero, point(1, 0, 0)]))
    }

    func testMaximumWaypointCountAndMeshWorkAreBounded() throws {
        let route = (0..<4_096).map { point(0, 0, Double($0) * 0.1) }
        let geometry = try XCTUnwrap(ARNavigationRibbonGeometry.make(waypoints: route))
        XCTAssertEqual(geometry.surface.positions.count, 4_095 * 4)
        XCTAssertEqual(geometry.borders.positions.count, 4_095 * 8)
        XCTAssertLessThanOrEqual(geometry.chevrons.positions.count, 2_667 * 8)
        XCTAssertEqual(geometry.destination.positions.count, 192)
        XCTAssertNil(ARNavigationRibbonGeometry.make(waypoints: route + [route.last!]))
        assertValidMeshes(geometry)
    }

    private func point(_ x: Double, _ y: Double, _ z: Double) -> Vec3 {
        try! Vec3(x: x, y: y, z: z)
    }

    private func distance(_ point: SIMD2<Double>, toSegmentFrom start: SIMD2<Double>, to end: SIMD2<Double>) -> Double {
        let delta = end - start
        let offset = point - start
        let fraction = max(0, min(1, (offset.x * delta.x + offset.y * delta.y) / (delta.x * delta.x + delta.y * delta.y)))
        let nearest = start + delta * fraction
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }

    private func assertValidMeshes(_ geometry: ARNavigationRibbonGeometry.Geometry, file: StaticString = #filePath, line: UInt = #line) {
        for mesh in [geometry.surface, geometry.borders, geometry.chevrons, geometry.destination] {
            XCTAssertEqual(mesh.triangleIndices.count % 3, 0, file: file, line: line)
            XCTAssertTrue(mesh.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, file: file, line: line)
            XCTAssertTrue(mesh.triangleIndices.allSatisfy { Int($0) < mesh.positions.count }, file: file, line: line)
            for index in stride(from: 0, to: mesh.triangleIndices.count, by: 3) {
                let first = mesh.positions[Int(mesh.triangleIndices[index + 1])] - mesh.positions[Int(mesh.triangleIndices[index])]
                let second = mesh.positions[Int(mesh.triangleIndices[index + 2])] - mesh.positions[Int(mesh.triangleIndices[index])]
                XCTAssertGreaterThanOrEqual(first.z * second.x - first.x * second.z, -0.000001, file: file, line: line)
            }
        }
    }
}
