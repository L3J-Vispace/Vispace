import XCTest

@testable import VispaceCore

final class FurniturePlacementEvaluationTests: XCTestCase {
    func testVerifiedSofaCandidateIsFeasibleWithHighConfidence() throws {
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(kind: .sofa),
            evidence: try clearEvidence()
        )

        XCTAssertEqual(result.disposition, .feasible)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.reasons.map(\.code), [.placementFeasible])
        XCTAssertEqual(result.measurements.floorSupportRatio, 1, accuracy: 1e-9)
        XCTAssertEqual(result.measurements.observationCoverageRatio, 1, accuracy: 1e-9)
    }

    func testSofaBedAndDeskRectangularFootprintsAreSupported() throws {
        let fixtures: [(FurnitureKind, Double, Double, Double)] = [
            (.sofa, 2.2, 0.9, 0.85),
            (.bed, 1.6, 2.1, 0.55),
            (.desk, 1.4, 0.7, 0.75),
        ]

        for (kind, width, depth, height) in fixtures {
            let candidate = try FurniturePlacementCandidate(
                position: vec(0, 0, 0),
                yawRadians: .pi / 7,
                furniture: FurnitureDimensions(
                    kind: kind,
                    width: width,
                    depth: depth,
                    height: height
                )
            )
            XCTAssertEqual(
                FurniturePlacementEvaluator().evaluate(
                    candidate: candidate,
                    evidence: try clearEvidence()
                ).disposition,
                .feasible,
                "Expected \(kind) to use the same verified rectangular-footprint path."
            )
        }
    }

    func testHighConfidenceExistingObjectCollisionRejectsCandidate() throws {
        let obstacle = try PlacementObstacleEvidence(
            objectID: objectID(41),
            bounds: box(
                minX: 0.75,
                minY: 0,
                minZ: -0.25,
                maxX: 1.25,
                maxY: 1,
                maxZ: 0.25
            ),
            confidence: score(0.92)
        )
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence(obstacles: [obstacle])
        )

        XCTAssertEqual(result.disposition, .rejected)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertTrue(result.reasons.contains { $0.code == .collidesWithExistingObject })
        XCTAssertEqual(result.reasons.first?.evidenceIdentifier, objectID(41).description)
    }

    func testObjectAboveFurnitureDoesNotCreateCollision() throws {
        let obstacle = try PlacementObstacleEvidence(
            objectID: objectID(42),
            bounds: box(
                minX: -0.5,
                minY: 1,
                minZ: -0.25,
                maxX: 0.5,
                maxY: 1.5,
                maxZ: 0.25
            ),
            confidence: score(0.95)
        )
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(height: 1),
            evidence: try clearEvidence(obstacles: [obstacle])
        )

        XCTAssertEqual(result.disposition, .feasible)
    }

    func testTouchingObjectBoundaryIsAcceptedWhenZeroClearanceIsRequired() throws {
        let policy = try FurniturePlacementPolicy(
            minimumWallClearance: 0,
            minimumObjectClearance: 0
        )
        let obstacle = try PlacementObstacleEvidence(
            objectID: objectID(43),
            bounds: box(
                minX: 1,
                minY: 0,
                minZ: -0.25,
                maxX: 1.5,
                maxY: 1,
                maxZ: 0.25
            ),
            confidence: score(0.95)
        )
        let result = FurniturePlacementEvaluator(policy: policy).evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence(obstacles: [obstacle])
        )

        XCTAssertEqual(result.disposition, .feasible)
        XCTAssertEqual(result.measurements.nearestObjectClearance, 0)
    }

    func testObjectClearanceJustBelowRequirementRejectsAndExactBoundaryPasses() throws {
        let policy = try FurniturePlacementPolicy(
            minimumWallClearance: 0,
            minimumObjectClearance: 0.10
        )
        let tooClose = try PlacementObstacleEvidence(
            objectID: objectID(44),
            bounds: box(
                minX: 1.09,
                minY: 0,
                minZ: -0.2,
                maxX: 1.4,
                maxY: 1,
                maxZ: 0.2
            ),
            confidence: score(0.9)
        )
        let exact = try PlacementObstacleEvidence(
            objectID: objectID(45),
            bounds: box(
                minX: 1.10,
                minY: 0,
                minZ: -0.2,
                maxX: 1.4,
                maxY: 1,
                maxZ: 0.2
            ),
            confidence: score(0.9)
        )

        XCTAssertEqual(
            FurniturePlacementEvaluator(policy: policy).evaluate(
                candidate: try candidate(),
                evidence: try clearEvidence(obstacles: [tooClose])
            ).reasons.first?.code,
            .objectClearanceTooSmall
        )
        XCTAssertEqual(
            FurniturePlacementEvaluator(policy: policy).evaluate(
                candidate: try candidate(),
                evidence: try clearEvidence(obstacles: [exact])
            ).disposition,
            .feasible
        )
    }

    func testWallClearanceRejectsBelowLimitAndAcceptsExactBoundary() throws {
        let policy = try FurniturePlacementPolicy(
            minimumWallClearance: 0.10,
            minimumObjectClearance: 0
        )
        let tooClose = try wall(id: "wall-near", x: 1.09)
        let exact = try wall(id: "wall-boundary", x: 1.10)

        let rejected = FurniturePlacementEvaluator(policy: policy).evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence(walls: [tooClose])
        )
        XCTAssertEqual(rejected.disposition, .rejected)
        XCTAssertEqual(rejected.reasons.first?.code, .wallClearanceTooSmall)

        let accepted = FurniturePlacementEvaluator(policy: policy).evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence(walls: [exact])
        )
        XCTAssertEqual(accepted.disposition, .feasible)
        XCTAssertEqual(accepted.measurements.nearestWallClearance!, 0.10, accuracy: 1e-9)
    }

    func testShortWallWhollyInsideCandidateIsRejectedIncludingRotatedFootprints() throws {
        let enclosedWall = try PlacementWallEvidence(
            identifier: "enclosed-wall", start: vec(-0.1, 0, 0), end: vec(0.1, 0, 0),
            confidence: score(0.95)
        )
        for yaw in [0.0, .pi / 4, .pi / 2] {
            let result = FurniturePlacementEvaluator().evaluate(
                candidate: try candidate(yaw: yaw),
                evidence: try clearEvidence(walls: [enclosedWall])
            )
            XCTAssertEqual(result.disposition, .rejected)
            XCTAssertEqual(result.reasons.first?.code, .wallClearanceTooSmall)
            XCTAssertEqual(result.measurements.nearestWallClearance, 0)
        }
    }

    func testZeroWallClearanceRejectsInteriorWallsButAllowsBoundaryOnlyContact() throws {
        let policy = try FurniturePlacementPolicy(minimumWallClearance: 0)
        let fixtures: [(Vec3, Vec3, FurniturePlacementDisposition)] = [
            (vec(-0.1, 0, 0), vec(0.1, 0, 0), .rejected),
            (vec(-2, 0, 0), vec(2, 0, 0), .rejected),
            (vec(-2, 0, -0.4), vec(0, 0, 1), .rejected),
            (vec(-1, 0, 0.5), vec(1, 0, 0.5), .feasible),
            (vec(1, 0, 0.5), vec(2, 0, 1), .feasible),
        ]
        for (start, end, expected) in fixtures {
            let wall = try PlacementWallEvidence(
                identifier: "zero-clearance-wall", start: start, end: end, confidence: score(0.95)
            )
            let result = FurniturePlacementEvaluator(policy: policy).evaluate(
                candidate: try candidate(), evidence: try clearEvidence(walls: [wall])
            )
            XCTAssertEqual(result.disposition, expected)
            if expected == .rejected {
                XCTAssertEqual(result.reasons.first?.code, .wallClearanceTooSmall)
            }
        }
    }

    func testLowConfidenceEnclosedWallRequiresMoreEvidence() throws {
        let enclosedWall = try PlacementWallEvidence(
            identifier: "uncertain-enclosed-wall", start: vec(0, 0, -0.1), end: vec(0, 0, 0.1),
            confidence: score(0.2)
        )
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(), evidence: try clearEvidence(walls: [enclosedWall])
        )
        XCTAssertEqual(result.disposition, .insufficientEvidence)
        XCTAssertEqual(result.reasons.first?.code, .possibleWallConflict)
        XCTAssertEqual(result.measurements.nearestWallClearance, 0)
    }

    func testCandidateInFrontOfDoorIsRejected() throws {
        let doorway = try PlacementDoorwayEvidence(
            identifier: "entry-door",
            keepClearRegion: region(x: 0.8, z: 0, width: 1, depth: 1.2),
            confidence: score(0.97)
        )
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence(doorways: [doorway])
        )

        XCTAssertEqual(result.disposition, .rejected)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.reasons.first?.code, .blocksDoorway)
        XCTAssertEqual(result.reasons.first?.evidenceIdentifier, "entry-door")
    }

    func testDoorwayBoundaryContactWithoutAreaOverlapIsAccepted() throws {
        let doorway = try PlacementDoorwayEvidence(
            identifier: "edge-door",
            keepClearRegion: region(x: 1.5, z: 0, width: 1, depth: 1),
            confidence: score(0.95)
        )
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence(doorways: [doorway])
        )

        XCTAssertEqual(result.disposition, .feasible)
    }

    func testCandidateThatNarrowsPassageBelowRequiredWidthIsRejected() throws {
        let passage = try PlacementPassageEvidence(
            identifier: "main-route",
            region: region(width: 8, depth: 2),
            travelAxis: .alongWidth,
            requiredClearWidth: 0.80,
            confidence: score(0.91)
        )
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(depth: 1),
            evidence: try clearEvidence(passages: [passage])
        )

        XCTAssertEqual(result.disposition, .rejected)
        XCTAssertEqual(result.reasons.first?.code, .passageWidthTooNarrow)
        XCTAssertEqual(result.measurements.narrowestAffectedPassageWidth!, 0.5, accuracy: 1e-9)
    }

    func testPassageExactRequiredWidthBoundaryIsAccepted() throws {
        let passage = try PlacementPassageEvidence(
            identifier: "exact-route",
            region: region(width: 8, depth: 2),
            travelAxis: .alongWidth,
            requiredClearWidth: 0.50,
            confidence: score(0.91)
        )
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(depth: 1),
            evidence: try clearEvidence(passages: [passage])
        )

        XCTAssertEqual(result.disposition, .feasible)
    }

    func testPassageCombinesCandidateAndExistingObstacleIntervals() throws {
        let passage = try PlacementPassageEvidence(
            identifier: "shared-route",
            region: region(width: 8, depth: 3),
            travelAxis: .alongWidth,
            requiredClearWidth: 0.80,
            confidence: score(0.95)
        )
        let obstacle = try PlacementObstacleEvidence(
            objectID: objectID(46),
            bounds: box(
                minX: 2,
                minY: 0,
                minZ: 0.5,
                maxX: 3,
                maxY: 1,
                maxZ: 1.5
            ),
            confidence: score(0.95)
        )
        let shiftedCandidate = try candidate(z: -0.5, width: 2, depth: 1)
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: shiftedCandidate,
            evidence: try clearEvidence(obstacles: [obstacle], passages: [passage])
        )

        XCTAssertEqual(result.disposition, .rejected)
        XCTAssertTrue(result.reasons.contains { $0.code == .passageWidthTooNarrow })
        XCTAssertEqual(result.measurements.narrowestAffectedPassageWidth!, 0.5, accuracy: 1e-9)
    }

    func testPassageIgnoresObstaclesOutsideFloorRelativeWalkingHeight() throws {
        for elevation in [0.0, 4.0] {
            let floorRegion = try region(y: elevation, width: 8, depth: 8)
            let floor = try PlacementFloorEvidence(
                identifier: "raised-floor", region: floorRegion,
                elevation: elevation, confidence: score(0.95)
            )
            let passage = try PlacementPassageEvidence(
                identifier: "walking-route", region: region(y: elevation, width: 8, depth: 4),
                travelAxis: .alongWidth, requiredClearWidth: 0.8, confidence: score(0.95)
            )
            for lowerY in [elevation - 1, elevation + 3] {
                let obstacle = try PlacementObstacleEvidence(
                    objectID: objectID(47),
                    bounds: box(
                        minX: -4, minY: lowerY, minZ: -4,
                        maxX: 4, maxY: lowerY + 0.1, maxZ: 4
                    ), confidence: score(0.95)
                )
                let result = FurniturePlacementEvaluator().evaluate(
                    candidate: try candidate(y: elevation),
                    evidence: try clearEvidence(
                        floors: [floor], obstacles: [obstacle], passages: [passage]
                    )
                )
                XCTAssertEqual(result.disposition, .feasible)
                XCTAssertEqual(result.measurements.narrowestAffectedPassageWidth, 1.5)
            }
        }
    }

    func testUncertainObstacleCannotProvePassageIsBlocked() throws {
        let passage = try PlacementPassageEvidence(
            identifier: "uncertain-route", region: region(width: 8, depth: 3),
            travelAxis: .alongWidth, requiredClearWidth: 0.8, confidence: score(0.95)
        )
        for confidence in [0.3, 0.7] {
            let obstacle = try PlacementObstacleEvidence(
                objectID: objectID(49),
                bounds: box(minX: 2, minY: 0, minZ: 0.5, maxX: 3, maxY: 1, maxZ: 1.5),
                confidence: score(confidence)
            )
            let result = FurniturePlacementEvaluator().evaluate(
                candidate: try candidate(z: -0.5),
                evidence: try clearEvidence(obstacles: [obstacle], passages: [passage])
            )
            XCTAssertEqual(result.disposition, confidence < 0.5 ? .insufficientEvidence : .rejected)
            XCTAssertEqual(result.reasons.map(\.code),
                [confidence < 0.5 ? .possiblePassageConflict : .passageWidthTooNarrow])
            XCTAssertEqual(result.confidenceScore.value, confidence, accuracy: 1e-9)
            XCTAssertEqual(result.measurements.narrowestAffectedPassageWidth!, 0.5, accuracy: 1e-9)
        }
    }

    func testUncertainObstacleDoesNotDowngradeIndependentlyProvenPassageBlockage() throws {
        let passage = try PlacementPassageEvidence(
            identifier: "narrow-route", region: region(width: 8, depth: 2),
            travelAxis: .alongWidth, requiredClearWidth: 0.8, confidence: score(0.95)
        )
        let obstacle = try PlacementObstacleEvidence(
            objectID: objectID(49),
            bounds: box(minX: 2, minY: 0, minZ: 0.5, maxX: 3, maxY: 1, maxZ: 1),
            confidence: score(0.3)
        )
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence(obstacles: [obstacle], passages: [passage])
        )
        XCTAssertEqual(result.disposition, .rejected)
        XCTAssertEqual(result.reasons.map(\.code), [.passageWidthTooNarrow])
        XCTAssertEqual(result.confidenceScore.value, 0.95, accuracy: 1e-9)
    }

    func testLowOverheadObstacleBlocksPassageEvenWhenFurnitureFitsBelowIt() throws {
        let overhead = try PlacementObstacleEvidence(
            objectID: objectID(48),
            bounds: box(minX: -4, minY: 1.5, minZ: -4, maxX: 4, maxY: 1.6, maxZ: 4),
            confidence: score(0.95)
        )
        let passage = try PlacementPassageEvidence(
            identifier: "low-headroom-route", region: region(width: 8, depth: 4),
            travelAxis: .alongWidth, requiredClearWidth: 0.8, confidence: score(0.95)
        )
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(height: 1),
            evidence: try clearEvidence(obstacles: [overhead], passages: [passage])
        )
        XCTAssertEqual(result.disposition, .rejected)
        XCTAssertTrue(result.reasons.contains { $0.code == .passageWidthTooNarrow })
        XCTAssertFalse(result.reasons.contains { $0.code == .collidesWithExistingObject })
        XCTAssertEqual(result.measurements.narrowestAffectedPassageWidth, 0)
    }

    func testCandidateExactlyOnFloorBoundaryHasFullSupport() throws {
        let floor = try PlacementFloorEvidence(
            identifier: "exact-floor",
            region: region(width: 2, depth: 1),
            elevation: 0,
            confidence: score(0.95)
        )
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence(floors: [floor])
        )

        XCTAssertEqual(result.disposition, .feasible)
        XCTAssertEqual(result.measurements.floorSupportRatio, 1, accuracy: 1e-9)
    }

    func testKnownFloorOverhangIsRejected() throws {
        let floor = try PlacementFloorEvidence(
            identifier: "narrow-floor",
            region: region(width: 1.8, depth: 1),
            elevation: 0,
            confidence: score(0.95)
        )
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence(floors: [floor])
        )

        XCTAssertEqual(result.disposition, .rejected)
        XCTAssertEqual(result.reasons.first?.code, .floorSupportInsufficient)
        XCTAssertEqual(result.measurements.floorSupportRatio, 0.9, accuracy: 1e-9)
    }

    func testWrongCandidateElevationIsRejectedWithVerifiedCoverage() throws {
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(y: 0.20),
            evidence: try clearEvidence()
        )

        XCTAssertEqual(result.disposition, .rejected)
        XCTAssertEqual(result.reasons.first?.code, .floorSupportInsufficient)
        XCTAssertEqual(result.measurements.floorSupportRatio, 0)
    }

    func testMissingMapEvidenceReturnsInsufficientEvidenceAndNeverFeasible() throws {
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(),
            evidence: FurniturePlacementEvidence(
                floors: [],
                observations: [],
                completeness: .unavailable
            )
        )

        XCTAssertEqual(result.disposition, .insufficientEvidence)
        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(
            Set(result.reasons.map(\.code)),
            Set([
                .floorEvidenceMissing,
                .observationEvidenceMissing,
                .wallEvidenceIncomplete,
                .doorwayEvidenceIncomplete,
                .obstacleEvidenceIncomplete,
                .passageEvidenceIncomplete,
            ])
        )
    }

    func testPartialObservationCoverageReturnsInsufficientEvidence() throws {
        let observation = try PlacementObservationEvidence(
            identifier: "partial-scan",
            region: region(width: 2, depth: 1.2),
            confidence: score(0.95)
        )
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence(observations: [observation])
        )

        XCTAssertEqual(result.disposition, .insufficientEvidence)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.reasons.first?.code, .observationCoverageInsufficient)
        XCTAssertLessThan(result.measurements.observationCoverageRatio, 0.95)
    }

    func testLowConfidenceFreeSpaceReturnsInsufficientEvidence() throws {
        let observation = try PlacementObservationEvidence(
            identifier: "uncertain-scan",
            region: region(width: 8, depth: 8),
            confidence: score(0.49)
        )
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence(observations: [observation])
        )

        XCTAssertEqual(result.disposition, .insufficientEvidence)
        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(result.reasons.first?.code, .observationConfidenceTooLow)
    }

    func testLowConfidenceDoorConflictStaysInsufficientRatherThanRejecting() throws {
        let doorway = try PlacementDoorwayEvidence(
            identifier: "uncertain-door",
            keepClearRegion: region(width: 1, depth: 1),
            confidence: score(0.40)
        )
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence(doorways: [doorway])
        )

        XCTAssertEqual(result.disposition, .insufficientEvidence)
        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(result.reasons.first?.code, .possibleDoorwayConflict)
    }

    func testMediumEvidenceProducesMediumFeasibleConfidence() throws {
        let floor = try PlacementFloorEvidence(
            identifier: "medium-floor",
            region: region(width: 8, depth: 8),
            elevation: 0,
            confidence: score(0.65)
        )
        let observation = try PlacementObservationEvidence(
            identifier: "medium-scan",
            region: region(width: 8, depth: 8),
            confidence: score(0.60)
        )
        let result = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence(floors: [floor], observations: [observation])
        )

        XCTAssertEqual(result.disposition, .feasible)
        XCTAssertEqual(result.confidence, .medium)
        XCTAssertEqual(result.confidenceScore, score(0.60))
    }

    func testRotatedCandidateCollisionUsesOrientedFootprint() throws {
        let obstacle = try PlacementObstacleEvidence(
            objectID: objectID(47),
            bounds: box(
                minX: 0.55,
                minY: 0,
                minZ: 0.55,
                maxX: 0.80,
                maxY: 1,
                maxZ: 0.80
            ),
            confidence: score(0.95)
        )
        let unrotated = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(width: 2, depth: 0.5),
            evidence: try clearEvidence(obstacles: [obstacle])
        )
        let rotated = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(width: 2, depth: 0.5, yaw: .pi / 4),
            evidence: try clearEvidence(obstacles: [obstacle])
        )

        XCTAssertEqual(unrotated.disposition, .feasible)
        XCTAssertEqual(rotated.disposition, .rejected)
        XCTAssertTrue(rotated.reasons.contains { $0.code == .collidesWithExistingObject })
    }

    func testInputValidationRejectsNaNInfinityZeroAndInvalidPassage() throws {
        XCTAssertThrowsError(
            try FurnitureDimensions(kind: .sofa, width: .nan, depth: 1, height: 1)
        ) { error in
            XCTAssertEqual(error as? FurniturePlacementInputError, .nonFiniteValue)
        }
        XCTAssertThrowsError(
            try FurnitureDimensions(kind: .bed, width: 1, depth: 0, height: 1)
        ) { error in
            XCTAssertEqual(error as? FurniturePlacementInputError, .nonPositiveDimension)
        }
        XCTAssertThrowsError(
            try FurniturePlacementCandidate(
                position: .zero,
                yawRadians: .infinity,
                furniture: FurnitureDimensions(kind: .desk, width: 1, depth: 1, height: 1)
            )
        ) { error in
            XCTAssertEqual(error as? FurniturePlacementInputError, .nonFiniteValue)
        }
        XCTAssertThrowsError(
            try PlacementHorizontalRegion(center: .zero, width: 1, depth: 1, yawRadians: .nan)
        ) { error in
            XCTAssertEqual(error as? FurniturePlacementInputError, .nonFiniteValue)
        }
        XCTAssertThrowsError(
            try PlacementWallEvidence(
                identifier: "wall",
                start: .zero,
                end: .zero,
                confidence: .one
            )
        ) { error in
            XCTAssertEqual(error as? FurniturePlacementInputError, .degenerateWall)
        }
        XCTAssertThrowsError(
            try PlacementPassageEvidence(
                identifier: "route",
                region: region(width: 2, depth: 1),
                travelAxis: .alongWidth,
                requiredClearWidth: 1.01,
                confidence: .one
            )
        ) { error in
            XCTAssertEqual(error as? FurniturePlacementInputError, .passageWidthExceedsRegion)
        }
        XCTAssertThrowsError(try FurniturePlacementPolicy(minimumFloorSupportRatio: .nan)) {
            error in
            XCTAssertEqual(error as? FurniturePlacementInputError, .nonFiniteValue)
        }
    }

    func testCodableCannotBypassFiniteCandidateValidation() throws {
        let payload = Data(
            #"{"position":{"x":0,"y":0,"z":0},"yawRadians":"NaN","furniture":{"kind":"sofa","width":2,"depth":1,"height":1}}"#
                .utf8
        )
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )

        XCTAssertThrowsError(try decoder.decode(FurniturePlacementCandidate.self, from: payload))
    }

    func testEvaluationIsDeterministicAcrossEvidenceOrdering() throws {
        let wallA = try wall(id: "a", x: 1.01, confidence: 0.7)
        let wallB = try wall(id: "b", x: -1.01, confidence: 0.9)
        let first = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence(walls: [wallB, wallA])
        )
        let second = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence(walls: [wallA, wallB])
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.reasons.compactMap(\.evidenceIdentifier), ["a", "b"])
    }

    func testEvaluationRoundTripsThroughJSON() throws {
        let original = FurniturePlacementEvaluator().evaluate(
            candidate: try candidate(),
            evidence: try clearEvidence()
        )
        let restored = try JSONDecoder().decode(
            FurniturePlacementEvaluation.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(restored, original)
        XCTAssertFalse(restored.reasons[0].message.isEmpty)
    }

    private func candidate(
        kind: FurnitureKind = .sofa,
        x: Double = 0,
        y: Double = 0,
        z: Double = 0,
        width: Double = 2,
        depth: Double = 1,
        height: Double = 1,
        yaw: Double = 0
    ) throws -> FurniturePlacementCandidate {
        try FurniturePlacementCandidate(
            position: vec(x, y, z),
            yawRadians: yaw,
            furniture: FurnitureDimensions(
                kind: kind,
                width: width,
                depth: depth,
                height: height
            )
        )
    }

    private func region(
        x: Double = 0,
        y: Double = 0,
        z: Double = 0,
        width: Double,
        depth: Double,
        yaw: Double = 0
    ) throws -> PlacementHorizontalRegion {
        try PlacementHorizontalRegion(
            center: vec(x, y, z),
            width: width,
            depth: depth,
            yawRadians: yaw
        )
    }

    private func wall(
        id: String,
        x: Double,
        confidence: Double = 0.95
    ) throws -> PlacementWallEvidence {
        try PlacementWallEvidence(
            identifier: id,
            start: vec(x, 0, -4),
            end: vec(x, 0, 4),
            confidence: score(confidence)
        )
    }

    private func clearEvidence(
        floors: [PlacementFloorEvidence]? = nil,
        observations: [PlacementObservationEvidence]? = nil,
        walls: [PlacementWallEvidence] = [],
        doorways: [PlacementDoorwayEvidence] = [],
        obstacles: [PlacementObstacleEvidence] = [],
        passages: [PlacementPassageEvidence] = []
    ) throws -> FurniturePlacementEvidence {
        let floor = try PlacementFloorEvidence(
            identifier: "main-floor",
            region: region(width: 8, depth: 8),
            elevation: 0,
            confidence: score(0.94)
        )
        let observation = try PlacementObservationEvidence(
            identifier: "verified-scan",
            region: region(width: 8, depth: 8),
            confidence: score(0.92)
        )
        return FurniturePlacementEvidence(
            floors: floors ?? [floor],
            observations: observations ?? [observation],
            walls: walls,
            doorways: doorways,
            obstacles: obstacles,
            passages: passages,
            completeness: .complete
        )
    }
}
