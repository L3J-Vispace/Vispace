import XCTest

@testable import VispaceCore

final class TemporalSpatialMemoryTests: XCTestCase {
    private let map = MapID(rawValue: testUUID(81_001))
    private let frame = CoordinateFrameID(rawValue: testUUID(81_002))

    func testCurrentConfidenceAdmissionMatchesAtomicReducerGateAcrossEveryRequiredDimension() throws {
        let weakID = objectID(81_100), healthyID = objectID(81_101)
        let cases: [(ConfidenceVector, SpatialTrackingQuality, Bool)] = [
            (vector(semantic: 0.95 * 0.83), .normal, false),
            (vector(geometry: 0.7999), .normal, false),
            (vector(identity: 0.7999), .normal, false),
            (vector(objectState: 0.7999), .normal, false),
            (vector(), .limited, false),
            (vector(), .unavailable, false),
            (vector(semantic: 0.8, geometry: 0.8, identity: 0.8, objectState: 0.8), .normal, true),
            // The unchanged Core contract does not invent additional gates on
            // unrelated place/relation scores or replace pose tracking quality.
            (vector(tracking: 0, place: 0, relation: 0), .normal, true),
        ]
        for (confidence, tracking, admitted) in cases {
            var coordinator = makeCoordinator()
            _ = try coordinator.apply(
                update(
                    revision: 0, sequence: 1, at: 100,
                    observations: [
                        newObservation(id: weakID, at: 100), newObservation(id: healthyID, at: 100),
                    ]))
            let before = coordinator.snapshot
            let base = existingObservation(id: weakID, at: 100.4)
            var object = base.metadata.object
            object.confidence = confidence
            let candidate = try TemporalSpatialObservation(
                metadata: SpatialObjectMetadata(
                    mapID: map, object: object,
                    position: FramedPosition(
                        coordinateFrameID: frame, value: base.metadata.position.value,
                        observedAt: 100.4, trackingQuality: tracking, uncertainty: .highConfidenceDepth)),
                promotionEvidence: base.promotionEvidence, identityDecision: base.identityDecision)
            let healthy = existingObservation(id: healthyID, at: 100.4)
            XCTAssertEqual(candidate.hasSufficientConfidenceForPersistence, admitted)
            let mixed = update(revision: 1, sequence: 2, at: 100.4, observations: [candidate, healthy])
            if admitted {
                _ = try coordinator.apply(mixed)
                XCTAssertEqual(coordinator.snapshot.metadata(for: weakID)?.object.lastSeenAt, 100.4)
            } else {
                XCTAssertThrowsError(try coordinator.apply(mixed)) {
                    XCTAssertEqual(
                        $0 as? TemporalSpatialMemoryError, .insufficientObservationConfidence(weakID))
                }
                XCTAssertEqual(coordinator.snapshot, before, "Core must retain atomic fail-closed validation")
                _ = try coordinator.apply(
                    update(
                        revision: 1, sequence: 2, at: 100.4,
                        observations: [healthy]))
                XCTAssertEqual(coordinator.snapshot.metadata(for: weakID), before.metadata(for: weakID))
            }
            XCTAssertEqual(coordinator.snapshot.metadata(for: healthyID)?.object.lastSeenAt, 100.4)
        }
    }

