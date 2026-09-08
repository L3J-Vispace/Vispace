import Foundation
import XCTest

@testable import VispaceCore

final class ObjectObservationPromotionTests: XCTestCase {
    private let coordinateFrameID = CoordinateFrameID(rawValue: testUUID(8_001))
    private let captureSegmentID = CaptureSegmentID(rawValue: testUUID(8_002))
    private let mapID = MapID(rawValue: testUUID(8_003))

    func testPromotedTransientCandidateFollowsSustainedMotionBeyondRollingWindow() throws {
        var promoter = ObjectObservationPromoter()
        var original: SpatialObjectMetadata?
        for index in 0..<48 {
            let outcome = try promoter.ingest(
                observation(
                    index + 1, frame: index + 1,
                    at: Double(index) * 0.2, x: Double(max(index - 2, 0)) * 0.10, mapID: mapID))
            if index == 2 {
                guard case .promoted(let metadata) = outcome else {
                    return XCTFail("Initial stable evidence must promote")
                }
                original = metadata
            } else if index > 2 {
                guard case .alreadyPromoted(let metadata) = outcome else {
                    return XCTFail("Sustained motion split the transient candidate at frame \(index + 1)")
                }
                XCTAssertEqual(
                    metadata, original,
                    "Transient association must not update durable metadata or confer identity authority")
                XCTAssertEqual(promoter.candidateCount, 1)
            }
        }
        let evidence = try XCTUnwrap(promoter.promotionEvidence(for: XCTUnwrap(original).object.id))
        XCTAssertEqual(evidence.count, 32)
        XCTAssertEqual(evidence.last?.position.value.x, 4.5)
        XCTAssertGreaterThan(try XCTUnwrap(evidence.first).position.observedAt, 0.4)
    }

    func testSingleObservationRemainsIDFreePendingEvidence() throws {
        var promoter = ObjectObservationPromoter()

        let outcome = try promoter.ingest(
            observation(1, frame: 1, at: 0, x: 0, mapID: mapID)
        )

        guard case .pending(let progress) = outcome else {
            return XCTFail("One frame must never create a permanent object.")
        }
        XCTAssertEqual(progress.candidateID, observationID(1))
        XCTAssertEqual(progress.distinctFrameCount, 1)
        XCTAssertEqual(progress.temporallyQualifiedFrameCount, 1)
        XCTAssertEqual(promoter.candidateCount, 1)
    }

    func testDuplicateFrameDoesNotCountTowardPromotion() throws {
        var promoter = ObjectObservationPromoter()
        let firstFrame = frameID(1)
        _ = try promoter.ingest(
            observation(
                1,
                frameID: firstFrame,
                at: 0,
                x: 0,
                mapID: mapID
            )
        )

        let duplicate = try promoter.ingest(
            observation(
                2,
                frameID: firstFrame,
                at: 0.2,
                x: 0.01,
                mapID: mapID
            )
        )
        guard case .ignoredDuplicateFrame(let duplicateProgress) = duplicate else {
            return XCTFail("A second observation from one frame must be ignored.")
        }
        XCTAssertEqual(duplicateProgress.distinctFrameCount, 1)

        let secondFrame = try promoter.ingest(
            observation(3, frame: 2, at: 0.4, x: 0.01, mapID: mapID)
        )
        guard case .pending(let progress) = secondFrame else {
            return XCTFail("Two distinct frames must still be provisional.")
        }
        XCTAssertEqual(progress.distinctFrameCount, 2)

        guard
            case .promoted = try promoter.ingest(
                observation(4, frame: 3, at: 0.8, x: 0, mapID: mapID)
            )
        else {
            return XCTFail("The third distinct, spaced frame should promote.")
        }
    }

