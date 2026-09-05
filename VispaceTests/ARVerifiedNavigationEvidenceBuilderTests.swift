import Foundation
import VispaceCore
import XCTest
import simd

@testable import Vispace

final class ARVerifiedNavigationEvidenceBuilderTests: XCTestCase {
    func testDenseFullyClassifiedCurrentFloorProducesBoundedEvidence() throws {
        let context = makeContext()
        let builder = ARVerifiedNavigationEvidenceBuilder(
            cellSize: 0.5,
            maximumTriangleCount: 2,
            maximumCellCount: 16
        )

        let evidence = try unwrapReady(
            builder.adapt(context.snapshot, currentIdentity: context.identity)
        )

        XCTAssertEqual(evidence.mapID, context.mapID)
        XCTAssertEqual(evidence.coordinateFrameID, context.frameID)
        XCTAssertEqual(evidence.revision, context.snapshot.revision)
        XCTAssertEqual(evidence.observedAt, context.snapshot.timestamp)
        XCTAssertEqual(evidence.gridOrigin, vec(-0.75, 0, -0.75))
        XCTAssertEqual(evidence.cellSize, 0.5)
        XCTAssertEqual(evidence.floors.count, 16)
        XCTAssertEqual(evidence.mesh.count, 16)
        XCTAssertLessThanOrEqual(evidence.floors.count, builder.maximumCellCount)
        XCTAssertLessThanOrEqual(evidence.mesh.count, builder.maximumCellCount)
        XCTAssertEqual(Set(evidence.floors.map(\.cell)), Set(evidence.mesh.map(\.cell)))
        XCTAssertTrue(evidence.mesh.allSatisfy { $0.occupancy == .free })
        XCTAssertTrue(evidence.floors.allSatisfy { $0.zoneIdentifier == "verified-current-floor" })
        XCTAssertTrue(evidence.floors.allSatisfy { $0.confidence == builder.evidenceConfidence })
        XCTAssertTrue(evidence.completeness.wallsAroundObservedCellsMapped)
        XCTAssertTrue(evidence.completeness.doorwayStatesMapped)
        XCTAssertTrue(evidence.completeness.obstaclesAroundObservedCellsMapped)
        XCTAssertTrue(evidence.doors.isEmpty)
        XCTAssertTrue(evidence.walls.isEmpty)
        XCTAssertTrue(evidence.obstacles.isEmpty)
    }

    func testUnknownAndUnclassifiedFacesFailClosed() throws {
        let context = makeContext()
        for classification in [ARMeshClassificationSnapshot.unknown, .none] {
            let mesh = denseFloorMesh(classifications: [.floor, classification])
            let snapshot = surface(
                mapID: context.mapID,
                frameID: context.frameID,
                segmentID: context.segmentID,
                meshes: [mesh]
            )

            XCTAssertEqual(
                try unwrapIssue(
                    ARVerifiedNavigationEvidenceBuilder().adapt(
                        snapshot,
                        currentIdentity: context.identity
                    )
                ),
                .coverageAttestationUnavailable
            )
        }
    }

    func testUnknownAndUnclassifiedPlanesFailClosed() throws {
        let context = makeContext()
        let builder = ARVerifiedNavigationEvidenceBuilder()
        for classification in [ARPlaneClassificationSnapshot.unknown, .none] {
            let snapshot = surface(
                mapID: context.mapID,
                frameID: context.frameID,
                segmentID: context.segmentID,
                planes: [floorPlane(), verticalPlane(classification: classification)]
            )

            XCTAssertEqual(
                try unwrapIssue(builder.adapt(snapshot, currentIdentity: context.identity)),
                .coverageAttestationUnavailable
            )
        }
    }