    func testCurrentCaptureAuthorityContinuesBeyond4096SessionsWithoutRetiredHistory() throws {
        var coordinator = makeCoordinator()
        for epoch in 1...4_100 {
            _ = try coordinator.apply(update(
                revision: UInt64(epoch - 1), sequence: UInt64(epoch), at: Double(10_000 - epoch),
                clock: TemporalSpatialClock(
                    epoch: UInt64(epoch), captureSegmentID: CaptureSegmentID(), monotonicTimestamp: 1,
                    authorization: .currentCapture
                )
            ))
        }
        XCTAssertEqual(coordinator.snapshot.latestClock?.epoch, 4_100)
        XCTAssertTrue(coordinator.snapshot.retiredCaptureSegmentIDs.isEmpty)
        let restored = try JSONDecoder().decode(
            TemporalSpatialMemorySnapshot.self, from: JSONEncoder().encode(coordinator.snapshot)
        )
        var restarted = try TemporalSpatialMemoryCoordinator(restoring: restored, policy: testPolicy())
        _ = try restarted.apply(update(
            revision: 4_100, sequence: 4_101, at: 100,
            clock: TemporalSpatialClock(
                epoch: 4_101, captureSegmentID: CaptureSegmentID(), monotonicTimestamp: 1,
                authorization: .currentCapture
            )
        ))
        let before = restarted.snapshot
        XCTAssertThrowsError(try restarted.apply(update(
            revision: 4_101, sequence: 4_102, at: 101,
            clock: TemporalSpatialClock(epoch: 4_102, captureSegmentID: CaptureSegmentID(), monotonicTimestamp: 2)
        )))
        XCTAssertEqual(restarted.snapshot, before)
    }

