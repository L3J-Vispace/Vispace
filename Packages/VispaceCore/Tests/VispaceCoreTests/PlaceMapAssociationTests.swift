import XCTest

@testable import VispaceCore

final class PlaceMapAssociationTests: XCTestCase {
    private let sourceMapID = placeMapID(1)
    private let candidateMapID = placeMapID(2)
    private let sourceFrameID = placeFrameID(1)
    private let candidateFrameID = placeFrameID(2)

    func testRepeatedMultimodalEvidenceRecognizesKnownMapInSameFrame() throws {
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: sourceMapID,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        for index in 0..<2 {
            _ = try reducer.apply(
                observation(
                    index: index,
                    candidate: candidate(
                        mapID: sourceMapID,
                        frameID: sourceFrameID,
                        evidence: placeEvidence(0.9)
                    )
                )
            )
        }

        let decision = reducer.decision()
        XCTAssertEqual(decision.outcome, .known)
        XCTAssertEqual(decision.selectedMapID, sourceMapID)
        XCTAssertEqual(
            decision.mutation,
            .associateExisting(targetMapID: sourceMapID)
        )
        XCTAssertEqual(decision.grade, .high)
        guard
            case .compatible(let transform, let confidence) =
                reducer.snapshot.candidates[sourceMapID]?.compatibility
        else {
            return XCTFail("A shared coordinate frame must latch as compatible")
        }
        XCTAssertEqual(transform, .identity)
        XCTAssertEqual(confidence, .one)
    }

    func testHighMultimodalPartialOverlapCanProposeMergeAfterThreeObservations() throws {
        let alignment = Transform3D.translation(try Vec3(x: 1, y: 0, z: -2))
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: sourceMapID,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        for index in 0..<3 {
            _ = try reducer.apply(
                observation(
                    index: index,
                    candidate: candidate(
                        mapID: candidateMapID,
                        frameID: candidateFrameID,
                        evidence: placeEvidence(0.9, overlap: 0.4),
                        compatibility: .aligned(
                            sourceToCandidate: alignment,
                            confidence: placeScore(0.95)
                        )
                    )
                )
            )
        }

        let decision = reducer.decision()
        XCTAssertEqual(decision.outcome, .overlapping)
        XCTAssertEqual(decision.grade, .high)
        XCTAssertEqual(
            decision.mutation,
            .mergeMaps(
                sourceMapID: sourceMapID,
                targetMapID: candidateMapID,
                sourceToTarget: alignment
            )
        )
    }

    func testTwoStrongObservationsCanRecognizeButCannotMergeDifferentMaps() throws {
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: sourceMapID,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        for index in 0..<2 {
            _ = try reducer.apply(
                observation(
                    index: index,
                    candidate: candidate(
                        mapID: candidateMapID,
                        frameID: candidateFrameID,
                        evidence: placeEvidence(0.9),
                        compatibility: .aligned(
                            sourceToCandidate: .identity,
                            confidence: placeScore(0.95)
                        )
                    )
                )
            )
        }

        let decision = reducer.decision()
        XCTAssertEqual(decision.outcome, .known)
        XCTAssertEqual(decision.selectedMapID, candidateMapID)
        XCTAssertEqual(decision.mutation, .deferDecision)
    }

