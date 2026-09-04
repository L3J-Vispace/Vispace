import XCTest

@testable import VispaceCore

final class SpatialDeltaReducerTests: XCTestCase {
    func testProvisionalObjectIsIsolatedFromConfirmedView() throws {
        let candidate = makeObject(
            id: objectID(1),
            certainty: .provisional,
            confidence: vector(identity: 0.6, objectState: 0.7)
        )
        var reducer = SpatialDeltaReducer()

        XCTAssertEqual(
            try reducer.apply(
                SpatialDelta(id: deltaID(1), baseRevision: 0, events: [.upsert(candidate)])
            ),
            .applied(newRevision: 1)
        )
        XCTAssertNil(reducer.snapshot.confirmedObjects[candidate.id])
        XCTAssertEqual(reducer.snapshot.provisionalObjects[candidate.id], candidate)
    }

    func testInsufficientConfidenceCannotEnterConfirmedView() {
        let unsafe = makeObject(
            id: objectID(1),
            confidence: vector(identity: 0.79, objectState: 1)
        )
        var reducer = SpatialDeltaReducer()

        XCTAssertThrowsError(
            try reducer.apply(
                SpatialDelta(id: deltaID(1), baseRevision: 0, events: [.upsert(unsafe)])
            )
        ) { error in
            XCTAssertEqual(error as? SpatialReducerError, .insufficientConfidence(unsafe.id))
        }
        XCTAssertEqual(reducer.snapshot.revision, 0)
        XCTAssertTrue(reducer.snapshot.confirmedObjects.isEmpty)
        XCTAssertTrue(reducer.snapshot.eventHistory.isEmpty)
    }

    func testHighConfidenceUpsertPromotesExistingCandidate() throws {
        let id = objectID(1)
        let candidate = makeObject(
            id: id,
            certainty: .provisional,
            confidence: vector(identity: 0.6, objectState: 0.6)
        )
        let confirmed = makeObject(id: id)
        var reducer = SpatialDeltaReducer()
        _ = try reducer.apply(
            SpatialDelta(id: deltaID(1), baseRevision: 0, events: [.upsert(candidate)])
        )
        _ = try reducer.apply(
            SpatialDelta(id: deltaID(2), baseRevision: 1, events: [.upsert(confirmed)])
        )

        XCTAssertNil(reducer.snapshot.provisionalObjects[id])
        XCTAssertEqual(reducer.snapshot.confirmedObjects[id], confirmed)
    }

    func testDeltaReplayIsIdempotentEvenAfterRevisionAdvances() throws {
        let object = makeObject(id: objectID(1))
        let delta = SpatialDelta(
            id: deltaID(1),
            baseRevision: 0,
            events: [.upsert(object)]
        )
        var reducer = SpatialDeltaReducer()

        XCTAssertEqual(try reducer.apply(delta), .applied(newRevision: 1))
        XCTAssertEqual(
            try reducer.apply(delta),
            .alreadyApplied(currentRevision: 1)
        )
        XCTAssertEqual(reducer.snapshot.eventHistory.count, 1)
        XCTAssertEqual(reducer.snapshot.appliedDeltaIDs.count, 1)
    }

    func testRevisionConflictDoesNotMutateSnapshot() {
        let object = makeObject(id: objectID(1))
        var reducer = SpatialDeltaReducer()
        let delta = SpatialDelta(
            id: deltaID(1),
            baseRevision: 4,
            events: [.upsert(object)]
        )

        XCTAssertThrowsError(try reducer.apply(delta)) { error in
            XCTAssertEqual(
                error as? SpatialReducerError,
                .revisionConflict(expected: 0, actualBase: 4)
            )
        }
        XCTAssertEqual(reducer.snapshot.revision, 0)
        XCTAssertTrue(reducer.snapshot.confirmedObjects.isEmpty)
    }