    func testNilMapObservationsDoNotPromoteUntilTwoShareAMap() throws {
        var promoter = ObjectObservationPromoter()
        var lastOutcome: ObjectObservationPromotionOutcome?
        for index in 0..<3 {
            lastOutcome = try promoter.ingest(
                observation(
                    index + 1,
                    frame: index + 1,
                    at: Double(index) * 0.2,
                    x: 0,
                    mapID: nil
                )
            )
        }

        guard let lastOutcome, case .pending(let unmappedProgress) = lastOutcome else {
            return XCTFail("Unmapped evidence must stay provisional.")
        }
        XCTAssertEqual(unmappedProgress.mappedObservationCount, 0)

        guard
            case .pending(let oneMappedProgress) = try promoter.ingest(
                observation(4, frame: 4, at: 0.6, x: 0, mapID: mapID)
            )
        else {
            return XCTFail("One mapped observation is insufficient.")
        }
        XCTAssertEqual(oneMappedProgress.mappedObservationCount, 1)

        guard
            case .promoted(let metadata) = try promoter.ingest(
                observation(5, frame: 5, at: 0.8, x: 0, mapID: mapID)
            )
        else {
            return XCTFail("Two observations on one map should satisfy map provenance.")
        }
        XCTAssertEqual(metadata.mapID, mapID)
    }

    func testPromotionCarriesConservativeUnionOfObservedBounds() throws {
        let firstBounds = try AABB(
            min: Vec3(x: -0.4, y: -0.2, z: -0.3),
            max: Vec3(x: 0.3, y: 0.5, z: 0.4)
        )
        let secondBounds = try AABB(
            min: Vec3(x: -0.3, y: -0.25, z: -0.4),
            max: Vec3(x: 0.45, y: 0.55, z: 0.3)
        )
        var promoter = ObjectObservationPromoter()
        _ = try promoter.ingest(
            observation(1, frame: 1, at: 0, x: 0, mapID: mapID, bounds: firstBounds)
        )
        _ = try promoter.ingest(
            observation(2, frame: 2, at: 0.2, x: 0, mapID: mapID, bounds: secondBounds)
        )

        guard
            case .promoted(let metadata) = try promoter.ingest(
                observation(3, frame: 3, at: 0.4, x: 0, mapID: mapID, bounds: firstBounds)
            )
        else {
            return XCTFail("Expected bounded observations to promote.")
        }

        XCTAssertEqual(
            metadata.object.bounds,
            try AABB(
                min: Vec3(x: -0.4, y: -0.25, z: -0.4),
                max: Vec3(x: 0.45, y: 0.55, z: 0.4)
            )
        )
    }

    func testPositionJitterAboveVarianceLimitStaysPending() throws {
        let policy = makePolicy(
            maximumAssociationDistance3D: 0.5,
            maximumMeanSquaredPositionDeviation: 0.005
        )
        var promoter = ObjectObservationPromoter(policy: policy)
        _ = try promoter.ingest(
            observation(1, frame: 1, at: 0, x: -0.2, mapID: mapID)
        )
        _ = try promoter.ingest(
            observation(2, frame: 2, at: 0.2, x: 0.2, mapID: mapID)
        )

        let outcome = try promoter.ingest(
            observation(3, frame: 3, at: 0.4, x: -0.2, mapID: mapID)
        )

        guard case .pending(let progress) = outcome else {
            return XCTFail("Spatially unstable evidence must not promote.")
        }
        XCTAssertGreaterThan(
            progress.meanSquaredPositionDeviation,
            policy.maximumMeanSquaredPositionDeviation
        )
    }

    func testSameLabelFarObjectsFormSeparatePermanentIdentities() throws {
        var promoter = ObjectObservationPromoter(
            policy: makePolicy(maximumAssociationDistance3D: 0.5)
        )
        _ = try promoter.ingest(
            observation(1, frame: 1, at: 0, x: 0, boxX: 0.1, mapID: mapID)
        )
        _ = try promoter.ingest(
            observation(2, frame: 2, at: 0.01, x: 2, boxX: 0.7, mapID: mapID)
        )
        _ = try promoter.ingest(
            observation(3, frame: 3, at: 0.2, x: 0.01, boxX: 0.1, mapID: mapID)
        )
        _ = try promoter.ingest(
            observation(4, frame: 4, at: 0.21, x: 2.01, boxX: 0.7, mapID: mapID)
        )

        guard
            case .promoted(let first) = try promoter.ingest(
                observation(5, frame: 5, at: 0.4, x: 0, boxX: 0.1, mapID: mapID)
            )
        else {
            return XCTFail("The first physical object should promote independently.")
        }
        guard
            case .promoted(let second) = try promoter.ingest(
                observation(6, frame: 6, at: 0.41, x: 2, boxX: 0.7, mapID: mapID)
            )
        else {
            return XCTFail("The distant object should promote independently.")
        }

        XCTAssertEqual(promoter.candidateCount, 2)
        XCTAssertNotEqual(first.object.id, second.object.id)
        XCTAssertEqual(first.object.semanticLabel, second.object.semanticLabel)
        XCTAssertLessThan(first.position.value.distance(to: second.position.value), 2.1)
        XCTAssertGreaterThan(first.position.value.distance(to: second.position.value), 1.9)
    }

