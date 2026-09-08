import Foundation
import VispaceCore
import XCTest

@testable import Vispace

final class PlaceMemoryRepositoryTests: XCTestCase {
    func testAcknowledgedMutationsRetireDurablyWithoutPermittingStaleReplay() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = PlaceMemoryRepository(directoryURL: root, maximumAssociationStates: 1)
        let completed = try PlaceAssociationStateRecord(
            context: PlaceAssociationContext(sourceMapID: nil, sourceCoordinateFrameID: coordinateFrameID(1)),
            observations: [observation(index: 0), observation(index: 1)],
            createdAt: 1, updatedAt: 3
        )
        XCTAssertEqual(completed.latestDecision.mutation, .createNewMap)
        try await repository.upsertAssociationState(completed)
        let incoming = try deferredState(index: 2, createdAt: 20, count: 1)
        await assertThrowsPlaceMemoryError(
            { try await repository.upsertAssociationState(incoming, retention: .retireCompletedAttempts) },
            equals: .associationStateCapacityReached(maximum: 1)
        )
        await assertThrowsPlaceMemoryError(
            { try await repository.acknowledgeAssociationMutation(id: completed.id, revision: completed.revision - 1) },
            equals: .invalidMutationAcknowledgement(id: completed.id)
        )
        try await repository.acknowledgeAssociationMutation(id: completed.id, revision: completed.revision)
        try await repository.acknowledgeAssociationMutation(id: completed.id, revision: completed.revision)
        let restarted = PlaceMemoryRepository(directoryURL: root, maximumAssociationStates: 1)
        try await restarted.upsertAssociationState(incoming, retention: .retireCompletedAttempts)
        let catalog = try await restarted.catalogSnapshot()
        XCTAssertEqual(catalog.associationStates, [incoming])
        XCTAssertTrue(catalog.acknowledgedMutationRevisions.isEmpty)
        await assertThrowsPlaceMemoryError(
            { try await restarted.upsertAssociationState(completed, retention: .retireCompletedAttempts) },
            equals: .retiredAssociationState(id: completed.id)
        )
    }

    func testDeletingOnePlaceFreesFingerprintCapacityAndPreservesOtherPlace() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = PlaceMemoryRepository(directoryURL: root, maximumFingerprints: 2)
        let first = try fingerprintRecord(index: 1, updatedAt: 2)
        let second = try fingerprintRecord(index: 2, updatedAt: 3)
        try await repository.upsertFingerprint(first)
        try await repository.upsertFingerprint(second)
        try await repository.deleteMap(mapID: first.mapID)
        let records = try await repository.listFingerprints()
        XCTAssertEqual(records, [second])
        try await repository.upsertFingerprint(fingerprintRecord(index: 3, updatedAt: 4))
    }
    func testFingerprintRoundTripIsDeterministicAndPrivacyBounded() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = PlaceMemoryRepository(directoryURL: root)
        let later = try fingerprintRecord(index: 2, updatedAt: 4)
        let earlier = try fingerprintRecord(index: 1, updatedAt: 3)

        try await repository.upsertFingerprint(later)
        try await repository.upsertFingerprint(earlier)
        try assertSpatialDirectoryPolicy(at: root)

        let listed = try await repository.listFingerprints()
        let loaded = try await repository.loadFingerprint(mapID: earlier.mapID)
        XCTAssertEqual(listed, [earlier, later])
        XCTAssertEqual(loaded, earlier)

        let data = try Data(
            contentsOf: root.appendingPathComponent(PlaceMemoryRepository.catalogFileName)
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("image"))
        XCTAssertFalse(text.contains("pixel"))
        XCTAssertFalse(text.contains("featurePoint"))
        XCTAssertFalse(text.contains("meshVertices"))
    }

    func testFingerprintRejectsStaleAndCoordinateFrameConflicts() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = PlaceMemoryRepository(directoryURL: root)
        let original = try fingerprintRecord(index: 1, updatedAt: 3)
        try await repository.upsertFingerprint(original)

        let stale = try PlaceFingerprintRecord(
            mapID: original.mapID,
            coordinateFrameID: original.coordinateFrameID,
            fingerprint: testFingerprint(objectCount: 3),
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        await assertThrowsPlaceMemoryError(
            { try await repository.upsertFingerprint(stale) },
            equals: .staleFingerprintUpdate(mapID: original.mapID)
        )

        let conflicting = try PlaceFingerprintRecord(
            mapID: original.mapID,
            coordinateFrameID: coordinateFrameID(99),
            fingerprint: testFingerprint(objectCount: 4),
            createdAt: original.createdAt,
            updatedAt: 4
        )
        await assertThrowsPlaceMemoryError(
            { try await repository.upsertFingerprint(conflicting) },
            equals: .mapCoordinateFrameConflict(mapID: original.mapID)
        )
        let persisted = try await repository.loadFingerprint(mapID: original.mapID)
        XCTAssertEqual(persisted, original)
    }

    func testAssociationStateReplaysAndExtendsWithoutRewritingHistory() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = PlaceMemoryRepository(directoryURL: root)
        let stateID = PlaceAssociationStateID(rawValue: testUUID(40))
        let context = PlaceAssociationContext(
            sourceMapID: nil,
            sourceCoordinateFrameID: coordinateFrameID(1)
        )
        let firstObservation = observation(index: 0)
        let first = try PlaceAssociationStateRecord(
            id: stateID,
            context: context,
            observations: [firstObservation],
            createdAt: 1,
            updatedAt: 2
        )
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.latestDecision.outcome, .ambiguous)
        try await repository.upsertAssociationState(first)

        let second = try PlaceAssociationStateRecord(
            id: stateID,
            context: context,
            observations: [observation(index: 1), firstObservation],
            createdAt: 1,
            updatedAt: 3
        )
        XCTAssertEqual(second.observations, [firstObservation, observation(index: 1)])
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(second.latestDecision.outcome, .new)
        XCTAssertEqual(second.latestDecision.mutation, .createNewMap)
        try await repository.upsertAssociationState(second)

        let loaded = try await repository.loadAssociationState(id: stateID)
        let listed = try await repository.listAssociationStates()
        XCTAssertEqual(loaded, second)
        XCTAssertEqual(listed, [second])
    }

    func testAssociationStateRejectsDivergentHistoryAtomically() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = PlaceMemoryRepository(directoryURL: root)
        let stateID = PlaceAssociationStateID(rawValue: testUUID(40))
        let context = PlaceAssociationContext(
            sourceMapID: nil,
            sourceCoordinateFrameID: coordinateFrameID(1)
        )
        let first = try PlaceAssociationStateRecord(
            id: stateID,
            context: context,
            observations: [observation(index: 0)],
            createdAt: 1,
            updatedAt: 2
        )
        try await repository.upsertAssociationState(first)

        let divergentFirst = PlaceAssociationObservation(
            id: observationID(99),
            baseRevision: 0,
            sequence: 1,
            candidates: []
        )
        let divergent = try PlaceAssociationStateRecord(
            id: stateID,
            context: context,
            observations: [divergentFirst, observation(index: 1)],
            createdAt: 1,
            updatedAt: 3
        )
        await assertThrowsPlaceMemoryError(
            { try await repository.upsertAssociationState(divergent) },
            equals: .associationHistoryDiverged(id: stateID)
        )
        let persisted = try await repository.loadAssociationState(id: stateID)
        XCTAssertEqual(persisted, first)
    }

    func testTamperedAssociationSummaryIsQuarantinedInsteadOfTrusted() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = PlaceMemoryRepository(directoryURL: root)
        let state = try PlaceAssociationStateRecord(
            id: PlaceAssociationStateID(rawValue: testUUID(40)),
            context: PlaceAssociationContext(
                sourceMapID: nil,
                sourceCoordinateFrameID: coordinateFrameID(1)
            ),
            observations: [observation(index: 0)],
            createdAt: 1,
            updatedAt: 2
        )
        try await repository.upsertAssociationState(state)
        let catalogURL = root.appendingPathComponent(PlaceMemoryRepository.catalogFileName)
        var text = try XCTUnwrap(String(data: Data(contentsOf: catalogURL), encoding: .utf8))
        text = text.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":7")
        try Data(text.utf8).write(to: catalogURL, options: .atomic)

        let snapshot = try await repository.catalogSnapshot()

        XCTAssertTrue(snapshot.associationStates.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))
        let quarantine = root.appendingPathComponent("Quarantine", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files.filter { $0.pathExtension == "quarantined" }.count, 1)
    }

    func testMalformedCatalogIsQuarantinedAndCapacityIsBounded() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalogURL = root.appendingPathComponent(PlaceMemoryRepository.catalogFileName)
        try Data("not-json".utf8).write(to: catalogURL)
        let repository = PlaceMemoryRepository(
            directoryURL: root,
            maximumFingerprints: 1,
            maximumAssociationStates: 1
        )

        let recovered = try await repository.catalogSnapshot()
        XCTAssertTrue(recovered.fingerprints.isEmpty)
        let first = try fingerprintRecord(index: 1, updatedAt: 2)
        try await repository.upsertFingerprint(first)
        let second = try fingerprintRecord(index: 2, updatedAt: 3)
        await assertThrowsPlaceMemoryError(
            { try await repository.upsertFingerprint(second) },
            equals: .fingerprintCapacityReached(maximum: 1)
        )
        let persisted = try await repository.listFingerprints()
        XCTAssertEqual(persisted, [first])
    }

    func testCancelledUpsertDoesNotPublishCatalog() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = PlaceMemoryRepository(directoryURL: root)
        let record = try fingerprintRecord(index: 1, updatedAt: 2)
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            try await repository.upsertFingerprint(record)
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    PlaceMemoryRepository.catalogFileName
                ).path
            )
        )
    }

    func testDeferredHistoryRotationStaysBoundedAndRetiredWritesCannotResurrect() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = PlaceMemoryRepository(directoryURL: root, maximumAssociationStates: 2)
        var states: [PlaceAssociationStateRecord] = []
        for index in 0..<5 {
            let state = try deferredState(
                index: index, createdAt: Double(index + 1) * 100,
                count: index == 4 ? 1 : 64)
            states.append(state)
            try await repository.upsertAssociationState(state, retention: .retireOlderDeferredAttempts)
            let catalog = try await repository.catalogSnapshot()
            XCTAssertLessThanOrEqual(catalog.associationStates.count, 2)
            XCTAssertTrue(catalog.associationStates.contains(state))
        }
        let restarted = PlaceMemoryRepository(directoryURL: root, maximumAssociationStates: 2)
        let catalog = try await restarted.catalogSnapshot()
        XCTAssertEqual(Set(catalog.associationStates.map(\.id)), Set(states.suffix(2).map(\.id)))
        XCTAssertEqual(catalog.retiredAssociationCreatedAtThrough, states[2].createdAt)
        let url = root.appendingPathComponent(PlaceMemoryRepository.catalogFileName)
        let before = try Data(contentsOf: url)
        await assertThrowsPlaceMemoryError(
            {
                try await restarted.upsertAssociationState(states[0], retention: .retireOlderDeferredAttempts)
            },
            equals: .retiredAssociationState(id: states[0].id)
        )
        XCTAssertEqual(try Data(contentsOf: url), before)

        // Retained attempts still support exact retries and append-only work.
        try await restarted.upsertAssociationState(states[4], retention: .retireOlderDeferredAttempts)
        XCTAssertEqual(try Data(contentsOf: url), before)
        let extended = try deferredState(index: 4, createdAt: 500, count: 2)
        try await restarted.upsertAssociationState(extended, retention: .retireOlderDeferredAttempts)
        await assertThrowsPlaceMemoryError(
            {
                try await restarted.upsertAssociationState(states[4], retention: .retireOlderDeferredAttempts)
            },
            equals: .staleAssociationStateUpdate(id: states[4].id)
        )
        let loaded = try await restarted.loadAssociationState(id: extended.id)
        XCTAssertEqual(loaded, extended)
    }

    func testRetentionRequiresOptInAndStrictlyNewerAttempt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = PlaceMemoryRepository(directoryURL: root, maximumAssociationStates: 1)
        let original = try deferredState(index: 1, createdAt: 10, count: 1)
        let newer = try deferredState(index: 2, createdAt: 20, count: 1)
        try await repository.upsertAssociationState(original)
        await assertThrowsPlaceMemoryError(
            { try await repository.upsertAssociationState(newer) },
            equals: .associationStateCapacityReached(maximum: 1)
        )
        let older = try deferredState(index: 3, createdAt: 9, count: 1)
        await assertThrowsPlaceMemoryError(
            { try await repository.upsertAssociationState(older, retention: .retireOlderDeferredAttempts) },
            equals: .associationStateCapacityReached(maximum: 1)
        )
        let retained = try await repository.listAssociationStates()
        XCTAssertEqual(retained, [original])
    }

    func testRetentionPinsHistoricalMutationEvenWhenLatestDecisionIsDeferred() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = PlaceMemoryRepository(directoryURL: root, maximumAssociationStates: 1)
        let deferred = try deferredState(index: 1, createdAt: 10, count: 3)
        let pending = try PlaceAssociationStateRecord(
            id: deferred.id, context: deferred.context,
            observations: [observation(index: 0), observation(index: 1), deferred.observations[2]],
            createdAt: 10, updatedAt: 13
        )
        XCTAssertEqual(pending.latestDecision.mutation, .deferDecision)
        try await repository.upsertAssociationState(pending)
        let url = root.appendingPathComponent(PlaceMemoryRepository.catalogFileName)
        let before = try Data(contentsOf: url)
        let incoming = try deferredState(index: 2, createdAt: 20, count: 1)
        await assertThrowsPlaceMemoryError(
            {
                try await repository.upsertAssociationState(incoming, retention: .retireOlderDeferredAttempts)
            },
            equals: .associationStateCapacityReached(maximum: 1)
        )
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testCancelledRetentionCannotEvictHistory() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = PlaceMemoryRepository(directoryURL: root, maximumAssociationStates: 1)
        let original = try deferredState(index: 1, createdAt: 10, count: 1)
        let incoming = try deferredState(index: 2, createdAt: 20, count: 1)
        try await repository.upsertAssociationState(original)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            try await repository.upsertAssociationState(incoming, retention: .retireOlderDeferredAttempts)
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let catalog = try await repository.catalogSnapshot()
        XCTAssertEqual(catalog.associationStates, [original])
        XCTAssertNil(catalog.retiredAssociationCreatedAtThrough)
    }

    func testLegacyCatalogAndRetentionWatermarkValidation() throws {
        let legacy = Data("{\"schemaVersion\":1,\"fingerprints\":[],\"associationStates\":[]}".utf8)
        let decoded = try JSONDecoder().decode(PlaceMemoryCatalogSnapshot.self, from: legacy)
        XCTAssertNil(decoded.retiredAssociationCreatedAtThrough)
        for invalid in [-1.0, .infinity, .nan] {
            XCTAssertThrowsError(try PlaceMemoryCatalogSnapshot(retiredAssociationCreatedAtThrough: invalid))
        }
        let catalog = try PlaceMemoryCatalogSnapshot(retiredAssociationCreatedAtThrough: 20)
        XCTAssertEqual(
            try JSONDecoder().decode(
                PlaceMemoryCatalogSnapshot.self, from: JSONEncoder().encode(catalog)
            ), catalog)
    }

    private func deferredState(index: Int, createdAt: TimeInterval, count: Int) throws
        -> PlaceAssociationStateRecord
    {
        let candidate = PlaceMapCandidateEvidence(
            mapID: mapID(99), coordinateFrameID: coordinateFrameID(99),
            placeEvidence: PlaceEvidence(
                visual: .one, geometry: .one, structure: .one,
                poseConsistency: .one, objectLayout: .one, spatialOverlap: .one
            ), coordinateCompatibility: .unresolved
        )
        return try PlaceAssociationStateRecord(
            id: PlaceAssociationStateID(rawValue: testUUID(10_000 + index)),
            context: PlaceAssociationContext(sourceMapID: nil, sourceCoordinateFrameID: coordinateFrameID(1)),
            observations: (0..<count).map { offset in
                PlaceAssociationObservation(
                    id: observationID(20_000 + index * 100 + offset),
                    baseRevision: UInt64(offset), sequence: UInt64(offset + 1), candidates: [candidate]
                )
            }, createdAt: createdAt, updatedAt: createdAt + Double(count)
        )
    }

    private func fingerprintRecord(index: Int, updatedAt: TimeInterval) throws
        -> PlaceFingerprintRecord
    {
        try PlaceFingerprintRecord(
            mapID: mapID(index),
            coordinateFrameID: coordinateFrameID(index),
            fingerprint: testFingerprint(objectCount: index),
            createdAt: 1,
            updatedAt: updatedAt
        )
    }

    private func testFingerprint(objectCount: Int) throws -> PlaceFingerprint {
        try PlaceFingerprint(
            coarseExtent: CoarsePlaceExtent(
                widthMeters: 4,
                heightMeters: 2.5,
                depthMeters: 5
            ),
            observedObjectCount: objectCount
        )
    }

    private func observation(index: Int) -> PlaceAssociationObservation {
        PlaceAssociationObservation(
            id: observationID(index + 1),
            baseRevision: UInt64(index),
            sequence: UInt64(index + 1),
            candidates: []
        )
    }

    private func mapID(_ value: Int) -> MapID {
        MapID(rawValue: testUUID(value))
    }

    private func coordinateFrameID(_ value: Int) -> CoordinateFrameID {
        CoordinateFrameID(rawValue: testUUID(1_000 + value))
    }

    private func observationID(_ value: Int) -> ObservationID {
        ObservationID(rawValue: testUUID(2_000 + value))
    }

    private func testUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vispace-place-memory-tests-\(UUID().uuidString)")
    }
}

private func assertThrowsPlaceMemoryError<T>(
    _ expression: () async throws -> T,
    equals expected: PlaceMemoryRepositoryError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? PlaceMemoryRepositoryError, expected, file: file, line: line)
    }
}
