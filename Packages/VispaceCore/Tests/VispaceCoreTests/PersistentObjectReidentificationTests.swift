import Foundation
import XCTest

@testable import VispaceCore

final class PersistentObjectReidentificationTests: XCTestCase {
    private let map = MapID(rawValue: testUUID(31_001))
    private let frame = CoordinateFrameID(rawValue: testUUID(31_002))
    private let segment = CaptureSegmentID(rawValue: testUUID(31_003))
    private let incomingID = ObjectID(rawValue: testUUID(31_004))

    func testThreeDistinctMappedFramesCanConfirmExistingObject() throws {
        let candidate = try metadata(id: objectID(101), x: 0.03)
        let request = try makeRequest(
            candidateContexts: [try context(for: candidate.object.id)]
        )

        let decision = try PersistentObjectReidentificationResolver().resolve(
            request,
            against: [candidate]
        )

        guard case .confirmedExisting(let match) = decision else {
            return XCTFail("Stable multi-frame evidence should reuse the existing identity.")
        }
        XCTAssertEqual(match.objectID, candidate.object.id)
        XCTAssertGreaterThanOrEqual(
            match.geometryScore,
            ConfidencePolicy.default.highThreshold
        )
        XCTAssertEqual(match.spatialContextScore, .one)
        XCTAssertGreaterThanOrEqual(match.score, ConfidencePolicy.default.highThreshold)
    }

    func testOneObservationCannotBecomePromotionEvidence() throws {
        XCTAssertThrowsError(
            try ObjectReidentificationPromotionEvidence(
                observations: [observation(1, frameNumber: 1, at: 10)]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .tooFewPromotionObservations(minimum: 3)
            )
        }
    }