    func testVersionTwoClockMigratesToCurrentCaptureAndRequiresRetiredHistoryWhenDecoding() throws {
        var coordinator = makeCoordinator()
        for epoch in 1...2 {
            _ = try coordinator.apply(update(
                revision: UInt64(epoch - 1), sequence: UInt64(epoch), at: Double(epoch),
                clock: TemporalSpatialClock(epoch: UInt64(epoch), captureSegmentID: CaptureSegmentID(), monotonicTimestamp: 1)
            ))
        }
        var versionTwo = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(coordinator.snapshot)
        ) as? [String: Any])
        versionTwo["schemaVersion"] = 2
        let decoded = try JSONDecoder().decode(
            TemporalSpatialMemorySnapshot.self, from: JSONSerialization.data(withJSONObject: versionTwo)
        )
        var restarted = try TemporalSpatialMemoryCoordinator(restoring: decoded, policy: testPolicy())
        XCTAssertEqual(restarted.snapshot.retiredCaptureSegmentIDs.count, 1)
        _ = try restarted.apply(update(
            revision: 2, sequence: 3, at: 1,
            clock: TemporalSpatialClock(
                epoch: 3, captureSegmentID: CaptureSegmentID(), monotonicTimestamp: 1,
                authorization: .currentCapture
            )
        ))
        XCTAssertTrue(restarted.snapshot.retiredCaptureSegmentIDs.isEmpty)
        XCTAssertEqual(restarted.snapshot.latestClock?.epoch, 3)
        versionTwo.removeValue(forKey: "retiredCaptureSegmentIDs")
        XCTAssertThrowsError(try JSONDecoder().decode(
            TemporalSpatialMemorySnapshot.self, from: JSONSerialization.data(withJSONObject: versionTwo)
        ))
        versionTwo["retiredCaptureSegmentIDs"] = []
        XCTAssertThrowsError(try JSONDecoder().decode(
            TemporalSpatialMemorySnapshot.self, from: JSONSerialization.data(withJSONObject: versionTwo)
        ))
    }

    func testLegacyFutureDatesMigrateWithoutRewritingObservationDates() throws {
        let id = objectID(81_140)
        let value = metadata(id: id, at: 1_000)
        let futureObject = try SpatialObject(
            id: id, semanticLabel: value.object.semanticLabel,
            position: value.object.position, bounds: value.object.bounds,
            certainty: .confirmed, confidence: value.object.confidence,
            firstSeenAt: 999, lastSeenAt: 1_000
        )
        let durable = try SpatialObjectMetadata(mapID: map, object: futureObject, position: value.position)
        var coordinator = try TemporalSpatialMemoryCoordinator(
            mapID: map, coordinateFrameID: frame, restoringDurableObjects: [durable], policy: testPolicy()
        )
        let segment = CaptureSegmentID()
        let delta = try applied(coordinator.apply(update(
            revision: 0, sequence: 1, at: 100,
            observations: [existingObservation(id: id, at: 100)],
            clock: TemporalSpatialClock(epoch: 1, captureSegmentID: segment, monotonicTimestamp: 10)
        )))
        let object = try XCTUnwrap(coordinator.snapshot.metadata(for: id)?.object)
        XCTAssertEqual(object.firstSeenAt, 999)
        XCTAssertEqual(object.lastSeenAt, 100)
        XCTAssertEqual(object.stateUpdatedAt, 100)
        XCTAssertEqual(object.temporalRevision, 1)
        XCTAssertTrue(delta.changes.contains(.clockEpochStarted(epoch: 1, at: 100)))
        let encoded = try JSONEncoder().encode(coordinator.snapshot)
        let decoded = try JSONDecoder().decode(TemporalSpatialMemorySnapshot.self, from: encoded)
        XCTAssertEqual(decoded, coordinator.snapshot)
        XCTAssertNoThrow(try TemporalSpatialMemoryCoordinator(restoring: decoded, policy: testPolicy()))

        for index in 1...4 {
            _ = try coordinator.apply(update(
                revision: UInt64(index), sequence: UInt64(index + 1), at: 100 + Double(index),
                expected: [id],
                clock: TemporalSpatialClock(epoch: 1, captureSegmentID: segment, monotonicTimestamp: 10 + Double(index))
            ))
        }
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.presence, .removed)
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.firstSeenAt, 999)
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.lastSeenAt, 100)
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.stateUpdatedAt, 104)
        XCTAssertNoThrow(try JSONDecoder().decode(
            TemporalSpatialMemorySnapshot.self, from: JSONEncoder().encode(coordinator.snapshot)
        ))
    }

    func testCalendarJumpsCannotReplaceElapsedMissEvidence() throws {
        let id = objectID(81_141)
        let segment = CaptureSegmentID()
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(update(
            revision: 0, sequence: 1, at: 100, observations: [newObservation(id: id, at: 100)],
            clock: TemporalSpatialClock(epoch: 1, captureSegmentID: segment, monotonicTimestamp: 10)
        ))
        for (index, wall, elapsed) in [(1, 5_000.0, 11.0), (2, 9_000.0, 11.1)] {
            _ = try coordinator.apply(update(
                revision: UInt64(index), sequence: UInt64(index + 1), at: wall, expected: [id],
                clock: TemporalSpatialClock(epoch: 1, captureSegmentID: segment, monotonicTimestamp: elapsed)
            ))
        }
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.presence, .visible)
        _ = try coordinator.apply(update(
            revision: 3, sequence: 4, at: 102, expected: [id],
            clock: TemporalSpatialClock(epoch: 1, captureSegmentID: segment, monotonicTimestamp: 12)
        ))
        XCTAssertEqual(coordinator.snapshot.lifecycleEvidence(for: id)?.consecutiveMissCount, 1)
        _ = try coordinator.apply(update(
            revision: 4, sequence: 5, at: 103, expected: [id],
            clock: TemporalSpatialClock(epoch: 1, captureSegmentID: segment, monotonicTimestamp: 13)
        ))
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.presence, .notVisible)
    }

    func testRetiredCaptureEpochCannotReturnAfterRestartAndEvidenceResets() throws {
        let firstSegment = CaptureSegmentID()
        let nextSegment = CaptureSegmentID()
        let id = objectID(81_142)
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(update(
            revision: 0, sequence: 1, at: 1_000, observations: [newObservation(id: id, at: 1_000)],
            clock: TemporalSpatialClock(epoch: 1, captureSegmentID: firstSegment, monotonicTimestamp: 500)
        ))
        _ = try coordinator.apply(update(
            revision: 1, sequence: 2, at: 1_001, expected: [id],
            clock: TemporalSpatialClock(epoch: 1, captureSegmentID: firstSegment, monotonicTimestamp: 501)
        ))
        _ = try coordinator.apply(update(
            revision: 2, sequence: 3, at: 100, expected: [id],
            clock: TemporalSpatialClock(epoch: 2, captureSegmentID: nextSegment, monotonicTimestamp: 1)
        ))
        XCTAssertEqual(coordinator.snapshot.lifecycleEvidence(for: id)?.consecutiveMissCount, 1)
        let restored = try JSONDecoder().decode(
            TemporalSpatialMemorySnapshot.self, from: JSONEncoder().encode(coordinator.snapshot)
        )
        var restarted = try TemporalSpatialMemoryCoordinator(restoring: restored, policy: testPolicy())
        XCTAssertThrowsError(try restarted.apply(update(
            revision: 3, sequence: 4, at: 1_002,
            clock: TemporalSpatialClock(epoch: 3, captureSegmentID: firstSegment, monotonicTimestamp: 502)
        ))) { error in
            XCTAssertEqual(error as? TemporalSpatialMemoryError, .clockEpochConflict)
        }
        XCTAssertEqual(restarted.snapshot, restored)
        XCTAssertThrowsError(try restarted.apply(update(revision: 3, sequence: 4, at: 101)))
        XCTAssertEqual(restarted.snapshot, restored)
    }

    func testImportedRevisionSeedsAboveItsDurableHighWaterMark() throws {
        let id = objectID(81_143)
        let original = metadata(id: id, at: 1_000)
        var object = original.object
        object.temporalRevision = 500
        let durable = try SpatialObjectMetadata(mapID: map, object: object, position: original.position)
        var coordinator = try TemporalSpatialMemoryCoordinator(
            mapID: map, coordinateFrameID: frame, restoringDurableObjects: [durable], policy: testPolicy()
        )
        XCTAssertEqual(coordinator.snapshot.revision, 500)
        _ = try coordinator.apply(update(
            revision: 500, sequence: 501, at: 100,
            observations: [existingObservation(id: id, at: 100)],
            clock: TemporalSpatialClock(epoch: 1, captureSegmentID: CaptureSegmentID(), monotonicTimestamp: 1)
        ))
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.object.temporalRevision, 501)
    }

    func testVersionOneSnapshotMigratesAndVersionTwoDeltasRemainReducerCompatible() throws {
        let id = objectID(81_144)
        var coordinator = makeCoordinator()
        let legacyDelta = try applied(coordinator.apply(update(
            revision: 0, sequence: 1, at: 1_000, observations: [newObservation(id: id, at: 1_000)]
        )))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(coordinator.snapshot)) as? [String: Any])
        json["schemaVersion"] = 1
        json.removeValue(forKey: "latestClock")
        json.removeValue(forKey: "retiredCaptureSegmentIDs")
        let migrated = try JSONDecoder().decode(TemporalSpatialMemorySnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        var restarted = try TemporalSpatialMemoryCoordinator(restoring: migrated, policy: testPolicy())
        let delta = try applied(restarted.apply(update(
            revision: 1, sequence: 2, at: 100, observations: [existingObservation(id: id, at: 100)],
            clock: TemporalSpatialClock(epoch: 1, captureSegmentID: CaptureSegmentID(), monotonicTimestamp: 1)
        )))
        var reducer = SpatialDeltaReducer()
        _ = try reducer.apply(legacyDelta.spatialDelta)
        _ = try reducer.apply(delta.spatialDelta)
        XCTAssertEqual(reducer.snapshot.confirmedObjects[id], restarted.snapshot.metadata(for: id)?.object)
        XCTAssertEqual(reducer.snapshot.confirmedObjects[id]?.lastSeenAt, 100)
        XCTAssertEqual(reducer.snapshot.confirmedObjects[id]?.temporalRevision, 2)
    }

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

    func testExplicitRemovedHistoryCleanupRetainsOrderingAndUnrelatedObjects() throws {
        let removedID = objectID(81_190), liveID = objectID(81_191)
        let segment = CaptureSegmentID()
        func clock(_ timestamp: TimeInterval) throws -> TemporalSpatialClock {
            try TemporalSpatialClock(epoch: 1, captureSegmentID: segment, monotonicTimestamp: timestamp)
        }
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(update(revision: 0, sequence: 1, at: 1,
            observations: [newObservation(id: removedID, at: 1), newObservation(id: liveID, at: 1)],
            clock: clock(1)))
        for sequence in UInt64(2)...5 {
            _ = try coordinator.apply(update(revision: sequence - 1, sequence: sequence,
                at: Double(sequence), expected: [removedID], clock: clock(Double(sequence))))
        }
        let original = coordinator.snapshot
        XCTAssertEqual(original.metadata(for: removedID)?.object.temporalRevision, 5)
        let compacted = original.reclaimingRemovedObjectHistory()
        XCTAssertNil(compacted.metadata(for: removedID))
        XCTAssertEqual(compacted.metadata(for: liveID), original.metadata(for: liveID))
        XCTAssertEqual(compacted.revision, original.revision)
        XCTAssertEqual(compacted.latestSequence, original.latestSequence)
        XCTAssertEqual(compacted.latestTimestamp, original.latestTimestamp)
        XCTAssertEqual(compacted.latestClock, original.latestClock)
        XCTAssertEqual(compacted.rememberedUpdateCount, original.rememberedUpdateCount)
        let encoded = try JSONEncoder().encode(compacted)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).lowercased()
            .contains(removedID.rawValue.uuidString.lowercased()))
        let limitedPolicy = try TemporalSpatialMemoryPolicy(maximumObjectCount: 2)
        var full = try TemporalSpatialMemoryCoordinator(restoring: original, policy: limitedPolicy)
        let admission = try update(revision: 5, sequence: 6, at: 6,
            observations: [newObservation(id: objectID(81_192), at: 6)], clock: clock(6))
        _ = try full.apply(admission)
        XCTAssertNil(full.snapshot.metadata(for: objectID(81_192)))
        var restored = try TemporalSpatialMemoryCoordinator(restoring: compacted, policy: limitedPolicy)
        XCTAssertEqual(try restored.apply(update(revision: 4, sequence: 5, at: 5,
            expected: [removedID], clock: clock(5))),
                       .alreadyApplied(currentRevision: 5))
        _ = try restored.apply(admission)
        XCTAssertEqual(restored.snapshot.objects.count, 2)
        XCTAssertNotNil(restored.snapshot.metadata(for: objectID(81_192)))
    }

    func testCleanupRetainsLastSeenNotVisibleAndManualRecords() throws {
        var records: [SpatialObjectMetadata] = []
        for (index, presence) in [ObjectPresence.lastSeen, .notVisible, .removed].enumerated() {
            let original = metadata(id: objectID(81_200 + index), at: 1)
            var object = original.object
            object.presence = presence
            object.temporalRevision = 1
            if presence == .removed { object.semanticLabel = UserObjectRegistrationAccumulator.semanticLabel }
            records.append(try SpatialObjectMetadata(mapID: original.mapID, object: object, position: original.position))
        }
        let snapshot = try TemporalSpatialMemoryCoordinator(mapID: map, coordinateFrameID: frame,
            restoringDurableObjects: records, policy: testPolicy()).snapshot
        XCTAssertTrue(snapshot.reclaimableRemovedObjects.isEmpty)
        XCTAssertEqual(snapshot.reclaimingRemovedObjectHistory(), snapshot)
    }

    func testExplicitCleanupReclaimsLegacyRemovedObjectWithoutTemporalRevision() throws {
        let original = metadata(id: objectID(81_210), at: 1)
        var object = original.object
        object.presence = .removed
        XCTAssertNil(object.temporalRevision)
        let removed = try SpatialObjectMetadata(mapID: original.mapID, object: object, position: original.position)
        let policy = try TemporalSpatialMemoryPolicy(maximumObjectCount: 1)
        let snapshot = try TemporalSpatialMemoryCoordinator(mapID: map, coordinateFrameID: frame,
            restoringDurableObjects: [removed], policy: policy).snapshot
        XCTAssertEqual(snapshot.reclaimableRemovedObjects, [removed])
        let compacted = snapshot.reclaimingRemovedObjectHistory()
        XCTAssertTrue(compacted.objects.isEmpty)
        XCTAssertEqual(compacted.revision, snapshot.revision)
        var restored = try TemporalSpatialMemoryCoordinator(restoring: compacted, policy: policy)
        _ = try restored.apply(update(revision: 0, sequence: 1, at: 2,
            observations: [newObservation(id: objectID(81_211), at: 2)]))
        XCTAssertNotNil(restored.snapshot.metadata(for: objectID(81_211)))
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

    func testExplicitClassificationCorrectionPreservesIdentityNameLocationAndHistory() throws {
        let id = objectID(81_901)
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(
            update(
                revision: 0, sequence: 1, at: 100,
                observations: [newObservation(id: id, at: 100)]))
        let before = try XCTUnwrap(coordinator.snapshot.metadata(for: id))
        let correction = try ObjectClassificationCorrection(
            objectID: id,
            expectedSemanticLabel: before.object.semanticLabel, expectedTemporalRevision: nil,
            semanticLabel: "table", displayName: "내 책상")
        let value = try TemporalSpatialUpdate(
            baseRevision: 1, sequence: 2, timestamp: 101,
            mapID: map, coordinateFrameID: frame, observations: [], expectedVisibleObjectIDs: [],
            classificationCorrections: [correction])
        let delta = try applied(coordinator.apply(value))
        let corrected = try XCTUnwrap(coordinator.snapshot.metadata(for: id))
        XCTAssertEqual(corrected.object.id, before.object.id)
        XCTAssertEqual(corrected.object.semanticLabel, "table")
        XCTAssertEqual(corrected.object.displayName, "내 책상")
        XCTAssertEqual(corrected.position, before.position)
        XCTAssertEqual(corrected.object.firstSeenAt, before.object.firstSeenAt)
        XCTAssertEqual(corrected.object.lastSeenAt, before.object.lastSeenAt)
        XCTAssertTrue(delta.changes.contains(.reclassified(objectID: id, from: "의자", to: "table", at: 101)))
        XCTAssertTrue(
            coordinator.snapshot.recentDeltas.first?.changes.contains(.added(object: before, at: 100)) == true
        )
        let restored = try TemporalSpatialMemoryCoordinator(
            restoring: JSONDecoder().decode(
                TemporalSpatialMemorySnapshot.self, from: JSONEncoder().encode(coordinator.snapshot)),
            policy: testPolicy())
        XCTAssertEqual(restored.snapshot.metadata(for: id), corrected)
    }

    func testStaleClassificationCorrectionAndDetectorLabelFluctuationAreAtomic() throws {
        let id = objectID(81_902)
        var coordinator = makeCoordinator()
        _ = try coordinator.apply(
            update(
                revision: 0, sequence: 1, at: 100,
                observations: [newObservation(id: id, at: 100)]))
        let before = coordinator.snapshot
        let stale = try ObjectClassificationCorrection(
            objectID: id, expectedSemanticLabel: "table",
            expectedTemporalRevision: nil, semanticLabel: "cup", displayName: nil)
        XCTAssertThrowsError(
            try coordinator.apply(
                TemporalSpatialUpdate(
                    baseRevision: 1, sequence: 2,
                    timestamp: 101, mapID: map, coordinateFrameID: frame, observations: [],
                    expectedVisibleObjectIDs: [], classificationCorrections: [stale])))
        XCTAssertEqual(coordinator.snapshot, before)
        let old = existingObservation(id: id, at: 101)
        var object = old.metadata.object
        object.semanticLabel = "table"
        XCTAssertThrowsError(
            try TemporalSpatialObservation(
                metadata: SpatialObjectMetadata(
                    mapID: map, object: object, position: old.metadata.position),
                promotionEvidence: old.promotionEvidence, identityDecision: old.identityDecision))
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
        idNumber: Int? = nil,
        clock: TemporalSpatialClock? = nil
    ) -> TemporalSpatialUpdate {
        try! TemporalSpatialUpdate(
            id: deltaID(idNumber ?? (Int(sequence) + 81_500)),
            baseRevision: revision,
            sequence: sequence,
            timestamp: timestamp,
            mapID: map,
            coordinateFrameID: frame,
            observations: observations,
            expectedVisibleObjectIDs: expected,
            clock: clock
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
