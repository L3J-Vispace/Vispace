import Foundation
import VispaceCore
import XCTest
import simd

@testable import Vispace

@MainActor
final class FurniturePlacementControllerTests: XCTestCase {
    func testDefaultFurnitureDimensionsAreStableAndPhysicallyMeaningful() {
        let sofa = ARFurnitureDefaults.dimensions(for: .sofa)
        let bed = ARFurnitureDefaults.dimensions(for: .bed)
        let desk = ARFurnitureDefaults.dimensions(for: .desk)

        XCTAssertEqual([sofa.width, sofa.depth, sofa.height], [2.0, 0.9, 0.9])
        XCTAssertEqual([bed.width, bed.depth, bed.height], [1.6, 2.0, 0.6])
        XCTAssertEqual([desk.width, desk.depth, desk.height], [1.4, 0.7, 0.75])
    }

    func testBuilderUsesActualProductDimensions() throws {
        let context = spatialContext()
        let dimensions = try FurnitureDimensions(kind: .desk, width: 1.8, depth: 0.8, height: 1.1)
        let prepared = try unwrapReady(builder().build(
            kind: .desk,
            candidatePosition: framedPosition(frameID: context.frameID, value: vec(0, 0, 0)),
            surface: context.surface, pose: context.pose,
            capabilities: fullCapabilities(), objects: [], furnitureDimensions: dimensions
        ))
        XCTAssertEqual(prepared.candidate.furniture, dimensions)
    }

    func testBuilderPreservesProviderCoordinateAndUsesHorizontalHeadingForYaw() throws {
        let context = spatialContext(cameraTransform: cameraYawNinetyDegrees())
        let candidate = try framedPosition(
            frameID: context.frameID,
            value: vec(0.5, 0, -0.25)
        )

        let prepared = try unwrapReady(
            builder().build(
                kind: .desk,
                candidatePosition: candidate,
                surface: context.surface,
                pose: context.pose,
                capabilities: fullCapabilities(),
                objects: []
            )
        )

        XCTAssertEqual(prepared.sourcePosition, candidate)
        XCTAssertEqual(prepared.candidate.position, candidate.value)
        XCTAssertEqual(prepared.candidate.furniture, ARFurnitureDefaults.dimensions(for: .desk))
        XCTAssertEqual(prepared.candidate.yawRadians, .pi / 2, accuracy: 1e-6)
    }

    func testPortraitFurnitureRotationRemainsLevelAcrossTiltAndYaw() throws {
        for yaw in [-Double.pi / 2, 0.0, Double.pi / 3] {
            for pitch in [-20.0, 0, 20] {
                let camera = portraitCamera(yaw: yaw, pitch: pitch * .pi / 180)
                let context = spatialContext(cameraTransform: camera)
                let prepared = try unwrapReady(
                    builder().build(
                        kind: .desk,
                        candidatePosition: framedPosition(frameID: context.frameID, value: .zero),
                        surface: context.surface, pose: context.pose,
                        capabilities: fullCapabilities(), objects: []
                    ))
                XCTAssertEqual(prepared.candidate.yawRadians, yaw, accuracy: 1e-6)
                XCTAssertEqual(context.pose.cameraTransform.simdValue, camera)
                XCTAssertEqual(
                    FurniturePlacementEvaluator().evaluate(
                        candidate: prepared.candidate, evidence: prepared.evidence
                    ).disposition, .feasible)
            }
        }
    }

    func testVerticallyPointingCameraCannotInventFurnitureYaw() throws {
        let context = spatialContext(cameraTransform: portraitCamera(yaw: 0, pitch: .pi / 2))
        XCTAssertEqual(
            try unwrapIssue(
                builder().build(
                    kind: .desk,
                    candidatePosition: framedPosition(frameID: context.frameID, value: .zero),
                    surface: context.surface, pose: context.pose,
                    capabilities: fullCapabilities(), objects: []
                )), .trackingUnstable)
    }

    func testFloorPlaneBecomesConservativelyInsetFloorAndObservationRegions() throws {
        let context = spatialContext(
            floorTransform: translationMatrix(x: 2, y: 0.25, z: -3),
            floorExtent: SIMD3<Float>(6, 0, 4)
        )
        let candidate = try framedPosition(
            frameID: context.frameID,
            value: vec(2, 0.25, -3)
        )

        let prepared = try unwrapReady(
            builder().build(
                kind: .sofa,
                candidatePosition: candidate,
                surface: context.surface,
                pose: context.pose,
                capabilities: fullCapabilities(),
                objects: []
            )
        )

        XCTAssertEqual(prepared.evidence.floors.count, 1)
        XCTAssertEqual(prepared.evidence.observations.count, 1)
        let floor = try XCTUnwrap(prepared.evidence.floors.first)
        XCTAssertEqual(floor.region.center.x, 2, accuracy: 1e-6)
        XCTAssertEqual(floor.region.center.y, 0.25, accuracy: 1e-6)
        XCTAssertEqual(floor.region.center.z, -3, accuracy: 1e-6)
        XCTAssertEqual(floor.region.width, 6 * 0.85, accuracy: 1e-6)
        XCTAssertEqual(floor.region.depth, 4 * 0.85, accuracy: 1e-6)
        XCTAssertEqual(floor.elevation, 0.25, accuracy: 1e-6)
    }

    func testPartiallyMeshedBroadPlanePreservesVerifiedCandidatePassage() throws {
        var vertices: [SIMD3<Float>] = []
        for row in 0..<8 {
            for column in 0..<8 {
                let minX = -2 + Float(column) * 0.5
                let minZ = -2 + Float(row) * 0.5
                vertices.append(
                    contentsOf: rectangleVertices(
                        minX: minX, minZ: minZ, maxX: minX + 0.5, maxZ: minZ + 0.5
                    ))
            }
        }
        let context = spatialContext(
            mesh: mesh(
                id: uuid(10_001), vertices: vertices,
                classifications: Array(repeating: .floor, count: vertices.count / 3)
            ))
        let prepared = try unwrapReady(
            ARFurniturePlacementEvidenceBuilder().build(
                kind: .sofa,
                candidatePosition: framedPosition(frameID: context.frameID, value: .zero),
                surface: context.surface, pose: context.pose,
                capabilities: fullCapabilities(), objects: []
            ))

        XCTAssertEqual(prepared.summary.localClassifiedTriangleCount, 128)
        XCTAssertTrue(prepared.summary.lidarEvidenceComplete)
        let observation = try XCTUnwrap(prepared.evidence.observations.first)
        XCTAssertEqual(observation.region.width, 3.6, accuracy: 1e-6)
        XCTAssertEqual(observation.region.depth, 2.5, accuracy: 1e-6)
        XCTAssertEqual(
            FurniturePlacementEvaluator().evaluate(
                candidate: prepared.candidate, evidence: prepared.evidence
            ).disposition, .feasible)
    }

