import XCTest

@testable import VispaceCore

final class PersistentObjectIdentitySupportTests: XCTestCase {
    private let map = MapID(), frame = CoordinateFrameID(), segment = CaptureSegmentID()

    func testContinuousTrackingUpdatesWithoutInventedSpatialContextAndReplays() throws {
        let id = ObjectID()
        let original = try metadata(id: id, at: 100, x: 0)
        let evidence = try promotion(times: [100, 100.2, 100.4], x: [0, 0.025, 0.05])
        let incoming = try metadata(id: id, at: 100.4, x: 0.05)
        let support = PersistentObjectIdentitySupport.continuousTracking(
            objectID: id,
            samples: try samples(evidence))
        let decision = try XCTUnwrap(
            PersistentObjectReidentificationResolver().resolveSupportedIdentity(
                incoming: incoming, promotionEvidence: evidence, support: support, against: original))
        guard case .confirmedExisting(let candidate) = decision else {
            return XCTFail("Expected supported identity")
        }
        XCTAssertNil(candidate.spatialContextScore)
        var coordinator = try TemporalSpatialMemoryCoordinator(
            mapID: map, coordinateFrameID: frame,
            restoringDurableObjects: [original])
        let update = try TemporalSpatialUpdate(
            baseRevision: 0, sequence: 1, timestamp: 100.4,
            mapID: map, coordinateFrameID: frame,
            observations: [
                TemporalSpatialObservation(
                    metadata: incoming, promotionEvidence: evidence,
                    identityDecision: decision, identitySupport: support)
            ], expectedVisibleObjectIDs: [])
        _ = try coordinator.apply(update)
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.position, incoming.position)
        XCTAssertEqual(
            coordinator.snapshot.metadata(for: id)?.object.firstSeenAt, original.object.firstSeenAt)
        let replayUpdate = try JSONDecoder().decode(
            TemporalSpatialUpdate.self, from: JSONEncoder().encode(update))
        var replay = try TemporalSpatialMemoryCoordinator(
            mapID: map, coordinateFrameID: frame,
            restoringDurableObjects: [original])
        _ = try replay.apply(replayUpdate)
        XCTAssertEqual(replay.snapshot, coordinator.snapshot)
        var unsupported = try TemporalSpatialMemoryCoordinator(
            mapID: map, coordinateFrameID: frame,
            restoringDurableObjects: [original])
        XCTAssertThrowsError(
            try unsupported.apply(
                TemporalSpatialUpdate(
                    baseRevision: 0, sequence: 1,
                    timestamp: 100.4, mapID: map, coordinateFrameID: frame,
                    observations: [
                        TemporalSpatialObservation(
                            metadata: incoming, promotionEvidence: evidence,
                            identityDecision: decision)
                    ], expectedVisibleObjectIDs: [])))
        XCTAssertEqual(unsupported.snapshot.revision, 0)
    }

    func testContinuousMotionBeyondRetainedWindowKeepsDurableAnchorAndMovementHistory() throws {
        let id = ObjectID()
        let original = try metadata(id: ObjectID(), at: 100, x: 0)
        let initial = try metadata(id: id, at: 100, x: 0)
        var coordinator = try TemporalSpatialMemoryCoordinator(
            mapID: map, coordinateFrameID: frame,
            restoringDurableObjects: [initial])
        for index in 2..<75 {
            let times = (max(0, index - 31)...index).map { 100 + Double($0) * 0.2 }
            let locations = (max(0, index - 31)...index).map { Double(min($0, 70)) * 0.05 }
            let evidence = try promotion(times: times, x: locations)
            let incoming = try metadata(
                id: id, at: 100 + Double(index) * 0.2, x: Double(min(index, 70)) * 0.05)
            let existing = try XCTUnwrap(coordinator.snapshot.metadata(for: id))
            let support = PersistentObjectIdentitySupport.continuousTracking(
                objectID: id,
                samples: try samples(evidence))
            let decision = try XCTUnwrap(
                PersistentObjectReidentificationResolver().resolveSupportedIdentity(
                    incoming: incoming, promotionEvidence: evidence, support: support, against: existing))
            _ = try coordinator.apply(
                TemporalSpatialUpdate(
                    baseRevision: UInt64(index - 2), sequence: UInt64(index - 1),
                    timestamp: incoming.position.observedAt, mapID: map, coordinateFrameID: frame,
                    observations: [
                        TemporalSpatialObservation(
                            metadata: incoming, promotionEvidence: evidence,
                            identityDecision: decision, identitySupport: support)
                    ], expectedVisibleObjectIDs: []))
            XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.position, incoming.position)
        }
        XCTAssertEqual(
            coordinator.snapshot.metadata(for: id)?.object.firstSeenAt, original.object.firstSeenAt)
        XCTAssertEqual(coordinator.snapshot.metadata(for: id)?.position.value.x, 3.5)
        XCTAssertTrue(
            coordinator.snapshot.recentDeltas.flatMap(\.changes).contains { change in
                if case .moved(let target, _, let to, _, _) = change { return target == id && to.x == 3.5 }
                return false
            })
    }

    func testBrokenAmbiguousOrJumpingTrackingCannotSupplyIdentity() throws {
        let id = ObjectID()
        let original = try metadata(id: ObjectID(), at: 100, x: 0)
        // Use a genuine target ID; unrelated IDs also must fail the contract.
        let target = try metadata(id: id, at: 100, x: 0)
        let evidence = try promotion(times: [100, 100.2, 100.4], x: [0, 0.025, 0.05])
        let incoming = try metadata(id: id, at: 100.4, x: 0.05)
        let valid = try samples(evidence)
        XCTAssertFalse(
            PersistentObjectIdentitySupport.continuousTracking(objectID: id, samples: valid)
                .validates(existing: original, incoming: incoming, promotionEvidence: evidence))
        for variant in 0..<4 {
            var values = valid
            let sample = values[1]
            values[1] = ContinuousObjectTrackingSample(
                frameID: sample.frameID,
                position: variant == 3 ? try position(at: 100.2, x: 2) : sample.position,
                captureSegmentID: sample.captureSegmentID,
                monotonicTimestamp: variant == 2 ? 90 : sample.monotonicTimestamp,
                trackerConfidence: variant == 0 ? nil : sample.trackerConfidence,
                associationMargin: variant == 1 ? 0.02 : sample.associationMargin, bounds: sample.bounds,
                geometryConfidence: .one)
            XCTAssertFalse(
                PersistentObjectIdentitySupport.continuousTracking(objectID: id, samples: values)
                    .validates(existing: target, incoming: incoming, promotionEvidence: evidence))
        }
    }

    func testFarUserConfirmedObjectPreservesOldIDAndHistoryWithoutMergingNearbyPeer() throws {
        let targetID = ObjectID()
        let peerID = ObjectID()
        let target = try metadata(id: targetID, at: 50, x: 0)
        let peer = try metadata(id: peerID, at: 50, x: 2.05)
        var coordinator = try TemporalSpatialMemoryCoordinator(
            mapID: map, coordinateFrameID: frame,
            restoringDurableObjects: [target, peer])
        let allTimes = [100.0, 100.2, 100.4, 100.6, 100.8]
        let evidence = try promotion(times: allTimes, x: Array(repeating: 2, count: 5))
        let support = try PersistentObjectIdentitySupport.userConfirmation(
            objectID: targetID,
            expectedTemporalRevision: nil, mapID: map, coordinateFrameID: frame,
            captureSegmentID: segment, reviewedFrameID: evidence.frameIDs[1],
            reviewedPosition: Vec3(x: 2, y: 0, z: -2), reviewedAt: 100.2, confirmedAt: 100.21)
        for index in 2...4 {
            let window = try ObjectReidentificationPromotionEvidence(
                observations: Array(evidence.observations.prefix(index + 1)))
            let incoming = try metadata(id: targetID, at: allTimes[index], x: 2)
            XCTAssertFalse(support.validates(existing: peer, incoming: incoming, promotionEvidence: window))
            let decision = try XCTUnwrap(
                PersistentObjectReidentificationResolver().resolveSupportedIdentity(
                    incoming: incoming, promotionEvidence: window, support: support, against: target))
            _ = try coordinator.apply(
                TemporalSpatialUpdate(
                    baseRevision: UInt64(index - 2),
                    sequence: UInt64(index - 1), timestamp: allTimes[index], mapID: map,
                    coordinateFrameID: frame,
                    observations: [
                        TemporalSpatialObservation(
                            metadata: incoming,
                            promotionEvidence: window, identityDecision: decision, identitySupport: support)
                    ],
                    expectedVisibleObjectIDs: []))
        }
        XCTAssertEqual(coordinator.snapshot.metadata(for: targetID)?.position.value.x, 2)
        XCTAssertEqual(
            coordinator.snapshot.metadata(for: targetID)?.object.firstSeenAt, target.object.firstSeenAt)
        XCTAssertEqual(coordinator.snapshot.metadata(for: peerID), peer)
        XCTAssertTrue(
            coordinator.snapshot.recentDeltas.flatMap(\.changes).contains { change in
                if case .moved(let id, let from, let to, _, _) = change {
                    return id == targetID && from == target.position.value && to.x == 2
                }
                return false
            })
        let stale = try PersistentObjectIdentitySupport.userConfirmation(
            objectID: targetID,
            expectedTemporalRevision: 7, mapID: map, coordinateFrameID: frame,
            captureSegmentID: segment, reviewedFrameID: evidence.frameIDs[1],
            reviewedPosition: Vec3(x: 2, y: 0, z: -2), reviewedAt: 100.2, confirmedAt: 100.21)
        XCTAssertFalse(
            stale.validates(
                existing: target, incoming: try metadata(id: targetID, at: 100.8, x: 2),
                promotionEvidence: evidence))
    }

    private func position(at time: Double, x: Double) throws -> FramedPosition {
        try FramedPosition(
            coordinateFrameID: frame, value: Vec3(x: x, y: 0, z: -2),
            observedAt: time, trackingQuality: .normal, uncertainty: .highConfidenceDepth)
    }
    private func bounds(x: Double) throws -> AABB {
        try AABB(min: Vec3(x: x - 0.1, y: -0.1, z: -2.1), max: Vec3(x: x + 0.1, y: 0.1, z: -1.9))
    }
    private func metadata(id: ObjectID, at time: Double, x: Double) throws -> SpatialObjectMetadata {
        let position = try position(at: time, x: x)
        return try SpatialObjectMetadata(
            mapID: map,
            object: SpatialObject(
                id: id, semanticLabel: "chair",
                position: position.value, bounds: bounds(x: x), certainty: .confirmed,
                confidence: ConfidenceVector(
                    semantic: .one, geometry: .one, tracking: .one,
                    place: .one, identity: .one, objectState: .one, relation: .one),
                firstSeenAt: 40, lastSeenAt: time, displayName: "내 의자"), position: position)
    }
    private func promotion(times: [Double], x: [Double]) throws -> ObjectReidentificationPromotionEvidence {
        try ObjectReidentificationPromotionEvidence(
            observations: zip(times, x).map { time, x in
                try ObjectPromotionObservation(
                    observationID: ObservationID(), frameID: FrameID(),
                    semanticLabel: "chair", coordinateFrameID: frame, captureSegmentID: segment, mapID: map,
                    boundingBox: NormalizedBoundingBox2D(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                    position: position(at: time, x: x), bounds: bounds(x: x),
                    semanticConfidence: .one, geometryConfidence: .one)
            })
    }
    private func samples(_ evidence: ObjectReidentificationPromotionEvidence) throws
        -> [ContinuousObjectTrackingSample]
    {
        try evidence.observations.enumerated().map { index, item in
            ContinuousObjectTrackingSample(
                frameID: item.frameID, position: item.position,
                captureSegmentID: segment, monotonicTimestamp: item.position.observedAt,
                trackerConfidence: index == 0 ? nil : .one, associationMargin: 1,
                bounds: try bounds(x: item.position.value.x), geometryConfidence: .one)
        }
    }
}