    func testEquallyPlausibleAssociationIsAmbiguousAndDoesNotMutateCandidates() throws {
        let policy = makePolicy(
            maximumAssociationDistance3D: 0.5,
            maximumBoundingBoxCenterDistance: 0.4,
            minimumAssociationScore: score(0.3),
            minimumAssociationScoreMargin: 0.05
        )
        var promoter = ObjectObservationPromoter(policy: policy)
        _ = try promoter.ingest(
            observation(1, frame: 1, at: 0, x: -0.3, boxX: 0.1, mapID: mapID)
        )
        _ = try promoter.ingest(
            observation(2, frame: 2, at: 0.01, x: 0.3, boxX: 0.7, mapID: mapID)
        )

        let ambiguousObservation = observation(
            3,
            frame: 3,
            at: 0.2,
            x: 0,
            boxX: 0.4,
            mapID: mapID
        )
        let outcome = try promoter.ingest(ambiguousObservation)

        guard case .ambiguous(let candidateIDs) = outcome else {
            return XCTFail("An equal association score must not be guessed.")
        }
        XCTAssertEqual(candidateIDs, [observationID(1), observationID(2)])
        XCTAssertEqual(promoter.candidateCount, 2)

        guard
            case .pending(let firstCandidateProgress) = try promoter.ingest(
                observation(4, frame: 4, at: 0.4, x: -0.3, boxX: 0.1, mapID: mapID)
            )
        else {
            return XCTFail("Ambiguous evidence must not advance either candidate.")
        }
        XCTAssertEqual(firstCandidateProgress.distinctFrameCount, 2)

        XCTAssertEqual(
            try promoter.ingest(ambiguousObservation),
            .ignoredDuplicateObservation(observationID(3))
        )
    }

    func testRapidDistinctFramesNeedTemporalSpacingAndDuration() throws {
        var promoter = ObjectObservationPromoter(
            policy: makePolicy(
                minimumObservationInterval: 0.1,
                minimumObservationDuration: 0.3
            )
        )
        _ = try promoter.ingest(
            observation(1, frame: 1, at: 0, x: 0, mapID: mapID)
        )
        _ = try promoter.ingest(
            observation(2, frame: 2, at: 0.05, x: 0, mapID: mapID)
        )
        let rapid = try promoter.ingest(
            observation(3, frame: 3, at: 0.1, x: 0, mapID: mapID)
        )

        guard case .pending(let progress) = rapid else {
            return XCTFail("High-rate frames alone must not promote.")
        }
        XCTAssertEqual(progress.distinctFrameCount, 3)
        XCTAssertEqual(progress.temporallyQualifiedFrameCount, 2)

        guard
            case .promoted = try promoter.ingest(
                observation(4, frame: 4, at: 0.31, x: 0, mapID: mapID)
            )
        else {
            return XCTFail("Spaced observations spanning the duration should promote.")
        }
    }

    func testWeakAverageSemanticConfidenceBlocksPromotion() throws {
        let policy = makePolicy(
            minimumAverageSemanticConfidence: score(0.8)
        )
        var promoter = ObjectObservationPromoter(policy: policy)
        _ = try promoter.ingest(
            observation(
                1,
                frame: 1,
                at: 0,
                x: 0,
                mapID: mapID,
                semanticConfidence: 0.9
            )
        )
        _ = try promoter.ingest(
            observation(
                2,
                frame: 2,
                at: 0.2,
                x: 0,
                mapID: mapID,
                semanticConfidence: 0.9
            )
        )
        let outcome = try promoter.ingest(
            observation(
                3,
                frame: 3,
                at: 0.4,
                x: 0,
                mapID: mapID,
                semanticConfidence: 0.4
            )
        )

        guard case .pending(let progress) = outcome else {
            return XCTFail("Weak average semantic evidence must stay provisional.")
        }
        XCTAssertLessThan(
            progress.averageSemanticConfidence,
            policy.minimumAverageSemanticConfidence
        )
    }