    func testMinimumObservedMarginIsInsufficientPassageEvidenceNotARejection() throws {
        var vertices: [SIMD3<Float>] = []
        for row in 0..<8 {
            for column in 0..<8 {
                let minX = -1.375 + Float(column) * 0.34375
                let minZ = -0.75 + Float(row) * 0.1875
                vertices.append(
                    contentsOf: rectangleVertices(
                        minX: minX, minZ: minZ, maxX: minX + 0.34375, maxZ: minZ + 0.1875
                    ))
            }
        }
        let context = spatialContext(
            mesh: mesh(
                id: uuid(10_002), vertices: vertices,
                classifications: Array(repeating: .floor, count: vertices.count / 3)
            ))
        let prepared = try unwrapReady(
            ARFurniturePlacementEvidenceBuilder().build(
                kind: .sofa,
                candidatePosition: framedPosition(frameID: context.frameID, value: .zero),
                surface: context.surface, pose: context.pose,
                capabilities: fullCapabilities(), objects: []
            ))

        XCTAssertTrue(prepared.summary.lidarEvidenceComplete)
        XCTAssertEqual(prepared.evidence.observations.count, 1)
        XCTAssertTrue(prepared.evidence.passages.isEmpty)
        XCTAssertFalse(prepared.evidence.completeness.passagesMapped)
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: prepared.candidate, evidence: prepared.evidence
        )
        XCTAssertEqual(result.disposition, .insufficientEvidence)
        XCTAssertTrue(result.reasons.contains { $0.code == .passageEvidenceIncomplete })
        XCTAssertFalse(result.reasons.contains { $0.code == .passageWidthTooNarrow })
    }

    func testClassifiedWallDoorAndObjectBoundsBecomeBoundedEvidence() throws {
        let map = mapID(10)
        let frame = frameID(10)
        let context = spatialContext(
            mapID: map,
            frameID: frame,
            additionalPlanes: [
                plane(
                    id: uuid(10_010),
                    center: SIMD3<Float>(3, 0, 0),
                    extent: SIMD3<Float>(2, 0, 2),
                    alignment: .vertical,
                    classification: .wall
                ),
                plane(
                    id: uuid(10_011),
                    center: SIMD3<Float>(-3, 0, 0),
                    extent: SIMD3<Float>(1, 0, 2),
                    alignment: .vertical,
                    classification: .door
                ),
            ]
        )
        let object = try metadata(
            id: objectID(10),
            mapID: map,
            frameID: frame,
            label: "table",
            position: vec(2, 0.5, 2),
            bounds: try AABB(min: vec(1.5, 0, 1.5), max: vec(2.5, 1, 2.5))
        )
        let candidate = try framedPosition(frameID: frame, value: .zero)

        let prepared = try unwrapReady(
            builder().build(
                kind: .sofa,
                candidatePosition: candidate,
                surface: context.surface,
                pose: context.pose,
                capabilities: fullCapabilities(),
                objects: [object]
            )
        )

        XCTAssertGreaterThanOrEqual(prepared.summary.wallSegmentCount, 1)
        XCTAssertEqual(prepared.summary.doorwayCount, 1)
        XCTAssertEqual(prepared.evidence.obstacles.map(\.objectID), [object.object.id])
        XCTAssertTrue(prepared.evidence.completeness.wallsMapped)
        XCTAssertTrue(prepared.evidence.completeness.doorwaysMapped)
        XCTAssertTrue(prepared.evidence.completeness.obstaclesMapped)
    }

    func testMeshTableGeometryBecomesConservativelyThickObstacle() throws {
        let context = spatialContext(
            mesh: mesh(
                id: uuid(20_001),
                vertices: [
                    SIMD3<Float>(-0.5, 0.4, -0.5),
                    SIMD3<Float>(0.5, 0.4, -0.5),
                    SIMD3<Float>(0, 0.4, 0.5),
                ],
                classifications: [.table]
            )
        )
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)

        let prepared = try unwrapReady(
            builder().build(
                kind: .desk,
                candidatePosition: candidate,
                surface: context.surface,
                pose: context.pose,
                capabilities: fullCapabilities(),
                objects: []
            )
        )

        let obstacle = try XCTUnwrap(prepared.evidence.obstacles.first)
        XCTAssertGreaterThanOrEqual(obstacle.bounds.size.x, 0.05)
        XCTAssertGreaterThanOrEqual(obstacle.bounds.size.y, 0.05)
        XCTAssertGreaterThanOrEqual(obstacle.bounds.size.z, 0.05)
    }

    func testUnsupportedLiDARProducesIncompleteEvidenceAndNeverFeasibleEvaluation() throws {
        let context = spatialContext()
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)
        let prepared = try unwrapReady(
            builder().build(
                kind: .sofa,
                candidatePosition: candidate,
                surface: context.surface,
                pose: context.pose,
                capabilities: ARCaptureCapabilities(
                    supportsWorldTracking: true,
                    supportsSceneDepth: false,
                    supportsSmoothedSceneDepth: false,
                    supportsMeshReconstruction: false,
                    supportsMeshClassification: false
                ),
                objects: []
            )
        )

        XCTAssertFalse(prepared.summary.lidarEvidenceComplete)
        XCTAssertFalse(prepared.evidence.completeness.wallsMapped)
        XCTAssertFalse(prepared.evidence.completeness.doorwaysMapped)
        XCTAssertFalse(prepared.evidence.completeness.obstaclesMapped)
        XCTAssertFalse(prepared.evidence.completeness.passagesMapped)
        XCTAssertEqual(
            FurniturePlacementEvaluator().evaluate(
                candidate: prepared.candidate,
                evidence: prepared.evidence
            ).disposition,
            .insufficientEvidence
        )
    }

    func testUnknownLocalMeshClassificationKeepsLiDARCompletenessFalse() throws {
        let context = spatialContext(
            mesh: mesh(
                id: uuid(30_001),
                vertices: triangleVertices(),
                classifications: [.unknown]
            )
        )
        let prepared = try unwrapReady(
            builder().build(
                kind: .bed,
                candidatePosition: framedPosition(frameID: context.frameID, value: .zero),
                surface: context.surface,
                pose: context.pose,
                capabilities: fullCapabilities(),
                objects: []
            )
        )

        XCTAssertEqual(prepared.summary.localClassifiedTriangleCount, 1)
        XCTAssertFalse(prepared.summary.lidarEvidenceComplete)
    }

    func testMalformedMeshFailsClosedInsteadOfDroppingUnknownGeometry() throws {
        let badMesh = ARMeshObservationSnapshot(
            anchorID: uuid(40_001),
            transform: Matrix4x4Snapshot(matrix_identity_float4x4),
            vertices: triangleVertices(),
            triangleIndices: [0, 1, 2],
            faceClassifications: []
        )
        let context = spatialContext(mesh: badMesh)

        let outcome = builder().build(
            kind: .sofa,
            candidatePosition: try framedPosition(frameID: context.frameID, value: .zero),
            surface: context.surface,
            pose: context.pose,
            capabilities: fullCapabilities(),
            objects: []
        )

        XCTAssertEqual(try unwrapIssue(outcome), .invalidSurfaceGeometry)
    }

    func testSingleTriangleCeilingAndElevatedFloorCannotProduceFeasiblePlacement() throws {
        let fixtures: [([SIMD3<Float>], [ARMeshClassificationSnapshot])] = [
            (triangleVertices(), [.floor]),
            (rectangleVertices(elevation: 2), [.ceiling, .ceiling]),
            (rectangleVertices(elevation: 2), [.floor, .floor]),
            (rectangleVertices(), [.table, .table]),
        ]
        for (vertices, classifications) in fixtures {
            let context = spatialContext(
                mesh: mesh(id: uuid(41_001), vertices: vertices, classifications: classifications))
            let prepared = try unwrapReady(
                builder().build(
                    kind: .sofa,
                    candidatePosition: framedPosition(frameID: context.frameID, value: .zero),
                    surface: context.surface, pose: context.pose,
                    capabilities: fullCapabilities(), objects: []
                ))
            XCTAssertFalse(prepared.summary.lidarEvidenceComplete)
            XCTAssertNotEqual(
                FurniturePlacementEvaluator().evaluate(
                    candidate: prepared.candidate, evidence: prepared.evidence
                ).disposition, .feasible)
        }
    }

    func testCompleteFloorWithLowCeilingMeshRejectsFurnitureButHighCeilingRemainsFeasible() throws {
        for ceilingHeight in [Float(0.5), 3] {
            let context = spatialContext(
                mesh: mesh(
                    id: uuid(41_020),
                    vertices: rectangleVertices() + rectangleVertices(elevation: ceilingHeight),
                    classifications: [.floor, .floor, .ceiling, .ceiling]
                ))
            let prepared = try unwrapReady(
                builder().build(
                    kind: .sofa,
                    candidatePosition: framedPosition(frameID: context.frameID, value: .zero),
                    surface: context.surface, pose: context.pose,
                    capabilities: fullCapabilities(), objects: []
                ))
            XCTAssertTrue(prepared.summary.lidarEvidenceComplete)
            XCTAssertEqual(prepared.evidence.obstacles.count, 1)
            let result = FurniturePlacementEvaluator().evaluate(
                candidate: prepared.candidate, evidence: prepared.evidence
            )
            if ceilingHeight < 1 {
                XCTAssertEqual(result.disposition, .rejected)
                XCTAssertTrue(result.reasons.contains { $0.code == .collidesWithExistingObject })
            } else {
                XCTAssertEqual(result.disposition, .feasible)
                XCTAssertFalse(result.reasons.contains { $0.code == .passageWidthTooNarrow })
            }
        }
    }

    func testCeilingPlaneAlsoRetainsItsCollisionHeight() throws {
        for ceilingHeight in [Float(0.5), 3] {
            let context = spatialContext(additionalPlanes: [
                plane(
                    id: uuid(41_021), center: SIMD3<Float>(0, ceilingHeight, 0),
                    extent: SIMD3<Float>(6, 0, 6), alignment: .horizontal, classification: .ceiling
                )
            ])
            let prepared = try unwrapReady(
                builder().build(
                    kind: .sofa,
                    candidatePosition: framedPosition(frameID: context.frameID, value: .zero),
                    surface: context.surface, pose: context.pose,
                    capabilities: fullCapabilities(), objects: []
                ))
            XCTAssertTrue(prepared.summary.lidarEvidenceComplete)
            XCTAssertEqual(prepared.evidence.obstacles.count, 1)
            let result = FurniturePlacementEvaluator().evaluate(
                candidate: prepared.candidate, evidence: prepared.evidence
            )
            XCTAssertEqual(result.disposition, ceilingHeight < 1 ? .rejected : .feasible)
            if ceilingHeight < 1 {
                XCTAssertTrue(result.reasons.contains { $0.code == .collidesWithExistingObject })
            }
        }
    }

    func testTableAndHighCeilingInOneMeshDoNotBecomeOneSolidObstacle() throws {
        let context = spatialContext(
            mesh: mesh(
                id: uuid(41_022),
                vertices: rectangleVertices() + rectangleVertices(elevation: 3)
                    + rectangleVertices(minX: 2, minZ: 2, maxX: 2.5, maxZ: 2.5, elevation: 0.7),
                classifications: [.floor, .floor, .ceiling, .ceiling, .table, .table]
            ))
        let prepared = try unwrapReady(
            builder().build(
                kind: .sofa,
                candidatePosition: framedPosition(frameID: context.frameID, value: .zero),
                surface: context.surface, pose: context.pose,
                capabilities: fullCapabilities(), objects: []
            ))
        XCTAssertTrue(prepared.summary.lidarEvidenceComplete)
        XCTAssertEqual(prepared.evidence.obstacles.count, 2)
        XCTAssertTrue(prepared.evidence.obstacles.contains { $0.bounds.min.y > 2.9 })
        XCTAssertTrue(prepared.evidence.obstacles.contains { $0.bounds.max.y < 0.8 })
        XCTAssertEqual(
            FurniturePlacementEvaluator().evaluate(
                candidate: prepared.candidate, evidence: prepared.evidence
            ).disposition, .feasible)
    }

    func testFloorMeshHoleAndDisjointPatchesCannotHideBehindTheirBoundingBox() throws {
        let ring =
            rectangleVertices(minX: -3, minZ: -3, maxX: 3, maxZ: -0.15)
            + rectangleVertices(minX: -3, minZ: 0.15, maxX: 3, maxZ: 3)
            + rectangleVertices(minX: -3, minZ: -0.15, maxX: -0.15, maxZ: 0.15)
            + rectangleVertices(minX: 0.15, minZ: -0.15, maxX: 3, maxZ: 0.15)
        let disjoint =
            rectangleVertices(minX: -3, maxX: -0.1)
            + rectangleVertices(minX: 0.1, maxX: 3)
        for vertices in [ring, disjoint] {
            let context = spatialContext(
                mesh: mesh(
                    id: uuid(41_002), vertices: vertices,
                    classifications: Array(repeating: .floor, count: vertices.count / 3)
                ))
            let prepared = try unwrapReady(
                builder().build(
                    kind: .desk,
                    candidatePosition: framedPosition(frameID: context.frameID, value: .zero),
                    surface: context.surface, pose: context.pose,
                    capabilities: fullCapabilities(), objects: []
                ))
            XCTAssertFalse(prepared.summary.lidarEvidenceComplete)
            XCTAssertNotEqual(
                FurniturePlacementEvaluator().evaluate(
                    candidate: prepared.candidate, evidence: prepared.evidence
                ).disposition, .feasible)
        }
    }

    func testConcaveFloorBoundaryCannotBeReplacedByItsInsetBoundingRectangle() throws {
        let context = spatialContext(floorBoundary: [
            SIMD3<Float>(-3, 0, -3), SIMD3<Float>(3, 0, -3), SIMD3<Float>(3, 0, 0),
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, 3), SIMD3<Float>(-3, 0, 3),
        ])
        let prepared = try unwrapReady(
            builder().build(
                kind: .sofa,
                candidatePosition: framedPosition(frameID: context.frameID, value: .zero),
                surface: context.surface, pose: context.pose,
                capabilities: fullCapabilities(), objects: []
            ))
        XCTAssertTrue(prepared.evidence.floors.isEmpty)
        XCTAssertNotEqual(
            FurniturePlacementEvaluator().evaluate(
                candidate: prepared.candidate, evidence: prepared.evidence
            ).disposition, .feasible)
    }

    func testExhaustedWallAndDoorwayBudgetsFailClosed() throws {
        for classification in [ARPlaneClassificationSnapshot.wall, .door] {
            let context = spatialContext(additionalPlanes: [
                plane(
                    id: uuid(41_010), center: SIMD3<Float>(-2, 0, 0), extent: SIMD3<Float>(1, 0, 2),
                    alignment: .vertical, classification: classification),
                plane(
                    id: uuid(41_011), center: SIMD3<Float>(0, 0, 0), extent: SIMD3<Float>(1, 0, 2),
                    alignment: .vertical, classification: classification),
            ])
            let bounded = ARFurniturePlacementEvidenceBuilder(
                policy: ARFurniturePlacementEvidenceBuilderPolicy(
                    minimumLocalClassifiedTriangleCount: 1,
                    maximumWallSegments: 1, maximumDoorways: 1
                ))
            XCTAssertEqual(
                try unwrapIssue(
                    bounded.build(
                        kind: .sofa,
                        candidatePosition: framedPosition(frameID: context.frameID, value: .zero),
                        surface: context.surface, pose: context.pose,
                        capabilities: fullCapabilities(), objects: []
                    )), .surfaceCapacityExceeded)
        }
    }

    func testLargeDoorMeshProducesEnclosingKeepClearRegionWithBoundedWork() throws {
        let doorTriangle: [SIMD3<Float>] = [
            SIMD3<Float>(-1, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 2, 0),
        ]
        let doorVertices = Array(repeating: doorTriangle, count: 10_000).flatMap { $0 }
        let context = spatialContext(
            mesh: mesh(
                id: uuid(41_020), vertices: rectangleVertices() + doorVertices,
                classifications: [.floor, .floor] + Array(repeating: .door, count: 10_000)
            ))
        let prepared = try unwrapReady(
            builder().build(
                kind: .sofa,
                candidatePosition: framedPosition(frameID: context.frameID, value: .zero),
                surface: context.surface, pose: context.pose,
                capabilities: fullCapabilities(), objects: []
            ))
        let doorway = try XCTUnwrap(prepared.evidence.doorways.first)
        XCTAssertGreaterThanOrEqual(doorway.keepClearRegion.width, 2)
        XCTAssertEqual(
            FurniturePlacementEvaluator().evaluate(
                candidate: prepared.candidate, evidence: prepared.evidence
            ).disposition, .rejected)
    }

    func testDegenerateLocalMeshFaceFailsClosedEvenAlongsideValidFloor() throws {
        let context = spatialContext(
            mesh: mesh(
                id: uuid(41_030),
                vertices: rectangleVertices() + [.zero, .zero, .zero],
                classifications: [.floor, .floor, .wall]
            ))
        XCTAssertEqual(
            try unwrapIssue(
                builder().build(
                    kind: .sofa,
                    candidatePosition: framedPosition(frameID: context.frameID, value: .zero),
                    surface: context.surface, pose: context.pose,
                    capabilities: fullCapabilities(), objects: []
                )), .invalidSurfaceGeometry)
    }

    func testTrackingMappingAndSurfaceCompletenessFailuresAreExplicit() throws {
        let context = spatialContext()
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)
        let limitedPose = pose(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            tracking: .limited(.excessiveMotion)
        )
        let extendingPose = pose(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            mapping: .extending
        )
        let incompleteSurface = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            isCurrent: false
        )

        XCTAssertEqual(
            try unwrapIssue(
                builder().build(
                    kind: .sofa,
                    candidatePosition: candidate,
                    surface: context.surface,
                    pose: limitedPose,
                    capabilities: fullCapabilities(),
                    objects: []
                )),
            .trackingUnstable
        )
        XCTAssertEqual(
            try unwrapIssue(
                builder().build(
                    kind: .sofa,
                    candidatePosition: candidate,
                    surface: context.surface,
                    pose: extendingPose,
                    capabilities: fullCapabilities(),
                    objects: []
                )),
            .worldMappingIncomplete
        )
        XCTAssertEqual(
            try unwrapIssue(
                builder().build(
                    kind: .sofa,
                    candidatePosition: candidate,
                    surface: incompleteSurface,
                    pose: context.pose,
                    capabilities: fullCapabilities(),
                    objects: []
                )),
            .incompleteSurfaceSnapshot
        )
    }

    func testCandidateAndSurfaceCoordinateMismatchesFailClosed() throws {
        let context = spatialContext()
        let wrongCandidate = try framedPosition(frameID: frameID(999), value: .zero)
        let wrongSurface = surface(
            mapID: context.mapID,
            frameID: frameID(998),
            segmentID: context.segmentID
        )

        XCTAssertEqual(
            try unwrapIssue(
                builder().build(
                    kind: .desk,
                    candidatePosition: wrongCandidate,
                    surface: context.surface,
                    pose: context.pose,
                    capabilities: fullCapabilities(),
                    objects: []
                )),
            .candidateCoordinateMismatch
        )
        XCTAssertEqual(
            try unwrapIssue(
                builder().build(
                    kind: .desk,
                    candidatePosition: try framedPosition(
                        frameID: context.frameID,
                        value: .zero
                    ),
                    surface: wrongSurface,
                    pose: context.pose,
                    capabilities: fullCapabilities(),
                    objects: []
                )),
            .coordinateContextMismatch
        )
    }

    func testStaleAndUncertainCandidatePositionsFailClosed() throws {
        let context = spatialContext()
        let stale = try framedPosition(
            frameID: context.frameID,
            value: .zero,
            observedAt: 90
        )
        let uncertain = try framedPosition(
            frameID: context.frameID,
            value: .zero,
            uncertainty: .lowConfidenceDepth
        )

        XCTAssertEqual(
            try unwrapIssue(
                builder().build(
                    kind: .bed,
                    candidatePosition: stale,
                    surface: context.surface,
                    pose: context.pose,
                    capabilities: fullCapabilities(),
                    objects: []
                )),
            .candidatePositionStale
        )
        XCTAssertEqual(
            try unwrapIssue(
                builder().build(
                    kind: .bed,
                    candidatePosition: uncertain,
                    surface: context.surface,
                    pose: context.pose,
                    capabilities: fullCapabilities(),
                    objects: []
                )),
            .candidatePositionUncertain
        )
    }

    func testCurrentMapObjectWithWrongFrameFailsWholeEvaluationContext() throws {
        let context = spatialContext()
        let mismatched = try metadata(
            id: objectID(50),
            mapID: context.mapID,
            frameID: frameID(500),
            label: "chair",
            position: vec(1, 0, 1),
            bounds: try AABB(min: vec(0.5, 0, 0.5), max: vec(1.5, 1, 1.5))
        )

        let outcome = builder().build(
            kind: .sofa,
            candidatePosition: try framedPosition(frameID: context.frameID, value: .zero),
            surface: context.surface,
            pose: context.pose,
            capabilities: fullCapabilities(),
            objects: [mismatched]
        )

        XCTAssertEqual(try unwrapIssue(outcome), .coordinateContextMismatch)
    }

    func testNearbyObjectWithoutBoundsMarksObstacleEvidenceIncomplete() throws {
        let context = spatialContext()
        let unbounded = try metadata(
            id: objectID(60),
            mapID: context.mapID,
            frameID: context.frameID,
            label: "chair",
            position: vec(1, 0, 1),
            bounds: nil
        )
        let prepared = try unwrapReady(
            builder().build(
                kind: .desk,
                candidatePosition: framedPosition(frameID: context.frameID, value: .zero),
                surface: context.surface,
                pose: context.pose,
                capabilities: fullCapabilities(),
                objects: [unbounded]
            )
        )

        XCTAssertFalse(prepared.evidence.completeness.obstaclesMapped)
        XCTAssertEqual(
            FurniturePlacementEvaluator().evaluate(
                candidate: prepared.candidate,
                evidence: prepared.evidence
            ).disposition,
            .insufficientEvidence
        )
    }

    func testControllerReturnsKoreanInsufficientResultWithoutRequiredSnapshots() {
        let controller = makeController(candidate: nil)

        controller.evaluate(.sofa)

        let presentation = controller.latestPresentation
        XCTAssertEqual(presentation?.disposition, .insufficientEvidence)
        XCTAssertEqual(presentation?.issue, .poseUnavailable)
        XCTAssertTrue(presentation?.message.contains("추천하지 않았어요") == true)
        XCTAssertNil(controller.latestRecommendedPlacement)
    }

    func testControllerPublishesFeasibleRecommendationFromExternallyProvidedPosition() async throws {
        let context = spatialContext()
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)
        let controller = makeController(candidate: candidate)
        controller.update(pose: context.pose)
        controller.update(surface: context.surface)

        controller.evaluate(.sofa)
        try await waitForIdle(controller)

        let presentation = try XCTUnwrap(controller.latestPresentation)
        let recommendation = try XCTUnwrap(controller.latestRecommendedPlacement)
        XCTAssertEqual(presentation.disposition, .feasible)
        XCTAssertEqual(presentation.evaluation?.disposition, .feasible)
        XCTAssertTrue(presentation.message.contains("놓아도 좋아 보여요"))
        XCTAssertEqual(recommendation.position, candidate)
        XCTAssertEqual(recommendation.kind, .sofa)
        XCTAssertEqual(recommendation.dimensions, ARFurnitureDefaults.dimensions(for: .sofa))
        XCTAssertEqual(controller.metrics.recommendationsPublished, 1)
    }

    func testControllerRejectsCollisionAndDoesNotPublishRenderablePlacement() async throws {
        let context = spatialContext()
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)
        let obstacle = try metadata(
            id: objectID(70),
            mapID: context.mapID,
            frameID: context.frameID,
            label: "table",
            position: vec(0, 0.5, 0),
            bounds: try AABB(min: vec(-0.5, 0, -0.5), max: vec(0.5, 1, 0.5))
        )
        let controller = makeController(candidate: candidate, objects: [obstacle])
        controller.update(pose: context.pose)
        controller.update(surface: context.surface)

        controller.evaluate(.desk)
        try await waitForIdle(controller)

        XCTAssertEqual(controller.latestPresentation?.disposition, .rejected)
        XCTAssertTrue(controller.latestPresentation?.message.contains("기존 물체") == true)
        XCTAssertNil(controller.latestRecommendedPlacement)
        XCTAssertEqual(controller.metrics.rejectionsPublished, 1)
    }

    func testControllerWithholdsRecommendationWhenLiDAREvidenceIsIncomplete() async throws {
        let context = spatialContext()
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)
        let limitedCapabilities = ARCaptureCapabilities(
            supportsWorldTracking: true,
            supportsSceneDepth: false,
            supportsSmoothedSceneDepth: false,
            supportsMeshReconstruction: false,
            supportsMeshClassification: false
        )
        let controller = makeController(
            candidate: candidate,
            capabilities: limitedCapabilities
        )
        controller.update(pose: context.pose)
        controller.update(surface: context.surface)

        controller.evaluate(.bed)
        try await waitForIdle(controller)

        XCTAssertEqual(controller.latestPresentation?.disposition, .insufficientEvidence)
        XCTAssertEqual(controller.latestPresentation?.issue, .lidarEvidenceIncomplete)
        XCTAssertTrue(controller.latestPresentation?.message.contains("LiDAR") == true)
        XCTAssertNil(controller.latestRecommendedPlacement)
    }

    func testNilCandidateProviderReturnsInsufficientInsteadOfInventingCoordinate() async throws {
        let context = spatialContext()
        let controller = makeController(candidate: nil)
        controller.update(pose: context.pose)
        controller.update(surface: context.surface)

        controller.evaluate(.sofa)
        try await waitForIdle(controller)

        XCTAssertEqual(controller.latestPresentation?.issue, .candidateUnavailable)
        XCTAssertNil(controller.latestPresentation?.candidatePosition)
        XCTAssertNil(controller.latestRecommendedPlacement)
    }

    func testMetadataProviderFailureReturnsSafeInsufficientResult() async throws {
        enum TestError: Error { case unavailable }
        let context = spatialContext()
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)
        let controller = FurniturePlacementController(
            candidatePositionProvider: { _ in candidate },
            objectMetadataProvider: { throw TestError.unavailable },
            capabilitiesProvider: { self.fullCapabilities() },
            evidenceBuilder: builder()
        )
        controller.update(pose: context.pose)
        controller.update(surface: context.surface)

        controller.evaluate(.desk)
        try await waitForIdle(controller)

        XCTAssertEqual(controller.latestPresentation?.disposition, .insufficientEvidence)
        XCTAssertEqual(controller.latestPresentation?.issue, .objectMetadataUnavailable)
        XCTAssertFalse(controller.latestPresentation?.message.contains("unavailable") == true)
    }

    func testOutOfOrderPoseAndSurfaceSnapshotsAreIgnored() {
        let context = spatialContext()
        let controller = makeController(candidate: nil)
        let newerPose = pose(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            timestamp: 20
        )
        let olderPose = pose(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            timestamp: 19
        )
        let newerSurface = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            revision: 2,
            timestamp: 20
        )
        let olderSurface = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            revision: 1,
            timestamp: 19
        )

        controller.update(pose: newerPose)
        controller.update(pose: olderPose)
        controller.update(surface: newerSurface)
        controller.update(surface: olderSurface)

        XCTAssertEqual(controller.latestPose, newerPose)
        XCTAssertEqual(controller.latestSurface, newerSurface)
        XCTAssertEqual(controller.metrics.posesRejectedAsOutOfOrder, 1)
        XCTAssertEqual(controller.metrics.surfacesRejectedAsOutOfOrder, 1)
    }

    func testNewerEvaluationWinsWhenCandidateProvidersCompleteOutOfOrder() async throws {
        let context = spatialContext()
        let provider = SuspendedPlacementCandidateProvider()
        let controller = FurniturePlacementController(
            candidatePositionProvider: { pose in
                try await provider.load(referencePose: pose)
            },
            objectMetadataProvider: { [] },
            capabilitiesProvider: { self.fullCapabilities() },
            evidenceBuilder: builder()
        )
        controller.update(pose: context.pose)
        controller.update(surface: context.surface)

        controller.evaluate(.sofa)
        try await waitForRequestCount(provider, 1)
        controller.evaluate(.desk)
        try await waitForRequestCount(provider, 2)
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)
        await provider.resume(index: 1, with: candidate)
        try await waitForIdle(controller)
        XCTAssertEqual(controller.latestRecommendedPlacement?.kind, .desk)

        await provider.resume(index: 0, with: candidate)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.latestRecommendedPlacement?.kind, .desk)
        XCTAssertEqual(controller.metrics.requestsCancelled, 1)
        XCTAssertGreaterThanOrEqual(controller.metrics.staleResultsRejected, 1)
    }

    func testSurfaceRevisionChangeCancelsInFlightEvaluationAndClearsOldRecommendation() async throws {
        let context = spatialContext()
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)
        let provider = SuspendedPlacementCandidateProvider()
        let controller = FurniturePlacementController(
            candidatePositionProvider: { pose in
                try await provider.load(referencePose: pose)
            },
            objectMetadataProvider: { [] },
            capabilitiesProvider: { self.fullCapabilities() },
            evidenceBuilder: builder()
        )
        controller.update(pose: context.pose)
        controller.update(surface: context.surface)
        controller.evaluate(.sofa)
        try await waitForRequestCount(provider, 1)

        controller.update(
            surface: surface(
                mapID: context.mapID,
                frameID: context.frameID,
                segmentID: context.segmentID,
                revision: context.surface.revision + 1,
                timestamp: context.surface.timestamp + 0.1
            )
        )
        await provider.resume(index: 0, with: candidate)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.latestPresentation)
        XCTAssertNil(controller.latestRecommendedPlacement)
        XCTAssertEqual(controller.metrics.requestsCancelled, 1)
    }

    func testCancelAndWaitAlsoWaitsForReplacedCandidateRead() async throws {
        let context = spatialContext()
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)
        let provider = SuspendedPlacementCandidateProvider()
        let completion = PlacementDeletionBarrierCompletion()
        let controller = FurniturePlacementController(
            candidatePositionProvider: { pose in
                try await provider.load(referencePose: pose)
            },
            objectMetadataProvider: { [] },
            capabilitiesProvider: { self.fullCapabilities() },
            evidenceBuilder: builder()
        )
        controller.update(pose: context.pose)
        controller.update(surface: context.surface)
        controller.evaluate(.sofa)
        try await waitForRequestCount(provider, 1)
        controller.evaluate(.sofa)
        try await waitForRequestCount(provider, 2)

        let barrierTask = Task { @MainActor in
            await controller.cancelCurrentEvaluationAndWait()
            await completion.markFinished()
        }
        try await waitForIdle(controller)

        let finishedWhileProviderWasBlocked = await completion.isFinished
        XCTAssertFalse(finishedWhileProviderWasBlocked)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.latestPresentation)
        XCTAssertNil(controller.latestRecommendedPlacement)

        // Releasing only the replacement leaves the earlier cancelled provider in flight.
        await provider.resume(index: 1, with: candidate)
        for _ in 0..<200 {
            if controller.metrics.staleResultsRejected == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.metrics.staleResultsRejected, 1)
        try await Task.sleep(for: .milliseconds(30))
        let finishedWhileReplacedReadWasBlocked = await completion.isFinished
        XCTAssertFalse(finishedWhileReplacedReadWasBlocked)

        await provider.resume(index: 0, with: candidate)
        await barrierTask.value

        let finishedAfterProviderReleased = await completion.isFinished
        XCTAssertTrue(finishedAfterProviderReleased)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.latestPresentation)
        XCTAssertNil(controller.latestRecommendedPlacement)
        XCTAssertEqual(controller.metrics.recommendationsPublished, 0)
        XCTAssertEqual(controller.metrics.rejectionsPublished, 0)
        XCTAssertEqual(controller.metrics.insufficientEvidencePublished, 0)
        XCTAssertEqual(controller.metrics.requestsCancelled, 2)
        XCTAssertEqual(controller.metrics.staleResultsRejected, 2)
    }

    func testPlacementStreamBridgeResubscribesAfterDeactivateAndActivate() async throws {
        let context = spatialContext()
        let poseChannel = LatestValueChannel<ARPoseSnapshot>()
        let surfaceChannel = LatestValueChannel<ARSurfaceStateSnapshot>()
        let controller = makeController(candidate: nil)
        let bridge = ARFurniturePlacementStreamBridge(
            poseStreamProvider: { poseChannel.stream },
            surfaceStreamProvider: { surfaceChannel.stream },
            controller: controller
        )

        bridge.activate()
        poseChannel.send(context.pose)
        surfaceChannel.send(context.surface)
        try await waitForSpatialContext(controller)

        bridge.deactivate()
        XCTAssertNil(controller.latestPose)
        XCTAssertNil(controller.latestSurface)

        let nextPose = pose(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            timestamp: 20
        )
        let nextSurface = surface(
            mapID: context.mapID,
            frameID: context.frameID,
            segmentID: context.segmentID,
            revision: context.surface.revision + 1,
            timestamp: 20
        )
        bridge.activate()
        poseChannel.send(nextPose)
        surfaceChannel.send(nextSurface)
        try await waitForSpatialContext(controller)

        XCTAssertEqual(controller.latestPose, nextPose)
        XCTAssertEqual(controller.latestSurface, nextSurface)
    }

    private func builder() -> ARFurniturePlacementEvidenceBuilder {
        ARFurniturePlacementEvidenceBuilder(
            policy: ARFurniturePlacementEvidenceBuilderPolicy(
                minimumLocalClassifiedTriangleCount: 1,
                minimumMeshCoverageMargin: 0
            )
        )
    }

    func testUnrelatedAnchorUpdateCannotRefreshOldFloorOrMeshEvidence() throws {
        let context = spatialContext()
        let currentPose = pose(mapID: context.mapID, frameID: context.frameID,
            segmentID: context.segmentID, timestamp: 1_000)
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)
        let anchorIDs = Array(context.surface.planes.keys) + Array(context.surface.meshes.keys)
        let freshTimes = Dictionary(uniqueKeysWithValues: anchorIDs.map { ($0, 1_000.0) })
        func snapshot(_ observedAt: [UUID: TimeInterval]) -> ARSurfaceStateSnapshot {
            ARSurfaceStateSnapshot(coordinateFrameID: context.frameID, segmentID: context.segmentID,
                mapID: context.mapID, coordinateFrameStatus: .confirmed, revision: 2, timestamp: 1_000,
                planes: context.surface.planes, meshes: context.surface.meshes,
                unresolvedFailures: [], isCurrentSessionData: true, anchorObservedAt: observedAt)
        }
        for oldAnchor in anchorIDs {
            var observedAt = freshTimes
            observedAt[oldAnchor] = 10
            XCTAssertEqual(try unwrapIssue(builder().build(kind: .sofa, candidatePosition: candidate,
                surface: snapshot(observedAt), pose: currentPose, capabilities: fullCapabilities(), objects: [])),
                .surfaceSnapshotStale)
            observedAt[oldAnchor] = nil
            XCTAssertEqual(try unwrapIssue(builder().build(kind: .sofa, candidatePosition: candidate,
                surface: snapshot(observedAt), pose: currentPose, capabilities: fullCapabilities(), objects: [])),
                .surfaceSnapshotStale)
        }
        let prepared = try unwrapReady(builder().build(kind: .sofa, candidatePosition: candidate,
            surface: snapshot(freshTimes), pose: currentPose, capabilities: fullCapabilities(), objects: []))
        XCTAssertEqual(FurniturePlacementEvaluator().evaluate(candidate: prepared.candidate,
            evidence: prepared.evidence).disposition, .feasible)
    }

    func testDelayedMetadataCannotPublishAfterMonotonicRequestDeadline() async throws {
        let context = spatialContext()
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)
        let metadata = SuspendedPlacementMetadataProvider()
        let clock = PlacementTestClock()
        let capabilities = fullCapabilities()
        let controller = FurniturePlacementController(candidatePositionProvider: { _ in candidate },
            objectMetadataProvider: { try await metadata.load() }, capabilitiesProvider: { capabilities },
            evidenceBuilder: builder(), monotonicNow: { clock.uptime })
        do {
            controller.update(pose: context.pose)
            controller.update(surface: context.surface)
            controller.evaluate(.sofa)
            for _ in 0..<250 {
                if await metadata.isWaiting { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let isWaiting = await metadata.isWaiting
            XCTAssertTrue(isWaiting)
            clock.uptime = 3
            await metadata.resume()
            try await waitForIdle(controller)
            XCTAssertNil(controller.latestRecommendedPlacement)
            XCTAssertNil(controller.latestPresentation)
            XCTAssertEqual(controller.metrics.recommendationsPublished, 0)
            XCTAssertGreaterThan(controller.metrics.staleResultsRejected, 0)
        } catch {
            await metadata.resumeAll()
            await controller.cancelCurrentEvaluationAndWait()
            throw error
        }
        await metadata.resumeAll()
        await controller.cancelCurrentEvaluationAndWait()
    }

    func testPoseOnlyProgressRevokesExpiredRecommendationAndPreventsReplay() async throws {
        let context = spatialContext()
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)
        let clock = PlacementTestClock()
        let controller = makeController(candidate: candidate, maximumRecommendationAge: 120,
            monotonicNow: { clock.uptime })
        controller.update(pose: context.pose)
        controller.update(surface: context.surface)
        controller.evaluate(.sofa)
        try await waitForIdle(controller)
        XCTAssertNotNil(controller.latestRecommendedPlacement)
        controller.update(pose: pose(mapID: context.mapID, frameID: context.frameID,
            segmentID: context.segmentID, timestamp: 71, capturedAt: 161))
        XCTAssertNil(controller.latestRecommendedPlacement)
        XCTAssertNil(controller.latestPresentation)
        XCTAssertEqual(controller.state, .idle)
        controller.evaluate(.sofa)
        XCTAssertEqual(controller.latestPresentation?.issue, .surfaceSnapshotStale)
        XCTAssertNil(controller.latestRecommendedPlacement)
    }

    func testPublishedRecommendationExpiresWithoutFurtherSnapshots() async throws {
        let context = spatialContext()
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)
        let controller = makeController(candidate: candidate, maximumRecommendationAge: 0.1)
        controller.update(pose: context.pose)
        controller.update(surface: context.surface)
        controller.evaluate(.sofa)
        try await waitForIdle(controller)
        XCTAssertNotNil(controller.latestRecommendedPlacement)
        for _ in 0..<250 where controller.latestRecommendedPlacement != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(controller.latestRecommendedPlacement)
        XCTAssertNil(controller.latestPresentation)
        XCTAssertEqual(controller.state, .idle)
    }

    func testPublishingCannotRenewOldestSurfaceObservationBudget() async throws {
        let context = spatialContext()
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)
        let clock = PlacementTestClock()
        let timer = SuspendedPlacementExpiration()
        let controller = makeController(candidate: candidate, monotonicNow: { clock.uptime },
            expirationSleeper: { try await timer.wait(seconds: $0) })
        do {
            controller.update(pose: pose(mapID: context.mapID, frameID: context.frameID,
                segmentID: context.segmentID, timestamp: 69))
            controller.update(surface: context.surface) // Observed at 10; expires at 70.
            controller.evaluate(.sofa)
            try await waitForIdle(controller)
            try await waitForExpirationCount(timer, 2)
            XCTAssertNotNil(controller.latestRecommendedPlacement)
            let durations = await timer.durations
            XCTAssertEqual(durations.count, 2)
            XCTAssertTrue(durations.allSatisfy { abs($0 - 1) < 0.000_001 })
            await timer.resume(index: 0) // Canceled request timer must not revoke its published lease.
            for _ in 0..<25 { await Task.yield() }
            XCTAssertNotNil(controller.latestRecommendedPlacement)
            await timer.resume(index: 1)
            for _ in 0..<250 where controller.latestRecommendedPlacement != nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertNil(controller.latestRecommendedPlacement)
        } catch {
            await timer.resumeAll()
            await controller.cancelCurrentEvaluationAndWait()
            throw error
        }
        await timer.resumeAll()
        await controller.cancelCurrentEvaluationAndWait()
    }

    func testCanceledLeaseCannotRevokeRecommendationFromNextSessionRun() async throws {
        let context = spatialContext()
        let candidate = try framedPosition(frameID: context.frameID, value: .zero)
        let clock = PlacementTestClock()
        let timer = SuspendedPlacementExpiration()
        let controller = makeController(candidate: candidate, monotonicNow: { clock.uptime },
            expirationSleeper: { try await timer.wait(seconds: $0) })
        do {
            controller.update(pose: context.pose)
            controller.update(surface: context.surface)
            controller.evaluate(.sofa)
            try await waitForIdle(controller)
            try await waitForExpirationCount(timer, 2)
            controller.cancelCurrentEvaluation()
            controller.update(pose: pose(mapID: context.mapID, frameID: context.frameID,
                segmentID: context.segmentID, timestamp: 11, runGeneration: 2))
            controller.evaluate(.desk)
            try await waitForIdle(controller)
            try await waitForExpirationCount(timer, 4)
            XCTAssertEqual(controller.latestRecommendedPlacement?.kind, .desk)
            // A noncooperative sleeper returns after cancellation. Neither the old
            // request nor the canceled pre-publication timer may touch this result.
            for index in 0..<3 { await timer.resume(index: index) }
            for _ in 0..<25 { await Task.yield() }
            XCTAssertEqual(controller.latestRecommendedPlacement?.kind, .desk)
            await timer.resume(index: 3)
            for _ in 0..<250 where controller.latestRecommendedPlacement != nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertNil(controller.latestRecommendedPlacement)
            XCTAssertNil(controller.latestPresentation)
        } catch {
            await timer.resumeAll()
            await controller.cancelCurrentEvaluationAndWait()
            throw error
        }
        await timer.resumeAll()
        await controller.cancelCurrentEvaluationAndWait()
    }

    private func waitForExpirationCount(_ timer: SuspendedPlacementExpiration, _ expected: Int) async throws {
        for _ in 0..<250 {
            if await timer.count == expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected \(expected) scheduled expiration waits")
        throw TestFailure.expirationNotScheduled
    }

    private func makeController(
        candidate: FramedPosition?,
        objects: [SpatialObjectMetadata] = [],
        capabilities: ARCaptureCapabilities? = nil,
        maximumRecommendationAge: TimeInterval = 30,
        monotonicNow: @escaping @MainActor @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        expirationSleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) -> FurniturePlacementController {
        let resolvedCapabilities = capabilities ?? fullCapabilities()
        return FurniturePlacementController(
            candidatePositionProvider: { _ in candidate },
            objectMetadataProvider: { objects },
            capabilitiesProvider: { resolvedCapabilities },
            evidenceBuilder: builder(), maximumRecommendationAge: maximumRecommendationAge,
            monotonicNow: monotonicNow, expirationSleeper: expirationSleeper
        )
    }

    private func spatialContext(
        mapID: MapID? = nil,
        frameID: CoordinateFrameID? = nil,
        cameraTransform: simd_float4x4 = matrix_identity_float4x4,
        floorTransform: simd_float4x4 = matrix_identity_float4x4,
        floorExtent: SIMD3<Float> = SIMD3<Float>(6, 0, 6),
        floorBoundary: [SIMD3<Float>]? = nil,
        additionalPlanes: [ARPlaneObservationSnapshot] = [],
        mesh: ARMeshObservationSnapshot? = nil
    ) -> PlacementSpatialContext {
        let resolvedMap = mapID ?? self.mapID(1)
        let resolvedFrame = frameID ?? self.frameID(1)
        let segment = segmentID(1)
        let pose = self.pose(
            mapID: resolvedMap,
            frameID: resolvedFrame,
            segmentID: segment,
            cameraTransform: cameraTransform
        )
        let floor = plane(
            id: uuid(1_001),
            transform: floorTransform,
            center: .zero,
            extent: floorExtent,
            alignment: .horizontal,
            classification: .floor,
            boundaryVertices: floorBoundary
        )
        let resolvedMesh =
            mesh
            ?? self.mesh(
                id: uuid(1_002),
                vertices: rectangleVertices().map { vertex in
                    let transformed = floorTransform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1)
                    return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
                },
                classifications: [.floor, .floor]
            )
        let planes = Dictionary(
            uniqueKeysWithValues: ([floor] + additionalPlanes).map { ($0.anchorID, $0) }
        )
        let surface = ARSurfaceStateSnapshot(
            coordinateFrameID: resolvedFrame,
            segmentID: segment,
            mapID: resolvedMap,
            coordinateFrameStatus: .confirmed,
            revision: 1,
            timestamp: 10,
            planes: planes,
            meshes: [resolvedMesh.anchorID: resolvedMesh],
            unresolvedFailures: [],
            isCurrentSessionData: true,
            anchorObservedAt: Dictionary(uniqueKeysWithValues:
                (Array(planes.keys) + [resolvedMesh.anchorID]).map { ($0, 10) })
        )
        return PlacementSpatialContext(
            mapID: resolvedMap,
            frameID: resolvedFrame,
            segmentID: segment,
            pose: pose,
            surface: surface
        )
    }

    private func pose(
        mapID: MapID?,
        frameID: CoordinateFrameID,
        segmentID: CaptureSegmentID,
        timestamp: TimeInterval = 10,
        capturedAt: TimeInterval = 100,
        cameraTransform: simd_float4x4 = matrix_identity_float4x4,
        tracking: ARTrackingStateSnapshot = .normal,
        mapping: ARWorldMappingStatusSnapshot = .mapped,
        status: ARCaptureIdentity.Status = .confirmed,
        runGeneration: UInt64 = 1
    ) -> ARPoseSnapshot {
        ARPoseSnapshot(
            id: ARFrameID(rawValue: uuid(Int(timestamp * 100) + 70_000)),
            sessionToken: ARSessionFrameToken(
                sessionRunGeneration: runGeneration,
                attachmentEpoch: 1
            ),
            coordinateFrameID: frameID,
            segmentID: segmentID,
            mapID: mapID,
            coordinateFrameStatus: status,
            capturedAt: capturedAt,
            timestamp: timestamp,
            cameraTransform: Matrix4x4Snapshot(cameraTransform),
            trackingState: tracking,
            worldMappingStatus: mapping
        )
    }

    private func surface(
        mapID: MapID?,
        frameID: CoordinateFrameID,
        segmentID: CaptureSegmentID,
        revision: UInt64 = 1,
        timestamp: TimeInterval = 10,
        isCurrent: Bool = true
    ) -> ARSurfaceStateSnapshot {
        let floor = plane(
            id: uuid(80_001),
            center: .zero,
            extent: SIMD3<Float>(6, 0, 6),
            alignment: .horizontal,
            classification: .floor
        )
        let localMesh = mesh(
            id: uuid(80_002),
            vertices: rectangleVertices(),
            classifications: [.floor, .floor]
        )
        return ARSurfaceStateSnapshot(
            coordinateFrameID: frameID,
            segmentID: segmentID,
            mapID: mapID,
            coordinateFrameStatus: .confirmed,
            revision: revision,
            timestamp: timestamp,
            planes: [floor.anchorID: floor],
            meshes: [localMesh.anchorID: localMesh],
            unresolvedFailures: [],
            isCurrentSessionData: isCurrent,
            anchorObservedAt: [floor.anchorID: timestamp, localMesh.anchorID: timestamp]
        )
    }

    private func plane(
        id: UUID,
        transform: simd_float4x4 = matrix_identity_float4x4,
        center: SIMD3<Float>,
        extent: SIMD3<Float>,
        alignment: ARPlaneAlignmentSnapshot,
        classification: ARPlaneClassificationSnapshot,
        boundaryVertices: [SIMD3<Float>]? = nil
    ) -> ARPlaneObservationSnapshot {
        let halfX = extent.x * 0.5
        let halfZ = extent.z * 0.5
        return ARPlaneObservationSnapshot(
            anchorID: id,
            transform: Matrix4x4Snapshot(transform),
            center: center,
            extent: extent,
            extentRotationOnYAxis: 0,
            boundaryVertices: boundaryVertices ?? [
                SIMD3<Float>(center.x - halfX, center.y, center.z - halfZ),
                SIMD3<Float>(center.x + halfX, center.y, center.z - halfZ),
                SIMD3<Float>(center.x + halfX, center.y, center.z + halfZ),
                SIMD3<Float>(center.x - halfX, center.y, center.z + halfZ),
            ],
            alignment: alignment,
            classification: classification
        )
    }

    private func mesh(
        id: UUID,
        vertices: [SIMD3<Float>],
        classifications: [ARMeshClassificationSnapshot]
    ) -> ARMeshObservationSnapshot {
        ARMeshObservationSnapshot(
            anchorID: id,
            transform: Matrix4x4Snapshot(matrix_identity_float4x4),
            vertices: vertices,
            triangleIndices: Array(0..<UInt32(vertices.count)),
            faceClassifications: classifications
        )
    }

    private func triangleVertices() -> [SIMD3<Float>] {
        [
            SIMD3<Float>(-1, 0, -1),
            SIMD3<Float>(1, 0, -1),
            SIMD3<Float>(0, 0, 1),
        ]
    }

    private func rectangleVertices(
        minX: Float = -3, minZ: Float = -3,
        maxX: Float = 3, maxZ: Float = 3,
        elevation: Float = 0
    ) -> [SIMD3<Float>] {
        [
            SIMD3<Float>(minX, elevation, minZ),
            SIMD3<Float>(maxX, elevation, minZ),
            SIMD3<Float>(maxX, elevation, maxZ),
            SIMD3<Float>(minX, elevation, minZ),
            SIMD3<Float>(maxX, elevation, maxZ),
            SIMD3<Float>(minX, elevation, maxZ),
        ]
    }

    private func framedPosition(
        frameID: CoordinateFrameID,
        value: Vec3,
        observedAt: TimeInterval = 100,
        tracking: SpatialTrackingQuality = .normal,
        uncertainty: SpatialPositionUncertainty = .raycastEstimate
    ) throws -> FramedPosition {
        try FramedPosition(
            coordinateFrameID: frameID,
            value: value,
            observedAt: observedAt,
            trackingQuality: tracking,
            uncertainty: uncertainty
        )
    }

    private func metadata(
        id: ObjectID,
        mapID: MapID,
        frameID: CoordinateFrameID,
        label: String,
        position: Vec3,
        bounds: AABB?
    ) throws -> SpatialObjectMetadata {
        let object = try SpatialObject(
            id: id,
            semanticLabel: label,
            position: position,
            bounds: bounds,
            certainty: .confirmed,
            confidence: ConfidenceVector(
                semantic: .one,
                geometry: .one,
                tracking: .one,
                identity: .one,
                objectState: .one
            ),
            firstSeenAt: 1,
            lastSeenAt: 100
        )
        return try SpatialObjectMetadata(
            mapID: mapID,
            object: object,
            position: FramedPosition(
                coordinateFrameID: frameID,
                value: position,
                observedAt: 100,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            )
        )
    }

    private func fullCapabilities() -> ARCaptureCapabilities {
        ARCaptureCapabilities(
            supportsWorldTracking: true,
            supportsSceneDepth: true,
            supportsSmoothedSceneDepth: true,
            supportsMeshReconstruction: true,
            supportsMeshClassification: true
        )
    }

    private func unwrapReady(
        _ outcome: ARFurniturePlacementEvidenceBuildOutcome
    ) throws -> ARFurniturePlacementPreparedInput {
        guard case .ready(let prepared) = outcome else {
            throw TestFailure.expectedReady
        }
        return prepared
    }

    private func unwrapIssue(
        _ outcome: ARFurniturePlacementEvidenceBuildOutcome
    ) throws -> ARFurniturePlacementEvidenceIssue {
        guard case .insufficient(let issue) = outcome else {
            throw TestFailure.expectedInsufficient
        }
        return issue
    }

    private func waitForIdle(_ controller: FurniturePlacementController) async throws {
        for _ in 0..<250 where controller.isProcessingForTesting {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isProcessingForTesting)
    }

    private func waitForSpatialContext(_ controller: FurniturePlacementController) async throws {
        for _ in 0..<100 {
            if controller.latestPose != nil, controller.latestSurface != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Placement stream context was not delivered")
    }

    private func waitForRequestCount(
        _ provider: SuspendedPlacementCandidateProvider,
        _ expected: Int
    ) async throws {
        for _ in 0..<250 {
            if await provider.requestCount == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Candidate provider did not receive \(expected) requests.")
    }

    private func translationMatrix(x: Float, y: Float, z: Float) -> simd_float4x4 {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(x, y, z, 1)
        return transform
    }

    private func cameraYawNinetyDegrees() -> simd_float4x4 {
        simd_float4x4(
            columns: (
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-1, 0, 0, 0),
                SIMD4<Float>(0, 0, 0, 1)
            ))
    }

    private func portraitCamera(yaw: Double, pitch: Double = 0) -> simd_float4x4 {
        let portrait = simd_float4x4(
            columns: (
                SIMD4<Float>(0, -1, 0, 0), SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, 0, 0, 1)
            ))
        let heading = simd_float4x4(simd_quatf(angle: Float(-yaw), axis: SIMD3<Float>(0, 1, 0)))
        let tilt = simd_float4x4(simd_quatf(angle: Float(pitch), axis: SIMD3<Float>(1, 0, 0)))
        return heading * tilt * portrait
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

    private func objectID(_ value: Int) -> ObjectID {
        ObjectID(rawValue: uuid(400_000 + value))
    }

    private func vec(_ x: Double, _ y: Double, _ z: Double) -> Vec3 {
        try! Vec3(x: x, y: y, z: z)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }
}