    func testMultiEventDeltaRollsBackAtomically() {
        let candidate = makeObject(
            id: objectID(1),
            certainty: .provisional,
            confidence: vector(identity: 0.6, objectState: 0.6)
        )
        let invalidConfirmed = makeObject(
            id: objectID(2),
            confidence: vector(identity: 0.2, objectState: 1)
        )
        var reducer = SpatialDeltaReducer()
        let delta = SpatialDelta(
            id: deltaID(1),
            baseRevision: 0,
            events: [.upsert(candidate), .upsert(invalidConfirmed)]
        )

        XCTAssertThrowsError(try reducer.apply(delta))
        XCTAssertEqual(reducer.snapshot.revision, 0)
        XCTAssertTrue(reducer.snapshot.provisionalObjects.isEmpty)
        XCTAssertTrue(reducer.snapshot.eventHistory.isEmpty)
    }

    func testLowConfidenceObservationCannotMoveConfirmedObject() throws {
        let object = makeObject(id: objectID(1), position: vec(0))
        var reducer = SpatialDeltaReducer()
        _ = try reducer.apply(
            SpatialDelta(id: deltaID(1), baseRevision: 0, events: [.upsert(object)])
        )
        let unsafeObservation = ObjectEvent.observed(
            objectID: object.id,
            at: 3,
            position: vec(10),
            bounds: nil,
            confidence: vector(identity: 0.6, objectState: 0.9)
        )

        XCTAssertThrowsError(
            try reducer.apply(
                SpatialDelta(id: deltaID(2), baseRevision: 1, events: [unsafeObservation])
            )
        )
        XCTAssertEqual(reducer.snapshot.revision, 1)
        XCTAssertEqual(reducer.snapshot.confirmedObjects[object.id]?.position, vec(0))
    }

    func testMovementRequiresMatchingOriginAndHighConfidence() throws {
        let object = makeObject(id: objectID(1), position: vec(0))
        var reducer = SpatialDeltaReducer()
        _ = try reducer.apply(
            SpatialDelta(id: deltaID(1), baseRevision: 0, events: [.upsert(object)])
        )

        let wrongOrigin = ObjectEvent.moved(
            objectID: object.id,
            from: vec(2),
            to: vec(3),
            at: 3,
            confidence: score(0.9)
        )
        XCTAssertThrowsError(
            try reducer.apply(
                SpatialDelta(id: deltaID(2), baseRevision: 1, events: [wrongOrigin])
            )
        ) { error in
            XCTAssertEqual(error as? SpatialReducerError, .movementOriginMismatch(object.id))
        }
        XCTAssertEqual(reducer.snapshot.confirmedObjects[object.id]?.position, vec(0))

        let validMove = ObjectEvent.moved(
            objectID: object.id,
            from: vec(0.049),
            to: vec(3),
            at: 3,
            confidence: score(0.8)
        )
        XCTAssertNoThrow(
            try reducer.apply(
                SpatialDelta(id: deltaID(3), baseRevision: 1, events: [validMove])
            )
        )
        XCTAssertEqual(reducer.snapshot.confirmedObjects[object.id]?.position, vec(3))
    }

    func testRemovedObjectCannotBecomeVisibleAgain() throws {
        let object = makeObject(id: objectID(1))
        var reducer = SpatialDeltaReducer()
        _ = try reducer.apply(
            SpatialDelta(id: deltaID(1), baseRevision: 0, events: [.upsert(object)])
        )
        _ = try reducer.apply(
            SpatialDelta(
                id: deltaID(2),
                baseRevision: 1,
                events: [.removed(objectID: object.id, at: 3, confidence: score(0.9))]
            )
        )
        let observation = ObjectEvent.observed(
            objectID: object.id,
            at: 4,
            position: vec(1),
            bounds: nil,
            confidence: vector()
        )

        XCTAssertThrowsError(
            try reducer.apply(
                SpatialDelta(id: deltaID(3), baseRevision: 2, events: [observation])
            )
        ) { error in
            XCTAssertEqual(error as? SpatialReducerError, .invalidStateTransition(object.id))
        }
        XCTAssertEqual(reducer.snapshot.confirmedObjects[object.id]?.presence, .removed)
    }