    func testPromotedCandidateReusesItsPermanentObjectID() throws {
        var promoter = ObjectObservationPromoter()
        _ = try promoter.ingest(
            observation(1, frame: 1, at: 0, x: 0, mapID: mapID)
        )
        _ = try promoter.ingest(
            observation(2, frame: 2, at: 0.2, x: 0, mapID: mapID)
        )
        guard
            case .promoted(let promoted) = try promoter.ingest(
                observation(3, frame: 3, at: 0.4, x: 0, mapID: mapID)
            )
        else {
            return XCTFail("Expected initial promotion.")
        }

        guard
            case .alreadyPromoted(let existing) = try promoter.ingest(
                observation(4, frame: 4, at: 0.6, x: 0, mapID: mapID)
            )
        else {
            return XCTFail("Later matches must reuse the promoted identity.")
        }
        XCTAssertEqual(existing.object.id, promoted.object.id)
    }

    func testPromotionEvidenceIsExposedOnlyAfterPromotion() throws {
        var promoter = ObjectObservationPromoter()
        let first = observation(1, frame: 1, at: 0, x: 0, mapID: mapID)
        _ = try promoter.ingest(first)

        XCTAssertNil(promoter.promotionEvidence(for: ObjectID()))

        let second = observation(2, frame: 2, at: 0.2, x: 0, mapID: mapID)
        let third = observation(3, frame: 3, at: 0.4, x: 0, mapID: mapID)
        _ = try promoter.ingest(second)
        guard case .promoted(let metadata) = try promoter.ingest(third) else {
            return XCTFail("Expected promotion.")
        }

        XCTAssertEqual(
            promoter.promotionEvidence(for: metadata.object.id),
            [first, second, third]
        )
    }

    func testDefaultPromotionProducesReducerAcceptableConfirmedObject() throws {
        var promoter = ObjectObservationPromoter()
        _ = try promoter.ingest(
            observation(1, frame: 1, at: 0, x: 0, mapID: mapID)
        )
        _ = try promoter.ingest(
            observation(2, frame: 2, at: 0.2, x: 0.01, mapID: mapID)
        )
        guard
            case .promoted(let metadata) = try promoter.ingest(
                observation(3, frame: 3, at: 0.4, x: 0, mapID: mapID)
            )
        else {
            return XCTFail("Expected stable default evidence to promote.")
        }

        let confidencePolicy = ConfidencePolicy.default
        XCTAssertEqual(
            confidencePolicy.grade(for: metadata.object.confidence.identity),
            .high
        )
        XCTAssertEqual(
            confidencePolicy.grade(for: metadata.object.confidence.objectState),
            .high
        )
        XCTAssertEqual(metadata.object.lastSeenAt, metadata.position.observedAt)

        var reducer = SpatialDeltaReducer()
        XCTAssertNoThrow(
            try reducer.apply(
                SpatialDelta(baseRevision: 0, events: [.upsert(metadata.object)])
            )
        )
        XCTAssertEqual(
            reducer.snapshot.confirmedObjects[metadata.object.id],
            metadata.object
        )
    }

