import XCTest

@testable import VispaceCore

final class RecognitionAndIdentityTests: XCTestCase {
    private let visualOnlyWeights = try! PlaceEvidenceWeights(
        visual: 1,
        geometry: 0,
        structure: 0,
        poseConsistency: 0,
        objectLayout: 0
    )

    func testKnownThresholdsAreInclusive() throws {
        let policy = try PlaceRecognitionPolicy(
            overlappingScoreThreshold: score(0.5),
            knownScoreThreshold: score(0.75),
            minimumOverlap: score(0.1),
            knownOverlapThreshold: score(0.5),
            minimumKnownGeometry: score(0.5),
            weights: visualOnlyWeights
        )
        let result = PlaceRecognizer(policy: policy).classify(
            PlaceEvidence(
                visual: score(0.75),
                geometry: score(0.5),
                structure: .zero,
                poseConsistency: .zero,
                objectLayout: .zero,
                spatialOverlap: score(0.5)
            )
        )
        XCTAssertEqual(result.classification, .known)
        XCTAssertEqual(result.mutationPlan, .updateExisting)
    }

    func testBalancedExactHighBoundaryIsNotLostToFloatingPointRounding() {
        let result = PlaceRecognizer().classify(
            PlaceEvidence(
                visual: .zero,
                geometry: .one,
                structure: .one,
                poseConsistency: .one,
                objectLayout: .one,
                spatialOverlap: .one
            )
        )

        XCTAssertEqual(result.aggregateScore, ConfidenceScore(clamping: 0.8))
        XCTAssertEqual(result.grade, .high)
        XCTAssertEqual(result.classification, .known)
    }

    func testHighAppearanceWithoutSpatialOverlapIsNew() throws {
        let policy = try PlaceRecognitionPolicy(
            overlappingScoreThreshold: score(0.5),
            knownScoreThreshold: score(0.75),
            minimumOverlap: score(0.1),
            knownOverlapThreshold: score(0.5),
            minimumKnownGeometry: score(0.5),
            weights: visualOnlyWeights
        )
        let result = PlaceRecognizer(policy: policy).classify(
            PlaceEvidence(
                visual: .one,
                geometry: .one,
                structure: .one,
                poseConsistency: .one,
                objectLayout: .one,
                spatialOverlap: score(0.099)
            )
        )
        XCTAssertEqual(result.classification, .new)
        XCTAssertEqual(result.mutationPlan, .createNewNode)
    }

    func testPartialOverlapProducesValidationPlanNotImmediateMerge() throws {
        let policy = try PlaceRecognitionPolicy(
            overlappingScoreThreshold: score(0.5),
            knownScoreThreshold: score(0.9),
            minimumOverlap: score(0.1),
            knownOverlapThreshold: score(0.8),
            minimumKnownGeometry: score(0.5),
            weights: visualOnlyWeights
        )
        let result = PlaceRecognizer(policy: policy).classify(
            PlaceEvidence(
                visual: score(0.5),
                geometry: .one,
                structure: .zero,
                poseConsistency: .zero,
                objectLayout: .zero,
                spatialOverlap: score(0.1)
            )
        )
        XCTAssertEqual(result.classification, .overlapping)
        XCTAssertEqual(result.mutationPlan, .validateMerge)
    }

    func testPlacePolicyRejectsInvalidOrderingAndWeights() {
        XCTAssertThrowsError(
            try PlaceEvidenceWeights(
                visual: 0,
                geometry: 0,
                structure: 0,
                poseConsistency: 0,
                objectLayout: 0
            )
        )
        XCTAssertThrowsError(
            try PlaceRecognitionPolicy(
                overlappingScoreThreshold: score(0.8),
                knownScoreThreshold: score(0.8)
            )
        )
    }

    func testRecognitionWeightsRejectFiniteComponentsWhoseTotalOverflows() throws {
        let huge = Double.greatestFiniteMagnitude
        XCTAssertThrowsError(
            try PlaceEvidenceWeights(
                visual: huge, geometry: huge, structure: 0, poseConsistency: 0, objectLayout: 0
            )
        ) { error in
            XCTAssertEqual(error as? PlaceRecognitionError, .invalidWeights)
        }
        XCTAssertThrowsError(
            try IdentityWeights(visual: huge, geometry: huge, spatialContext: 0, temporalContinuity: 0)
        ) { error in
            XCTAssertEqual(error as? ObjectIdentityError, .invalidWeights)
        }

        let placeJSON = try JSONSerialization.data(withJSONObject: [
            "visual": huge, "geometry": huge, "structure": 0,
            "poseConsistency": 0, "objectLayout": 0,
        ])
        XCTAssertThrowsError(try JSONDecoder().decode(PlaceEvidenceWeights.self, from: placeJSON))
        let identityJSON = try JSONSerialization.data(withJSONObject: [
            "visual": huge, "geometry": huge, "spatialContext": 0, "temporalContinuity": 0,
        ])
        XCTAssertThrowsError(try JSONDecoder().decode(IdentityWeights.self, from: identityJSON))

        // Large but representable totals remain valid custom policies.
        XCTAssertNoThrow(
            try PlaceEvidenceWeights(
                visual: huge, geometry: 0, structure: 0, poseConsistency: 0, objectLayout: 0
            )
        )
        XCTAssertNoThrow(
            try IdentityWeights(visual: huge, geometry: 0, spatialContext: 0, temporalContinuity: 0)
        )
    }