private struct PlacementSpatialContext {
    let mapID: MapID
    let frameID: CoordinateFrameID
    let segmentID: CaptureSegmentID
    let pose: ARPoseSnapshot
    let surface: ARSurfaceStateSnapshot
}

private enum TestFailure: Error {
    case expectedReady
    case expectedInsufficient
    case expirationNotScheduled
}

private actor SuspendedPlacementCandidateProvider {
    private var continuations: [CheckedContinuation<FramedPosition?, Error>] = []

    var requestCount: Int {
        continuations.count
    }

    func load(referencePose: ARPoseSnapshot) async throws -> FramedPosition? {
        _ = referencePose
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(index: Int, with position: FramedPosition?) {
        continuations[index].resume(returning: position)
    }
}

private actor PlacementDeletionBarrierCompletion {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}

@MainActor
private final class PlacementTestClock {
    var uptime: TimeInterval = 0
}

private actor SuspendedPlacementMetadataProvider {
    private var continuation: CheckedContinuation<[SpatialObjectMetadata], Error>?
    private var released = false
    var isWaiting: Bool { continuation != nil }

    func load() async throws -> [SpatialObjectMetadata] {
        if released { return [] }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resume() {
        resumeAll()
    }

    func resumeAll() {
        released = true
        continuation?.resume(returning: [])
        continuation = nil
    }
}

private actor SuspendedPlacementExpiration {
    private var continuations: [CheckedContinuation<Void, Error>?] = []
    private var releasedIndices: Set<Int> = []
    private var releasedAll = false
    private(set) var durations: [TimeInterval] = []
    var count: Int { continuations.count }

    func wait(seconds: TimeInterval) async throws {
        durations.append(seconds)
        let index = continuations.count
        continuations.append(nil)
        guard !releasedAll, !releasedIndices.contains(index) else { return }
        try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }

    func resume(index: Int) {
        releasedIndices.insert(index)
        guard continuations.indices.contains(index) else { return }
        continuations[index]?.resume()
        continuations[index] = nil
    }

    func resumeAll() {
        releasedAll = true
        for index in continuations.indices {
            continuations[index]?.resume()
            continuations[index] = nil
        }
    }
}