    func testCandidateCountAndAgePruningAreDeterministic() throws {
        let policy = makePolicy(
            maximumAssociationDistance3D: 0.1,
            maximumCandidateAge: 0.5,
            maximumCandidateCount: 2,
            maximumObservationsPerCandidate: 3
        )
        var promoter = ObjectObservationPromoter(policy: policy)
        _ = try promoter.ingest(
            observation(1, frame: 1, at: 0, x: 0, mapID: mapID)
        )
        _ = try promoter.ingest(
            observation(2, frame: 2, at: 0, x: 1, mapID: mapID)
        )
        _ = try promoter.ingest(
            observation(3, frame: 3, at: 0, x: 2, mapID: mapID)
        )

        XCTAssertEqual(promoter.candidateCount, 2)
        XCTAssertEqual(promoter.candidateIDs, [observationID(2), observationID(3)])

        _ = try promoter.ingest(
            observation(4, frame: 4, at: 0.6, x: 3, mapID: mapID)
        )
        XCTAssertEqual(promoter.candidateCount, 1)
        XCTAssertEqual(promoter.candidateIDs, [observationID(4)])
    }

    func testObservationHistoryIsCappedDeterministically() throws {
        let policy = makePolicy(
            maximumObservationsPerCandidate: 3
        )
        var promoter = ObjectObservationPromoter(policy: policy)
        var outcome: ObjectObservationPromotionOutcome?
        for index in 0..<4 {
            outcome = try promoter.ingest(
                observation(
                    index + 1,
                    frame: index + 1,
                    at: Double(index) * 0.2,
                    x: 0,
                    mapID: mapID,
                    semanticConfidence: 0.2
                )
            )
        }

        guard let outcome, case .pending(let progress) = outcome else {
            return XCTFail("Low-confidence evidence must remain bounded and pending.")
        }
        XCTAssertEqual(progress.distinctFrameCount, 3)
        XCTAssertEqual(progress.observationDuration, 0.4, accuracy: 0.000_001)
    }

    func testSameMapCannotBeRegisteredUnderAnotherCoordinateFrame() throws {
        var promoter = ObjectObservationPromoter()
        _ = try promoter.ingest(
            observation(1, frame: 1, at: 0, x: 0, mapID: mapID)
        )
        let conflictingFrameID = CoordinateFrameID(rawValue: testUUID(8_099))

        XCTAssertThrowsError(
            try promoter.ingest(
                observation(
                    2,
                    frame: 2,
                    at: 0.2,
                    x: 0,
                    mapID: mapID,
                    coordinateFrameID: conflictingFrameID
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ObjectObservationPromotionError,
                .mapCoordinateFrameMismatch
            )
        }
        XCTAssertEqual(promoter.candidateIDs, [observationID(1)])
    }

    func testWeakSoleAssociationStartsAnotherCandidate() throws {
        let policy = makePolicy(
            maximumAssociationDistance3D: 1,
            maximumBoundingBoxCenterDistance: 1,
            minimumAssociationScore: score(0.9)
        )
        var promoter = ObjectObservationPromoter(policy: policy)
        _ = try promoter.ingest(
            observation(1, frame: 1, at: 0, x: 0, boxX: 0.1, mapID: mapID)
        )
        _ = try promoter.ingest(
            observation(2, frame: 2, at: 0.2, x: 0.8, boxX: 0.7, mapID: mapID)
        )

        XCTAssertEqual(promoter.candidateCount, 2)
        XCTAssertEqual(promoter.candidateIDs, [observationID(1), observationID(2)])
    }

    func testDifferentMappedScopesDoNotMergeOneCandidate() throws {
        let secondMapID = MapID(rawValue: testUUID(8_004))
        var promoter = ObjectObservationPromoter()
        _ = try promoter.ingest(
            observation(1, frame: 1, at: 0, x: 0, mapID: mapID)
        )
        _ = try promoter.ingest(
            observation(2, frame: 2, at: 0.2, x: 0, mapID: secondMapID)
        )

        XCTAssertEqual(promoter.candidateCount, 2)
    }

    func testCodableRoundTripPreservesProvisionalEvidence() throws {
        var original = ObjectObservationPromoter()
        _ = try original.ingest(
            observation(1, frame: 1, at: 0, x: 0, mapID: mapID)
        )
        _ = try original.ingest(
            observation(2, frame: 2, at: 0.2, x: 0, mapID: mapID)
        )

        let data = try JSONEncoder().encode(original)
        var restored = try JSONDecoder().decode(
            ObjectObservationPromoter.self,
            from: data
        )

        guard
            case .promoted = try restored.ingest(
                observation(3, frame: 3, at: 0.4, x: 0, mapID: mapID)
            )
        else {
            return XCTFail("Decoded provisional evidence must remain usable.")
        }
    }

    func testCodableRejectsUnknownStateSchema() throws {
        let data = try JSONEncoder().encode(ObjectObservationPromoter())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["schemaVersion"] = 999
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(ObjectObservationPromoter.self, from: corrupted)
        )
    }

