import Foundation
import XCTest

@testable import VispaceCore

final class IndoorARNavigationTests: XCTestCase {
    private let navigationMapID = MapID(rawValue: testUUID(8_001))
    private let navigationFrameID = CoordinateFrameID(rawValue: testUUID(8_002))

    func testStraightObservedRouteSucceedsWithDistanceQualityAndConfidence() throws {
        let cells = lineCells(0...3)
        let evidence = try makeEvidence(cells: cells, revision: 42)

        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 3),
            using: evidence
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.reason, .routeFound)
        let path = try XCTUnwrap(result.path)
        XCTAssertEqual(path.waypoints.map(\.cell), cells)
        XCTAssertEqual(path.totalDistance, 3, accuracy: 1e-10)
        XCTAssertEqual(path.straightLineDistance, 3, accuracy: 1e-10)
        XCTAssertEqual(path.quality, .direct)
        XCTAssertEqual(path.confidence, .high)
        XCTAssertEqual(path.confidenceScore, score(0.9))
        XCTAssertEqual(path.evidenceRevision, 42)
        XCTAssertEqual(path.destinationObjectID, objectID(8_100))
    }

    func testRouteNeverCrossesMissingUnobservedCell() throws {
        let cells = [cell(0), cell(2)]
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 2),
            using: try makeEvidence(cells: cells)
        )

        XCTAssertEqual(result.status, .unreachable)
        XCTAssertEqual(result.reason, .noTraversableObservedRoute)
        XCTAssertNil(result.path)
    }

    func testIncompleteCoverageReturnsInsufficientEvidenceBeforePlanning() throws {
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 1),
            using: try makeEvidence(
                cells: lineCells(0...1),
                completeness: .unavailable
            )
        )

        XCTAssertEqual(result.status, .insufficientEvidence)
        XCTAssertEqual(result.reason, .evidenceCoverageIncomplete)
    }

    func testLowConfidenceFreeMeshBridgeReturnsInsufficientInsteadOfUnsafePath() throws {
        let cells = lineCells(0...2)
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 2),
            using: try makeEvidence(
                cells: cells,
                meshConfidence: { $0 == cell(1) ? 0.2 : 0.9 }
            )
        )

        XCTAssertEqual(result.status, .insufficientEvidence)
        XCTAssertEqual(result.reason, .uncertainRouteEvidence)
        XCTAssertNil(result.path)
    }

    func testUnknownMeshBridgeIsNeverUsedAndIsReportedAsUncertain() throws {
        let cells = lineCells(0...2)
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 2),
            using: try makeEvidence(
                cells: cells,
                occupancy: { $0 == cell(1) ? .unknown : .free }
            )
        )

        XCTAssertEqual(result.status, .insufficientEvidence)
        XCTAssertEqual(result.reason, .uncertainRouteEvidence)
    }

    func testBlockedMeshBridgeProducesDefinitiveUnreachableResult() throws {
        let cells = lineCells(0...2)
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 2),
            using: try makeEvidence(
                cells: cells,
                occupancy: { $0 == cell(1) ? .blocked : .free }
            )
        )

        XCTAssertEqual(result.status, .unreachable)
        XCTAssertEqual(result.reason, .noTraversableObservedRoute)
    }

    func testDifferentZonesCannotConnectWithoutObservedDoor() throws {
        let cells = lineCells(0...1)
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 1),
            using: try makeEvidence(
                cells: cells,
                zone: { $0.column == 0 ? "living" : "hall" }
            )
        )

        XCTAssertEqual(result.status, .unreachable)
    }

    func testVerifiedOpenDoorAllowsExactPortalAcrossCoarseWall() throws {
        let first = cell(0)
        let second = cell(1)
        let door = try IndoorNavigationDoorEvidence(
            identifier: "living-hall",
            firstCell: first,
            secondCell: second,
            state: .open,
            confidence: score(0.95)
        )
        let wall = try IndoorNavigationWallEvidence(
            identifier: "partition",
            start: vec(0.5, 0, -2),
            end: vec(0.5, 0, 2),
            thickness: 0.1,
            confidence: score(0.9)
        )
        let evidence = try makeEvidence(
            cells: [first, second],
            zone: { $0 == first ? "living" : "hall" },
            doors: [door],
            walls: [wall]
        )

        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 1),
            using: evidence
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.path?.waypoints.map(\.cell), [first, second])
        XCTAssertEqual(result.path?.confidenceScore, score(0.9))
    }

    func testClosedDoorIsUnreachableAndUnknownDoorIsInsufficient() throws {
        for state: IndoorNavigationDoorState in [.closed, .unknown] {
            let door = try IndoorNavigationDoorEvidence(
                identifier: "door",
                firstCell: cell(0),
                secondCell: cell(1),
                state: state,
                confidence: score(0.9)
            )
            let result = IndoorARNavigationEngine().route(
                from: try start(column: 0),
                to: try destination(column: 1),
                using: try makeEvidence(
                    cells: lineCells(0...1),
                    zone: { $0.column == 0 ? "a" : "b" },
                    doors: [door]
                )
            )
            if state == .closed {
                XCTAssertEqual(result.status, .unreachable)
            } else {
                XCTAssertEqual(result.status, .insufficientEvidence)
                XCTAssertEqual(result.reason, .uncertainRouteEvidence)
            }
        }
    }

    func testLowConfidenceOpenDoorIsNotTrusted() throws {
        let door = try IndoorNavigationDoorEvidence(
            identifier: "door",
            firstCell: cell(0),
            secondCell: cell(1),
            state: .open,
            confidence: score(0.2)
        )
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 1),
            using: try makeEvidence(
                cells: lineCells(0...1),
                zone: { $0.column == 0 ? "a" : "b" },
                doors: [door]
            )
        )

        XCTAssertEqual(result.status, .insufficientEvidence)
        XCTAssertEqual(result.reason, .uncertainRouteEvidence)
    }

    func testNarrowDoorCannotFitAgentAndUncertainWidthFailsClosed() throws {
        for confidence in [0.9, 0.2] {
            let door = try IndoorNavigationDoorEvidence(
                identifier: "narrow",
                firstCell: cell(0),
                secondCell: cell(1),
                state: .open,
                confidence: score(confidence),
                clearWidth: 0.3
            )
            let result = IndoorARNavigationEngine().route(
                from: try start(column: 0),
                to: try destination(column: 1),
                using: try makeEvidence(
                    cells: lineCells(0...1),
                    zone: { $0.column == 0 ? "a" : "b" },
                    doors: [door]
                )
            )
            if confidence >= 0.5 {
                XCTAssertEqual(result.status, .unreachable)
            } else {
                XCTAssertEqual(result.status, .insufficientEvidence)
                XCTAssertEqual(result.reason, .uncertainRouteEvidence)
            }
        }
    }

    func testConflictingDoorRecordsForSamePortalAreInvalidEvidence() throws {
        let first = try IndoorNavigationDoorEvidence(
            identifier: "door-open",
            firstCell: cell(0),
            secondCell: cell(1),
            state: .open,
            confidence: score(0.9)
        )
        let second = try IndoorNavigationDoorEvidence(
            identifier: "door-closed",
            firstCell: cell(1),
            secondCell: cell(0),
            state: .closed,
            confidence: score(0.9)
        )
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 1),
            using: try makeEvidence(
                cells: lineCells(0...1),
                zone: { $0.column == 0 ? "a" : "b" },
                doors: [first, second]
            )
        )
        XCTAssertEqual(result.status, .invalidEvidence)
        XCTAssertEqual(result.reason, .duplicateEvidence)
    }

    func testWallBlocksDirectEdgeAndPlannerUsesObservedDetour() throws {
        let cells = rectangleCells(columns: 0...2, rows: 0...1)
        let wall = try IndoorNavigationWallEvidence(
            identifier: "short-wall",
            start: vec(0.5, 0, -0.4),
            end: vec(1.5, 0, 0.4),
            thickness: 0.08,
            confidence: score(0.8)
        )
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0, row: 0),
            to: try destination(column: 2, row: 0),
            using: try makeEvidence(cells: cells, walls: [wall])
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertTrue(result.path?.waypoints.contains(where: { $0.cell.row == 1 }) == true)
        XCTAssertGreaterThan(result.path?.totalDistance ?? 0, 2)
        XCTAssertNotEqual(result.path?.quality, .direct)
    }

    func testFullWallDividerNeverReturnsAPathThroughWall() throws {
        let cells = rectangleCells(columns: 0...2, rows: -1...1)
        let wall = try IndoorNavigationWallEvidence(
            identifier: "divider",
            start: vec(0.5, 0, -2),
            end: vec(0.5, 0, 2),
            thickness: 0.1,
            confidence: score(0.2)
        )
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 2),
            using: try makeEvidence(cells: cells, walls: [wall])
        )

        XCTAssertEqual(result.status, .unreachable)
        XCTAssertNil(result.path)
    }

    func testCellCenteredOnWallCannotProduceAlreadyThereSuccess() throws {
        let wall = try IndoorNavigationWallEvidence(
            identifier: "center-wall",
            start: vec(0, 0, -1),
            end: vec(0, 0, 1),
            thickness: 0.1,
            confidence: score(0.9)
        )
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 0),
            using: try makeEvidence(cells: [cell(0)], walls: [wall])
        )
        XCTAssertEqual(result.status, .insufficientEvidence)
        XCTAssertEqual(result.reason, .endpointOutsideObservedFreeSpace)
        XCTAssertNil(result.path)
    }

    func testObstacleBlocksDirectEdgeAndRoutesAroundItsClearance() throws {
        let obstacle = try IndoorNavigationObstacleEvidence(
            identifier: "box",
            bounds: box(
                minX: 0.40, minY: 0, minZ: -0.10,
                maxX: 0.60, maxY: 1, maxZ: 0.10
            ),
            confidence: score(0.3)
        )
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 2),
            using: try makeEvidence(
                cells: rectangleCells(columns: 0...2, rows: 0...1),
                obstacles: [obstacle]
            )
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertTrue(result.path?.waypoints.contains(where: { $0.cell.row == 1 }) == true)
    }

    func testObstacleAtStoredObjectSnapsToNearestSafeApproachCell() throws {
        let destinationID = objectID(8_100)
        let obstacle = try IndoorNavigationObstacleEvidence(
            identifier: "target-furniture",
            objectID: destinationID,
            bounds: box(
                minX: 1.8, minY: 0, minZ: -0.2,
                maxX: 2.2, maxY: 1, maxZ: 0.2
            ),
            confidence: score(0.9)
        )
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 2),
            using: try makeEvidence(
                cells: lineCells(0...2),
                obstacles: [obstacle]
            )
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.path?.waypoints.last?.cell, cell(1))
        XCTAssertEqual(result.path?.destinationObjectID, destinationID)
    }

    func testDestinationApproachCannotSnapAcrossSeparateWall() throws {
        let wall = try IndoorNavigationWallEvidence(
            identifier: "approach-wall", start: vec(0.5, 0, -1), end: vec(0.5, 0, 1),
            thickness: 0.1, confidence: score(0.9)
        )
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0), to: try destination(column: 1),
            using: try makeEvidence(
                cells: lineCells(0...1), walls: [wall], obstacles: [targetObstacle(column: 1)]
            )
        )
        XCTAssertEqual(result.status, .insufficientEvidence)
        XCTAssertEqual(result.reason, .endpointOutsideObservedFreeSpace)
        XCTAssertNil(result.path)
    }

    func testDestinationApproachExemptsOnlyTargetBoundsContainingStoredPosition() throws {
        // Neither a different object nor another component carrying the same
        // ID away from the target may be ignored by the approach connector.
        for blockerID in [objectID(8_101), objectID(8_100)] {
            let blocker = try IndoorNavigationObstacleEvidence(
                identifier: "separate-blocker", objectID: blockerID,
                bounds: box(
                    minX: 0.4, minY: 0, minZ: -0.1,
                    maxX: 0.6, maxY: 1, maxZ: 0.1
                ), confidence: score(0.9)
            )
            let result = IndoorARNavigationEngine().route(
                from: try start(column: 0), to: try destination(column: 1),
                using: try makeEvidence(
                    cells: lineCells(0...1),
                    obstacles: [targetObstacle(column: 1), blocker]
                )
            )
            XCTAssertEqual(result.status, .insufficientEvidence)
            XCTAssertNil(result.path)
        }
    }

    func testDestinationApproachRequiresObservedEndpointAndIntermediateCells() throws {
        let policy = try IndoorNavigationPolicy(maximumDestinationSnapDistance: 3)
        for cells in [[cell(0), cell(2)], [cell(0), cell(1)]] {
            let result = IndoorARNavigationEngine(policy: policy).route(
                from: try start(column: 0), to: try destination(column: 2),
                using: try makeEvidence(cells: cells, obstacles: [targetObstacle(column: 2)])
            )
            XCTAssertEqual(result.status, .insufficientEvidence)
            XCTAssertEqual(result.reason, .endpointOutsideObservedFreeSpace)
            XCTAssertNil(result.path)
        }
    }

    func testDestinationObjectDoesNotExemptBlockedOrUnknownMesh() throws {
        for occupancy in [IndoorNavigationMeshOccupancy.blocked, .unknown] {
            let result = IndoorARNavigationEngine().route(
                from: try start(column: 0), to: try destination(column: 2),
                using: try makeEvidence(
                    cells: lineCells(0...2),
                    occupancy: { $0.column == 2 ? occupancy : .free },
                    obstacles: [targetObstacle(column: 2)]
                )
            )
            XCTAssertEqual(result.status, .insufficientEvidence)
            XCTAssertEqual(
                result.reason,
                occupancy == .unknown ? .uncertainRouteEvidence : .endpointOutsideObservedFreeSpace
            )
            XCTAssertNil(result.path)
        }
    }

    func testDestinationApproachTriesNextSafeSideWhenNearestSideIsWalledOff() throws {
        let wall = try IndoorNavigationWallEvidence(
            identifier: "short-approach-wall", start: vec(1.5, 0, -0.4), end: vec(1.5, 0, 0.4),
            thickness: 0.1, confidence: score(0.9)
        )
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0), to: try destination(column: 2),
            using: try makeEvidence(
                cells: lineCells(0...2) + [cell(1, 1), cell(2, 1)], walls: [wall],
                obstacles: [targetObstacle(column: 2)]
            )
        )
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.path?.waypoints.last?.cell, cell(2, 1))
        XCTAssertFalse(result.path?.waypoints.contains(where: { $0.cell == cell(2) }) == true)
    }

    func testDestinationApproachChoosesReachableSideOfOccupiedTarget() throws {
        let cells = lineCells(1...4)
        for orderedCells in [cells, Array(cells.reversed())] {
            for startColumn in [1, 3, 4] {
                let result = IndoorARNavigationEngine().route(
                    from: try start(column: startColumn), to: try destination(column: 2),
                    using: try makeEvidence(
                        cells: orderedCells, obstacles: [targetObstacle(column: 2)]
                    )
                )
                XCTAssertEqual(result.status, .success)
                let expectedGoal = startColumn == 1 ? cell(1) : cell(3)
                XCTAssertEqual(result.path?.waypoints.last?.cell, expectedGoal)
                XCTAssertEqual(result.reason, startColumn == 4 ? .routeFound : .alreadyAtDestination)
                XCTAssertFalse(result.path?.waypoints.contains { $0.cell == cell(2) } == true)
            }
        }
    }

    func testDestinationApproachConfidenceIncludesSweptTargetCell() throws {
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0), to: try destination(column: 2),
            using: try makeEvidence(
                cells: lineCells(0...2), floorConfidence: { $0.column == 2 ? 0.55 : 0.9 },
                obstacles: [targetObstacle(column: 2)]
            )
        )
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(try XCTUnwrap(result.path).confidenceScore.value, 0.55, accuracy: 1e-9)
    }

    func testEqualCostRoutesAndShuffledEvidenceAreDeterministic() throws {
        let expected = [cell(0), cell(0, -1), cell(1, -1), cell(2, -1), cell(2)]
        let cells = [
            cell(0), cell(0, -1), cell(1, -1), cell(2, -1),
            cell(0, 1), cell(1, 1), cell(2, 1), cell(2),
        ]
        var routes: [[IndoorNavigationCell]] = []
        for ordered in [cells, Array(cells.reversed())] {
            let result = IndoorARNavigationEngine().route(
                from: try start(column: 0),
                to: try destination(column: 2),
                using: try makeEvidence(cells: ordered)
            )
            XCTAssertEqual(result.status, .success)
            routes.append(result.path!.waypoints.map(\.cell))
        }
        XCTAssertEqual(routes[0], routes[1])
        XCTAssertEqual(routes[0], expected)
    }

    func testExcessiveElevationStepCannotBecomeAnEdge() throws {
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 1, elevation: 0.5),
            using: try makeEvidence(
                cells: lineCells(0...1),
                elevation: { $0.column == 0 ? 0 : 0.5 }
            )
        )

        XCTAssertEqual(result.status, .unreachable)
    }

    func testDifferentGridLevelsNeverGainAnInventedVerticalConnection() throws {
        let first = IndoorNavigationCell(level: 0, column: 0, row: 0)
        let second = IndoorNavigationCell(level: 1, column: 0, row: 0)
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 0, elevation: 0),
            using: try makeEvidence(cells: [first, second])
        )
        // Equal world positions deterministically snap both endpoints to level 0.
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.path?.waypoints.map(\.cell), [first])

        XCTAssertThrowsError(
            try IndoorNavigationDoorEvidence(
                identifier: "invented-stairs",
                firstCell: first,
                secondCell: second,
                state: .open,
                confidence: score(0.9)
            )
        )
    }

    func testAlreadyAtDestinationProducesOneGroundedWaypoint() throws {
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 0),
            using: try makeEvidence(cells: [cell(0)])
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.reason, .alreadyAtDestination)
        XCTAssertEqual(result.path?.waypoints.count, 1)
        XCTAssertEqual(result.path?.totalDistance, 0)
        XCTAssertEqual(result.path?.quality, .direct)
    }

    func testStartFrameTrackingAndFreshnessAreValidated() throws {
        let evidence = try makeEvidence(cells: lineCells(0...1))
        let wrongFrame = try FramedPosition(
            coordinateFrameID: CoordinateFrameID(rawValue: testUUID(9_999)),
            value: vec(0),
            observedAt: 99,
            trackingQuality: .normal,
            uncertainty: .highConfidenceDepth
        )
        XCTAssertEqual(
            IndoorARNavigationEngine().route(
                from: wrongFrame,
                to: try destination(column: 1),
                using: evidence
            ).reason,
            .startFrameMismatch
        )

        let unavailable = try start(column: 0, tracking: .limited)
        XCTAssertEqual(
            IndoorARNavigationEngine().route(
                from: unavailable,
                to: try destination(column: 1),
                using: evidence
            ).reason,
            .startTrackingUnavailable
        )

        let stale = try start(column: 0, observedAt: 90)
        XCTAssertEqual(
            IndoorARNavigationEngine().route(
                from: stale,
                to: try destination(column: 1),
                using: evidence
            ).reason,
            .startPoseStale
        )
    }

    func testDestinationMustBeSameMapAndFrameVerifiedStoredMetadata() throws {
        let evidence = try makeEvidence(cells: lineCells(0...1))
        let otherMap = MapID(rawValue: testUUID(9_001))
        XCTAssertEqual(
            IndoorARNavigationEngine().route(
                from: try start(column: 0),
                to: try destination(column: 1, mapID: otherMap),
                using: evidence
            ).reason,
            .destinationMapMismatch
        )

        let otherFrame = CoordinateFrameID(rawValue: testUUID(9_002))
        XCTAssertEqual(
            IndoorARNavigationEngine().route(
                from: try start(column: 0),
                to: try destination(column: 1, frameID: otherFrame),
                using: evidence
            ).reason,
            .destinationFrameMismatch
        )
    }

    func testCurrentPoseRoutesAgainstRecentOlderGeometryUsingEvaluationClock() throws {
        let evidence = try makeEvidence(cells: lineCells(0...1), observedAt: 100)
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0, observedAt: 100.4),
            to: try destination(column: 1),
            using: evidence,
            evaluatedAt: 100.4
        )
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(evidence.observedAt, 100)
    }

    func testEvaluationClockRejectsStaleAndFutureStartIndependentlyOfGeometry() throws {
        for timestamp in [94.9, 100.3] {
            let result = IndoorARNavigationEngine().route(
                from: try start(column: 0, observedAt: timestamp),
                to: try destination(column: 1),
                using: try makeEvidence(cells: lineCells(0...1), observedAt: 100),
                evaluatedAt: 100
            )
            XCTAssertEqual(result.status, .invalidStart)
            XCTAssertEqual(result.reason, .startPoseStale)
            XCTAssertNil(result.path)
        }
    }

    func testEvaluationClockRejectsStaleAndFutureGeometryIndependentlyOfStart() throws {
        for timestamp in [94.9, 100.3] {
            let result = IndoorARNavigationEngine().route(
                from: try start(column: 0, observedAt: 100),
                to: try destination(column: 1),
                using: try makeEvidence(cells: lineCells(0...1), observedAt: timestamp),
                evaluatedAt: 100
            )
            XCTAssertEqual(result.status, .invalidEvidence)
            XCTAssertEqual(result.reason, .evidenceStale)
            XCTAssertNil(result.path)
        }
    }

    func testEvaluationClockRejectsEquallyStaleInputsAndInvalidTime() throws {
        for evaluatedAt in [Double(106), -.infinity, .infinity, .nan, -1] {
            let result = IndoorARNavigationEngine().route(
                from: try start(column: 0, observedAt: 100),
                to: try destination(column: 1),
                using: try makeEvidence(cells: lineCells(0...1)),
                evaluatedAt: evaluatedAt
            )
            XCTAssertNotEqual(result.status, .success)
            XCTAssertNil(result.path)
        }
    }

    func testEvidenceAgePolicyIsIndependentAndDecodesOlderPolicyDocuments() throws {
        let policy = try IndoorNavigationPolicy(maximumStartAge: 1, maximumEvidenceAge: 10)
        let result = IndoorARNavigationEngine(policy: policy).route(
            from: try start(column: 0, observedAt: 105),
            to: try destination(column: 1),
            using: try makeEvidence(cells: lineCells(0...1), observedAt: 100),
            evaluatedAt: 105
        )
        XCTAssertEqual(result.status, .success)

        var legacy = try jsonObject(policy)
        legacy.removeValue(forKey: "maximumEvidenceAge")
        let decoded = try JSONDecoder().decode(
            IndoorNavigationPolicy.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertEqual(decoded.maximumStartAge, 1)
        XCTAssertEqual(decoded.maximumEvidenceAge, 5)
        XCTAssertThrowsError(try IndoorNavigationPolicy(maximumEvidenceAge: -.infinity))
        XCTAssertThrowsError(try IndoorNavigationPolicy(maximumEvidenceAge: -1))
    }

    func testStartCannotSnapOutOfBlockedUnknownOrUnobservedCell() throws {
        let blocked = try makeEvidence(
            cells: lineCells(0...1), occupancy: { $0.column == 0 ? .blocked : .free }
        )
        let unknown = try makeEvidence(
            cells: lineCells(0...1), occupancy: { $0.column == 0 ? .unknown : .free }
        )
        let unobserved = try makeEvidence(cells: [cell(1)])
        for evidence in [blocked, unknown, unobserved] {
            let result = IndoorARNavigationEngine().route(
                from: try start(column: 0),
                to: try destination(column: 1),
                using: evidence
            )
            XCTAssertEqual(result.status, .insufficientEvidence)
            XCTAssertNotEqual(result.reason, .alreadyAtDestination)
            XCTAssertNil(result.path)
        }
    }

    func testStartConnectorCannotCrossWallInsideContainingCell() throws {
        let wall = try IndoorNavigationWallEvidence(
            identifier: "wall-between-start-and-center",
            start: vec(0.25, 0, -1), end: vec(0.25, 0, 1),
            thickness: 0.02, confidence: score(0.9)
        )
        let result = IndoorARNavigationEngine().route(
            from: try start(at: vec(0.49)),
            to: try destination(column: 0),
            using: try makeEvidence(cells: lineCells(0...1), walls: [wall])
        )
        XCTAssertEqual(result.status, .insufficientEvidence)
        XCTAssertNil(result.path)
    }

    func testStartConnectorCannotCrossObstacleBetweenClearEndpoints() throws {
        let obstacle = try IndoorNavigationObstacleEvidence(
            identifier: "connector-obstacle",
            bounds: AABB(min: vec(0.20, 0, -0.02), max: vec(0.22, 1, 0.02)),
            confidence: score(0.9)
        )
        let policy = try IndoorNavigationPolicy(agentRadius: 0.05, obstacleClearance: 0.02)
        let result = IndoorARNavigationEngine(policy: policy).route(
            from: try start(at: vec(0.4)),
            to: try destination(column: 0),
            using: try makeEvidence(cells: [cell(0)], obstacles: [obstacle])
        )
        XCTAssertEqual(result.status, .insufficientEvidence)
        XCTAssertNil(result.path)
    }

    func testStartConnectorRequiresObservedFootprintBesideOffCenterPosition() throws {
        let result = IndoorARNavigationEngine().route(
            from: try start(at: vec(0.4)),
            to: try destination(column: 0),
            using: try makeEvidence(cells: [cell(0)])
        )
        XCTAssertEqual(result.status, .insufficientEvidence)
        XCTAssertNil(result.path)
    }

    func testSafeOffCenterStartIncludesVerifiedConnectorInPath() throws {
        let startPosition = try start(at: vec(0.4))
        let result = IndoorARNavigationEngine().route(
            from: startPosition,
            to: try destination(column: 1),
            using: try makeEvidence(cells: lineCells(0...1))
        )
        XCTAssertEqual(result.status, .success)
        let path = try XCTUnwrap(result.path)
        XCTAssertEqual(path.waypoints.first?.position, startPosition.value)
        XCTAssertEqual(path.waypoints.map(\.position), [vec(0.4), vec(0), vec(1)])
        XCTAssertEqual(path.totalDistance, 1.4, accuracy: 1e-10)
    }

    func testSafeConnectorToDestinationCellDoesNotClaimAlreadyArrived() throws {
        let result = IndoorARNavigationEngine().route(
            from: try start(at: vec(0.2)),
            to: try destination(column: 0),
            using: try makeEvidence(cells: [cell(0)])
        )
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.reason, .routeFound)
        XCTAssertEqual(try XCTUnwrap(result.path).totalDistance, 0.2, accuracy: 1e-10)
    }

    func testStartConnectorRespectsWaypointCapacity() throws {
        let policy = try IndoorNavigationPolicy(maximumWaypoints: 1)
        let result = IndoorARNavigationEngine(policy: policy).route(
            from: try start(at: vec(0.2)),
            to: try destination(column: 0),
            using: try makeEvidence(cells: [cell(0)])
        )
        XCTAssertEqual(result.reason, .waypointCapacityExceeded)
        XCTAssertNil(result.path)
    }

    func testProvisionalRemovedUntrackedAndLowConfidenceDestinationsAreRejected() throws {
        let evidence = try makeEvidence(cells: lineCells(0...1))
        let cases: [(SpatialObjectMetadata, IndoorNavigationReason)] = [
            (try destination(column: 1, certainty: .provisional), .destinationNotConfirmed),
            (try destination(column: 1, presence: .removed), .destinationRemoved),
            (
                try destination(column: 1, tracking: .limited),
                .destinationTrackingUnavailable
            ),
            (
                try destination(column: 1, confidence: 0.2),
                .destinationConfidenceTooLow
            ),
        ]
        for (destination, reason) in cases {
            XCTAssertEqual(
                IndoorARNavigationEngine().route(
                    from: try start(column: 0),
                    to: destination,
                    using: evidence
                ).reason,
                reason
            )
        }
    }

    func testDuplicateCellAndEvidenceIdentifiersAreRejectedDeterministically() throws {
        let duplicateCellEvidence = try makeEvidence(cells: [cell(0), cell(0)])
        XCTAssertEqual(
            IndoorARNavigationEngine().route(
                from: try start(column: 0),
                to: try destination(column: 0),
                using: duplicateCellEvidence
            ).reason,
            .duplicateEvidence
        )

        let wall = try IndoorNavigationWallEvidence(
            identifier: "same",
            start: vec(10, 0, 0),
            end: vec(10, 0, 1),
            thickness: 0.1,
            confidence: score(0.9)
        )
        let duplicateWallEvidence = try makeEvidence(
            cells: [cell(0)],
            walls: [wall, wall]
        )
        XCTAssertEqual(
            IndoorARNavigationEngine().route(
                from: try start(column: 0),
                to: try destination(column: 0),
                using: duplicateWallEvidence
            ).reason,
            .duplicateEvidence
        )
    }

    func testDoorMustReferenceExistingFloorCellsInDifferentZones() throws {
        let door = try IndoorNavigationDoorEvidence(
            identifier: "orphan",
            firstCell: cell(0),
            secondCell: cell(1),
            state: .open,
            confidence: score(0.9)
        )
        let orphan = try makeEvidence(cells: [cell(0)], doors: [door])
        XCTAssertEqual(
            IndoorARNavigationEngine().route(
                from: try start(column: 0),
                to: try destination(column: 0),
                using: orphan
            ).reason,
            .inconsistentDoorEvidence
        )

        let sameZone = try makeEvidence(cells: lineCells(0...1), doors: [door])
        XCTAssertEqual(
            IndoorARNavigationEngine().route(
                from: try start(column: 0),
                to: try destination(column: 1),
                using: sameZone
            ).reason,
            .inconsistentDoorEvidence
        )
    }

    func testInputExplorationAndWaypointCapacityLimitsFailClosed() throws {
        let cells = lineCells(0...3)
        let smallInputPolicy = try IndoorNavigationPolicy(maximumFloorCells: 2)
        XCTAssertEqual(
            IndoorARNavigationEngine(policy: smallInputPolicy).route(
                from: try start(column: 0),
                to: try destination(column: 3),
                using: try makeEvidence(cells: cells)
            ).reason,
            .inputCapacityExceeded
        )

        let smallExplorationPolicy = try IndoorNavigationPolicy(maximumExploredNodes: 1)
        XCTAssertEqual(
            IndoorARNavigationEngine(policy: smallExplorationPolicy).route(
                from: try start(column: 0),
                to: try destination(column: 3),
                using: try makeEvidence(cells: cells)
            ).reason,
            .explorationCapacityExceeded
        )

        let smallWaypointPolicy = try IndoorNavigationPolicy(maximumWaypoints: 2)
        XCTAssertEqual(
            IndoorARNavigationEngine(policy: smallWaypointPolicy).route(
                from: try start(column: 0),
                to: try destination(column: 3),
                using: try makeEvidence(cells: cells)
            ).reason,
            .waypointCapacityExceeded
        )
    }

    func testGridTooSmallToProveAgentClearanceIsInsufficientEvidence() throws {
        let evidence = try IndoorNavigationEvidence(
            mapID: navigationMapID,
            coordinateFrameID: navigationFrameID,
            revision: 1,
            observedAt: 100,
            gridOrigin: vec(0),
            cellSize: 0.25,
            floors: [
                try IndoorNavigationFloorEvidence(
                    cell: cell(0), zoneIdentifier: "room", elevation: 0,
                    confidence: score(0.9)
                )
            ],
            mesh: [
                IndoorNavigationMeshEvidence(
                    cell: cell(0), occupancy: .free, confidence: score(0.9)
                )
            ],
            completeness: .complete
        )
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 0),
            using: evidence
        )
        XCTAssertEqual(result.status, .insufficientEvidence)
        XCTAssertEqual(result.reason, .gridResolutionCannotProveClearance)
    }

    func testDerivedCoordinateOverflowFailsClosed() throws {
        let evidence = try IndoorNavigationEvidence(
            mapID: navigationMapID,
            coordinateFrameID: navigationFrameID,
            revision: 1,
            observedAt: 100,
            gridOrigin: vec(Double.greatestFiniteMagnitude),
            cellSize: Double.greatestFiniteMagnitude,
            floors: [
                try IndoorNavigationFloorEvidence(
                    cell: cell(1), zoneIdentifier: "room", elevation: 0,
                    confidence: score(0.9)
                )
            ],
            mesh: [
                IndoorNavigationMeshEvidence(
                    cell: cell(1), occupancy: .free, confidence: score(0.9)
                )
            ],
            completeness: .complete
        )

        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 1),
            using: evidence
        )
        XCTAssertEqual(result.status, .invalidEvidence)
        XCTAssertEqual(result.reason, .nonFiniteDerivedCoordinate)
    }

    func testEvidencePolicyPathAndResultCodableRoundTrips() throws {
        let evidence = try makeEvidence(cells: lineCells(0...2), revision: 77)
        let encodedEvidence = try JSONEncoder().encode(evidence)
        let restoredEvidence = try JSONDecoder().decode(
            IndoorNavigationEvidence.self,
            from: encodedEvidence
        )
        let encodedPolicy = try JSONEncoder().encode(IndoorNavigationPolicy.default)
        XCTAssertNoThrow(
            try JSONDecoder().decode(IndoorNavigationPolicy.self, from: encodedPolicy)
        )

        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 2),
            using: restoredEvidence
        )
        let encodedResult = try JSONEncoder().encode(result)
        let restoredResult = try JSONDecoder().decode(
            IndoorNavigationResult.self,
            from: encodedResult
        )
        XCTAssertEqual(restoredResult, result)
    }

    func testCodableRejectsInvalidEvidencePathAndResultInvariants() throws {
        var evidenceJSON = try jsonObject(try makeEvidence(cells: [cell(0)]))
        evidenceJSON["cellSize"] = -1
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                IndoorNavigationEvidence.self,
                from: try JSONSerialization.data(withJSONObject: evidenceJSON)
            )
        )

        let validResult = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 1),
            using: try makeEvidence(cells: lineCells(0...1))
        )
        var resultJSON = try jsonObject(validResult)
        var pathJSON = resultJSON["path"] as! [String: Any]
        pathJSON["totalDistance"] = 999
        resultJSON["path"] = pathJSON
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                IndoorNavigationResult.self,
                from: try JSONSerialization.data(withJSONObject: resultJSON)
            )
        )

        resultJSON = try jsonObject(validResult)
        resultJSON.removeValue(forKey: "path")
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                IndoorNavigationResult.self,
                from: try JSONSerialization.data(withJSONObject: resultJSON)
            )
        )

        resultJSON = try jsonObject(validResult)
        resultJSON["status"] = IndoorNavigationStatus.unreachable.rawValue
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                IndoorNavigationResult.self,
                from: try JSONSerialization.data(withJSONObject: resultJSON)
            )
        )
    }

    func testExtendedDetourQualityIsReported() throws {
        let cells = [
            cell(0), cell(0, 1), cell(1, 1), cell(2, 1), cell(2),
        ]
        let result = IndoorARNavigationEngine().route(
            from: try start(column: 0),
            to: try destination(column: 2),
            using: try makeEvidence(cells: cells)
        )
        XCTAssertEqual(result.status, .success)
        let path = try XCTUnwrap(result.path)
        XCTAssertEqual(path.totalDistance, 4, accuracy: 1e-10)
        XCTAssertEqual(path.straightLineDistance, 2, accuracy: 1e-10)
        XCTAssertEqual(path.quality, .extendedDetour)
    }

    // MARK: - Fixtures

    private func targetObstacle(column: Double) throws -> IndoorNavigationObstacleEvidence {
        try IndoorNavigationObstacleEvidence(
            identifier: "target-furniture", objectID: objectID(8_100),
            bounds: box(
                minX: column - 0.2, minY: 0, minZ: -0.2,
                maxX: column + 0.2, maxY: 1, maxZ: 0.2
            ), confidence: score(0.9)
        )
    }

    private func cell(_ column: Int, _ row: Int = 0) -> IndoorNavigationCell {
        IndoorNavigationCell(column: column, row: row)
    }

    private func lineCells(_ columns: ClosedRange<Int>) -> [IndoorNavigationCell] {
        columns.map { cell($0) }
    }

    private func rectangleCells(
        columns: ClosedRange<Int>,
        rows: ClosedRange<Int>
    ) -> [IndoorNavigationCell] {
        rows.flatMap { row in columns.map { cell($0, row) } }
    }

    private func makeEvidence(
        cells: [IndoorNavigationCell],
        revision: UInt64 = 1,
        observedAt: TimeInterval = 100,
        zone: (IndoorNavigationCell) -> String = { _ in "room" },
        elevation: (IndoorNavigationCell) -> Double = { _ in 0 },
        floorConfidence: (IndoorNavigationCell) -> Double = { _ in 0.9 },
        occupancy: (IndoorNavigationCell) -> IndoorNavigationMeshOccupancy = { _ in .free },
        meshConfidence: (IndoorNavigationCell) -> Double = { _ in 0.9 },
        doors: [IndoorNavigationDoorEvidence] = [],
        walls: [IndoorNavigationWallEvidence] = [],
        obstacles: [IndoorNavigationObstacleEvidence] = [],
        completeness: IndoorNavigationEvidenceCompleteness = .complete
    ) throws -> IndoorNavigationEvidence {
        try IndoorNavigationEvidence(
            mapID: navigationMapID,
            coordinateFrameID: navigationFrameID,
            revision: revision,
            observedAt: observedAt,
            gridOrigin: vec(0),
            cellSize: 1,
            floors: try cells.map {
                try IndoorNavigationFloorEvidence(
                    cell: $0,
                    zoneIdentifier: zone($0),
                    elevation: elevation($0),
                    confidence: score(floorConfidence($0))
                )
            },
            mesh: cells.map {
                IndoorNavigationMeshEvidence(
                    cell: $0,
                    occupancy: occupancy($0),
                    confidence: score(meshConfidence($0))
                )
            },
            doors: doors,
            walls: walls,
            obstacles: obstacles,
            completeness: completeness
        )
    }

    private func start(
        column: Int,
        row: Int = 0,
        observedAt: TimeInterval = 99,
        tracking: SpatialTrackingQuality = .normal
    ) throws -> FramedPosition {
        try FramedPosition(
            coordinateFrameID: navigationFrameID,
            value: vec(Double(column), 0, Double(row)),
            observedAt: observedAt,
            trackingQuality: tracking,
            uncertainty: .highConfidenceDepth
        )
    }

    private func start(at position: Vec3) throws -> FramedPosition {
        try FramedPosition(
            coordinateFrameID: navigationFrameID,
            value: position,
            observedAt: 99,
            trackingQuality: .normal,
            uncertainty: .highConfidenceDepth
        )
    }

    private func destination(
        column: Int,
        row: Int = 0,
        elevation: Double = 0,
        mapID: MapID? = nil,
        frameID: CoordinateFrameID? = nil,
        certainty: ObjectCertainty = .confirmed,
        presence: ObjectPresence = .lastSeen,
        tracking: SpatialTrackingQuality = .normal,
        confidence: Double = 0.9
    ) throws -> SpatialObjectMetadata {
        let position = vec(Double(column), elevation, Double(row))
        let object = try SpatialObject(
            id: objectID(8_100),
            semanticLabel: "sofa",
            position: position,
            certainty: certainty,
            presence: presence,
            confidence: vector(
                geometry: confidence,
                tracking: confidence,
                place: confidence,
                identity: confidence
            ),
            firstSeenAt: 1,
            lastSeenAt: 90
        )
        let framed = try FramedPosition(
            coordinateFrameID: frameID ?? navigationFrameID,
            value: position,
            observedAt: 90,
            trackingQuality: tracking,
            uncertainty: .highConfidenceDepth
        )
        return try SpatialObjectMetadata(
            mapID: mapID ?? navigationMapID,
            object: object,
            position: framed
        )
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
}