    func testDistinctObservationIDsFromOneFrameCannotAuthorizeIdentity() throws {
        let repeatedFrame = frameID(1)
        let values = [
            observation(1, frameID: repeatedFrame, at: 10),
            observation(2, frameID: repeatedFrame, at: 10.2),
            observation(3, frameID: repeatedFrame, at: 10.4),
        ]

        XCTAssertThrowsError(
            try ObjectReidentificationPromotionEvidence(observations: values)
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .duplicatePromotionFrameID(repeatedFrame)
            )
        }
    }

    func testDuplicateObservationIDIsRejectedEvenAcrossDistinctFrames() throws {
        let duplicateID = ObservationID(rawValue: testUUID(32_001))
        let values = [
            observation(1, observationID: duplicateID, frameNumber: 1, at: 10),
            observation(2, observationID: duplicateID, frameNumber: 2, at: 10.2),
            observation(3, frameNumber: 3, at: 10.4),
        ]

        XCTAssertThrowsError(
            try ObjectReidentificationPromotionEvidence(observations: values)
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .duplicatePromotionObservationID(duplicateID)
            )
        }
    }

    func testPromotionEvidenceRequiresMapFrameSegmentAndExactSemanticConsistency() throws {
        let otherMap = MapID(rawValue: testUUID(32_010))
        let otherFrame = CoordinateFrameID(rawValue: testUUID(32_011))
        let otherSegment = CaptureSegmentID(rawValue: testUUID(32_012))

        XCTAssertThrowsError(
            try ObjectReidentificationPromotionEvidence(
                observations: [
                    observation(1, frameNumber: 1, at: 10),
                    observation(2, frameNumber: 2, at: 10.2, mapID: otherMap),
                    observation(3, frameNumber: 3, at: 10.4),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .inconsistentPromotionMap
            )
        }

        XCTAssertThrowsError(
            try ObjectReidentificationPromotionEvidence(
                observations: [
                    observation(1, frameNumber: 1, at: 10),
                    observation(
                        2,
                        frameNumber: 2,
                        at: 10.2,
                        coordinateFrameID: otherFrame
                    ),
                    observation(3, frameNumber: 3, at: 10.4),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .inconsistentPromotionCoordinateFrame
            )
        }

        XCTAssertThrowsError(
            try ObjectReidentificationPromotionEvidence(
                observations: [
                    observation(1, frameNumber: 1, at: 10),
                    observation(
                        2,
                        frameNumber: 2,
                        at: 10.2,
                        captureSegmentID: otherSegment
                    ),
                    observation(3, frameNumber: 3, at: 10.4),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .inconsistentPromotionCaptureSegment
            )
        }

        XCTAssertThrowsError(
            try ObjectReidentificationPromotionEvidence(
                observations: [
                    observation(1, frameNumber: 1, at: 10),
                    observation(2, frameNumber: 2, at: 10.2, label: "Sofa"),
                    observation(3, frameNumber: 3, at: 10.4),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .inconsistentPromotionSemanticClass
            )
        }
    }

    func testPromotionEvidenceRejectsUnmappedWeakRapidAndLimitedSamples() throws {
        XCTAssertThrowsError(
            try ObjectReidentificationPromotionEvidence(
                observations: [
                    observation(1, frameNumber: 1, at: 10),
                    observation(2, frameNumber: 2, at: 10.2, mapID: nil),
                    observation(3, frameNumber: 3, at: 10.4),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .promotionObservationIsUnmapped(
                    ObservationID(rawValue: testUUID(33_002))
                )
            )
        }

        XCTAssertThrowsError(
            try ObjectReidentificationPromotionEvidence(
                observations: [
                    observation(1, frameNumber: 1, at: 10),
                    observation(2, frameNumber: 2, at: 10.1),
                    observation(3, frameNumber: 3, at: 10.2),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .insufficientPromotionDuration(minimum: 0.30)
            )
        }

        XCTAssertThrowsError(
            try ObjectReidentificationPromotionEvidence(
                observations: [
                    observation(1, frameNumber: 1, at: 10, semantic: 0.4),
                    observation(2, frameNumber: 2, at: 10.2, semantic: 0.4),
                    observation(3, frameNumber: 3, at: 10.4, semantic: 0.4),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .insufficientPromotionConfidence
            )
        }

        let limitedID = ObservationID(rawValue: testUUID(33_003))
        XCTAssertThrowsError(
            try ObjectReidentificationPromotionEvidence(
                observations: [
                    observation(1, frameNumber: 1, at: 10),
                    observation(2, frameNumber: 2, at: 10.2),
                    observation(
                        3,
                        observationID: limitedID,
                        frameNumber: 3,
                        at: 10.4,
                        tracking: .limited
                    ),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .insufficientPromotionTrackingQuality(limitedID)
            )
        }
    }

    func testPromotionEvidenceIsBounded() throws {
        let values = (0...ObjectReidentificationPromotionEvidence.maximumObservationCount)
            .map { index in
                observation(
                    index + 1,
                    frameNumber: index + 1,
                    at: 10 + Double(index) * 0.2
                )
            }

        XCTAssertThrowsError(
            try ObjectReidentificationPromotionEvidence(observations: values)
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .tooManyPromotionObservations(maximum: 32)
            )
        }
    }

    func testPromotionEvidenceCodableRoundTripAndSchemaValidation() throws {
        let original = try promotionEvidence()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            ObjectReidentificationPromotionEvidence.self,
            from: encoded
        )
        XCTAssertEqual(decoded, original)

        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        json["schemaVersion"] = 999
        let corrupted = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ObjectReidentificationPromotionEvidence.self,
                from: corrupted
            )
        )
    }

    func testRequestMustBindPromotionEvidenceAndHighConfidenceMetadata() throws {
        let evidence = try promotionEvidence()
        let wrongTimes = try metadata(
            id: incomingID,
            x: 0,
            firstSeenAt: 9,
            lastSeenAt: 10.4
        )
        XCTAssertThrowsError(
            try PersistentObjectReidentificationRequest(
                promotedObject: wrongTimes,
                promotionEvidence: evidence,
                incomingContext: try context(for: incomingID)
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .promotionMetadataMismatch
            )
        }

        let lowConfidence = try metadata(
            id: incomingID,
            x: 0,
            confidence: vector(identity: 0.7),
            firstSeenAt: 10,
            lastSeenAt: 10.4
        )
        XCTAssertThrowsError(
            try PersistentObjectReidentificationRequest(
                promotedObject: lowConfidence,
                promotionEvidence: evidence,
                incomingContext: try context(for: incomingID)
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .insufficientPromotedObjectConfidence
            )
        }

        let provisional = try metadata(
            id: incomingID,
            x: 0,
            certainty: .provisional,
            firstSeenAt: 10,
            lastSeenAt: 10.4
        )
        XCTAssertThrowsError(
            try PersistentObjectReidentificationRequest(
                promotedObject: provisional,
                promotionEvidence: evidence,
                incomingContext: try context(for: incomingID)
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .promotedObjectIsNotConfirmed
            )
        }
    }

    func testMissingSpatialContextStaysAmbiguous() throws {
        let candidate = try metadata(id: objectID(201), x: 0.01)
        let request = try makeRequest(candidateContexts: [])

        let decision = try PersistentObjectReidentificationResolver().resolve(
            request,
            against: [candidate]
        )

        guard case .ambiguousCandidates(let candidates) = decision else {
            return XCTFail("Geometry alone must never reuse a permanent identity.")
        }
        XCTAssertEqual(candidates.map(\.objectID), [candidate.object.id])
        XCTAssertNil(candidates[0].spatialContextScore)
    }

    func testConflictingSpatialContextStaysAmbiguousRatherThanGuessing() throws {
        let candidate = try metadata(id: objectID(202), x: 0.01)
        let conflictingFeature = ObjectReidentificationSpatialFeature(
            predicate: .inside,
            reference: .spatialNode(nodeID(99))
        )
        let request = try makeRequest(
            candidateContexts: [
                try context(for: candidate.object.id, features: [conflictingFeature])
            ]
        )

        let decision = try PersistentObjectReidentificationResolver().resolve(
            request,
            against: [candidate]
        )
        guard case .ambiguousCandidates(let candidates) = decision else {
            return XCTFail("A nearby same-class object with conflicting context is unresolved.")
        }
        XCTAssertEqual(candidates[0].spatialContextScore, .zero)
    }

    func testTwoCloseCandidatesInsideMarginAreDeterministicallyAmbiguous() throws {
        let lowerID = try metadata(id: objectID(301), x: 0.02)
        let higherID = try metadata(id: objectID(302), x: 0.02)
        let request = try makeRequest(
            candidateContexts: [
                try context(for: higherID.object.id),
                try context(for: lowerID.object.id),
            ]
        )

        let decision = try PersistentObjectReidentificationResolver().resolve(
            request,
            against: [higherID, lowerID]
        )

        guard case .ambiguousCandidates(let candidates) = decision else {
            return XCTFail("Equal high-confidence candidates must not be guessed.")
        }
        XCTAssertEqual(candidates.map(\.objectID), [lowerID.object.id, higherID.object.id])
    }

    func testOptionalVisualEvidenceCanRankButCannotReplaceMandatorySignals() throws {
        let first = try metadata(id: objectID(401), x: 0.02)
        let second = try metadata(id: objectID(402), x: 0.02)
        let rankedRequest = try makeRequest(
            candidateContexts: [
                try context(for: first.object.id),
                try context(for: second.object.id),
            ],
            visualEvidence: [
                ObjectReidentificationVisualEvidence(
                    objectID: first.object.id,
                    similarity: .one
                ),
                ObjectReidentificationVisualEvidence(
                    objectID: second.object.id,
                    similarity: .zero
                ),
            ]
        )
        let permissiveMargin = try PersistentObjectReidentificationPolicy(
            ambiguityMargin: score(0.05)
        )
        let ranked = try PersistentObjectReidentificationResolver(
            policy: permissiveMargin
        ).resolve(rankedRequest, against: [second, first])
        guard case .confirmedExisting(let match) = ranked else {
            return XCTFail("Optional visual evidence should deterministically break this tie.")
        }
        XCTAssertEqual(match.objectID, first.object.id)

        let noContextRequest = try makeRequest(
            candidateContexts: [],
            visualEvidence: [
                ObjectReidentificationVisualEvidence(
                    objectID: first.object.id,
                    similarity: .one
                )
            ]
        )
        let unresolved = try PersistentObjectReidentificationResolver().resolve(
            noContextRequest,
            against: [first]
        )
        guard case .ambiguousCandidates = unresolved else {
            return XCTFail("Perfect visual similarity cannot replace missing spatial context.")
        }
    }

    func testExactSemanticClassIsRequired() throws {
        let differentCase = try metadata(id: objectID(501), label: "Sofa", x: 0)
        let request = try makeRequest(
            candidateContexts: [try context(for: differentCase.object.id)]
        )

        XCTAssertEqual(
            try PersistentObjectReidentificationResolver().resolve(
                request,
                against: [differentCase]
            ),
            .genuinelyNew
        )
    }

    func testFarSameClassAndRemovedObjectsAreGenuinelyNew() throws {
        let far = try metadata(id: objectID(502), x: 2)
        let removed = try metadata(id: objectID(503), x: 0, presence: .removed)
        let request = try makeRequest(
            candidateContexts: [
                try context(for: far.object.id),
                try context(for: removed.object.id),
            ]
        )

        XCTAssertEqual(
            try PersistentObjectReidentificationResolver().resolve(
                request,
                against: [far, removed]
            ),
            .genuinelyNew
        )
    }

    func testResolverRejectsMapAndCoordinateFrameBoundaryViolations() throws {
        let otherMap = MapID(rawValue: testUUID(34_001))
        let wrongMap = try metadata(id: objectID(601), x: 0, mapID: otherMap)
        let request = try makeRequest()
        XCTAssertThrowsError(
            try PersistentObjectReidentificationResolver().resolve(
                request,
                against: [wrongMap]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .candidateMapMismatch(wrongMap.object.id)
            )
        }

        let otherFrame = CoordinateFrameID(rawValue: testUUID(34_002))
        let wrongFrame = try metadata(
            id: objectID(602),
            x: 0,
            coordinateFrameID: otherFrame
        )
        XCTAssertThrowsError(
            try PersistentObjectReidentificationResolver().resolve(
                request,
                against: [wrongFrame]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .candidateCoordinateFrameMismatch(wrongFrame.object.id)
            )
        }
    }

    func testResolverRejectsDuplicateUnconfirmedAndLowConfidenceCandidates() throws {
        let candidate = try metadata(id: objectID(701), x: 0)
        let request = try makeRequest()
        XCTAssertThrowsError(
            try PersistentObjectReidentificationResolver().resolve(
                request,
                against: [candidate, candidate]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .duplicateExistingObject(candidate.object.id)
            )
        }

        let provisional = try metadata(
            id: objectID(702),
            x: 0,
            certainty: .provisional
        )
        XCTAssertThrowsError(
            try PersistentObjectReidentificationResolver().resolve(
                request,
                against: [provisional]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .candidateIsNotConfirmed(provisional.object.id)
            )
        }

        let low = try metadata(
            id: objectID(703),
            x: 0,
            confidence: vector(geometry: 0.7)
        )
        XCTAssertThrowsError(
            try PersistentObjectReidentificationResolver().resolve(
                request,
                against: [low]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .insufficientCandidateConfidence(low.object.id)
            )
        }
    }

    func testResolverRejectsUnknownCandidateEvidenceAndCandidateOverflow() throws {
        let known = try metadata(id: objectID(801), x: 0)
        let unknownID = objectID(899)
        let unknownContext = try makeRequest(
            candidateContexts: [try context(for: unknownID)]
        )
        XCTAssertThrowsError(
            try PersistentObjectReidentificationResolver().resolve(
                unknownContext,
                against: [known]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .unknownCandidateContext(unknownID)
            )
        }

        let unknownVisual = try makeRequest(
            visualEvidence: [
                ObjectReidentificationVisualEvidence(
                    objectID: unknownID,
                    similarity: .one
                )
            ]
        )
        XCTAssertThrowsError(
            try PersistentObjectReidentificationResolver().resolve(
                unknownVisual,
                against: [known]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .unknownVisualEvidence(unknownID)
            )
        }

        let boundedPolicy = try PersistentObjectReidentificationPolicy(
            maximumCandidateCount: 1
        )
        let second = try metadata(id: objectID(802), x: 0)
        XCTAssertThrowsError(
            try PersistentObjectReidentificationResolver(policy: boundedPolicy).resolve(
                try makeRequest(),
                against: [known, second]
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .tooManyExistingObjects(maximum: 1)
            )
        }
    }

    func testSpatialContextRejectsDuplicatesSelfReferencesAndOverflow() throws {
        let feature = ObjectReidentificationSpatialFeature(
            predicate: .near,
            reference: .object(objectID(901))
        )
        XCTAssertThrowsError(
            try context(for: incomingID, features: [feature, feature])
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .duplicateSpatialContextFeature
            )
        }

        let selfFeature = ObjectReidentificationSpatialFeature(
            predicate: .near,
            reference: .object(incomingID)
        )
        XCTAssertThrowsError(
            try context(for: incomingID, features: [selfFeature])
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .selfReferentialSpatialContext
            )
        }

        let tooMany = (0...ObjectReidentificationSpatialContext.maximumFeatureCount)
            .map { index in
                ObjectReidentificationSpatialFeature(
                    predicate: .near,
                    reference: .object(objectID(10_000 + index))
                )
            }
        XCTAssertThrowsError(
            try context(for: incomingID, features: tooMany)
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .tooManySpatialContextFeatures(maximum: 64)
            )
        }
    }

    func testRequestRejectsDuplicateAndCrossFrameEvidence() throws {
        let candidateID = objectID(1_001)
        let duplicate = try context(for: candidateID)
        XCTAssertThrowsError(
            try makeRequest(candidateContexts: [duplicate, duplicate])
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .duplicateCandidateContext(candidateID)
            )
        }

        let visual = ObjectReidentificationVisualEvidence(
            objectID: candidateID,
            similarity: .one
        )
        XCTAssertThrowsError(
            try makeRequest(visualEvidence: [visual, visual])
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .duplicateVisualEvidence(candidateID)
            )
        }

        let otherFrame = CoordinateFrameID(rawValue: testUUID(35_001))
        let crossFrame = try context(for: candidateID, coordinateFrameID: otherFrame)
        XCTAssertThrowsError(
            try makeRequest(candidateContexts: [crossFrame])
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .contextProvenanceMismatch(candidateID)
            )
        }
    }

    func testPolicyAndCandidateEvaluationCodableValidation() throws {
        XCTAssertThrowsError(
            try PersistentObjectReidentificationPolicy(
                minimumConfirmationGeometryScore: score(0.7)
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentObjectReidentificationError,
                .invalidPolicy
            )
        }
        XCTAssertThrowsError(
            try PersistentObjectReidentificationPolicy(
                geometryWeight: 0,
                spatialContextWeight: 0
            )
        )
        XCTAssertThrowsError(
            try PersistentObjectReidentificationPolicy(
                geometryWeight: .greatestFiniteMagnitude,
                spatialContextWeight: .greatestFiniteMagnitude
            )
        )

        let policyData = try JSONEncoder().encode(
            PersistentObjectReidentificationPolicy.default
        )
        var policyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: policyData) as? [String: Any]
        )
        policyJSON["maximumPositionDistance"] = -1
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                PersistentObjectReidentificationPolicy.self,
                from: JSONSerialization.data(withJSONObject: policyJSON)
            )
        )

        let evaluation = try PersistentObjectReidentificationCandidate(
            objectID: objectID(1_101),
            score: .one,
            geometryScore: .one,
            spatialContextScore: .one,
            visualSimilarity: nil,
            positionDistance: 0
        )
        var evaluationJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(evaluation)
            ) as? [String: Any]
        )
        evaluationJSON["positionDistance"] = -1
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                PersistentObjectReidentificationCandidate.self,
                from: JSONSerialization.data(withJSONObject: evaluationJSON)
            )
        )
    }

    func testRequestAndDecisionCodableRoundTrip() throws {
        let candidate = try metadata(id: objectID(1_201), x: 0.03)
        let request = try makeRequest(
            candidateContexts: [try context(for: candidate.object.id)],
            visualEvidence: [
                ObjectReidentificationVisualEvidence(
                    objectID: candidate.object.id,
                    similarity: score(0.9)
                )
            ]
        )
        let restoredRequest = try JSONDecoder().decode(
            PersistentObjectReidentificationRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(restoredRequest, request)

        let decision = try PersistentObjectReidentificationResolver().resolve(
            restoredRequest,
            against: [candidate]
        )
        let restoredDecision = try JSONDecoder().decode(
            PersistentObjectReidentificationDecision.self,
            from: JSONEncoder().encode(decision)
        )
        XCTAssertEqual(restoredDecision, decision)
    }

    private func makeRequest(
        candidateContexts: [ObjectReidentificationSpatialContext] = [],
        visualEvidence: [ObjectReidentificationVisualEvidence] = []
    ) throws -> PersistentObjectReidentificationRequest {
        try PersistentObjectReidentificationRequest(
            promotedObject: metadata(
                id: incomingID,
                x: 0,
                firstSeenAt: 10,
                lastSeenAt: 10.4
            ),
            promotionEvidence: promotionEvidence(),
            incomingContext: context(for: incomingID),
            candidateContexts: candidateContexts,
            visualEvidence: visualEvidence
        )
    }

    private func promotionEvidence() throws -> ObjectReidentificationPromotionEvidence {
        try ObjectReidentificationPromotionEvidence(
            observations: [
                observation(1, frameNumber: 1, at: 10),
                observation(2, frameNumber: 2, at: 10.2),
                observation(3, frameNumber: 3, at: 10.4),
            ]
        )
    }

    private func observation(
        _ number: Int,
        observationID customObservationID: ObservationID? = nil,
        frameNumber: Int,
        at timestamp: TimeInterval,
        mapID customMapID: MapID? = .some(MapID(rawValue: testUUID(31_001))),
        coordinateFrameID customFrameID: CoordinateFrameID? = nil,
        captureSegmentID customSegmentID: CaptureSegmentID? = nil,
        label: String = "소파",
        semantic: Double = 0.9,
        geometry: Double = 0.9,
        tracking: SpatialTrackingQuality = .normal
    ) -> ObjectPromotionObservation {
        observation(
            number,
            observationID: customObservationID,
            frameID: VispaceCore.FrameID(rawValue: testUUID(32_100 + frameNumber)),
            at: timestamp,
            mapID: customMapID,
            coordinateFrameID: customFrameID,
            captureSegmentID: customSegmentID,
            label: label,
            semantic: semantic,
            geometry: geometry,
            tracking: tracking
        )
    }

    private func observation(
        _ number: Int,
        observationID customObservationID: ObservationID? = nil,
        frameID: FrameID,
        at timestamp: TimeInterval,
        mapID customMapID: MapID? = .some(MapID(rawValue: testUUID(31_001))),
        coordinateFrameID customFrameID: CoordinateFrameID? = nil,
        captureSegmentID customSegmentID: CaptureSegmentID? = nil,
        label: String = "소파",
        semantic: Double = 0.9,
        geometry: Double = 0.9,
        tracking: SpatialTrackingQuality = .normal
    ) -> ObjectPromotionObservation {
        let resolvedFrameID = customFrameID ?? frame
        return try! ObjectPromotionObservation(
            observationID: customObservationID
                ?? ObservationID(rawValue: testUUID(33_000 + number)),
            frameID: frameID,
            semanticLabel: label,
            coordinateFrameID: resolvedFrameID,
            captureSegmentID: customSegmentID ?? segment,
            mapID: customMapID,
            boundingBox: try! NormalizedBoundingBox2D(
                x: 0.4,
                y: 0.4,
                width: 0.2,
                height: 0.2
            ),
            position: try! FramedPosition(
                coordinateFrameID: resolvedFrameID,
                value: .zero,
                observedAt: timestamp,
                trackingQuality: tracking,
                uncertainty: .highConfidenceDepth
            ),
            semanticConfidence: score(semantic),
            geometryConfidence: score(geometry)
        )
    }

    private func metadata(
        id: ObjectID,
        label: String = "소파",
        x: Double,
        mapID customMapID: MapID? = nil,
        coordinateFrameID customFrameID: CoordinateFrameID? = nil,
        certainty: ObjectCertainty = .confirmed,
        presence: ObjectPresence = .visible,
        confidence: ConfidenceVector = vector(),
        firstSeenAt: TimeInterval = 1,
        lastSeenAt: TimeInterval = 2,
        bounds: AABB? = nil
    ) throws -> SpatialObjectMetadata {
        let resolvedMap = customMapID ?? map
        let resolvedFrame = customFrameID ?? frame
        let position = vec(x)
        return try SpatialObjectMetadata(
            mapID: resolvedMap,
            object: SpatialObject(
                id: id,
                semanticLabel: label,
                position: position,
                bounds: bounds,
                certainty: certainty,
                presence: presence,
                confidence: confidence,
                firstSeenAt: firstSeenAt,
                lastSeenAt: lastSeenAt
            ),
            position: FramedPosition(
                coordinateFrameID: resolvedFrame,
                value: position,
                observedAt: lastSeenAt,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            )
        )
    }

    private func context(
        for objectID: ObjectID,
        coordinateFrameID customFrameID: CoordinateFrameID? = nil,
        features: [ObjectReidentificationSpatialFeature]? = nil
    ) throws -> ObjectReidentificationSpatialContext {
        try ObjectReidentificationSpatialContext(
            objectID: objectID,
            mapID: map,
            coordinateFrameID: customFrameID ?? frame,
            features: features ?? defaultFeatures
        )
    }

    private var defaultFeatures: [ObjectReidentificationSpatialFeature] {
        [
            ObjectReidentificationSpatialFeature(
                predicate: .inside,
                reference: .spatialNode(nodeID(31_100))
            ),
            ObjectReidentificationSpatialFeature(
                predicate: .near,
                reference: .object(objectID(31_101))
            ),
        ]
    }
}