    func testSingleStrongModalityNeverAssociatesOrMerges() throws {
        let visualOnly = try PlaceRecognitionPolicy(
            overlappingScoreThreshold: placeScore(0.5),
            knownScoreThreshold: placeScore(0.8),
            minimumOverlap: .zero,
            knownOverlapThreshold: placeScore(0.1),
            minimumKnownGeometry: .zero,
            weights: try PlaceEvidenceWeights(
                visual: 1,
                geometry: 0,
                structure: 0,
                poseConsistency: 0,
                objectLayout: 0
            )
        )
        let policy = try PlaceAssociationPolicy(recognitionPolicy: visualOnly)
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: sourceMapID,
                sourceCoordinateFrameID: sourceFrameID
            ),
            policy: policy
        )
        let weaklyMultimodal = PlaceEvidence(
            visual: .one,
            geometry: .zero,
            structure: .zero,
            poseConsistency: .zero,
            objectLayout: .zero,
            spatialOverlap: placeScore(0.2)
        )
        for index in 0..<3 {
            _ = try reducer.apply(
                observation(
                    index: index,
                    candidate: candidate(
                        mapID: candidateMapID,
                        frameID: sourceFrameID,
                        evidence: weaklyMultimodal
                    )
                )
            )
        }

        let decision = reducer.decision()
        XCTAssertEqual(decision.outcome, .ambiguous)
        XCTAssertEqual(decision.mutation, .deferDecision)
        XCTAssertEqual(decision.reason, .insufficientIndependentModalities)
        XCTAssertEqual(reducer.candidateEvaluations().first?.highModalityCount, 1)
    }

    func testMediumAlignmentEvidenceDoesNotLatchCompatibility() throws {
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: sourceMapID,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        for index in 0..<3 {
            _ = try reducer.apply(
                observation(
                    index: index,
                    candidate: candidate(
                        mapID: candidateMapID,
                        frameID: candidateFrameID,
                        evidence: placeEvidence(0.9),
                        compatibility: .aligned(
                            sourceToCandidate: .identity,
                            confidence: placeScore(0.7)
                        )
                    )
                )
            )
        }

        XCTAssertEqual(
            reducer.snapshot.candidates[candidateMapID]?.compatibility,
            .unresolved
        )
        let decision = reducer.decision()
        XCTAssertEqual(decision.outcome, .ambiguous)
        XCTAssertEqual(decision.mutation, .deferDecision)
        XCTAssertEqual(decision.reason, .coordinateCompatibilityUnresolved)
    }

    func testHighIncompatibilityIsLatchedAndResultsInNewPlace() throws {
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: sourceMapID,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        for index in 0..<2 {
            _ = try reducer.apply(
                observation(
                    index: index,
                    candidate: candidate(
                        mapID: candidateMapID,
                        frameID: candidateFrameID,
                        evidence: placeEvidence(0.95),
                        compatibility: .incompatible(confidence: placeScore(0.9))
                    )
                )
            )
        }

        guard
            case .incompatible =
                reducer.snapshot.candidates[candidateMapID]?.compatibility
        else {
            return XCTFail("High-confidence incompatibility must be latched")
        }
        XCTAssertEqual(reducer.decision().outcome, .new)
        XCTAssertEqual(reducer.decision().mutation, .createNewMap)
    }

    func testConflictingCompatibilityFailsAtomically() throws {
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: sourceMapID,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        _ = try reducer.apply(
            observation(
                index: 0,
                candidate: candidate(
                    mapID: candidateMapID,
                    frameID: candidateFrameID,
                    evidence: placeEvidence(0.9),
                    compatibility: .aligned(
                        sourceToCandidate: .identity,
                        confidence: placeScore(0.9)
                    )
                )
            )
        )
        let before = reducer.snapshot

        XCTAssertThrowsError(
            try reducer.apply(
                observation(
                    index: 1,
                    candidate: candidate(
                        mapID: candidateMapID,
                        frameID: candidateFrameID,
                        evidence: placeEvidence(0.9),
                        compatibility: .incompatible(confidence: placeScore(0.95))
                    )
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaceMapAssociationError,
                .compatibilityConflict(mapID: self.candidateMapID)
            )
        }
        XCTAssertEqual(reducer.snapshot, before)
    }

    func testCandidateFrameBindingCannotChange() throws {
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: nil,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        _ = try reducer.apply(
            observation(
                index: 0,
                candidate: candidate(
                    mapID: candidateMapID,
                    frameID: candidateFrameID,
                    evidence: placeEvidence(0.8)
                )
            )
        )
        let before = reducer.snapshot

        XCTAssertThrowsError(
            try reducer.apply(
                observation(
                    index: 1,
                    candidate: candidate(
                        mapID: candidateMapID,
                        frameID: placeFrameID(3),
                        evidence: placeEvidence(0.8)
                    )
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaceMapAssociationError,
                .candidateCoordinateFrameConflict(mapID: self.candidateMapID)
            )
        }
        XCTAssertEqual(reducer.snapshot, before)
    }

    func testSourceMapCannotBePresentedInDifferentCoordinateFrame() {
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: sourceMapID,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        XCTAssertThrowsError(
            try reducer.apply(
                observation(
                    index: 0,
                    candidate: candidate(
                        mapID: sourceMapID,
                        frameID: candidateFrameID,
                        evidence: placeEvidence(0.9)
                    )
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaceMapAssociationError,
                .sourceMapCoordinateFrameConflict(mapID: self.sourceMapID)
            )
        }
        XCTAssertEqual(reducer.snapshot.revision, 0)
    }

    func testCompetingCandidatesStayAmbiguousInStableMapIDOrder() throws {
        let lowerID = placeMapID(10)
        let higherID = placeMapID(20)
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: nil,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        for index in 0..<2 {
            let candidates = [
                candidate(
                    mapID: higherID,
                    frameID: sourceFrameID,
                    evidence: placeEvidence(0.9)
                ),
                candidate(
                    mapID: lowerID,
                    frameID: sourceFrameID,
                    evidence: placeEvidence(0.9)
                ),
            ]
            _ = try reducer.apply(observation(index: index, candidates: candidates))
        }

        let decision = reducer.decision()
        XCTAssertEqual(decision.outcome, .ambiguous)
        XCTAssertEqual(decision.reason, .competingCandidates)
        XCTAssertEqual(decision.candidateMapIDs, [lowerID, higherID])
    }

    func testCandidateEvidenceIsStrictlyBoundedToNewestSamples() throws {
        let policy = try PlaceAssociationPolicy(
            minimumObservationsForMerge: 3,
            maximumEvidencePerCandidate: 3
        )
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: nil,
                sourceCoordinateFrameID: sourceFrameID
            ),
            policy: policy
        )
        for index in 0..<5 {
            _ = try reducer.apply(
                observation(
                    index: index,
                    candidate: candidate(
                        mapID: candidateMapID,
                        frameID: sourceFrameID,
                        evidence: placeEvidence(Double(index) / 10)
                    )
                )
            )
        }

        XCTAssertEqual(
            reducer.snapshot.candidates[candidateMapID]?.evidence.map(\.sequence),
            [3, 4, 5]
        )
    }

    func testSequenceAgeExpiresEvidenceWithoutForgettingCompatibilityLatch() throws {
        let policy = try PlaceAssociationPolicy(maximumEvidenceSequenceAge: 2)
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: nil,
                sourceCoordinateFrameID: sourceFrameID
            ),
            policy: policy
        )
        _ = try reducer.apply(
            PlaceAssociationObservation(
                id: placeObservationID(1),
                baseRevision: 0,
                sequence: 1,
                candidates: [
                    candidate(
                        mapID: candidateMapID,
                        frameID: sourceFrameID,
                        evidence: placeEvidence(0.9)
                    )
                ]
            )
        )
        _ = try reducer.apply(
            PlaceAssociationObservation(
                id: placeObservationID(2),
                baseRevision: 1,
                sequence: 10,
                candidates: []
            )
        )

        XCTAssertEqual(reducer.snapshot.candidates[candidateMapID]?.evidence, [])
        guard
            case .compatible =
                reducer.snapshot.candidates[candidateMapID]?.compatibility
        else {
            return XCTFail("Compatibility provenance must outlive rolling score evidence")
        }
        XCTAssertEqual(reducer.decision().outcome, .ambiguous)

        _ = try reducer.apply(
            PlaceAssociationObservation(
                id: placeObservationID(3),
                baseRevision: 2,
                sequence: 11,
                candidates: []
            )
        )
        XCTAssertEqual(reducer.decision().outcome, .new)
    }

    func testLowConfidenceAbsenceNeverCreatesNewMap() throws {
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: nil,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        for index in 0..<3 {
            _ = try reducer.apply(
                observation(
                    index: index,
                    candidate: candidate(
                        mapID: candidateMapID,
                        frameID: sourceFrameID,
                        evidence: placeEvidence(0.54)
                    )
                )
            )
        }

        let decision = reducer.decision()
        XCTAssertEqual(decision.outcome, .ambiguous)
        XCTAssertEqual(decision.mutation, .deferDecision)
        XCTAssertEqual(decision.reason, .insufficientNoMatchConfidence)
        XCTAssertEqual(reducer.snapshot.recentNoMatchObservationCount, 0)
    }

    func testPastPositiveEvidenceAndOneFreshMissCannotCreateNewMap() throws {
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: nil,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        for index in 0..<2 {
            _ = try reducer.apply(
                observation(
                    index: index,
                    candidate: candidate(
                        mapID: candidateMapID,
                        frameID: sourceFrameID,
                        evidence: placeEvidence(0.9)
                    )
                )
            )
        }
        XCTAssertEqual(reducer.decision().outcome, .known)

        _ = try reducer.apply(observation(index: 2, candidates: []))
        let decision = reducer.decision()
        XCTAssertEqual(decision.outcome, .ambiguous)
        XCTAssertEqual(decision.mutation, .deferDecision)
        XCTAssertEqual(decision.reason, .insufficientRepeatedEvidence)
        XCTAssertEqual(reducer.snapshot.recentNoMatchObservationCount, 1)
    }

    func testCandidateMustAppearInLatestObservationBeforeMergeIsProposed() throws {
        let alignment = Transform3D.translation(try Vec3(x: 1, y: 0, z: 0))
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: sourceMapID,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        for index in 0..<3 {
            _ = try reducer.apply(
                observation(
                    index: index,
                    candidate: candidate(
                        mapID: candidateMapID,
                        frameID: candidateFrameID,
                        evidence: placeEvidence(0.9, overlap: 0.4),
                        compatibility: .aligned(
                            sourceToCandidate: alignment,
                            confidence: placeScore(0.95)
                        )
                    )
                )
            )
        }
        guard case .mergeMaps = reducer.decision().mutation else {
            return XCTFail("Precondition should produce a merge proposal")
        }

        _ = try reducer.apply(observation(index: 3, candidates: []))
        XCTAssertEqual(reducer.decision().outcome, .ambiguous)
        XCTAssertEqual(reducer.decision().mutation, .deferDecision)
    }

    func testExactReplayLedgerIsBounded() throws {
        let policy = try PlaceAssociationPolicy(maximumRememberedObservations: 2)
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: nil,
                sourceCoordinateFrameID: sourceFrameID
            ),
            policy: policy
        )
        let events = (0..<4).map { observation(index: $0, candidates: []) }
        for event in events {
            _ = try reducer.apply(event)
        }
        XCTAssertEqual(reducer.snapshot.rememberedObservationCount, 2)

        XCTAssertThrowsError(try reducer.apply(events[0])) { error in
            XCTAssertEqual(
                error as? PlaceMapAssociationError,
                .revisionConflict(expected: 4, actualBase: 0)
            )
        }
    }

    func testTrackedCandidateLimitRejectsWholeObservationAtomically() throws {
        let policy = try PlaceAssociationPolicy(maximumTrackedCandidates: 1)
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: nil,
                sourceCoordinateFrameID: sourceFrameID
            ),
            policy: policy
        )
        _ = try reducer.apply(
            observation(
                index: 0,
                candidate: candidate(
                    mapID: candidateMapID,
                    frameID: sourceFrameID,
                    evidence: placeEvidence(0.5)
                )
            )
        )
        let before = reducer.snapshot
        XCTAssertThrowsError(
            try reducer.apply(
                observation(
                    index: 1,
                    candidate: candidate(
                        mapID: placeMapID(3),
                        frameID: sourceFrameID,
                        evidence: placeEvidence(0.5)
                    )
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaceMapAssociationError,
                .tooManyCandidates(maximum: 1)
            )
        }
        XCTAssertEqual(reducer.snapshot, before)
    }

    func testExpiredCandidateIsEvictedDeterministicallyToAdmitFreshCandidate() throws {
        let policy = try PlaceAssociationPolicy(
            maximumTrackedCandidates: 1,
            maximumEvidenceSequenceAge: 1
        )
        let freshMapID = placeMapID(3)
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: nil,
                sourceCoordinateFrameID: sourceFrameID
            ),
            policy: policy
        )
        _ = try reducer.apply(
            PlaceAssociationObservation(
                id: placeObservationID(1),
                baseRevision: 0,
                sequence: 1,
                candidates: [
                    candidate(
                        mapID: candidateMapID,
                        frameID: sourceFrameID,
                        evidence: placeEvidence(0.2)
                    )
                ]
            )
        )
        _ = try reducer.apply(
            PlaceAssociationObservation(
                id: placeObservationID(2),
                baseRevision: 1,
                sequence: 3,
                candidates: [
                    candidate(
                        mapID: freshMapID,
                        frameID: sourceFrameID,
                        evidence: placeEvidence(0.2)
                    )
                ]
            )
        )

        XCTAssertNil(reducer.snapshot.candidates[candidateMapID])
        XCTAssertNotNil(reducer.snapshot.candidates[freshMapID])
        XCTAssertEqual(reducer.snapshot.candidates.count, 1)
    }

    func testExpiredCandidateEvictionUsesMapIDAsStableTieBreaker() throws {
        let lowerID = placeMapID(10)
        let higherID = placeMapID(20)
        let freshID = placeMapID(30)
        let policy = try PlaceAssociationPolicy(
            maximumTrackedCandidates: 2,
            maximumEvidenceSequenceAge: 1
        )
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: nil,
                sourceCoordinateFrameID: sourceFrameID
            ),
            policy: policy
        )
        _ = try reducer.apply(
            PlaceAssociationObservation(
                id: placeObservationID(1),
                baseRevision: 0,
                sequence: 1,
                candidates: [
                    candidate(
                        mapID: higherID,
                        frameID: sourceFrameID,
                        evidence: placeEvidence(0.2)
                    ),
                    candidate(
                        mapID: lowerID,
                        frameID: sourceFrameID,
                        evidence: placeEvidence(0.2)
                    ),
                ]
            )
        )
        _ = try reducer.apply(
            PlaceAssociationObservation(
                id: placeObservationID(2),
                baseRevision: 1,
                sequence: 3,
                candidates: [
                    candidate(
                        mapID: freshID,
                        frameID: sourceFrameID,
                        evidence: placeEvidence(0.2)
                    )
                ]
            )
        )

        XCTAssertNil(reducer.snapshot.candidates[lowerID])
        XCTAssertNotNil(reducer.snapshot.candidates[higherID])
        XCTAssertNotNil(reducer.snapshot.candidates[freshID])
    }

    func testReplaySortsEventsDeterministically() throws {
        let context = PlaceAssociationContext(
            sourceMapID: nil,
            sourceCoordinateFrameID: sourceFrameID
        )
        let events = (0..<3).map { index in
            observation(
                index: index,
                sequence: UInt64((index + 1) * 10),
                candidate: candidate(
                    mapID: candidateMapID,
                    frameID: sourceFrameID,
                    evidence: placeEvidence(0.7 + Double(index) / 10)
                )
            )
        }
        let ordered = try PlaceMapAssociationReducer.replay(
            context: context,
            observations: events
        )
        let shuffled = try PlaceMapAssociationReducer.replay(
            context: context,
            observations: [events[2], events[0], events[1]]
        )

        XCTAssertEqual(ordered.snapshot, shuffled.snapshot)
        XCTAssertEqual(ordered.decision(), shuffled.decision())
    }

    func testDuplicateReplayIsIdempotentButIdentifierCollisionFails() throws {
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: nil,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        let original = observation(index: 0, candidates: [])
        _ = try reducer.apply(original)

        let repeated = try reducer.apply(original)
        guard case .alreadyApplied(let revision, _) = repeated else {
            return XCTFail("Exact duplicate must be idempotent")
        }
        XCTAssertEqual(revision, 1)

        let collision = PlaceAssociationObservation(
            id: original.id,
            baseRevision: 1,
            sequence: 2,
            candidates: []
        )
        XCTAssertThrowsError(try reducer.apply(collision)) { error in
            XCTAssertEqual(
                error as? PlaceMapAssociationError,
                .observationIdentifierCollision(original.id)
            )
        }
        XCTAssertEqual(reducer.snapshot.revision, 1)
    }

    func testEmptyRepeatedScansBecomeNewButSingleScanStaysAmbiguous() throws {
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: nil,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        _ = try reducer.apply(observation(index: 0, candidates: []))
        XCTAssertEqual(reducer.decision().outcome, .ambiguous)
        XCTAssertEqual(reducer.decision().reason, .insufficientRepeatedEvidence)

        _ = try reducer.apply(observation(index: 1, candidates: []))
        XCTAssertEqual(reducer.decision().outcome, .new)
        XCTAssertEqual(reducer.decision().confidence, .one)
        XCTAssertEqual(reducer.decision().grade, .high)
    }

    func testCandidateEvaluationExposesHighMediumAndLowGrades() throws {
        let highID = placeMapID(10)
        let mediumID = placeMapID(20)
        let lowID = placeMapID(30)
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: nil,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        _ = try reducer.apply(
            observation(
                index: 0,
                candidates: [
                    candidate(
                        mapID: lowID,
                        frameID: sourceFrameID,
                        evidence: placeEvidence(0.2)
                    ),
                    candidate(
                        mapID: mediumID,
                        frameID: sourceFrameID,
                        evidence: placeEvidence(0.65)
                    ),
                    candidate(
                        mapID: highID,
                        frameID: sourceFrameID,
                        evidence: placeEvidence(0.9)
                    ),
                ]
            )
        )

        let grades = Dictionary(
            uniqueKeysWithValues: reducer.candidateEvaluations().map {
                ($0.mapID, $0.recognition.grade)
            }
        )
        XCTAssertEqual(grades[highID], .high)
        XCTAssertEqual(grades[mediumID], .medium)
        XCTAssertEqual(grades[lowID], .low)
    }

    func testChangedHighConfidenceAlignmentCannotReplaceLatch() throws {
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: sourceMapID,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        _ = try reducer.apply(
            observation(
                index: 0,
                candidate: candidate(
                    mapID: candidateMapID,
                    frameID: candidateFrameID,
                    evidence: placeEvidence(0.9),
                    compatibility: .aligned(
                        sourceToCandidate: .identity,
                        confidence: placeScore(0.9)
                    )
                )
            )
        )
        let before = reducer.snapshot
        let changed = Transform3D.translation(try Vec3(x: 0.1, y: 0, z: 0))

        XCTAssertThrowsError(
            try reducer.apply(
                observation(
                    index: 1,
                    candidate: candidate(
                        mapID: candidateMapID,
                        frameID: candidateFrameID,
                        evidence: placeEvidence(0.9),
                        compatibility: .aligned(
                            sourceToCandidate: changed,
                            confidence: placeScore(0.95)
                        )
                    )
                )
            )
        )
        XCTAssertEqual(reducer.snapshot, before)
    }

    func testSameFrameNonIdentityAlignmentFailsClosed() throws {
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: sourceMapID,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        let nonIdentity = Transform3D.translation(try Vec3(x: 0.01, y: 0, z: 0))

        XCTAssertThrowsError(
            try reducer.apply(
                observation(
                    index: 0,
                    candidate: candidate(
                        mapID: candidateMapID,
                        frameID: sourceFrameID,
                        evidence: placeEvidence(0.9),
                        compatibility: .aligned(
                            sourceToCandidate: nonIdentity,
                            confidence: placeScore(0.95)
                        )
                    )
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaceMapAssociationError,
                .compatibilityConflict(mapID: self.candidateMapID)
            )
        }
        XCTAssertEqual(reducer.snapshot.revision, 0)
    }

    func testRevisionSequenceAndDuplicateCandidateValidation() throws {
        var reducer = PlaceMapAssociationReducer(
            context: PlaceAssociationContext(
                sourceMapID: nil,
                sourceCoordinateFrameID: sourceFrameID
            )
        )
        let item = candidate(
            mapID: candidateMapID,
            frameID: sourceFrameID,
            evidence: placeEvidence(0.6)
        )
        XCTAssertThrowsError(
            try reducer.apply(
                PlaceAssociationObservation(
                    id: placeObservationID(1),
                    baseRevision: 1,
                    sequence: 1,
                    candidates: [item]
                )
            )
        )
        _ = try reducer.apply(observation(index: 0, candidate: item))
        let before = reducer.snapshot

        XCTAssertThrowsError(
            try reducer.apply(
                PlaceAssociationObservation(
                    id: placeObservationID(2),
                    baseRevision: 1,
                    sequence: 1,
                    candidates: [item]
                )
            )
        )
        XCTAssertThrowsError(
            try reducer.apply(
                PlaceAssociationObservation(
                    id: placeObservationID(3),
                    baseRevision: 1,
                    sequence: 2,
                    candidates: [item, item]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaceMapAssociationError,
                .duplicateCandidate(self.candidateMapID)
            )
        }
        XCTAssertEqual(reducer.snapshot, before)
    }

    func testObservationCodableRoundTripPreservesAlignmentEvidence() throws {
        let original = observation(
            index: 0,
            candidate: candidate(
                mapID: candidateMapID,
                frameID: candidateFrameID,
                evidence: placeEvidence(0.8),
                compatibility: .aligned(
                    sourceToCandidate: Transform3D.translation(
                        try Vec3(x: 1, y: 2, z: 3)
                    ),
                    confidence: placeScore(0.9)
                )
            )
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            PlaceAssociationObservation.self,
            from: data
        )
        XCTAssertEqual(decoded, original)
    }

    func testReplayDetectsIdentifierCollisionBeforeSorting() throws {
        let sharedID = placeObservationID(99)
        let first = PlaceAssociationObservation(
            id: sharedID,
            baseRevision: 0,
            sequence: 1,
            candidates: []
        )
        let conflicting = PlaceAssociationObservation(
            id: sharedID,
            baseRevision: 1,
            sequence: 1,
            candidates: [
                candidate(
                    mapID: candidateMapID,
                    frameID: sourceFrameID,
                    evidence: placeEvidence(0.9)
                )
            ]
        )

        for order in [[first, conflicting], [conflicting, first]] {
            XCTAssertThrowsError(
                try PlaceMapAssociationReducer.replay(
                    context: PlaceAssociationContext(
                        sourceMapID: nil,
                        sourceCoordinateFrameID: sourceFrameID
                    ),
                    observations: order
                )
            ) { error in
                XCTAssertEqual(
                    error as? PlaceMapAssociationError,
                    .observationIdentifierCollision(sharedID)
                )
            }
        }
    }

    func testPolicyRejectsUnsafeOrUnboundedConfigurations() {
        XCTAssertThrowsError(
            try PlaceAssociationPolicy(minimumModalitiesForAssociation: 1)
        )
        XCTAssertThrowsError(
            try PlaceAssociationPolicy(
                minimumObservationsForMerge: 9,
                maximumEvidencePerCandidate: 8
            )
        )
        XCTAssertThrowsError(
            try PlaceAssociationPolicy(maximumTrackedCandidates: 0)
        )
        XCTAssertThrowsError(
            try PlaceAssociationPolicy(maximumEvidenceSequenceAge: 0)
        )
        XCTAssertThrowsError(
            try PlaceAssociationPolicy(
                minimumNewPlaceConfidence: placeScore(0.7)
            )
        )
        XCTAssertThrowsError(
            try PlaceAssociationPolicy(maximumRememberedObservations: 0)
        )
    }

    private func observation(
        index: Int,
        sequence: UInt64? = nil,
        candidate: PlaceMapCandidateEvidence
    ) -> PlaceAssociationObservation {
        observation(index: index, sequence: sequence, candidates: [candidate])
    }

    private func observation(
        index: Int,
        sequence: UInt64? = nil,
        candidates: [PlaceMapCandidateEvidence]
    ) -> PlaceAssociationObservation {
        PlaceAssociationObservation(
            id: placeObservationID(index + 1),
            baseRevision: UInt64(index),
            sequence: sequence ?? UInt64(index + 1),
            candidates: candidates
        )
    }

    private func candidate(
        mapID: MapID,
        frameID: CoordinateFrameID,
        evidence: PlaceEvidence,
        compatibility: PlaceCoordinateCompatibilityEvidence = .unresolved
    ) -> PlaceMapCandidateEvidence {
        PlaceMapCandidateEvidence(
            mapID: mapID,
            coordinateFrameID: frameID,
            placeEvidence: evidence,
            coordinateCompatibility: compatibility
        )
    }

    private func placeEvidence(
        _ value: Double,
        overlap: Double? = nil
    ) -> PlaceEvidence {
        let confidence = placeScore(value)
        return PlaceEvidence(
            visual: confidence,
            geometry: confidence,
            structure: confidence,
            poseConsistency: confidence,
            objectLayout: confidence,
            spatialOverlap: placeScore(overlap ?? value)
        )
    }
}

private func placeMapID(_ value: Int) -> MapID {
    MapID(rawValue: placeUUID(value))
}

private func placeFrameID(_ value: Int) -> CoordinateFrameID {
    CoordinateFrameID(rawValue: placeUUID(1_000 + value))
}

private func placeObservationID(_ value: Int) -> ObservationID {
    ObservationID(rawValue: placeUUID(2_000 + value))
}

private func placeUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func placeScore(_ value: Double) -> ConfidenceScore {
    ConfidenceScore(clamping: value)
}
