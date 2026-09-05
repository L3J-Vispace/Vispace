import XCTest

@testable import VispaceCore

final class TemporalSpatialMemoryTests: XCTestCase {
    private let map = MapID(rawValue: testUUID(81_001))
    private let frame = CoordinateFrameID(rawValue: testUUID(81_002))

    func testRepeatedMissesAdvanceLifecycleAndPreserveLastSeenLocationAndTime() throws {
        let id = objectID(81_101)
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(
            update(
                revision: 0,
                sequence: 1,
                at: 1,
                observations: [newObservation(id: id, at: 1, position: vec(4))]
            )
        )

        let firstMiss = try applied(
            coordinator.apply(
                update(revision: 1, sequence: 2, at: 2, expected: [id])
            )
        )
        XCTAssertTrue(firstMiss.changes.isEmpty)
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.presence, .visible)

        let notVisible = try applied(
            coordinator.apply(
                update(revision: 2, sequence: 3, at: 3, expected: [id])
            )
        )
        XCTAssertTrue(
            notVisible.changes.contains { change in
                guard
                    case .missing(
                        let objectID,
                        let lastSeenPosition,
                        let lastSeenAt,
                        let detectedAt
                    ) = change
                else { return false }
                return objectID == id
                    && lastSeenPosition == vec(4)
                    && lastSeenAt == 1
                    && detectedAt == 3
            })
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.presence, .notVisible)

        _ = try coordinator.apply(
            update(revision: 3, sequence: 4, at: 4, expected: [id])
        )
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.presence, .lastSeen)

        let removal = try applied(
            coordinator.apply(
                update(revision: 4, sequence: 5, at: 5, expected: [id])
            )
        )
        XCTAssertTrue(
            removal.changes.contains { change in
                guard
                    case .removed(
                        let objectID,
                        let lastSeenPosition,
                        let lastSeenAt,
                        let removedAt
                    ) = change
                else { return false }
                return objectID == id
                    && lastSeenPosition == vec(4)
                    && lastSeenAt == 1
                    && removedAt == 5
            })
        let removed = try XCTUnwrap(coordinator.snapshot.metadata(for: id))
        XCTAssertEqual(removed.object.presence, .removed)
        XCTAssertEqual(removed.object.lastSeenAt, 1)
        XCTAssertEqual(removed.position.observedAt, 1)
        XCTAssertEqual(removed.position.value, vec(4))
        XCTAssertEqual(removed.object.stateUpdatedAt, 5)
    }

    func testSingleMissNeverChangesDurablePresenceAndCoverageIsExplicit() throws {
        let id = objectID(81_102)
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(
            update(
                revision: 0,
                sequence: 1,
                at: 1,
                observations: [newObservation(id: id, at: 1)]
            )
        )
        _ = try coordinator.apply(
            update(revision: 1, sequence: 2, at: 2, expected: [id])
        )
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.presence, .visible)
        XCTAssertEqual(
            coordinator.snapshot.lifecycleEvidence(for: id)?.consecutiveMissCount,
            1
        )

        _ = try coordinator.apply(
            update(revision: 2, sequence: 3, at: 3, expected: [])
        )
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.presence, .visible)
        XCTAssertEqual(
            coordinator.snapshot.lifecycleEvidence(for: id)?.consecutiveMissCount,
            1
        )
    }

    func testHighConfidenceReidentificationRestoresLastSeenObject() throws {
        let id = objectID(81_103)
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(
            update(
                revision: 0,
                sequence: 1,
                at: 1,
                observations: [newObservation(id: id, at: 1, position: vec(2))]
            )
        )
        _ = try coordinator.apply(update(revision: 1, sequence: 2, at: 2, expected: [id]))
        _ = try coordinator.apply(update(revision: 2, sequence: 3, at: 3, expected: [id]))
        _ = try coordinator.apply(update(revision: 3, sequence: 4, at: 4, expected: [id]))
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.presence, .lastSeen)

        let result = try applied(
            coordinator.apply(
                update(
                    revision: 4,
                    sequence: 5,
                    at: 5,
                    observations: [existingObservation(id: id, at: 5, position: vec(2))],
                    expected: [id]
                )
            )
        )
        XCTAssertTrue(
            result.changes.contains { change in
                guard
                    case .stateChanged(
                        let objectID,
                        let previous,
                        let current,
                        let timestamp
                    ) = change
                else { return false }
                return objectID == id
                    && previous == .lastSeen
                    && current == .visible
                    && timestamp == 5
            })
        let restored = try XCTUnwrap(coordinator.snapshot.metadata(for: id))
        XCTAssertEqual(restored.object.presence, .visible)
        XCTAssertEqual(restored.object.lastSeenAt, 5)
        XCTAssertEqual(restored.position.observedAt, 5)
        XCTAssertEqual(
            coordinator.snapshot.lifecycleEvidence(for: id)?.consecutiveMissCount,
            0
        )
    }

    func testRefreshUpdatesBoundsAndMissingBoundsPreserveLastGeometry() throws {
        let id = objectID(81_119)
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(
            update(
                revision: 0,
                sequence: 1,
                at: 1,
                observations: [newObservation(id: id, at: 1)]
            )
        )

        let boundedObservation = existingObservation(
            id: id,
            at: 2,
            position: vec(0.02)
        )
        let updatedBounds = try XCTUnwrap(boundedObservation.metadata.object.bounds)
        let boundedDelta = try applied(
            coordinator.apply(
                update(
                    revision: 1,
                    sequence: 2,
                    at: 2,
                    observations: [boundedObservation],
                    expected: [id]
                )
            )
        )
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.bounds, updatedBounds)
        XCTAssertTrue(
            boundedDelta.spatialDelta.events.contains { event in
                guard case .observed(let objectID, _, _, let bounds, _) = event else {
                    return false
                }
                return objectID == id && bounds == updatedBounds
            }
        )

        let missingBoundsObservation = existingObservation(
            id: id,
            at: 3,
            position: vec(0.03),
            includesBounds: false
        )
        let preservedDelta = try applied(
            coordinator.apply(
                update(
                    revision: 2,
                    sequence: 3,
                    at: 3,
                    observations: [missingBoundsObservation],
                    expected: [id]
                )
            )
        )
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.bounds, updatedBounds)
        XCTAssertTrue(
            preservedDelta.spatialDelta.events.contains { event in
                guard case .observed(let objectID, _, _, let bounds, _) = event else {
                    return false
                }
                return objectID == id && bounds == updatedBounds
            }
        )
    }

    func testMovementRequiresRepeatedClusteredHighConfidenceObservations() throws {
        let id = objectID(81_104)
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(
            update(
                revision: 0,
                sequence: 1,
                at: 1,
                observations: [newObservation(id: id, at: 1)]
            )
        )

        for (revision, sequence, timestamp, position) in [
            (UInt64(1), UInt64(2), 2.0, 1.00),
            (UInt64(2), UInt64(3), 2.1, 1.04),
        ] {
            let delta = try applied(
                coordinator.apply(
                    update(
                        revision: revision,
                        sequence: sequence,
                        at: timestamp,
                        observations: [
                            existingObservation(
                                id: id,
                                at: timestamp,
                                position: vec(position)
                            )
                        ],
                        expected: [id]
                    )
                )
            )
            XCTAssertFalse(delta.changes.contains(where: isMove))
            XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.position.value, .zero)
        }

        let confirmed = try applied(
            coordinator.apply(
                update(
                    revision: 3,
                    sequence: 4,
                    at: 2.3,
                    observations: [
                        existingObservation(id: id, at: 2.3, position: vec(1.02))
                    ],
                    expected: [id]
                )
            )
        )
        XCTAssertTrue(confirmed.changes.contains(where: isMove))
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.position.value, vec(1.02))
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.lastSeenAt, 2.3)
        XCTAssertEqual(
            coordinator.snapshot.lifecycleEvidence(for: id)?.pendingMovementObservationCount,
            0
        )
    }

    func testOneFramePositionJumpIsDiscardedWhenObjectReturnsToStableLocation() throws {
        let id = objectID(81_105)
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(
            update(
                revision: 0,
                sequence: 1,
                at: 1,
                observations: [newObservation(id: id, at: 1)]
            )
        )
        _ = try coordinator.apply(
            update(
                revision: 1,
                sequence: 2,
                at: 2,
                observations: [existingObservation(id: id, at: 2, position: vec(5))],
                expected: [id]
            )
        )
        XCTAssertEqual(
            coordinator.snapshot.lifecycleEvidence(for: id)?.pendingMovementObservationCount,
            1
        )

        let result = try applied(
            coordinator.apply(
                update(
                    revision: 2,
                    sequence: 3,
                    at: 3,
                    observations: [existingObservation(id: id, at: 3, position: vec(0.02))],
                    expected: [id]
                )
            )
        )
        XCTAssertFalse(result.changes.contains(where: isMove))
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.position.value, vec(0.02))
        XCTAssertEqual(
            coordinator.snapshot.lifecycleEvidence(for: id)?.pendingMovementObservationCount,
            0
        )
    }

    func testAmbiguousAndWeakReidentificationCannotMutateMemory() throws {
        let id = objectID(81_106)
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(
            update(
                revision: 0,
                sequence: 1,
                at: 1,
                observations: [newObservation(id: id, at: 1)]
            )
        )
        let before = coordinator.snapshot
        let ambiguous = try TemporalSpatialObservation(
            metadata: metadata(id: id, at: 2),
            promotionEvidence: promotionEvidence(at: 2),
            identityDecision: .ambiguousCandidates([])
        )
        XCTAssertThrowsError(
            try coordinator.apply(
                update(
                    revision: 1,
                    sequence: 2,
                    at: 2,
                    observations: [ambiguous],
                    expected: [id]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TemporalSpatialMemoryError,
                .identityNotConfirmed(id)
            )
        }
        XCTAssertEqual(coordinator.snapshot, before)

        let weak = try TemporalSpatialObservation(
            metadata: metadata(id: id, at: 2),
            promotionEvidence: promotionEvidence(at: 2),
            identityDecision: .confirmedExisting(
                candidate(id: id, score: 0.79, geometry: 0.95, context: 0.95)
            )
        )
        XCTAssertThrowsError(
            try coordinator.apply(
                update(
                    revision: 1,
                    sequence: 2,
                    at: 2,
                    observations: [weak],
                    expected: [id]
                )
            )
        )
        XCTAssertEqual(coordinator.snapshot, before)
    }

    func testNewObjectRequiresGenuinelyNewIdentityDecision() throws {
        let id = objectID(81_107)
        var coordinator = makeCoordinator()
        let falsePositive = try TemporalSpatialObservation(
            metadata: metadata(id: id, at: 1),
            promotionEvidence: promotionEvidence(at: 1),
            identityDecision: .ambiguousCandidates([
                candidate(id: objectID(81_108))
            ])
        )

        XCTAssertThrowsError(
            try coordinator.apply(
                update(
                    revision: 0,
                    sequence: 1,
                    at: 1,
                    observations: [falsePositive]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TemporalSpatialMemoryError,
                .identityDecisionMismatch(id)
            )
        }
        XCTAssertTrue(coordinator.snapshot.objects.isEmpty)
        XCTAssertEqual(coordinator.snapshot.revision, 0)
    }

    func testCrossMapAndCrossFrameUpdatesAreRejectedAtomically() throws {
        let otherMap = MapID(rawValue: testUUID(81_201))
        let otherFrame = CoordinateFrameID(rawValue: testUUID(81_202))
        var coordinator = makeCoordinator()
        let crossMap = try TemporalSpatialUpdate(
            baseRevision: 0,
            sequence: 1,
            timestamp: 1,
            mapID: otherMap,
            coordinateFrameID: frame,
            observations: [
                newObservation(id: objectID(81_109), at: 1, mapID: otherMap)
            ],
            expectedVisibleObjectIDs: []
        )
        XCTAssertThrowsError(try coordinator.apply(crossMap)) { error in
            XCTAssertEqual(
                error as? TemporalSpatialMemoryError,
                .mapMismatch(expected: self.map, actual: otherMap)
            )
        }

        let crossFrame = try TemporalSpatialUpdate(
            baseRevision: 0,
            sequence: 1,
            timestamp: 1,
            mapID: map,
            coordinateFrameID: otherFrame,
            observations: [
                newObservation(
                    id: objectID(81_110),
                    at: 1,
                    coordinateFrameID: otherFrame
                )
            ],
            expectedVisibleObjectIDs: []
        )
        XCTAssertThrowsError(try coordinator.apply(crossFrame)) { error in
            XCTAssertEqual(
                error as? TemporalSpatialMemoryError,
                .coordinateFrameMismatch(expected: self.frame, actual: otherFrame)
            )
        }
        XCTAssertEqual(coordinator.snapshot.revision, 0)
        XCTAssertTrue(coordinator.snapshot.objects.isEmpty)
    }

    func testRevisionSequenceAndTimestampOrderingAreFailClosed() throws {
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(
            update(revision: 0, sequence: 10, at: 10)
        )
        let before = coordinator.snapshot

        XCTAssertThrowsError(
            try coordinator.apply(update(revision: 0, sequence: 11, at: 11))
        ) { error in
            XCTAssertEqual(
                error as? TemporalSpatialMemoryError,
                .revisionConflict(expected: 1, actualBase: 0)
            )
        }
        XCTAssertThrowsError(
            try coordinator.apply(
                update(revision: 1, sequence: 10, at: 11, idNumber: 81_999)
            )
        ) { error in
            XCTAssertEqual(
                error as? TemporalSpatialMemoryError,
                .outOfOrderSequence(previous: 10, incoming: 10)
            )
        }
        XCTAssertThrowsError(
            try coordinator.apply(update(revision: 1, sequence: 11, at: 9))
        ) { error in
            XCTAssertEqual(
                error as? TemporalSpatialMemoryError,
                .outOfOrderTimestamp(previous: 10, incoming: 9)
            )
        }
        XCTAssertEqual(coordinator.snapshot, before)
    }

    func testReplayIsIdempotentWhileRemembered() throws {
        var coordinator = makeCoordinator()
        let value = update(revision: 0, sequence: 1, at: 1)
        _ = try coordinator.apply(value)
        XCTAssertEqual(
            try coordinator.apply(value),
            .alreadyApplied(currentRevision: 1)
        )
        XCTAssertEqual(coordinator.snapshot.revision, 1)
        XCTAssertEqual(coordinator.snapshot.recentDeltas.count, 1)
    }

    func testCapacityDefersNewIdentityWhileExistingIdentityAndHistoryAdvance() throws {
        let policy = try TemporalSpatialMemoryPolicy(
            minimumMissesForNotVisible: 2,
            minimumMissesForLastSeen: 3,
            minimumMissesForRemoval: 4,
            notVisibleGraceInterval: 1,
            lastSeenGraceInterval: 2,
            removalGraceInterval: 3,
            minimumMovementObservationInterval: 0.2,
            maximumObjectCount: 1,
            maximumRetainedDeltaCount: 2,
            maximumRememberedUpdateCount: 2
        )
        let firstID = objectID(81_111)
        var coordinator = TemporalSpatialMemoryCoordinator(
            mapID: map,
            coordinateFrameID: frame,
            policy: policy
        )
        _ = try coordinator.apply(
            update(
                revision: 0,
                sequence: 1,
                at: 1,
                observations: [newObservation(id: firstID, at: 1)]
            )
        )
        _ = try coordinator.apply(update(revision: 1, sequence: 2, at: 2))
        _ = try coordinator.apply(update(revision: 2, sequence: 3, at: 3))
        XCTAssertEqual(coordinator.snapshot.recentDeltas.count, 2)
        XCTAssertEqual(coordinator.snapshot.rememberedUpdateCount, 2)

        let deferredID = objectID(81_112)
        let delta = try applied(
            coordinator.apply(
                update(
                    revision: 3,
                    sequence: 4,
                    at: 4,
                    observations: [
                        newObservation(id: deferredID, at: 4),
                        existingObservation(id: firstID, at: 4),
                    ],
                    expected: [firstID, deferredID]
                )
            )
        )
        XCTAssertEqual(delta.deferredObjectIDs, [deferredID])
        XCTAssertEqual(coordinator.snapshot.objects.count, 1)
        XCTAssertEqual(coordinator.snapshot.metadata(for: firstID)?.object.lastSeenAt, 4)
        XCTAssertNil(coordinator.snapshot.metadata(for: deferredID))
        XCTAssertEqual(coordinator.snapshot.revision, 4)
        XCTAssertEqual(coordinator.snapshot.recentDeltas.count, 2)
        XCTAssertEqual(coordinator.snapshot.rememberedUpdateCount, 2)

        let restored = try JSONDecoder().decode(
            TemporalSpatialMemorySnapshot.self,
            from: JSONEncoder().encode(coordinator.snapshot)
        )
        XCTAssertEqual(restored, coordinator.snapshot)
        XCTAssertNoThrow(try TemporalSpatialMemoryCoordinator(restoring: restored, policy: policy))
    }

    func testCapacityAdmissionIsDeterministicAndDoesNotBlockMissEvidence() throws {
        let policy = try TemporalSpatialMemoryPolicy(maximumObjectCount: 1)
        let admittedID = objectID(81_120)
        let deferredID = objectID(81_121)
        let initial = update(
            revision: 0,
            sequence: 1,
            at: 1,
            observations: [
                newObservation(id: deferredID, at: 1),
                newObservation(id: admittedID, at: 1),
            ],
            expected: [deferredID, admittedID]
        )
        var coordinator = TemporalSpatialMemoryCoordinator(
            mapID: map, coordinateFrameID: frame, policy: policy
        )
        let delta = try applied(coordinator.apply(initial))
        XCTAssertNotNil(coordinator.snapshot.metadata(for: admittedID))
        XCTAssertEqual(delta.deferredObjectIDs, [deferredID])
        XCTAssertEqual(try coordinator.apply(initial), .alreadyApplied(currentRevision: 1))

        _ = try coordinator.apply(
            update(
                revision: 1,
                sequence: 2,
                at: 2,
                observations: [newObservation(id: deferredID, at: 2)],
                expected: [admittedID, deferredID]
            )
        )
        XCTAssertEqual(
            coordinator.snapshot.lifecycleEvidence(for: admittedID)?.consecutiveMissCount,
            1
        )
        XCTAssertNil(coordinator.snapshot.lifecycleEvidence(for: deferredID))
    }

    func testSnapshotCodableRoundTripPreservesPendingAndMissEvidence() throws {
        let id = objectID(81_113)
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(
            update(
                revision: 0,
                sequence: 1,
                at: 1,
                observations: [newObservation(id: id, at: 1)]
            )
        )
        _ = try coordinator.apply(
            update(
                revision: 1,
                sequence: 2,
                at: 2,
                observations: [existingObservation(id: id, at: 2, position: vec(1))],
                expected: [id]
            )
        )
        _ = try coordinator.apply(
            update(revision: 2, sequence: 3, at: 3, expected: [id])
        )

        let data = try JSONEncoder().encode(coordinator.snapshot)
        let restored = try JSONDecoder().decode(
            TemporalSpatialMemorySnapshot.self,
            from: data
        )
        XCTAssertEqual(restored, coordinator.snapshot)
        XCTAssertEqual(restored.lifecycleEvidence(for: id)?.consecutiveMissCount, 1)
        XCTAssertEqual(restored.lifecycleEvidence(for: id)?.pendingMovementObservationCount, 1)
        XCTAssertNoThrow(
            try TemporalSpatialMemoryCoordinator(
                restoring: restored,
                policy: testPolicy()
            )
        )

        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        json["schemaVersion"] = 999
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TemporalSpatialMemorySnapshot.self,
                from: JSONSerialization.data(withJSONObject: json)
            )
        )
    }

    func testRestoredSnapshotRequiresBothUpdateClocks() throws {
        var coordinator = makeCoordinator()
        XCTAssertNoThrow(
            try TemporalSpatialMemoryCoordinator(restoring: coordinator.snapshot, policy: testPolicy())
        )
        _ = try coordinator.apply(update(revision: 0, sequence: 10, at: 10))
        let encoded = try JSONEncoder().encode(coordinator.snapshot)
        let valid = try JSONDecoder().decode(TemporalSpatialMemorySnapshot.self, from: encoded)
        XCTAssertNoThrow(
            try TemporalSpatialMemoryCoordinator(restoring: valid, policy: testPolicy())
        )

        for missingKey in ["latestSequence", "latestTimestamp"] {
            var json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            json.removeValue(forKey: missingKey)
            let invalid = try JSONDecoder().decode(
                TemporalSpatialMemorySnapshot.self,
                from: JSONSerialization.data(withJSONObject: json)
            )
            XCTAssertThrowsError(
                try TemporalSpatialMemoryCoordinator(restoring: invalid, policy: testPolicy()),
                "A missing \(missingKey) must not disable ordering after recovery."
            ) { error in
                XCTAssertEqual(error as? TemporalSpatialMemoryError, .invalidSnapshot)
            }
        }
    }

    func testRestoredSnapshotRequiresBothMissEvidenceClocks() throws {
        let id = objectID(81_114)
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(
            update(revision: 0, sequence: 1, at: 1, observations: [newObservation(id: id, at: 1)])
        )
        _ = try coordinator.apply(update(revision: 1, sequence: 2, at: 2, expected: [id]))
        XCTAssertEqual(coordinator.snapshot.lifecycleEvidence(for: id)?.consecutiveMissCount, 1)
        let encoded = try JSONEncoder().encode(coordinator.snapshot)
        let valid = try JSONDecoder().decode(TemporalSpatialMemorySnapshot.self, from: encoded)
        XCTAssertNoThrow(
            try TemporalSpatialMemoryCoordinator(restoring: valid, policy: testPolicy())
        )

        for missingKey in ["firstMissedAt", "lastMissedAt"] {
            var json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            // Typed-ID dictionaries encode as alternating key/value arrays.
            var states = try XCTUnwrap(json["objectStates"] as? [Any])
            XCTAssertEqual(states.count, 2)
            var state = try XCTUnwrap(states[1] as? [String: Any])
            state.removeValue(forKey: missingKey)
            states[1] = state
            json["objectStates"] = states
            let invalid = try JSONDecoder().decode(
                TemporalSpatialMemorySnapshot.self,
                from: JSONSerialization.data(withJSONObject: json)
            )
            XCTAssertThrowsError(
                try TemporalSpatialMemoryCoordinator(restoring: invalid, policy: testPolicy()),
                "A missing \(missingKey) must not disable lifecycle transitions after recovery."
            ) { error in
                XCTAssertEqual(error as? TemporalSpatialMemoryError, .invalidSnapshot)
            }
        }
    }

    func testPolicyUpdateDeltaAndPromotionEvidenceRoundTripThroughCodable() throws {
        let policy = testPolicy()
        XCTAssertEqual(
            try JSONDecoder().decode(
                TemporalSpatialMemoryPolicy.self,
                from: JSONEncoder().encode(policy)
            ),
            policy
        )

        let id = objectID(81_116)
        let originalUpdate = update(
            revision: 0,
            sequence: 1,
            at: 1,
            observations: [newObservation(id: id, at: 1)],
            expected: [id]
        )
        let restoredUpdate = try JSONDecoder().decode(
            TemporalSpatialUpdate.self,
            from: JSONEncoder().encode(originalUpdate)
        )
        XCTAssertEqual(restoredUpdate, originalUpdate)

        var coordinator = makeCoordinator()
        let delta = try applied(coordinator.apply(restoredUpdate))
        XCTAssertEqual(
            try JSONDecoder().decode(
                TemporalSpatialDelta.self,
                from: JSONEncoder().encode(delta)
            ),
            delta
        )

        XCTAssertThrowsError(
            try TemporalSpatialObservation(
                metadata: metadata(id: objectID(81_117), at: 2),
                promotionEvidence: promotionEvidence(at: 1),
                identityDecision: .genuinelyNew
            )
        ) { error in
            XCTAssertEqual(
                error as? TemporalSpatialMemoryError,
                .promotionEvidenceMismatch(objectID(81_117))
            )
        }
    }

    func testDurableMetadataCanSeedFirstJournalWithoutFabricatingObservationEvidence() throws {
        let id = objectID(81_118)
        let durable = metadata(id: id, at: 3, position: vec(2))
        let coordinator = try TemporalSpatialMemoryCoordinator(
            mapID: map,
            coordinateFrameID: frame,
            restoringDurableObjects: [durable],
            policy: testPolicy()
        )
        XCTAssertEqual(coordinator.snapshot.revision, 0)
        XCTAssertEqual(coordinator.snapshot.metadata(for: id), durable)
        XCTAssertTrue(coordinator.snapshot.recentDeltas.isEmpty)

        XCTAssertThrowsError(
            try TemporalSpatialMemoryCoordinator(
                mapID: map,
                coordinateFrameID: frame,
                restoringDurableObjects: [durable, durable],
                policy: testPolicy()
            )
        ) { error in
            XCTAssertEqual(
                error as? TemporalSpatialMemoryError,
                .duplicateDurableObject(id)
            )
        }
    }

    func testGeneratedSpatialDeltasStayCompatibleWithExistingReducer() throws {
        let id = objectID(81_114)
        var coordinator = makeCoordinator()
        var reducer = SpatialDeltaReducer()

        for value in [
            update(
                revision: 0,
                sequence: 1,
                at: 1,
                observations: [newObservation(id: id, at: 1)]
            ),
            update(revision: 1, sequence: 2, at: 2, expected: [id]),
            update(revision: 2, sequence: 3, at: 3, expected: [id]),
            update(revision: 3, sequence: 4, at: 4, expected: [id]),
        ] {
            let delta = try applied(coordinator.apply(value))
            _ = try reducer.apply(delta.spatialDelta)
        }

        XCTAssertEqual(reducer.snapshot.revision, coordinator.snapshot.revision)
        XCTAssertEqual(
            reducer.snapshot.confirmedObjects[id]?.presence,
            coordinator.snapshot.metadata(for: id)?.object.presence
        )
        XCTAssertEqual(reducer.snapshot.confirmedObjects[id]?.lastSeenAt, 1)
    }

    func testRemovedObjectCannotBeResurrected() throws {
        let id = objectID(81_115)
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(
            update(
                revision: 0,
                sequence: 1,
                at: 1,
                observations: [newObservation(id: id, at: 1)]
            )
        )
        _ = try coordinator.apply(update(revision: 1, sequence: 2, at: 2, expected: [id]))
        _ = try coordinator.apply(update(revision: 2, sequence: 3, at: 3, expected: [id]))
        _ = try coordinator.apply(update(revision: 3, sequence: 4, at: 4, expected: [id]))
        _ = try coordinator.apply(update(revision: 4, sequence: 5, at: 5, expected: [id]))
        let before = coordinator.snapshot

        XCTAssertThrowsError(
            try coordinator.apply(
                update(
                    revision: 5,
                    sequence: 6,
                    at: 6,
                    observations: [existingObservation(id: id, at: 6)],
                    expected: [id]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TemporalSpatialMemoryError,
                .removedObjectCannotReappear(id)
            )
        }
        XCTAssertEqual(coordinator.snapshot, before)
    }

    private func makeCoordinator() -> TemporalSpatialMemoryCoordinator {
        TemporalSpatialMemoryCoordinator(
            mapID: map,
            coordinateFrameID: frame,
            policy: testPolicy()
        )
    }

    private func testPolicy() -> TemporalSpatialMemoryPolicy {
        try! TemporalSpatialMemoryPolicy(
            minimumMissesForNotVisible: 2,
            minimumMissesForLastSeen: 3,
            minimumMissesForRemoval: 4,
            notVisibleGraceInterval: 1,
            lastSeenGraceInterval: 2,
            removalGraceInterval: 3,
            movementThreshold: 0.2,
            movementClusterRadius: 0.1,
            minimumMovementObservationCount: 3,
            minimumMovementObservationInterval: 0.2,
            maximumRetainedDeltaCount: 8,
            maximumRememberedUpdateCount: 8
        )
    }

    private func update(
        revision: UInt64,
        sequence: UInt64,
        at timestamp: TimeInterval,
        observations: [TemporalSpatialObservation] = [],
        expected: [ObjectID] = [],
        idNumber: Int? = nil
    ) -> TemporalSpatialUpdate {
        try! TemporalSpatialUpdate(
            id: deltaID(idNumber ?? (Int(sequence) + 81_500)),
            baseRevision: revision,
            sequence: sequence,
            timestamp: timestamp,
            mapID: map,
            coordinateFrameID: frame,
            observations: observations,
            expectedVisibleObjectIDs: expected
        )
    }

    private func newObservation(
        id: ObjectID,
        at timestamp: TimeInterval,
        position: Vec3 = .zero,
        mapID: MapID? = nil,
        coordinateFrameID: CoordinateFrameID? = nil
    ) -> TemporalSpatialObservation {
        try! TemporalSpatialObservation(
            metadata: metadata(
                id: id,
                at: timestamp,
                position: position,
                mapID: mapID,
                coordinateFrameID: coordinateFrameID
            ),
            promotionEvidence: promotionEvidence(
                at: timestamp,
                position: position,
                mapID: mapID,
                coordinateFrameID: coordinateFrameID
            ),
            identityDecision: .genuinelyNew
        )
    }

    private func existingObservation(
        id: ObjectID,
        at timestamp: TimeInterval,
        position: Vec3 = .zero,
        includesBounds: Bool = true
    ) -> TemporalSpatialObservation {
        try! TemporalSpatialObservation(
            metadata: metadata(
                id: id,
                at: timestamp,
                position: position,
                includesBounds: includesBounds
            ),
            promotionEvidence: promotionEvidence(at: timestamp, position: position),
            identityDecision: .confirmedExisting(candidate(id: id))
        )
    }

    private func metadata(
        id: ObjectID,
        at timestamp: TimeInterval,
        position: Vec3 = .zero,
        mapID customMapID: MapID? = nil,
        coordinateFrameID customFrameID: CoordinateFrameID? = nil,
        includesBounds: Bool = true
    ) -> SpatialObjectMetadata {
        let resolvedMap = customMapID ?? map
        let resolvedFrame = customFrameID ?? frame
        return try! SpatialObjectMetadata(
            mapID: resolvedMap,
            object: SpatialObject(
                id: id,
                semanticLabel: "의자",
                position: position,
                bounds: includesBounds
                    ? box(
                        minX: position.x - 0.1,
                        minY: -0.1,
                        minZ: -0.1,
                        maxX: position.x + 0.1,
                        maxY: 0.1,
                        maxZ: 0.1
                    )
                    : nil,
                certainty: .confirmed,
                presence: .visible,
                confidence: vector(),
                firstSeenAt: min(0.5, timestamp),
                lastSeenAt: timestamp
            ),
            position: FramedPosition(
                coordinateFrameID: resolvedFrame,
                value: position,
                observedAt: timestamp,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            )
        )
    }

    private func candidate(
        id: ObjectID,
        score aggregate: Double = 0.95,
        geometry: Double = 0.95,
        context: Double? = 0.95
    ) -> PersistentObjectReidentificationCandidate {
        try! PersistentObjectReidentificationCandidate(
            objectID: id,
            score: score(aggregate),
            geometryScore: score(geometry),
            spatialContextScore: context.map(score),
            visualSimilarity: nil,
            positionDistance: 0.02
        )
    }

    private func promotionEvidence(
        at timestamp: TimeInterval,
        position: Vec3 = .zero,
        mapID customMapID: MapID? = nil,
        coordinateFrameID customFrameID: CoordinateFrameID? = nil
    ) -> ObjectReidentificationPromotionEvidence {
        let resolvedMap = customMapID ?? map
        let resolvedFrame = customFrameID ?? frame
        let segment = CaptureSegmentID()
        let times = [timestamp - 0.4, timestamp - 0.2, timestamp]
        let observations = times.map { observationTime in
            try! ObjectPromotionObservation(
                observationID: ObservationID(),
                frameID: FrameID(),
                semanticLabel: "의자",
                coordinateFrameID: resolvedFrame,
                captureSegmentID: segment,
                mapID: resolvedMap,
                boundingBox: try! NormalizedBoundingBox2D(
                    x: 0.4,
                    y: 0.4,
                    width: 0.2,
                    height: 0.2
                ),
                position: try! FramedPosition(
                    coordinateFrameID: resolvedFrame,
                    value: position,
                    observedAt: observationTime,
                    trackingQuality: .normal,
                    uncertainty: .highConfidenceDepth
                ),
                semanticConfidence: score(0.95),
                geometryConfidence: score(0.95)
            )
        }
        return try! ObjectReidentificationPromotionEvidence(observations: observations)
    }

    private func applied(
        _ result: TemporalSpatialMemoryApplicationResult
    ) throws -> TemporalSpatialDelta {
        guard case .applied(let delta) = result else {
            XCTFail("Expected an applied temporal delta.")
            throw TestFailure.expectedAppliedDelta
        }
        return delta
    }

    private func isMove(_ change: TemporalSpatialChange) -> Bool {
        if case .moved = change {
            return true
        }
        return false
    }
}

private enum TestFailure: Error {
    case expectedAppliedDelta
}