    func testOutOfOrderEventIsRejected() throws {
        let object = makeObject(id: objectID(1), lastSeenAt: 10)
        var reducer = SpatialDeltaReducer()
        _ = try reducer.apply(
            SpatialDelta(id: deltaID(1), baseRevision: 0, events: [.upsert(object)])
        )
        XCTAssertThrowsError(
            try reducer.apply(
                SpatialDelta(
                    id: deltaID(2),
                    baseRevision: 1,
                    events: [.becameNotVisible(objectID: object.id, at: 9)]
                )
            )
        ) { error in
            XCTAssertEqual(error as? SpatialReducerError, .outOfOrderEvent(object.id))
        }
    }

    func testPresenceTransitionsCannotSkipNotVisibleState() throws {
        let object = makeObject(id: objectID(1))
        var reducer = SpatialDeltaReducer()
        _ = try reducer.apply(
            SpatialDelta(id: deltaID(1), baseRevision: 0, events: [.upsert(object)])
        )

        XCTAssertThrowsError(
            try reducer.apply(
                SpatialDelta(
                    id: deltaID(2),
                    baseRevision: 1,
                    events: [.becameLastSeen(objectID: object.id, at: 3)]
                )
            )
        ) { error in
            XCTAssertEqual(error as? SpatialReducerError, .invalidStateTransition(object.id))
        }

        _ = try reducer.apply(
            SpatialDelta(
                id: deltaID(3),
                baseRevision: 1,
                events: [.becameNotVisible(objectID: object.id, at: 3)]
            )
        )
        _ = try reducer.apply(
            SpatialDelta(
                id: deltaID(4),
                baseRevision: 2,
                events: [.becameLastSeen(objectID: object.id, at: 4)]
            )
        )
        XCTAssertEqual(reducer.snapshot.confirmedObjects[object.id]?.presence, .lastSeen)
        XCTAssertEqual(reducer.snapshot.confirmedObjects[object.id]?.lastSeenAt, 2)
        XCTAssertEqual(reducer.snapshot.confirmedObjects[object.id]?.stateUpdatedAt, 4)
    }

    func testRestoredSnapshotValidatesCertaintyPartitionsAndConfidence() throws {
        let candidate = makeObject(
            id: objectID(1),
            certainty: .provisional,
            confidence: vector(identity: 0.6, objectState: 0.6)
        )
        XCTAssertThrowsError(
            try SpatialSnapshot(
                validatingRevision: 1,
                confirmedObjects: [candidate.id: candidate],
                provisionalObjects: [:],
                eventHistory: [],
                appliedDeltaIDs: []
            )
        ) { error in
            XCTAssertEqual(error as? SpatialReducerError, .snapshotCertaintyMismatch(candidate.id))
        }

        let lowConfidenceConfirmed = makeObject(
            id: objectID(2),
            confidence: vector(identity: 0.7, objectState: 0.9)
        )
        let snapshot = try SpatialSnapshot(
            validatingRevision: 1,
            confirmedObjects: [lowConfidenceConfirmed.id: lowConfidenceConfirmed],
            provisionalObjects: [:],
            eventHistory: [],
            appliedDeltaIDs: []
        )
        XCTAssertThrowsError(try SpatialDeltaReducer(validating: snapshot)) { error in
            XCTAssertEqual(
                error as? SpatialReducerError,
                .invalidConfirmedSnapshotConfidence(lowConfidenceConfirmed.id)
            )
        }
    }

    func testValidSnapshotCodableRoundTrip() throws {
        let object = makeObject(id: objectID(1))
        let snapshot = try SpatialSnapshot(
            validatingRevision: 7,
            confirmedObjects: [object.id: object],
            provisionalObjects: [:],
            eventHistory: [.upsert(object)],
            appliedDeltaIDs: [deltaID(1)]
        )
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(SpatialSnapshot.self, from: data)
        XCTAssertEqual(restored, snapshot)
        XCTAssertNoThrow(try SpatialDeltaReducer(validating: restored))
    }
}