    func testIdentityTieRemainsProvisionalWithDeterministicOrder() throws {
        let firstID = objectID(1)
        let secondID = objectID(2)
        let engine = ObjectIdentityEngine(
            policy: try ObjectIdentityPolicy(
                candidateThreshold: score(0.5),
                confirmationThreshold: score(0.75),
                ambiguityMargin: score(0.1),
                minimumObservationCount: 2,
                weights: try IdentityWeights(
                    visual: 1,
                    geometry: 0,
                    spatialContext: 0,
                    temporalContinuity: 0
                )
            )
        )
        let evidence = [secondID, firstID].map {
            IdentityEvidence(
                objectID: $0,
                semanticClassMatches: true,
                visual: score(0.9),
                geometry: .zero,
                spatialContext: .zero,
                temporalContinuity: .zero,
                validObservationCount: 3
            )
        }

        guard case .provisional(let candidates) = engine.decide(from: evidence) else {
            return XCTFail("An exact tie must stay provisional")
        }
        XCTAssertEqual(candidates.map(\.objectID), [firstID, secondID])
    }

    func testIdentityExactScoreAndMarginBoundariesCanConfirm() throws {
        let engine = ObjectIdentityEngine(
            policy: try ObjectIdentityPolicy(
                candidateThreshold: score(0.5),
                confirmationThreshold: score(0.75),
                ambiguityMargin: score(0.25),
                minimumObservationCount: 2,
                weights: try IdentityWeights(
                    visual: 1,
                    geometry: 0,
                    spatialContext: 0,
                    temporalContinuity: 0
                )
            )
        )
        let best = IdentityEvidence(
            objectID: objectID(1),
            semanticClassMatches: true,
            visual: score(0.75),
            geometry: .zero,
            spatialContext: .zero,
            temporalContinuity: .zero,
            validObservationCount: 2
        )
        let runnerUp = IdentityEvidence(
            objectID: objectID(2),
            semanticClassMatches: true,
            visual: score(0.5),
            geometry: .zero,
            spatialContext: .zero,
            temporalContinuity: .zero,
            validObservationCount: 10
        )

        guard case .confirmed(let candidate) = engine.decide(from: [runnerUp, best]) else {
            return XCTFail("Exact inclusive boundaries should confirm")
        }
        XCTAssertEqual(candidate.objectID, best.objectID)
    }

    func testIdentityRejectsWrongClassAndWeakEvidence() {
        let engine = ObjectIdentityEngine()
        let wrongClass = IdentityEvidence(
            objectID: objectID(1),
            semanticClassMatches: false,
            visual: .one,
            geometry: .one,
            spatialContext: .one,
            temporalContinuity: .one,
            validObservationCount: 10
        )
        XCTAssertEqual(engine.decide(from: [wrongClass]), .newObject)

        let weak = IdentityEvidence(
            objectID: objectID(2),
            semanticClassMatches: true,
            visual: score(0.1),
            geometry: score(0.1),
            spatialContext: score(0.1),
            temporalContinuity: score(0.1),
            validObservationCount: 10
        )
        XCTAssertEqual(engine.decide(from: [weak]), .newObject)
    }

    func testHighScoreWithTooFewObservationsStaysProvisional() {
        let engine = ObjectIdentityEngine()
        let evidence = IdentityEvidence(
            objectID: objectID(1),
            semanticClassMatches: true,
            visual: .one,
            geometry: .one,
            spatialContext: .one,
            temporalContinuity: .one,
            validObservationCount: 1
        )
        guard case .provisional = engine.decide(from: [evidence]) else {
            return XCTFail("A single observation must not confirm a permanent identity")
        }
    }

    func testDuplicateEvidenceForSameObjectDoesNotCreateFalseAmbiguity() throws {
        let engine = ObjectIdentityEngine(
            policy: try ObjectIdentityPolicy(
                candidateThreshold: score(0.5),
                confirmationThreshold: score(0.8),
                ambiguityMargin: score(0.15),
                minimumObservationCount: 2,
                weights: try IdentityWeights(
                    visual: 1,
                    geometry: 0,
                    spatialContext: 0,
                    temporalContinuity: 0
                )
            )
        )
        let repeatedID = objectID(1)
        let evidence = [
            IdentityEvidence(
                objectID: repeatedID,
                semanticClassMatches: true,
                visual: score(0.9),
                geometry: .zero,
                spatialContext: .zero,
                temporalContinuity: .zero,
                validObservationCount: 3
            ),
            IdentityEvidence(
                objectID: repeatedID,
                semanticClassMatches: true,
                visual: score(0.8),
                geometry: .zero,
                spatialContext: .zero,
                temporalContinuity: .zero,
                validObservationCount: 2
            ),
            IdentityEvidence(
                objectID: objectID(2),
                semanticClassMatches: true,
                visual: score(0.7),
                geometry: .zero,
                spatialContext: .zero,
                temporalContinuity: .zero,
                validObservationCount: 5
            ),
        ]

        guard case .confirmed(let candidate) = engine.decide(from: evidence) else {
            return XCTFail("Duplicate evidence must be collapsed by object ID")
        }
        XCTAssertEqual(candidate.objectID, repeatedID)
    }
}