    private func observation(
        _ observationNumber: Int,
        frame frameNumber: Int,
        at timestamp: TimeInterval,
        x: Double,
        boxX: Double = 0.4,
        mapID: MapID?,
        semanticConfidence: Double = 0.9,
        geometryConfidence: Double = 0.9,
        coordinateFrameID customCoordinateFrameID: CoordinateFrameID? = nil,
        bounds: AABB? = nil
    ) -> ObjectPromotionObservation {
        observation(
            observationNumber,
            frameID: frameID(frameNumber),
            at: timestamp,
            x: x,
            boxX: boxX,
            mapID: mapID,
            semanticConfidence: semanticConfidence,
            geometryConfidence: geometryConfidence,
            coordinateFrameID: customCoordinateFrameID,
            bounds: bounds
        )
    }

    private func observation(
        _ observationNumber: Int,
        frameID: FrameID,
        at timestamp: TimeInterval,
        x: Double,
        boxX: Double = 0.4,
        mapID: MapID?,
        semanticConfidence: Double = 0.9,
        geometryConfidence: Double = 0.9,
        coordinateFrameID customCoordinateFrameID: CoordinateFrameID? = nil,
        bounds: AABB? = nil
    ) -> ObjectPromotionObservation {
        let resolvedCoordinateFrameID = customCoordinateFrameID ?? coordinateFrameID
        return try! ObjectPromotionObservation(
            observationID: observationID(observationNumber),
            frameID: frameID,
            semanticLabel: "소파",
            coordinateFrameID: resolvedCoordinateFrameID,
            captureSegmentID: captureSegmentID,
            mapID: mapID,
            boundingBox: try! NormalizedBoundingBox2D(
                x: boxX,
                y: 0.4,
                width: 0.2,
                height: 0.2
            ),
            position: try! FramedPosition(
                coordinateFrameID: resolvedCoordinateFrameID,
                value: vec(x),
                observedAt: timestamp,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            ),
            bounds: bounds,
            semanticConfidence: score(semanticConfidence),
            geometryConfidence: score(geometryConfidence)
        )
    }

    private func observationID(_ value: Int) -> ObservationID {
        ObservationID(rawValue: testUUID(9_000 + value))
    }

    private func makePolicy(
        minimumObservationInterval: TimeInterval = 0.1,
        minimumObservationDuration: TimeInterval = 0.3,
        maximumAssociationDistance3D: Double = 0.35,
        maximumBoundingBoxCenterDistance: Double = 0.18,
        maximumMeanSquaredPositionDeviation: Double = 0.01,
        minimumAverageSemanticConfidence: ConfidenceScore = score(0.8),
        minimumAssociationScore: ConfidenceScore = score(0.5),
        minimumAssociationScoreMargin: Double = 0.08,
        maximumCandidateAge: TimeInterval = 5,
        maximumCandidateCount: Int = 64,
        maximumObservationsPerCandidate: Int = 32
    ) -> ObjectObservationPromotionPolicy {
        try! ObjectObservationPromotionPolicy(
            minimumObservationInterval: minimumObservationInterval,
            minimumObservationDuration: minimumObservationDuration,
            maximumAssociationDistance3D: maximumAssociationDistance3D,
            minimumAssociationScore: minimumAssociationScore,
            maximumBoundingBoxCenterDistance: maximumBoundingBoxCenterDistance,
            maximumMeanSquaredPositionDeviation: maximumMeanSquaredPositionDeviation,
            minimumAverageSemanticConfidence: minimumAverageSemanticConfidence,
            minimumAssociationScoreMargin: minimumAssociationScoreMargin,
            maximumCandidateAge: maximumCandidateAge,
            maximumCandidateCount: maximumCandidateCount,
            maximumObservationsPerCandidate: maximumObservationsPerCandidate
        )
    }
}
