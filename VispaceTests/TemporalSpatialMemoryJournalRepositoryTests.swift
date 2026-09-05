import VispaceCore
import XCTest

@testable import Vispace

final class TemporalSpatialMemoryJournalRepositoryTests: XCTestCase {
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
