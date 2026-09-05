import XCTest

@testable import VispaceCore

final class HorizontalFootprintCoverageTests: XCTestCase {
    func testTwoTrianglesCoverRectangleWithoutTreatingSharedEdgeAsHole() throws {
        XCTAssertTrue(
            HorizontalFootprintCoverage.trianglesCover(try region(), triangles: rectangle(-2, -2, 2, 2)))
    }

    func testTriangleBoundingBoxAndDuplicateFacesDoNotEstablishCoverage() throws {
        let triangle = [point(-2, -2), point(2, -2), point(0, 2)]
        XCTAssertFalse(HorizontalFootprintCoverage.trianglesCover(try region(), triangles: [triangle]))
        XCTAssertFalse(
            HorizontalFootprintCoverage.trianglesCover(
                try region(), triangles: Array(repeating: triangle, count: 128)
            ))
    }

    func testHoleAndDisjointFloorPatchesRemainUncovered() throws {
        let ring =
            rectangle(-2, -2, 2, -0.2)
            + rectangle(-2, 0.2, 2, 2)
            + rectangle(-2, -0.2, -0.2, 0.2)
            + rectangle(0.2, -0.2, 2, 0.2)
        XCTAssertFalse(HorizontalFootprintCoverage.trianglesCover(try region(), triangles: ring))
        let disjoint = rectangle(-2, -2, -0.1, 2) + rectangle(0.1, -2, 2, 2)
        XCTAssertFalse(HorizontalFootprintCoverage.trianglesCover(try region(), triangles: disjoint))
    }

    func testOverheadAndSlopingTrianglesCannotSupplyFloorAtCandidateElevation() throws {
        let overhead = rectangle(-2, -2, 2, 2).map { face in
            face.map { point in try! Vec3(x: point.x, y: 2, z: point.z) }
        }
        XCTAssertFalse(HorizontalFootprintCoverage.trianglesCover(try region(), triangles: overhead))
        let slope = rectangle(-2, -2, 2, 2).map { face in
            face.map { point in try! Vec3(x: point.x, y: point.x * 0.2, z: point.z) }
        }
        XCTAssertFalse(HorizontalFootprintCoverage.trianglesCover(try region(), triangles: slope))
    }

    func testRotatedFootprintUsesActualRectangle() throws {
        let rotated = try PlacementHorizontalRegion(center: .zero, width: 2, depth: 2, yawRadians: .pi / 4)
        XCTAssertTrue(HorizontalFootprintCoverage.trianglesCover(rotated, triangles: rectangle(-2, -2, 2, 2)))
        XCTAssertFalse(
            HorizontalFootprintCoverage.trianglesCover(rotated, triangles: rectangle(-1, -1, 1, 1)))
    }

    func testConcavePolygonMustContainEntireFootprintNotOnlyCorners() throws {
        let notch = [
            point(-2, -2), point(2, -2), point(2, 2), point(0.2, 2),
            point(0.2, 0), point(-0.2, 0), point(-0.2, 2), point(-2, 2),
        ]
        XCTAssertFalse(HorizontalFootprintCoverage.polygonCovers(try region(), polygon: notch))
        let lShape = [point(-2, -2), point(2, -2), point(2, 0), point(0, 0), point(0, 2), point(-2, 2)]
        XCTAssertFalse(HorizontalFootprintCoverage.polygonCovers(try region(), polygon: lShape))
        let insideArm = try PlacementHorizontalRegion(center: point(-1, 0), width: 1, depth: 2)
        XCTAssertTrue(HorizontalFootprintCoverage.polygonCovers(insideArm, polygon: lShape))
    }

    func testBoundaryContactIsAcceptedButInvalidAndOversizedPolygonsFailClosed() throws {
        let boundary = [point(-1, -1), point(1, -1), point(1, 1), point(-1, 1)]
        XCTAssertTrue(HorizontalFootprintCoverage.polygonCovers(try region(), polygon: boundary))
        XCTAssertTrue(
            HorizontalFootprintCoverage.polygonCovers(try region(), polygon: Array(boundary.reversed())))
        XCTAssertFalse(
            HorizontalFootprintCoverage.polygonCovers(
                try region(), polygon: [point(-2, -2), point(2, 2), point(-2, 2), point(2, -2)]
            ))
        XCTAssertFalse(
            HorizontalFootprintCoverage.polygonCovers(
                try region(), polygon: Array(repeating: point(0, 0), count: 513)
            ))
    }

    @MainActor
    func testCancelledGeometryWorkFailsClosed() async throws {
        let requested = try region()
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return HorizontalFootprintCoverage.trianglesCover(
                requested,
                triangles: [
                    [
                        try! Vec3(x: -2, y: 0, z: -2), try! Vec3(x: 2, y: 0, z: -2),
                        try! Vec3(x: 0, y: 0, z: 2),
                    ]
                ]
            )
        }
        let result = await work.value
        XCTAssertFalse(result)
    }

    private func region() throws -> PlacementHorizontalRegion {
        try PlacementHorizontalRegion(center: .zero, width: 2, depth: 2)
    }

    private func point(_ x: Double, _ z: Double) -> Vec3 {
        try! Vec3(x: x, y: 0, z: z)
    }

    private func rectangle(_ x0: Double, _ z0: Double, _ x1: Double, _ z1: Double) -> [[Vec3]] {
        [
            [point(x0, z0), point(x1, z0), point(x1, z1)],
            [point(x0, z0), point(x1, z1), point(x0, z1)],
        ]
    }
}
