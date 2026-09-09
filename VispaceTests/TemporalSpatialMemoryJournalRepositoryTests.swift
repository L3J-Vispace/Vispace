import VispaceCore
import XCTest

@testable import Vispace

final class TemporalSpatialMemoryJournalRepositoryTests: XCTestCase {
    func testLegacyVersionThreeWithoutReclamationIntentsMigratesOnNextCommit() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = temporalTestPolicy(), mapID = temporalTestMapID(81), frameID = temporalTestFrameID(81)
        var coordinator = TemporalSpatialMemoryCoordinator(mapID: mapID, coordinateFrameID: frameID, policy: policy)
        let first = try temporalTestJournalMaterial(coordinator: &coordinator, sequence: 1, timestamp: 100, idNumber: 81)
        let second = try temporalTestJournalMaterial(coordinator: &coordinator, sequence: 2, timestamp: 101, idNumber: 82)
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        _ = try await repository.append(first.entry, policy: policy, previousSnapshot: first.previous, resultingSnapshot: first.resulting)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL(in: root))) as? [String: Any])
        document["schemaVersion"] = 3
        var journals = try XCTUnwrap(document["journals"] as? [[String: Any]])
        for index in journals.indices { journals[index].removeValue(forKey: "pendingRemovedObjects") }
        document["journals"] = journals
        try JSONSerialization.data(withJSONObject: document).write(to: catalogURL(in: root))
        let restarted = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let recovery = try await restarted.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertEqual(recovery?.snapshot, first.resulting)
        XCTAssertEqual(recovery?.pendingRemovedObjects, [])
        _ = try await restarted.append(second.entry, policy: policy,
            previousSnapshot: second.previous, resultingSnapshot: second.resulting)
        let upgraded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL(in: root))) as? [String: Any])
        XCTAssertEqual(upgraded["schemaVersion"] as? Int, 4)
    }

    func testFutureVersionFiveIsPreservedByReadAndPerPlaceDeletion() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try SpatialStorageDirectory.prepare(at: root)
        let bytes = Data(#"{"schemaVersion":5,"journals":[]}"#.utf8)
        try bytes.write(to: catalogURL(in: root))
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        do {
            _ = try await repository.catalogSnapshot()
            XCTFail("Future journal must not be decoded or quarantined")
        } catch { XCTAssertEqual(error as? SpatialStorageError, .unsupportedSchema(actual: 5)) }
        do {
            try await repository.deleteMap(mapID: temporalTestMapID(81))
            XCTFail("Per-place maintenance must preserve an unknown future journal")
        } catch { XCTAssertEqual(error as? SpatialStorageError, .unsupportedSchema(actual: 5)) }
        XCTAssertEqual(try Data(contentsOf: catalogURL(in: root)), bytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("quarantined") })
    }
    func testBytePressureCompactsBeforeEntryLimitAndExactRetrySurvivesRestart() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = temporalTestPolicy()
        let mapID = temporalTestMapID(71)
        let frameID = temporalTestFrameID(71)
        var coordinator = TemporalSpatialMemoryCoordinator(mapID: mapID, coordinateFrameID: frameID, policy: policy)
        let first = try temporalTestJournalMaterial(coordinator: &coordinator, sequence: 1, timestamp: 100, idNumber: 71)
        let second = try temporalTestJournalMaterial(coordinator: &coordinator, sequence: 2, timestamp: 101, idNumber: 72)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let compact = try TemporalSpatialMemoryJournalCatalog(journals: [
            TemporalSpatialMemoryJournalRecord(mapID: mapID, coordinateFrameID: frameID,
                policy: policy, checkpoint: second.resulting, entries: [])
        ])
        let expanded = try TemporalSpatialMemoryJournalCatalog(journals: [
            TemporalSpatialMemoryJournalRecord(mapID: mapID, coordinateFrameID: frameID,
                policy: policy, checkpoint: first.previous, entries: [first.entry, second.entry])
        ])
        let limit = try encoder.encode(compact).count + 64
        XCTAssertGreaterThan(try encoder.encode(expanded).count, limit)
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root, maximumCatalogBytes: limit)
        _ = try await repository.append(first.entry, policy: policy, previousSnapshot: first.previous, resultingSnapshot: first.resulting)
        _ = try await repository.append(second.entry, policy: policy, previousSnapshot: second.previous, resultingSnapshot: second.resulting)
        let restarted = TemporalSpatialMemoryJournalRepository(directoryURL: root, maximumCatalogBytes: limit)
        let recovered = try await restarted.recover(mapID: mapID, coordinateFrameID: frameID)
        XCTAssertEqual(recovered?.snapshot, second.resulting)
        XCTAssertEqual(recovered?.replayedEntryCount, 0)
        let before = try Data(contentsOf: catalogURL(in: root))
        XCTAssertLessThanOrEqual(before.count, limit)
        let retry = try await restarted.append(second.entry, policy: policy, previousSnapshot: second.previous, resultingSnapshot: second.resulting)
        XCTAssertEqual(retry, .alreadyAppended(second.resulting))
        XCTAssertEqual(try Data(contentsOf: catalogURL(in: root)), before)
    }

    func testUncompactableStateDoesNotReplaceDurableJournal() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = temporalTestPolicy()
        var coordinator = TemporalSpatialMemoryCoordinator(mapID: temporalTestMapID(73), coordinateFrameID: temporalTestFrameID(73), policy: policy)
        let first = try temporalTestJournalMaterial(coordinator: &coordinator, sequence: 1, timestamp: 100, idNumber: 73)
        let second = try temporalTestJournalMaterial(coordinator: &coordinator, sequence: 2, timestamp: 101, idNumber: 74)
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        _ = try await repository.append(first.entry, policy: policy, previousSnapshot: first.previous, resultingSnapshot: first.resulting)
        let before = try Data(contentsOf: catalogURL(in: root))
        let constrained = TemporalSpatialMemoryJournalRepository(directoryURL: root, maximumCatalogBytes: 1)
        do {
            _ = try await constrained.append(second.entry, policy: policy, previousSnapshot: second.previous, resultingSnapshot: second.resulting)
            XCTFail("An oversized current state must fail without replacing the previous journal")
        } catch let error as TemporalSpatialMemoryJournalError {
            guard case .catalogTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: catalogURL(in: root)), before)
    }

    func testCachedCatalogCannotResurrectAnExternallyDeletedFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = temporalTestPolicy()
        var coordinator = TemporalSpatialMemoryCoordinator(mapID: temporalTestMapID(75), coordinateFrameID: temporalTestFrameID(75), policy: policy)
        let material = try temporalTestJournalMaterial(coordinator: &coordinator, sequence: 1, timestamp: 100, idNumber: 75)
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        _ = try await repository.append(material.entry, policy: policy, previousSnapshot: material.previous, resultingSnapshot: material.resulting)
        _ = try await repository.catalogSnapshot()
        try FileManager.default.removeItem(at: catalogURL(in: root))
        let after = try await repository.catalogSnapshot()
        XCTAssertTrue(after.journals.isEmpty)
    }

    func testCaptureAuthorityIsRevalidatedImmediatelyBeforeDurableCommit() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = temporalTestPolicy()
        var coordinator = TemporalSpatialMemoryCoordinator(
            mapID: temporalTestMapID(44), coordinateFrameID: temporalTestFrameID(44), policy: policy
        )
        let material = try temporalTestJournalMaterial(
            coordinator: &coordinator, sequence: 1, timestamp: 100, idNumber: 44
        )
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let authority = TemporalCommitAuthorityGate()
        do {
            _ = try await repository.append(
                material.entry, policy: policy, previousSnapshot: material.previous,
                resultingSnapshot: material.resulting,
                validateBeforeCommit: { try authority.validateThenRevoke() }
            )
            XCTFail("Authority revoked after admission must prevent the durable commit")
        } catch {
            XCTAssertEqual(error as? TemporalSpatialMemoryServiceError, .captureAuthorityMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL(in: root).path))
        let empty = try await repository.catalogSnapshot()
        XCTAssertTrue(empty.journals.isEmpty)
    }

    func testRestartReplaysExactBoundedJournalWithoutRawFramePayloads() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(1)
        let frameID = temporalTestFrameID(1)
        let policy = temporalTestPolicy()
        var coordinator = TemporalSpatialMemoryCoordinator(
            mapID: mapID,
            coordinateFrameID: frameID,
            policy: policy
        )
        let first = try temporalTestJournalMaterial(
            coordinator: &coordinator,
            sequence: 1,
            timestamp: 100,
            idNumber: 1
        )
        let second = try temporalTestJournalMaterial(
            coordinator: &coordinator,
            sequence: 2,
            timestamp: 101,
            idNumber: 2
        )
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        _ = try await repository.append(
            first.entry,
            policy: policy,
            previousSnapshot: first.previous,
            resultingSnapshot: first.resulting
        )
        _ = try await repository.append(
            second.entry,
            policy: policy,
            previousSnapshot: second.previous,
            resultingSnapshot: second.resulting
        )
        try assertSpatialDirectoryPolicy(at: root)

        let restarted = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let recoveredJournal = try await restarted.recover(
            mapID: mapID,
            coordinateFrameID: frameID
        )
        let recovery = try XCTUnwrap(recoveredJournal)
        XCTAssertEqual(recovery.snapshot, coordinator.snapshot)
        XCTAssertEqual(recovery.replayedEntryCount, 2)
        XCTAssertEqual(recovery.policy, policy)

        let bytes = try Data(contentsOf: catalogURL(in: root))
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("capturedImage"))
        XCTAssertFalse(text.contains("depthMeters"))
        XCTAssertFalse(text.contains("cameraIntrinsics"))
        XCTAssertTrue(text.contains("cameraTransform"))
        XCTAssertTrue(text.contains("coordinateFrameID"))
    }

    func testExactAppendRetryIsIdempotentAndDoesNotRewriteCatalog() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = temporalTestPolicy()
        var coordinator = TemporalSpatialMemoryCoordinator(
            mapID: temporalTestMapID(2),
            coordinateFrameID: temporalTestFrameID(2),
            policy: policy
        )
        let material = try temporalTestJournalMaterial(
            coordinator: &coordinator,
            sequence: 1,
            timestamp: 100,
            idNumber: 3
        )
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let firstAppend = try await repository.append(
            material.entry,
            policy: policy,
            previousSnapshot: material.previous,
            resultingSnapshot: material.resulting
        )
        XCTAssertEqual(firstAppend, .appended(material.resulting))
        let firstBytes = try Data(contentsOf: catalogURL(in: root))
        let retryAppend = try await repository.append(
            material.entry,
            policy: policy,
            previousSnapshot: material.previous,
            resultingSnapshot: material.resulting
        )
        XCTAssertEqual(retryAppend, .alreadyAppended(material.resulting))
        XCTAssertEqual(try Data(contentsOf: catalogURL(in: root)), firstBytes)
    }

    func testJournalCompactsToCheckpointAtConfiguredEntryBound() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(3)
        let frameID = temporalTestFrameID(3)
        let policy = temporalTestPolicy()
        var coordinator = TemporalSpatialMemoryCoordinator(
            mapID: mapID,
            coordinateFrameID: frameID,
            policy: policy
        )
        let repository = TemporalSpatialMemoryJournalRepository(
            directoryURL: root,
            maximumEntriesPerJournal: 1
        )
        let first = try temporalTestJournalMaterial(
            coordinator: &coordinator,
            sequence: 1,
            timestamp: 100,
            idNumber: 4
        )
        _ = try await repository.append(
            first.entry,
            policy: policy,
            previousSnapshot: first.previous,
            resultingSnapshot: first.resulting
        )
        let second = try temporalTestJournalMaterial(
            coordinator: &coordinator,
            sequence: 2,
            timestamp: 101,
            idNumber: 5
        )
        _ = try await repository.append(
            second.entry,
            policy: policy,
            previousSnapshot: second.previous,
            resultingSnapshot: second.resulting
        )

        let catalog = try await repository.catalogSnapshot()
        XCTAssertEqual(catalog.journals.count, 1)
        XCTAssertEqual(catalog.journals[0].entries.count, 0)
        XCTAssertEqual(catalog.journals[0].checkpoint, coordinator.snapshot)
        let recoveredJournal = try await repository.recover(
            mapID: mapID,
            coordinateFrameID: frameID
        )
        let recovery = try XCTUnwrap(recoveredJournal)
        XCTAssertEqual(recovery.snapshot, coordinator.snapshot)
        XCTAssertEqual(recovery.replayedEntryCount, 0)
    }

    func testJournalCountCapacityRejectsSecondMapAtomically() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = temporalTestPolicy()
        let repository = TemporalSpatialMemoryJournalRepository(
            directoryURL: root,
            maximumJournalCount: 1
        )
        var firstCoordinator = TemporalSpatialMemoryCoordinator(
            mapID: temporalTestMapID(4),
            coordinateFrameID: temporalTestFrameID(4),
            policy: policy
        )
        let first = try temporalTestJournalMaterial(
            coordinator: &firstCoordinator,
            sequence: 1,
            timestamp: 100,
            idNumber: 6
        )
        _ = try await repository.append(
            first.entry,
            policy: policy,
            previousSnapshot: first.previous,
            resultingSnapshot: first.resulting
        )
        let before = try Data(contentsOf: catalogURL(in: root))

        var secondCoordinator = TemporalSpatialMemoryCoordinator(
            mapID: temporalTestMapID(5),
            coordinateFrameID: temporalTestFrameID(5),
            policy: policy
        )
        let second = try temporalTestJournalMaterial(
            coordinator: &secondCoordinator,
            sequence: 1,
            timestamp: 100,
            idNumber: 7
        )
        await assertThrowsJournalError(
            {
                try await repository.append(
                    second.entry,
                    policy: policy,
                    previousSnapshot: second.previous,
                    resultingSnapshot: second.resulting
                )
            },
            equals: .journalCapacityReached(maximum: 1)
        )
        XCTAssertEqual(try Data(contentsOf: catalogURL(in: root)), before)
    }

    func testDivergentPreviousSnapshotAndFrameBindingFailClosed() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(6)
        let frameID = temporalTestFrameID(6)
        let policy = temporalTestPolicy()
        var coordinator = TemporalSpatialMemoryCoordinator(
            mapID: mapID,
            coordinateFrameID: frameID,
            policy: policy
        )
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let first = try temporalTestJournalMaterial(
            coordinator: &coordinator,
            sequence: 1,
            timestamp: 100,
            idNumber: 8
        )
        _ = try await repository.append(
            first.entry,
            policy: policy,
            previousSnapshot: first.previous,
            resultingSnapshot: first.resulting
        )
        let second = try temporalTestJournalMaterial(
            coordinator: &coordinator,
            sequence: 2,
            timestamp: 101,
            idNumber: 9
        )
        await assertThrowsJournalError(
            {
                try await repository.append(
                    second.entry,
                    policy: policy,
                    previousSnapshot: first.previous,
                    resultingSnapshot: second.resulting
                )
            },
            equals: .journalDiverged(mapID: mapID)
        )
        await assertThrowsJournalError(
            {
                try await repository.recover(
                    mapID: mapID,
                    coordinateFrameID: temporalTestFrameID(99)
                )
            },
            equals: .mapCoordinateFrameConflict(mapID: mapID)
        )
    }

    func testMalformedAndOutOfOrderCatalogsAreQuarantined() async throws {
        let malformedRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: malformedRoot) }
        try FileManager.default.createDirectory(
            at: malformedRoot,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: catalogURL(in: malformedRoot))
        let malformedRepository = TemporalSpatialMemoryJournalRepository(
            directoryURL: malformedRoot
        )
        let malformedCatalog = try await malformedRepository.catalogSnapshot()
        XCTAssertTrue(malformedCatalog.journals.isEmpty)
        try assertQuarantinedCatalog(in: malformedRoot)

        let reorderedRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: reorderedRoot) }
        let mapID = temporalTestMapID(7)
        let frameID = temporalTestFrameID(7)
        let policy = temporalTestPolicy()
        var coordinator = TemporalSpatialMemoryCoordinator(
            mapID: mapID,
            coordinateFrameID: frameID,
            policy: policy
        )
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: reorderedRoot)
        for (sequence, timestamp, id) in [(UInt64(1), 100.0, 10), (2, 101, 11)] {
            let material = try temporalTestJournalMaterial(
                coordinator: &coordinator,
                sequence: sequence,
                timestamp: timestamp,
                idNumber: id
            )
            _ = try await repository.append(
                material.entry,
                policy: policy,
                previousSnapshot: material.previous,
                resultingSnapshot: material.resulting
            )
        }
        let url = catalogURL(in: reorderedRoot)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        var journals = try XCTUnwrap(json["journals"] as? [[String: Any]])
        let entries = try XCTUnwrap(journals[0]["entries"] as? [Any])
        journals[0]["entries"] = Array(entries.reversed())
        json["journals"] = journals
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            .write(to: url, options: .atomic)

        let restarted = TemporalSpatialMemoryJournalRepository(directoryURL: reorderedRoot)
        let restartedCatalog = try await restarted.catalogSnapshot()
        XCTAssertTrue(restartedCatalog.journals.isEmpty)
        try assertQuarantinedCatalog(in: reorderedRoot)
    }

    func testCancelledAppendDoesNotPublishCatalog() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = temporalTestPolicy()
        var coordinator = TemporalSpatialMemoryCoordinator(
            mapID: temporalTestMapID(8),
            coordinateFrameID: temporalTestFrameID(8),
            policy: policy
        )
        let material = try temporalTestJournalMaterial(
            coordinator: &coordinator,
            sequence: 1,
            timestamp: 100,
            idNumber: 12
        )
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await repository.append(
                material.entry,
                policy: policy,
                previousSnapshot: material.previous,
                resultingSnapshot: material.resulting
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL(in: root).path))
    }

    func testScale512ObjectsAnd32UpdatesRecoverExactlyAndReportMeasurements() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapID = temporalTestMapID(91), frameID = temporalTestFrameID(91)
        let policy = TemporalSpatialMemoryPolicy.default
        let objects = (0..<512).map { index in
            temporalTestMetadata(mapID: mapID, coordinateFrameID: frameID,
                objectID: temporalTestObjectID(91_000 + index), at: 10,
                position: temporalTestPosition(Double(index) / 10))
        }
        var coordinator = try TemporalSpatialMemoryCoordinator(mapID: mapID, coordinateFrameID: frameID,
            restoringDurableObjects: objects, policy: policy)
        let materials = try (1...32).map { index in
            try temporalTestJournalMaterial(coordinator: &coordinator, sequence: UInt64(index),
                timestamp: 100 + Double(index), idNumber: 91_000 + index)
        }
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let appendStart = ProcessInfo.processInfo.systemUptime
        for material in materials {
            _ = try await repository.append(material.entry, policy: policy,
                previousSnapshot: material.previous, resultingSnapshot: material.resulting)
        }
        let appendSeconds = ProcessInfo.processInfo.systemUptime - appendStart
        let catalogBytes = try Data(contentsOf: catalogURL(in: root))
        XCTAssertLessThanOrEqual(catalogBytes.count, TemporalSpatialMemoryJournalRepository.maximumCatalogBytes)
        let cold = TemporalSpatialMemoryJournalRepository(directoryURL: root)
        let coldStart = ProcessInfo.processInfo.systemUptime
        let recovered = try await cold.recover(mapID: mapID, coordinateFrameID: frameID)
        let coldSeconds = ProcessInfo.processInfo.systemUptime - coldStart
        XCTAssertEqual(recovered?.snapshot, coordinator.snapshot)
        XCTAssertEqual(recovered?.snapshot.objects.count, 512)
        XCTAssertEqual(recovered?.replayedEntryCount, 32)
        let hotStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<16 {
            let hot = try await cold.recover(mapID: mapID, coordinateFrameID: frameID)
            XCTAssertEqual(hot, recovered)
        }
        let hotSeconds = ProcessInfo.processInfo.systemUptime - hotStart
        XCTAssertEqual(try Data(contentsOf: catalogURL(in: root)), catalogBytes, "Read-only recovery cannot rewrite history")
        let report: [String: Any] = [
            "fixture": "journal-512-objects-32-empty-updates", "policy": "default",
            "objects": 512, "updates": 32, "catalog_bytes": catalogBytes.count,
            "append_total_seconds": appendSeconds, "cold_recover_seconds": coldSeconds,
            "hot_recover_iterations": 16, "hot_recover_total_seconds": hotSeconds,
        ]
        print("VISPACE_SCALE " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }

    func testByteCompactionPreservesEveryPlaceIncludingTheUntouchedPlace() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = temporalTestPolicy()
        let mapA = temporalTestMapID(92), frameA = temporalTestFrameID(92)
        let mapB = temporalTestMapID(93), frameB = temporalTestFrameID(93)
        var a = try TemporalSpatialMemoryCoordinator(mapID: mapA, coordinateFrameID: frameA,
            restoringDurableObjects: [temporalTestMetadata(mapID: mapA, coordinateFrameID: frameA,
                objectID: temporalTestObjectID(92), at: 10)], policy: policy)
        var b = try TemporalSpatialMemoryCoordinator(mapID: mapB, coordinateFrameID: frameB,
            restoringDurableObjects: [temporalTestMetadata(mapID: mapB, coordinateFrameID: frameB,
                objectID: temporalTestObjectID(93), at: 10, position: temporalTestPosition(3))], policy: policy)
        let a1 = try temporalTestJournalMaterial(coordinator: &a, sequence: 1, timestamp: 100, idNumber: 92_001)
        let a2 = try temporalTestJournalMaterial(coordinator: &a, sequence: 2, timestamp: 101, idNumber: 92_002)
        let b1 = try temporalTestJournalMaterial(coordinator: &b, sequence: 1, timestamp: 100, idNumber: 93_001)
        let b2 = try temporalTestJournalMaterial(coordinator: &b, sequence: 2, timestamp: 101, idNumber: 93_002)
        func record(_ checkpoint: TemporalSpatialMemorySnapshot, _ entries: [TemporalSpatialMemoryJournalEntry]) throws -> TemporalSpatialMemoryJournalRecord {
            try TemporalSpatialMemoryJournalRecord(mapID: checkpoint.mapID, coordinateFrameID: checkpoint.coordinateFrameID,
                policy: policy, checkpoint: checkpoint, entries: entries)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try TemporalSpatialMemoryJournalCatalog(journals: [
            record(a1.previous, [a1.entry]), record(b1.previous, [b1.entry, b2.entry])])
        let compacted = try TemporalSpatialMemoryJournalCatalog(journals: [record(a2.resulting, []), record(b2.resulting, [])])
        let expanded = try TemporalSpatialMemoryJournalCatalog(journals: [
            record(a1.previous, [a1.entry, a2.entry]), record(b1.previous, [b1.entry, b2.entry])])
        let limit = max(try encoder.encode(before).count, try encoder.encode(compacted).count) + 8
        XCTAssertGreaterThan(try encoder.encode(expanded).count, limit)
        let repository = TemporalSpatialMemoryJournalRepository(directoryURL: root, maximumCatalogBytes: limit)
        for material in [b1, b2, a1, a2] {
            _ = try await repository.append(material.entry, policy: policy,
                previousSnapshot: material.previous, resultingSnapshot: material.resulting)
        }
        let restarted = TemporalSpatialMemoryJournalRepository(directoryURL: root, maximumCatalogBytes: limit)
        let recoveredA = try await restarted.recover(mapID: mapA, coordinateFrameID: frameA)
        let recoveredB = try await restarted.recover(mapID: mapB, coordinateFrameID: frameB)
        XCTAssertEqual(recoveredA?.snapshot, a2.resulting)
        XCTAssertEqual(recoveredB?.snapshot, b2.resulting)
        XCTAssertEqual(recoveredA?.replayedEntryCount, 0)
        XCTAssertEqual(recoveredB?.replayedEntryCount, 0)
        XCTAssertLessThanOrEqual(try Data(contentsOf: catalogURL(in: root)).count, limit)
    }

    private func catalogURL(in root: URL) -> URL {
        root.appendingPathComponent(
            TemporalSpatialMemoryJournalRepository.catalogFileName
        )
    }

    private func assertQuarantinedCatalog(
        in root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let quarantine = root.appendingPathComponent("Quarantine", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(
            files.filter { $0.pathExtension == "quarantined" }.count,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            files.filter { $0.lastPathComponent.hasSuffix(".reason.txt") }.count,
            1,
            file: file,
            line: line
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "vispace-temporal-journal-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private final class TemporalCommitAuthorityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isCurrent = true

    func validateThenRevoke() throws {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrent else { throw TemporalSpatialMemoryServiceError.captureAuthorityMismatch }
        isCurrent = false
    }
}

private func assertThrowsJournalError<T>(
    _ expression: () async throws -> T,
    equals expected: TemporalSpatialMemoryJournalError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
        XCTAssertEqual(
            error as? TemporalSpatialMemoryJournalError,
            expected,
            file: file,
            line: line
        )
    }
}