    func testSparseFloorAndMissingFloorPlaneFailClosed() throws {
        let context = makeContext()
        let sparseMesh = mesh(
            id: uuid(2_001),
            vertices: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(0.1, 0, 0),
                SIMD3<Float>(0, 0, 0.1),
            ],
            indices: [0, 1, 2],
            classifications: [.floor]
        )
        let sparseSnapshot = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            meshes: [sparseMesh]
        )
        let noPlaneSnapshot = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            planes: [],
            meshes: [denseFloorMesh()]
        )
        let builder = ARVerifiedNavigationEvidenceBuilder()

        XCTAssertEqual(
            try unwrapIssue(builder.adapt(sparseSnapshot, currentIdentity: context.identity)),
            .coverageAttestationUnavailable
        )
        XCTAssertEqual(
            try unwrapIssue(builder.adapt(noPlaneSnapshot, currentIdentity: context.identity)),
            .coverageAttestationUnavailable
        )
    }

    func testPartiallyCoveredCellIsExcludedInsteadOfMarkedFree() throws {
        let context = makeContext()
        let snapshot = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            meshes: [floorMeshWithHole()]
        )

        let evidence = try unwrapReady(
            ARVerifiedNavigationEvidenceBuilder().adapt(
                snapshot,
                currentIdentity: context.identity
            )
        )

        let holeCell = IndoorNavigationCell(column: 1, row: 1)
        XCTAssertFalse(evidence.floors.contains { $0.cell == holeCell })
        XCTAssertFalse(evidence.mesh.contains { $0.cell == holeCell })
        XCTAssertEqual(evidence.floors.count, 15)
        XCTAssertEqual(evidence.mesh.count, 15)
    }

    func testWallGeometryProducesWallEvidenceAndBlockedCells() throws {
        let context = makeContext()
        let wall = mesh(
            id: uuid(3_001),
            vertices: [
                SIMD3<Float>(0, 0, -1),
                SIMD3<Float>(0, 2, -1),
                SIMD3<Float>(0, 2, 1),
            ],
            indices: [0, 1, 2],
            classifications: [.wall]
        )
        let snapshot = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            meshes: [denseFloorMesh(), wall]
        )

        let evidence = try unwrapReady(
            ARVerifiedNavigationEvidenceBuilder().adapt(
                snapshot,
                currentIdentity: context.identity
            )
        )

        XCTAssertEqual(evidence.walls.count, 1)
        XCTAssertTrue(evidence.obstacles.isEmpty)
        XCTAssertTrue(evidence.mesh.contains { $0.occupancy == .blocked })
        XCTAssertTrue(evidence.mesh.contains { $0.occupancy == .free })
        let occupancy = Dictionary(uniqueKeysWithValues: evidence.mesh.map { ($0.cell, $0.occupancy) })
        for row in 0..<4 {
            XCTAssertEqual(occupancy[IndoorNavigationCell(column: 1, row: row)], .blocked)
            XCTAssertEqual(occupancy[IndoorNavigationCell(column: 2, row: row)], .blocked)
        }
    }

    func testWallPlaneCannotDisappearIntoAllFreeEvidence() throws {
        let context = makeContext()
        let snapshot = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            planes: [floorPlane(), verticalPlane(classification: .wall)]
        )

        let evidence = try unwrapReady(
            ARVerifiedNavigationEvidenceBuilder().adapt(
                snapshot,
                currentIdentity: context.identity
            )
        )

        XCTAssertTrue(evidence.mesh.contains { $0.occupancy == .blocked })
        XCTAssertFalse(evidence.mesh.allSatisfy { $0.occupancy == .free })
        XCTAssertFalse(evidence.walls.isEmpty)
    }

    func testDoorGeometryFailsUntilTraversalStateCanBeVerified() throws {
        let context = makeContext()
        let doorPlaneSnapshot = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            planes: [floorPlane(), verticalPlane(classification: .door)]
        )
        let doorMesh = mesh(
            id: uuid(3_002),
            vertices: [
                SIMD3<Float>(0, 0, -0.5),
                SIMD3<Float>(0, 2, -0.5),
                SIMD3<Float>(0, 2, 0.5),
            ],
            indices: [0, 1, 2],
            classifications: [.door]
        )
        let doorMeshSnapshot = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            meshes: [denseFloorMesh(), doorMesh]
        )

        for snapshot in [doorPlaneSnapshot, doorMeshSnapshot] {
            XCTAssertEqual(
                try unwrapIssue(
                    ARVerifiedNavigationEvidenceBuilder().adapt(
                        snapshot,
                        currentIdentity: context.identity
                    )
                ),
                .coverageAttestationUnavailable
            )
        }
    }

    func testMultipleFloorElevationsFailClosed() throws {
        let context = makeContext()
        let raisedFloor = mesh(
            id: uuid(3_003),
            vertices: floorVertices().map {
                SIMD3<Float>($0.x, $0.y + 0.5, $0.z)
            },
            indices: [0, 1, 2, 0, 2, 3],
            classifications: [.floor, .floor]
        )
        let snapshot = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            meshes: [denseFloorMesh(), raisedFloor]
        )

        XCTAssertEqual(
            try unwrapIssue(
                ARVerifiedNavigationEvidenceBuilder().adapt(
                    snapshot,
                    currentIdentity: context.identity
                )
            ),
            .coverageAttestationUnavailable
        )
    }

    func testRecognizedObstacleNeverLeaksAsFreeSpace() throws {
        let context = makeContext()
        let table = mesh(
            id: uuid(4_001),
            vertices: [
                SIMD3<Float>(-0.2, 0.6, -0.2),
                SIMD3<Float>(0.2, 0.6, -0.2),
                SIMD3<Float>(0, 0.6, 0.2),
            ],
            indices: [0, 1, 2],
            classifications: [.table]
        )
        let snapshot = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            meshes: [denseFloorMesh(), table]
        )
        let builder = ARVerifiedNavigationEvidenceBuilder(obstacleClearance: 0.01)

        let evidence = try unwrapReady(
            builder.adapt(snapshot, currentIdentity: context.identity)
        )

        XCTAssertTrue(evidence.walls.isEmpty)
        XCTAssertTrue(evidence.obstacles.isEmpty)
        let blockedCells = Set(
            evidence.mesh.filter { $0.occupancy == .blocked }.map(\.cell)
        )
        XCTAssertEqual(
            blockedCells,
            Set([
                IndoorNavigationCell(column: 1, row: 1),
                IndoorNavigationCell(column: 2, row: 1),
                IndoorNavigationCell(column: 1, row: 2),
                IndoorNavigationCell(column: 2, row: 2),
            ])
        )
    }

    func testForeignOrUnconfirmedIdentityFailsClosed() throws {
        let context = makeContext()
        let builder = ARVerifiedNavigationEvidenceBuilder()
        let relocalizing = identity(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            status: .relocalizing
        )
        let foreignMap = identity(
            mapID: mapID(99),
            frameID: context.frameID,
            segmentID: context.segmentID
        )
        let foreignFrame = identity(
            mapID: context.mapID,
            frameID: frameID(99),
            segmentID: context.segmentID
        )
        let foreignSegment = identity(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: segmentID(99)
        )

        XCTAssertEqual(
            try unwrapIssue(builder.adapt(context.snapshot, currentIdentity: relocalizing)),
            .captureNotConfirmed
        )
        XCTAssertEqual(
            try unwrapIssue(builder.adapt(context.snapshot, currentIdentity: foreignMap)),
            .currentMapUnavailable
        )
        XCTAssertEqual(
            try unwrapIssue(builder.adapt(context.snapshot, currentIdentity: foreignFrame)),
            .coordinateContextMismatch
        )
        XCTAssertEqual(
            try unwrapIssue(builder.adapt(context.snapshot, currentIdentity: foreignSegment)),
            .coordinateContextMismatch
        )
    }

    func testIncompleteAndFailedSnapshotsFailClosed() throws {
        let context = makeContext()
        let inactive = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            isCurrentSessionData: false
        )
        let failed = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            failures: [
                ARSurfaceObservationFailure(
                    anchorID: uuid(5_001),
                    error: .invalidFaceBuffer
                )
            ]
        )
        let builder = ARVerifiedNavigationEvidenceBuilder()

        XCTAssertEqual(
            try unwrapIssue(builder.adapt(inactive, currentIdentity: context.identity)),
            .surfaceSnapshotIncomplete
        )
        XCTAssertEqual(
            try unwrapIssue(builder.adapt(failed, currentIdentity: context.identity)),
            .surfaceSnapshotIncomplete
        )
    }

    func testTriangleAndCellCapacityBoundariesFailClosed() throws {
        let context = makeContext()
        let exactCapacityEvidence = try unwrapReady(
            ARVerifiedNavigationEvidenceBuilder(
                maximumTriangleCount: 2,
                maximumCellCount: 16
            ).adapt(context.snapshot, currentIdentity: context.identity)
        )
        XCTAssertEqual(exactCapacityEvidence.floors.count, 16)

        let triangleOverflow = ARVerifiedNavigationEvidenceBuilder(
            maximumTriangleCount: 1,
            maximumCellCount: 16
        )
        XCTAssertEqual(
            try unwrapIssue(
                triangleOverflow.adapt(context.snapshot, currentIdentity: context.identity)
            ),
            .coverageAttestationUnavailable
        )

        let cellOverflow = ARVerifiedNavigationEvidenceBuilder(
            maximumTriangleCount: 2,
            maximumCellCount: 15
        )
        XCTAssertEqual(
            try unwrapIssue(
                cellOverflow.adapt(context.snapshot, currentIdentity: context.identity)
            ),
            .coverageAttestationUnavailable
        )
    }

    func testTinyCellSizeIsClampedBeforeGridArithmetic() throws {
        let context = makeContext()
        let builder = ARVerifiedNavigationEvidenceBuilder(
            cellSize: Double.leastNonzeroMagnitude,
            maximumCellCount: 16
        )

        let evidence = try unwrapReady(
            builder.adapt(context.snapshot, currentIdentity: context.identity)
        )

        XCTAssertEqual(builder.cellSize, 0.5)
        XCTAssertEqual(evidence.cellSize, 0.5)
        XCTAssertEqual(evidence.floors.count, 16)
    }

    func testWallCapacityOverflowFailsWholeAdaptation() throws {
        let context = makeContext()
        let walls = mesh(
            id: uuid(6_001),
            vertices: [
                SIMD3<Float>(0, 0, -1),
                SIMD3<Float>(0, 2, -1),
                SIMD3<Float>(0, 2, 0),
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(0, 2, 0),
                SIMD3<Float>(0, 2, 1),
            ],
            indices: [0, 1, 2, 3, 4, 5],
            classifications: [.wall, .wall]
        )
        let snapshot = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            meshes: [denseFloorMesh(), walls]
        )

        XCTAssertEqual(
            try unwrapIssue(
                ARVerifiedNavigationEvidenceBuilder(maximumWallCount: 1).adapt(
                    snapshot,
                    currentIdentity: context.identity
                )
            ),
            .coverageAttestationUnavailable
        )
    }

    func testMalformedMeshTopologyAndClassificationsFailClosed() throws {
        let context = makeContext()
        let badTopology = mesh(
            id: uuid(7_001),
            vertices: floorVertices(),
            indices: [0, 1],
            classifications: [.floor]
        )
        let missingClassification = mesh(
            id: uuid(7_002),
            vertices: floorVertices(),
            indices: [0, 1, 2, 0, 2, 3],
            classifications: [.floor]
        )
        let outOfRangeIndex = mesh(
            id: uuid(7_003),
            vertices: floorVertices(),
            indices: [0, 1, 9],
            classifications: [.floor]
        )
        let builder = ARVerifiedNavigationEvidenceBuilder()

        for malformed in [badTopology, missingClassification, outOfRangeIndex] {
            let snapshot = surface(
                mapID: context.mapID,
                frameID: context.frameID,
                segmentID: context.segmentID,
                meshes: [malformed]
            )
            XCTAssertEqual(
                try unwrapIssue(builder.adapt(snapshot, currentIdentity: context.identity)),
                .coverageAttestationUnavailable
            )
        }
    }

    func testHugeFiniteWallCoordinatesFailClosedWithoutIntegerConversionTrap() throws {
        let context = makeContext()
        let huge = Float.greatestFiniteMagnitude / 4
        let hugeWall = mesh(
            id: uuid(8_001),
            vertices: [
                SIMD3<Float>(huge, 0, 0),
                SIMD3<Float>(huge, 2, 0),
                SIMD3<Float>(huge, 2, 1),
            ],
            indices: [0, 1, 2],
            classifications: [.wall]
        )
        let snapshot = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            meshes: [denseFloorMesh(), hugeWall]
        )

        XCTAssertEqual(
            try unwrapIssue(
                ARVerifiedNavigationEvidenceBuilder().adapt(
                    snapshot,
                    currentIdentity: context.identity
                )
            ),
            .coverageAttestationUnavailable
        )
    }

    private func makeContext() -> NavigationEvidenceContext {
        let map = mapID(1)
        let frame = frameID(1)
        let segment = segmentID(1)
        return NavigationEvidenceContext(
            mapID: map,
            frameID: frame,
            segmentID: segment,
            identity: identity(mapID: map, frameID: frame, segmentID: segment),
            snapshot: surface(mapID: map, frameID: frame, segmentID: segment)
        )
    }

    private func surface(
        mapID: MapID?,
        frameID: CoordinateFrameID,
        segmentID: CaptureSegmentID,
        status: ARCaptureIdentity.Status = .confirmed,
        planes: [ARPlaneObservationSnapshot]? = nil,
        meshes: [ARMeshObservationSnapshot]? = nil,
        failures: [ARSurfaceObservationFailure] = [],
        isCurrentSessionData: Bool = true
    ) -> ARSurfaceStateSnapshot {
        let resolvedPlanes = planes ?? [floorPlane()]
        let resolvedMeshes = meshes ?? [denseFloorMesh()]
        return ARSurfaceStateSnapshot(
            coordinateFrameID: frameID,
            segmentID: segmentID,
            mapID: mapID,
            coordinateFrameStatus: status,
            revision: 7,
            timestamp: 10,
            planes: Dictionary(uniqueKeysWithValues: resolvedPlanes.map { ($0.anchorID, $0) }),
            meshes: Dictionary(uniqueKeysWithValues: resolvedMeshes.map { ($0.anchorID, $0) }),
            unresolvedFailures: failures,
            isCurrentSessionData: isCurrentSessionData
        )
    }

    private func floorPlane() -> ARPlaneObservationSnapshot {
        ARPlaneObservationSnapshot(
            anchorID: uuid(10_001),
            transform: Matrix4x4Snapshot(matrix_identity_float4x4),
            center: .zero,
            extent: SIMD3<Float>(2, 0, 2),
            extentRotationOnYAxis: 0,
            boundaryVertices: [
                SIMD3<Float>(-1, 0, -1),
                SIMD3<Float>(1, 0, -1),
                SIMD3<Float>(1, 0, 1),
                SIMD3<Float>(-1, 0, 1),
            ],
            alignment: .horizontal,
            classification: .floor
        )
    }

    private func verticalPlane(
        classification: ARPlaneClassificationSnapshot
    ) -> ARPlaneObservationSnapshot {
        let transform = simd_float4x4(
            columns: (
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 0, 1)
            ))
        return ARPlaneObservationSnapshot(
            anchorID: uuid(10_004 + classificationIndex(classification)),
            transform: Matrix4x4Snapshot(transform),
            center: SIMD3<Float>(0, 0, 1),
            extent: SIMD3<Float>(2, 0, 2),
            extentRotationOnYAxis: 0,
            boundaryVertices: [
                SIMD3<Float>(-1, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(1, 0, 2),
                SIMD3<Float>(-1, 0, 2),
            ],
            alignment: .vertical,
            classification: classification
        )
    }

    private func classificationIndex(_ classification: ARPlaneClassificationSnapshot) -> Int {
        switch classification {
        case .none: return 0
        case .wall: return 1
        case .floor: return 2
        case .ceiling: return 3
        case .table: return 4
        case .seat: return 5
        case .window: return 6
        case .door: return 7
        case .unknown: return 8
        }
    }

    private func denseFloorMesh(
        classifications: [ARMeshClassificationSnapshot] = [.floor, .floor]
    ) -> ARMeshObservationSnapshot {
        mesh(
            id: uuid(10_002),
            vertices: floorVertices(),
            indices: [0, 1, 2, 0, 2, 3],
            classifications: classifications
        )
    }

    private func floorVertices() -> [SIMD3<Float>] {
        [
            SIMD3<Float>(-1, 0, -1),
            SIMD3<Float>(1, 0, -1),
            SIMD3<Float>(1, 0, 1),
            SIMD3<Float>(-1, 0, 1),
        ]
    }

    private func floorMeshWithHole() -> ARMeshObservationSnapshot {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var classifications: [ARMeshClassificationSnapshot] = []

        func appendRectangle(minX: Float, maxX: Float, minZ: Float, maxZ: Float) {
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: [
                SIMD3<Float>(minX, 0, minZ),
                SIMD3<Float>(maxX, 0, minZ),
                SIMD3<Float>(maxX, 0, maxZ),
                SIMD3<Float>(minX, 0, maxZ),
            ])
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
            classifications.append(contentsOf: [.floor, .floor])
        }

        appendRectangle(minX: -1, maxX: -0.18, minZ: -1, maxZ: 1)
        appendRectangle(minX: -0.08, maxX: 1, minZ: -1, maxZ: 1)
        appendRectangle(minX: -0.18, maxX: -0.08, minZ: -1, maxZ: -0.18)
        appendRectangle(minX: -0.18, maxX: -0.08, minZ: -0.08, maxZ: 1)
        return mesh(
            id: uuid(10_003),
            vertices: vertices,
            indices: indices,
            classifications: classifications
        )
    }

    private func mesh(
        id: UUID,
        vertices: [SIMD3<Float>],
        indices: [UInt32],
        classifications: [ARMeshClassificationSnapshot]
    ) -> ARMeshObservationSnapshot {
        ARMeshObservationSnapshot(
            anchorID: id,
            transform: Matrix4x4Snapshot(matrix_identity_float4x4),
            vertices: vertices,
            triangleIndices: indices,
            faceClassifications: classifications
        )
    }

    private func identity(
        mapID: MapID?,
        frameID: CoordinateFrameID,
        segmentID: CaptureSegmentID,
        status: ARCaptureIdentity.Status = .confirmed
    ) -> ARCaptureIdentity {
        ARCaptureIdentity(
            coordinateFrameID: frameID,
            segmentID: segmentID,
            mapID: mapID,
            status: status
        )
    }

    private func unwrapReady(
        _ adaptation: ARIndoorNavigationEvidenceAdaptation
    ) throws -> IndoorNavigationEvidence {
        guard case .ready(let evidence) = adaptation else {
            throw NavigationEvidenceTestFailure.expectedReady
        }
        return evidence
    }

    private func unwrapIssue(
        _ adaptation: ARIndoorNavigationEvidenceAdaptation
    ) throws -> ARIndoorNavigationEvidenceIssue {
        guard case .insufficientEvidence(let issue) = adaptation else {
            throw NavigationEvidenceTestFailure.expectedInsufficientEvidence
        }
        return issue
    }

    private func mapID(_ value: Int) -> MapID {
        MapID(rawValue: uuid(100_000 + value))
    }

    private func frameID(_ value: Int) -> CoordinateFrameID {
        CoordinateFrameID(rawValue: uuid(200_000 + value))
    }

    private func segmentID(_ value: Int) -> CaptureSegmentID {
        CaptureSegmentID(rawValue: uuid(300_000 + value))
    }

    private func vec(_ x: Double, _ y: Double, _ z: Double) -> Vec3 {
        try! Vec3(x: x, y: y, z: z)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }
}

private struct NavigationEvidenceContext {
    let mapID: MapID
    let frameID: CoordinateFrameID
    let segmentID: CaptureSegmentID
    let identity: ARCaptureIdentity
    let snapshot: ARSurfaceStateSnapshot
}

private enum NavigationEvidenceTestFailure: Error {
    case expectedReady
    case expectedInsufficientEvidence
}
