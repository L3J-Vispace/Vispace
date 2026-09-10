import Foundation
import CoreVideo
import VispaceCore
import XCTest
import simd

@testable import Vispace

final class ARVerifiedNavigationEvidenceBuilderTests: XCTestCase {
    func testRecentDepthScanAllowsRouteFromActualCurrentFootprint() throws {
        let context = makeContext()
        let current = try depthFrame(identity: context.identity, timestamp: 10, cameraZ: 0.25, meters: 5)
        let previous = try depthFrame(identity: context.identity, timestamp: 9, cameraZ: 3, meters: 5)
        let evidence = try unwrapReady(ARVerifiedNavigationEvidenceBuilder().adapt(
            context.snapshot, currentIdentity: context.identity, currentDepthFrame: current,
            recentDepthFrames: [try XCTUnwrap(ARNavigationDepthFrame(previous))]
        ))
        let result = try routeFromCurrentFootprint(evidence: evidence, identity: context.identity)
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.path?.waypoints.first?.position, vec(0.25, 0, 0.25))
    }

    func testCurrentObstacleOverridesEarlierFreeScanAtStart() throws {
        let context = makeContext()
        let current = try depthFrame(identity: context.identity, timestamp: 10, cameraZ: 0.25, meters: 0.2)
        let previous = try depthFrame(identity: context.identity, timestamp: 9, cameraZ: 3, meters: 5)
        let result = ARVerifiedNavigationEvidenceBuilder().adapt(
            context.snapshot, currentIdentity: context.identity, currentDepthFrame: current,
            recentDepthFrames: [try XCTUnwrap(ARNavigationDepthFrame(previous))]
        )
        if case .ready(let evidence) = result {
            XCTAssertNil(try routeFromCurrentFootprint(evidence: evidence, identity: context.identity).path)
        }
    }

    func testExpiredScanCannotRestoreUnobservedCurrentStart() throws {
        let context = makeContext()
        let current = try depthFrame(identity: context.identity, timestamp: 10, cameraZ: 0.25, meters: 5)
        let previous = try depthFrame(identity: context.identity, timestamp: 6.9, cameraZ: 3, meters: 5)
        let result = ARVerifiedNavigationEvidenceBuilder().adapt(
            context.snapshot, currentIdentity: context.identity, currentDepthFrame: current,
            recentDepthFrames: [try XCTUnwrap(ARNavigationDepthFrame(previous))]
        )
        if case .ready(let evidence) = result {
            XCTAssertNil(try routeFromCurrentFootprint(evidence: evidence, identity: context.identity).path)
        }
    }

    @MainActor
    func testDepthHistoryIsBoundedExpiresAndClearsOnDeactivate() throws {
        let context = makeContext()
        let history = ARRecentNavigationDepthHistory(frameStreamProvider: { AsyncStream { $0.finish() } })
        for index in 0..<180 {
            history.consume(try depthFrame(identity: context.identity,
                timestamp: 10 + Double(index) / 60, cameraZ: 3, meters: 5))
        }
        let retained = history.frames(matching: context.identity, evaluatedAt: 13)
        XCTAssertLessThanOrEqual(retained.count, 16)
        XCTAssertGreaterThanOrEqual(retained.count, 14)
        let earliest = try XCTUnwrap(retained.first?.pose.timestamp)
        let latest = try XCTUnwrap(retained.last?.pose.timestamp)
        XCTAssertGreaterThan(latest - earliest, 2.5)
        XCTAssertTrue(history.frames(matching: context.identity, evaluatedAt: 16).isEmpty)
        history.deactivate()
        XCTAssertTrue(history.frames(matching: context.identity, evaluatedAt: 13).isEmpty)
    }

    func testStaticFloorCannotAttestCurrentDynamicFreeSpace() throws {
        let context = makeContext()
        XCTAssertEqual(try unwrapIssue(ARVerifiedNavigationEvidenceBuilder().adapt(
            context.snapshot, currentIdentity: context.identity
        )), .dynamicOccupancyUnavailable)
    }

    func testFreshSnapshotCannotHideStaleIndividualSurface() throws {
        let context = makeContext()
        let original = context.snapshot
        let stale = ARSurfaceStateSnapshot(
            coordinateFrameID: original.coordinateFrameID, segmentID: original.segmentID,
            mapID: original.mapID, coordinateFrameStatus: original.coordinateFrameStatus,
            revision: original.revision, timestamp: 10, planes: original.planes, meshes: original.meshes,
            unresolvedFailures: [], isCurrentSessionData: true,
            anchorObservedAt: original.anchorObservedAt.mapValues { _ in 1 }
        )
        XCTAssertEqual(try unwrapIssue(ARVerifiedNavigationEvidenceBuilder().adapt(
            stale, currentIdentity: context.identity
        )), .surfaceObservationStale)
    }

    func testDenseFullyClassifiedCurrentFloorProducesBoundedEvidence() throws {
        let context = makeContext()
        let builder = ARVerifiedNavigationEvidenceBuilder(
            cellSize: 0.5,
            maximumTriangleCount: 2,
            maximumCellCount: 16
        )

        let evidence = try unwrapReady(
            builder.adaptStaticGeometry(context.snapshot, currentIdentity: context.identity)
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

            let evidence = try unwrapReady(ARVerifiedNavigationEvidenceBuilder().adaptStaticGeometry(
                snapshot, currentIdentity: context.identity))
            XCTAssertTrue(evidence.mesh.allSatisfy { $0.occupancy == .blocked })
            XCTAssertNil(try routeFromCurrentFootprint(evidence: evidence, identity: context.identity).path)
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

            let evidence = try unwrapReady(builder.adaptStaticGeometry(snapshot, currentIdentity: context.identity))
            XCTAssertTrue(evidence.mesh.contains { $0.occupancy == .blocked })
            XCTAssertNil(try routeFromCurrentFootprint(evidence: evidence, identity: context.identity).path)
        }
    }

    func testUnrelatedUnclassifiedSurfacesDoNotDenyDepthVerifiedLocalRoute() throws {
        let context = makeContext()
        let current = try depthFrame(identity: context.identity, timestamp: 10, cameraZ: 0.25, meters: 5)
        let previous = try depthFrame(identity: context.identity, timestamp: 9, cameraZ: 3, meters: 5)
        for classification in [ARMeshClassificationSnapshot.none, .unknown] {
            let snapshot = surface(mapID: context.mapID, frameID: context.frameID,
                segmentID: context.segmentID,
                planes: [floorPlane(), shiftedUnknownPlane(x: 5)],
                meshes: [denseFloorMesh(), unclassifiedMesh(classification: classification, x: 5)])
            let evidence = try unwrapReady(ARVerifiedNavigationEvidenceBuilder().adapt(
                snapshot, currentIdentity: context.identity, currentDepthFrame: current,
                recentDepthFrames: [try XCTUnwrap(ARNavigationDepthFrame(previous))]))
            XCTAssertEqual(try routeFromCurrentFootprint(evidence: evidence, identity: context.identity).status,
                           .success)
        }
    }

    func testDepthCannotClearUnclassifiedFootprintIntersectingRoute() throws {
        let context = makeContext()
        let current = try depthFrame(identity: context.identity, timestamp: 10, cameraZ: 0.25, meters: 5)
        let previous = try depthFrame(identity: context.identity, timestamp: 9, cameraZ: 3, meters: 5)
        for classification in [ARMeshClassificationSnapshot.none, .unknown] {
            let snapshot = surface(mapID: context.mapID, frameID: context.frameID,
                segmentID: context.segmentID,
                meshes: [denseFloorMesh(), unclassifiedMesh(classification: classification, x: 0)])
            let evidence = try unwrapReady(ARVerifiedNavigationEvidenceBuilder().adapt(
                snapshot, currentIdentity: context.identity, currentDepthFrame: current,
                recentDepthFrames: [try XCTUnwrap(ARNavigationDepthFrame(previous))]))
            XCTAssertTrue(evidence.mesh.contains { $0.occupancy == .blocked })
            XCTAssertNil(try routeFromCurrentFootprint(evidence: evidence, identity: context.identity).path)
        }
    }

    func testUnclassifiedGeometryStillRequiresActualFreshAnchorEvidence() throws {
        let context = makeContext()
        let unknown = unclassifiedMesh(classification: .unknown, x: 0)
        let original = surface(mapID: context.mapID, frameID: context.frameID,
            segmentID: context.segmentID, meshes: [denseFloorMesh(), unknown])
        let observationTimes: [TimeInterval?] = [4, nil]
        for observedAt in observationTimes {
            var observations = original.anchorObservedAt
            observations[unknown.anchorID] = observedAt
            let snapshot = ARSurfaceStateSnapshot(
                coordinateFrameID: original.coordinateFrameID, segmentID: original.segmentID,
                mapID: original.mapID, coordinateFrameStatus: original.coordinateFrameStatus,
                revision: original.revision, timestamp: original.timestamp,
                planes: original.planes, meshes: original.meshes, unresolvedFailures: [],
                isCurrentSessionData: true, anchorObservedAt: observations)
            XCTAssertEqual(try unwrapIssue(ARVerifiedNavigationEvidenceBuilder().adaptStaticGeometry(
                snapshot, currentIdentity: context.identity)), .surfaceObservationStale)
        }
    }

    func testUnclassifiedGeometryWithMalformedBoundsStillFailsClosed() throws {
        let context = makeContext()
        for invalidX in [Float.nan, Float.greatestFiniteMagnitude] {
            let snapshot = surface(mapID: context.mapID, frameID: context.frameID,
                segmentID: context.segmentID,
                meshes: [denseFloorMesh(), unclassifiedMesh(classification: .unknown, x: invalidX)])
            XCTAssertEqual(try unwrapIssue(ARVerifiedNavigationEvidenceBuilder().adaptStaticGeometry(
                snapshot, currentIdentity: context.identity)), .coverageAttestationUnavailable)
        }
        let invalidPlane = shiftedUnknownPlane(x: .nan)
        let snapshot = surface(mapID: context.mapID, frameID: context.frameID,
            segmentID: context.segmentID, planes: [floorPlane(), invalidPlane])
        XCTAssertEqual(try unwrapIssue(ARVerifiedNavigationEvidenceBuilder().adaptStaticGeometry(
            snapshot, currentIdentity: context.identity)), .coverageAttestationUnavailable)
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
            try unwrapIssue(builder.adaptStaticGeometry(sparseSnapshot, currentIdentity: context.identity)),
            .coverageAttestationUnavailable
        )
        XCTAssertEqual(
            try unwrapIssue(builder.adaptStaticGeometry(noPlaneSnapshot, currentIdentity: context.identity)),
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
            ARVerifiedNavigationEvidenceBuilder().adaptStaticGeometry(
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
            ARVerifiedNavigationEvidenceBuilder().adaptStaticGeometry(
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
            ARVerifiedNavigationEvidenceBuilder().adaptStaticGeometry(
                snapshot,
                currentIdentity: context.identity
            )
        )

        XCTAssertTrue(evidence.mesh.contains { $0.occupancy == .blocked })
        XCTAssertFalse(evidence.mesh.allSatisfy { $0.occupancy == .free })
        XCTAssertFalse(evidence.walls.isEmpty)
    }

    func testUnverifiedDoorGeometryBlocksLocallyAndPreservesOtherCells() throws {
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
            let evidence = try unwrapReady(
                ARVerifiedNavigationEvidenceBuilder().adaptStaticGeometry(
                    snapshot, currentIdentity: context.identity))
            XCTAssertFalse(evidence.doors.isEmpty)
            XCTAssertTrue(evidence.doors.allSatisfy { $0.state == .unknown })
            XCTAssertTrue(evidence.mesh.contains { $0.occupancy == .unknown })
            XCTAssertTrue(evidence.mesh.contains { $0.occupancy == .free })
        }
    }

    func testDoorRequiresCurrentDepthAndIndependentRecentView() throws {
        let context = makeContext()
        let snapshot = surface(
            mapID: context.mapID, frameID: context.frameID,
            segmentID: context.segmentID, planes: [floorPlane(), verticalPlane(classification: .door)])
        let current = try depthFrame(identity: context.identity, timestamp: 10, cameraZ: 3, meters: 5)
        let previous = try depthFrame(identity: context.identity, timestamp: 9.5, cameraZ: 3.2, meters: 5)
        let builder = ARVerifiedNavigationEvidenceBuilder()
        let open = try unwrapReady(
            builder.adapt(
                snapshot, currentIdentity: context.identity,
                currentDepthFrame: current,
                recentDepthFrames: [try XCTUnwrap(ARNavigationDepthFrame(previous))]))
        XCTAssertTrue(open.doors.contains { $0.state == .open })
        XCTAssertEqual(
            try routeFromCurrentFootprint(evidence: open, identity: context.identity).status, .success)
        XCTAssertTrue(open.doors.allSatisfy { $0.observedAt == 10 && $0.validUntil == 10.75 })
        XCTAssertEqual(
            open.doors.filter { $0.state == .open }.map(\.clearWidth).min() ?? 0, 1.4, accuracy: 0.0001)
        let single = try unwrapReady(
            builder.adapt(snapshot, currentIdentity: context.identity, currentDepthFrame: current))
        XCTAssertTrue(single.doors.allSatisfy { $0.state == .unknown })
        XCTAssertNil(try routeFromCurrentFootprint(evidence: single, identity: context.identity).path)
        XCTAssertEqual(
            try routeFromCurrentFootprint(
                evidence: single, identity: context.identity,
                from: vec(-0.75, 0, 0.25), to: vec(-0.75, 0, -0.25)
            ).status, .success)
        let duplicatePose = try depthFrame(identity: context.identity, timestamp: 9.5, cameraZ: 3, meters: 5)
        let stationary = try unwrapReady(
            builder.adapt(
                snapshot, currentIdentity: context.identity,
                currentDepthFrame: current,
                recentDepthFrames: [try XCTUnwrap(ARNavigationDepthFrame(duplicatePose))]))
        XCTAssertTrue(stationary.doors.allSatisfy { $0.state == .unknown })
        let expired = try depthFrame(identity: context.identity, timestamp: 8.9, cameraZ: 3.2, meters: 5)
        let stale = try unwrapReady(
            builder.adapt(
                snapshot, currentIdentity: context.identity,
                currentDepthFrame: current,
                recentDepthFrames: [try XCTUnwrap(ARNavigationDepthFrame(expired))]))
        XCTAssertTrue(stale.doors.allSatisfy { $0.state == .unknown })
    }

    func testCurrentDoorBlockerOverridesOpenHistoryAtSameSurfaceRevision() throws {
        let context = makeContext()
        let snapshot = surface(
            mapID: context.mapID, frameID: context.frameID,
            segmentID: context.segmentID, planes: [floorPlane(), verticalPlane(classification: .door)])
        let previous = try depthFrame(identity: context.identity, timestamp: 9.5, cameraZ: 3.2, meters: 5)
        let current = try depthFrame(
            identity: context.identity, timestamp: 10, cameraZ: 3,
            meters: 5, blockedDoorPixel: true)
        let result = try unwrapReady(
            ARVerifiedNavigationEvidenceBuilder().adapt(
                snapshot,
                currentIdentity: context.identity, currentDepthFrame: current,
                recentDepthFrames: [try XCTUnwrap(ARNavigationDepthFrame(previous))]))
        XCTAssertTrue(result.doors.allSatisfy { $0.state == .closed })
        XCTAssertTrue(result.mesh.contains { $0.occupancy == .blocked })
        XCTAssertTrue(result.mesh.contains { $0.occupancy == .free })
        XCTAssertNil(try routeFromCurrentFootprint(evidence: result, identity: context.identity).path)
        XCTAssertEqual(
            try routeFromCurrentFootprint(
                evidence: result, identity: context.identity,
                from: vec(-0.75, 0, 0.25), to: vec(-0.75, 0, -0.25)
            ).status, .success)
    }

    func testRotatedDoorMeasuresBothCrossingGridDirections() throws {
        let context = makeContext()
        let candidate = try unwrapReady(
            ARVerifiedNavigationEvidenceBuilder().adaptStaticGeometry(
                context.snapshot, currentIdentity: context.identity))
        let door = try XCTUnwrap(
            ARObservedDoorSurface(
                identifier: "rotated-door",
                vertices: [vec(-0.8, 0, -0.8), vec(0.8, 0, 0.8), vec(0.8, 2, 0.8), vec(-0.8, 2, -0.8)],
                supportsOpeningMeasurement: true))
        XCTAssertTrue(door.supportsOpeningMeasurement)
        XCTAssertEqual(door.width, sqrt(2) * 1.6, accuracy: 0.0001)
        let current = try depthFrame(identity: context.identity, timestamp: 10, cameraZ: 3, meters: 5)
        let previous = try depthFrame(identity: context.identity, timestamp: 9.5, cameraZ: 3.2, meters: 5)
        let result = try XCTUnwrap(
            ARObservedDoorEvidenceProvider().observe(
                surfaces: [door],
                gridOrigin: candidate.gridOrigin, cellSize: candidate.cellSize,
                floors: candidate.floors, mesh: candidate.mesh,
                frames: [
                    try XCTUnwrap(ARNavigationDepthFrame(current)),
                    try XCTUnwrap(ARNavigationDepthFrame(previous)),
                ],
                confidence: .one))
        XCTAssertTrue(
            result.doors.contains { $0.state == .open && $0.firstCell.column != $0.secondCell.column })
        XCTAssertTrue(result.doors.contains { $0.state == .open && $0.firstCell.row != $0.secondCell.row })
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
                ARVerifiedNavigationEvidenceBuilder().adaptStaticGeometry(
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
            builder.adaptStaticGeometry(snapshot, currentIdentity: context.identity)
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
            try unwrapIssue(builder.adaptStaticGeometry(context.snapshot, currentIdentity: relocalizing)),
            .captureNotConfirmed
        )
        XCTAssertEqual(
            try unwrapIssue(builder.adaptStaticGeometry(context.snapshot, currentIdentity: foreignMap)),
            .currentMapUnavailable
        )
        XCTAssertEqual(
            try unwrapIssue(builder.adaptStaticGeometry(context.snapshot, currentIdentity: foreignFrame)),
            .coordinateContextMismatch
        )
        XCTAssertEqual(
            try unwrapIssue(builder.adaptStaticGeometry(context.snapshot, currentIdentity: foreignSegment)),
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
            try unwrapIssue(builder.adaptStaticGeometry(inactive, currentIdentity: context.identity)),
            .surfaceSnapshotIncomplete
        )
        XCTAssertEqual(
            try unwrapIssue(builder.adaptStaticGeometry(failed, currentIdentity: context.identity)),
            .surfaceSnapshotIncomplete
        )
    }

    func testTriangleAndCellCapacityBoundariesFailClosed() throws {
        let context = makeContext()
        let exactCapacityEvidence = try unwrapReady(
            ARVerifiedNavigationEvidenceBuilder(
                maximumTriangleCount: 2,
                maximumCellCount: 16
            ).adaptStaticGeometry(context.snapshot, currentIdentity: context.identity)
        )
        XCTAssertEqual(exactCapacityEvidence.floors.count, 16)

        let triangleOverflow = ARVerifiedNavigationEvidenceBuilder(
            maximumTriangleCount: 1,
            maximumCellCount: 16
        )
        XCTAssertEqual(
            try unwrapIssue(
                triangleOverflow.adaptStaticGeometry(context.snapshot, currentIdentity: context.identity)
            ),
            .coverageAttestationUnavailable
        )

        let cellOverflow = ARVerifiedNavigationEvidenceBuilder(
            maximumTriangleCount: 2,
            maximumCellCount: 15
        )
        XCTAssertEqual(
            try unwrapIssue(
                cellOverflow.adaptStaticGeometry(context.snapshot, currentIdentity: context.identity)
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
            builder.adaptStaticGeometry(context.snapshot, currentIdentity: context.identity)
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
                ARVerifiedNavigationEvidenceBuilder(maximumWallCount: 1).adaptStaticGeometry(
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
                try unwrapIssue(builder.adaptStaticGeometry(snapshot, currentIdentity: context.identity)),
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
                ARVerifiedNavigationEvidenceBuilder().adaptStaticGeometry(
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
            isCurrentSessionData: isCurrentSessionData,
            anchorObservedAt: Dictionary(uniqueKeysWithValues:
                (resolvedPlanes.map(\.anchorID) + resolvedMeshes.map(\.anchorID)).map { ($0, 10) })
        )
    }

    private func depthFrame(identity: ARCaptureIdentity, timestamp: TimeInterval,
        cameraZ: Float, meters: Float, blockedDoorPixel: Bool = false
    ) throws -> ARFrameSnapshot {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 1, 1,
            kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        var camera = matrix_identity_float4x4
        camera.columns.3 = SIMD4<Float>(0.25, 1, cameraZ, 1)
        let pose = ARPoseSnapshot(id: ARFrameID(),
            sessionToken: ARSessionFrameToken(sessionRunGeneration: 1, attachmentEpoch: 1),
            coordinateFrameID: identity.coordinateFrameID, segmentID: identity.segmentID,
            mapID: identity.mapID, coordinateFrameStatus: .confirmed, capturedAt: 100,
            timestamp: timestamp, cameraTransform: Matrix4x4Snapshot(camera),
            trackingState: .normal, worldMappingStatus: .mapped)
        var depths = Array(repeating: meters, count: 10_000)
        if blockedDoorPixel { depths[50 * 100 + 45] = 2.8 }
        return ARFrameSnapshot(pose: pose, imageOrientation: .up,
            capturedImage: ImmutablePixelBuffer(pixelBuffer: try XCTUnwrap(pixelBuffer)),
            cameraIntrinsics: Matrix3x3Snapshot(simd_float3x3(columns: (
                SIMD3<Float>(50, 0, 0), SIMD3<Float>(0, 50, 0), SIMD3<Float>(50, 50, 1)))),
            cameraImageDimensions: ImageDimensions(width: 100, height: 100), displayTransform: nil,
            sceneDepth: ARDepthSnapshot(dimensions: ImageDimensions(width: 100, height: 100),
                depthMeters: depths,
                confidence: Array(repeating: 2, count: 10_000)), smoothedSceneDepth: nil)
    }

    private func routeFromCurrentFootprint(evidence: IndoorNavigationEvidence,
        identity: ARCaptureIdentity,
        from startPosition: Vec3? = nil,
        to targetPosition: Vec3? = nil
    ) throws -> IndoorNavigationResult {
        let destinationPosition = targetPosition ?? vec(-0.25, 0, -0.25)
        let confidence = ConfidenceScore(clamping: 0.9)
        let destination = try SpatialObjectMetadata(mapID: XCTUnwrap(identity.mapID),
            object: SpatialObject(semanticLabel: "chair", position: destinationPosition,
                certainty: .confirmed, confidence: ConfidenceVector(semantic: confidence,
                    geometry: confidence, tracking: confidence, place: confidence,
                    identity: confidence, objectState: confidence), firstSeenAt: 1, lastSeenAt: 10),
            position: FramedPosition(coordinateFrameID: identity.coordinateFrameID,
                value: destinationPosition, observedAt: 10, trackingQuality: .normal,
                uncertainty: .highConfidenceDepth))
        return IndoorARNavigationEngine().route(from: try FramedPosition(
                coordinateFrameID: identity.coordinateFrameID, value: startPosition ?? vec(0.25, 0, 0.25),
                observedAt: 10, trackingQuality: .normal, uncertainty: .raycastEstimate),
            to: destination, using: evidence, evaluatedAt: 10)
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

    private func shiftedUnknownPlane(x: Float) -> ARPlaneObservationSnapshot {
        let original = verticalPlane(classification: .unknown)
        var transform = original.transform.simdValue
        transform.columns.3.x = x
        return ARPlaneObservationSnapshot(anchorID: original.anchorID,
            transform: Matrix4x4Snapshot(transform), center: original.center, extent: original.extent,
            extentRotationOnYAxis: original.extentRotationOnYAxis,
            boundaryVertices: original.boundaryVertices, alignment: original.alignment,
            classification: original.classification)
    }

    private func unclassifiedMesh(
        classification: ARMeshClassificationSnapshot, x: Float
    ) -> ARMeshObservationSnapshot {
        mesh(id: uuid(10_100), vertices: [
            SIMD3<Float>(x, 0, -1), SIMD3<Float>(x, 2, -1), SIMD3<Float>(x, 2, 1),
        ], indices: [0, 1, 2], classifications: [classification])
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
