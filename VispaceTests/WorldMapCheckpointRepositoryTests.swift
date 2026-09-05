import Foundation
import VispaceCore
import XCTest

@testable import Vispace

final class WorldMapCheckpointRepositoryTests: XCTestCase {
    func testCheckpointIsRestoredWithCoordinateIdentity() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let identity = ARCaptureIdentity(status: .confirmed)
        let archive = Data("world-map".utf8)

        let saved = try await repository.saveCheckpoint(
            archive: archive,
            captureIdentity: identity,
            savedAt: Date(timeIntervalSince1970: 10)
        )
        try assertSpatialDirectoryPolicy(at: root)
        try assertSpatialDirectoryPolicy(
            at: root.appendingPathComponent("WorldMaps", isDirectory: true)
        )
        let restored = try await repository.loadLatestValidCheckpoint()

        XCTAssertEqual(restored?.archive, archive)
        XCTAssertEqual(restored?.metadata, saved)
        XCTAssertEqual(restored?.metadata.coordinateFrameID, identity.coordinateFrameID)
        XCTAssertTrue(restored?.objects.isEmpty == true)
    }

    func testSubsequentCheckpointsRetainLogicalMapIDWithoutLosingHistory() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let initialIdentity = ARCaptureIdentity(status: .confirmed)
        let first = try await repository.saveCheckpoint(
            archive: Data("first".utf8),
            captureIdentity: initialIdentity,
            savedAt: Date(timeIntervalSince1970: 10)
        )
        let continuedIdentity = ARCaptureIdentity(
            coordinateFrameID: initialIdentity.coordinateFrameID,
            segmentID: initialIdentity.segmentID,
            mapID: first.mapID,
            status: .confirmed
        )

        let second = try await repository.saveCheckpoint(
            archive: Data("second".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 20)
        )
        let snapshot = try await repository.metadataSnapshot()

        XCTAssertEqual(second.mapID, first.mapID)
        XCTAssertEqual(second.createdAt, first.createdAt)
        XCTAssertEqual(snapshot.maps.count, 2)
        XCTAssertTrue(snapshot.maps.allSatisfy { $0.mapID == first.mapID })
    }

    func testUnconfirmedCoordinateFrameCannotBePersisted() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)

        await assertThrowsErrorAsync {
            _ = try await repository.saveCheckpoint(
                archive: Data("world-map".utf8),
                captureIdentity: ARCaptureIdentity(status: .relocalizing)
            )
        } verify: { error in
            XCTAssertEqual(
                error as? WorldMapCheckpointRepositoryError,
                .unconfirmedCoordinateFrame
            )
        }
    }

    func testCorruptedNewestBlobIsQuarantinedAndOlderCheckpointRestores() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let identity = ARCaptureIdentity(status: .confirmed)
        let olderArchive = Data("older-map".utf8)
        let older = try await repository.saveCheckpoint(
            archive: olderArchive,
            captureIdentity: identity,
            savedAt: Date(timeIntervalSince1970: 10)
        )
        let continuedIdentity = ARCaptureIdentity(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: older.mapID,
            status: .confirmed
        )
        let newest = try await repository.saveCheckpoint(
            archive: Data("newer-map".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 20)
        )
        let newestURL =
            root
            .appendingPathComponent("WorldMaps", isDirectory: true)
            .appendingPathComponent(
                "\(newest.worldMapBlobID.uuidString.lowercased()).vispacemap"
            )
        try Data("corrupted".utf8).write(to: newestURL, options: .atomic)

        let restored = try await repository.loadLatestValidCheckpoint()
        let metadata = try await repository.metadataSnapshot()

        XCTAssertEqual(restored?.archive, olderArchive)
        XCTAssertEqual(
            metadata.maps.first {
                $0.worldMapBlobID == newest.worldMapBlobID
            }?.availability,
            .quarantined
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: newestURL.path))
        let quarantine =
            root
            .appendingPathComponent("WorldMaps", isDirectory: true)
            .appendingPathComponent("Quarantine", isDirectory: true)
        let quarantinedFiles = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(quarantinedFiles.count, 2)
    }

    func testFailedBlobQuarantineLeavesMetadataActiveForRetry() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let saved = try await repository.saveCheckpoint(
            archive: Data("world-map".utf8),
            captureIdentity: ARCaptureIdentity(status: .confirmed)
        )
        let worldMaps = root.appendingPathComponent("WorldMaps", isDirectory: true)
        let blobURL = worldMaps.appendingPathComponent(
            "\(saved.worldMapBlobID.uuidString.lowercased()).vispacemap"
        )
        try Data("corrupted".utf8).write(to: blobURL, options: .atomic)
        let quarantinePath = worldMaps.appendingPathComponent("Quarantine")
        try Data("blocks-directory-creation".utf8).write(to: quarantinePath)

        await assertThrowsErrorAsync {
            try await repository.loadLatestValidCheckpoint()
        } verify: { _ in
        }
        let snapshot = try await repository.metadataSnapshot()

        XCTAssertEqual(snapshot.maps.first?.availability, .active)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobURL.path))
    }

    func testConcurrentCheckpointsSerializeCatalogUpdates() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root, maximumCheckpointsPerMap: 16)
        let initialIdentity = ARCaptureIdentity(status: .confirmed)
        let first = try await repository.saveCheckpoint(
            archive: Data("map-0".utf8),
            captureIdentity: initialIdentity,
            savedAt: Date(timeIntervalSince1970: 1)
        )
        let continuedIdentity = ARCaptureIdentity(
            coordinateFrameID: initialIdentity.coordinateFrameID,
            segmentID: initialIdentity.segmentID,
            mapID: first.mapID,
            status: .confirmed
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 1...8 {
                group.addTask {
                    _ = try await repository.saveCheckpoint(
                        archive: Data("map-\(index)".utf8),
                        captureIdentity: continuedIdentity,
                        savedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
                    )
                }
            }
            try await group.waitForAll()
        }
        let snapshot = try await repository.metadataSnapshot()

        XCTAssertEqual(snapshot.maps.count, 9)
        XCTAssertTrue(snapshot.maps.allSatisfy { $0.mapID == first.mapID })
        XCTAssertEqual(Set(snapshot.maps.map(\.worldMapBlobID)).count, 9)
    }

    func testCheckpointRetentionRollsForwardWithoutUnboundedBlobGrowth() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root, maximumCheckpointsPerMap: 2)
        let identity = ARCaptureIdentity(status: .confirmed)
        let first = try await repository.saveCheckpoint(
            archive: Data("map-1".utf8),
            captureIdentity: identity,
            savedAt: Date(timeIntervalSince1970: 1)
        )
        let continuedIdentity = ARCaptureIdentity(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: first.mapID,
            status: .confirmed
        )
        _ = try await repository.saveCheckpoint(
            archive: Data("map-2".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 2)
        )
        _ = try await repository.saveCheckpoint(
            archive: Data("map-3".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 3)
        )

        let snapshot = try await repository.metadataSnapshot()
        let restored = try await repository.loadLatestValidCheckpoint()
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("WorldMaps", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(snapshot.maps.count, 2)
        XCTAssertFalse(snapshot.maps.contains { $0.worldMapBlobID == first.worldMapBlobID })
        XCTAssertEqual(restored?.archive, Data("map-3".utf8))
        XCTAssertEqual(files.filter { $0.pathExtension == "vispacemap" }.count, 2)
    }

    func testCheckpointOrderingRemainsMonotonicWhenDeviceClockMovesBackward() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root, maximumCheckpointsPerMap: 2)
        let identity = ARCaptureIdentity(status: .confirmed)
        let first = try await repository.saveCheckpoint(
            archive: Data("map-1".utf8),
            captureIdentity: identity,
            savedAt: Date(timeIntervalSince1970: 10)
        )
        let continuedIdentity = ARCaptureIdentity(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: first.mapID,
            status: .confirmed
        )
        let second = try await repository.saveCheckpoint(
            archive: Data("map-2".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 5)
        )
        let third = try await repository.saveCheckpoint(
            archive: Data("map-3".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 5)
        )

        let snapshot = try await repository.metadataSnapshot()
        let restored = try await repository.loadLatestValidCheckpoint()

        XCTAssertGreaterThan(second.updatedAt, first.updatedAt)
        XCTAssertGreaterThan(third.updatedAt, second.updatedAt)
        XCTAssertTrue(snapshot.maps.contains { $0.worldMapBlobID == third.worldMapBlobID })
        XCTAssertEqual(restored?.archive, Data("map-3".utf8))
    }

    func testCorruptedSupersededCheckpointIsQuarantinedInsteadOfDeleted() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root, maximumCheckpointsPerMap: 2)
        let identity = ARCaptureIdentity(status: .confirmed)
        let first = try await repository.saveCheckpoint(
            archive: Data("map-1".utf8),
            captureIdentity: identity,
            savedAt: Date(timeIntervalSince1970: 1)
        )
        let continuedIdentity = ARCaptureIdentity(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: first.mapID,
            status: .confirmed
        )
        _ = try await repository.saveCheckpoint(
            archive: Data("map-2".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 2)
        )
        let firstURL =
            root
            .appendingPathComponent("WorldMaps", isDirectory: true)
            .appendingPathComponent(
                "\(first.worldMapBlobID.uuidString.lowercased()).vispacemap"
            )
        try Data("corrupted".utf8).write(to: firstURL, options: .atomic)

        _ = try await repository.saveCheckpoint(
            archive: Data("map-3".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 3)
        )
        let snapshot = try await repository.metadataSnapshot()

        XCTAssertEqual(
            snapshot.maps.first { $0.worldMapBlobID == first.worldMapBlobID }?.availability,
            .quarantined
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        let quarantine =
            root
            .appendingPathComponent("WorldMaps", isDirectory: true)
            .appendingPathComponent("Quarantine", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: quarantine,
                includingPropertiesForKeys: nil
            ).count,
            2
        )
    }

    func testDeferredQuarantineFailureDoesNotBlockNewestValidCheckpoint() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root, maximumCheckpointsPerMap: 2)
        let identity = ARCaptureIdentity(status: .confirmed)
        let first = try await repository.saveCheckpoint(
            archive: Data("map-1".utf8),
            captureIdentity: identity,
            savedAt: Date(timeIntervalSince1970: 1)
        )
        let continuedIdentity = ARCaptureIdentity(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: first.mapID,
            status: .confirmed
        )
        _ = try await repository.saveCheckpoint(
            archive: Data("map-2".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 2)
        )
        let worldMaps = root.appendingPathComponent("WorldMaps", isDirectory: true)
        let firstURL = worldMaps.appendingPathComponent(
            "\(first.worldMapBlobID.uuidString.lowercased()).vispacemap"
        )
        try Data("corrupted".utf8).write(to: firstURL, options: .atomic)
        try Data("blocks-quarantine".utf8).write(
            to: worldMaps.appendingPathComponent("Quarantine")
        )

        let newest = try await repository.saveCheckpoint(
            archive: Data("map-3".utf8),
            captureIdentity: continuedIdentity,
            savedAt: Date(timeIntervalSince1970: 3)
        )
        let restored = try await repository.loadLatestValidCheckpoint()

        XCTAssertEqual(restored?.metadata.worldMapBlobID, newest.worldMapBlobID)
        XCTAssertEqual(restored?.archive, Data("map-3".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
    }

    func testDetachedBlobFromInterruptedCommitIsPreservedInQuarantine() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let worldMaps = root.appendingPathComponent("WorldMaps", isDirectory: true)
        let blobStore = ARWorldMapBlobStore(
            directoryURL: worldMaps,
            maximumArchiveBytes: ARWorldMapArchiveCodec.maximumArchiveBytes,
            archiveValidator: { _ in }
        )
        let orphan = try await blobStore.saveArchive(Data("orphan".utf8))
        let repository = WorldMapCheckpointRepository(
            directoryURL: root,
            blobStore: blobStore
        )

        let restored = try await repository.loadLatestValidCheckpoint()

        XCTAssertNil(restored)
        let remainsActive = await blobStore.contains(id: orphan.id)
        XCTAssertFalse(remainsActive)
        let quarantine = worldMaps.appendingPathComponent("Quarantine", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: quarantine,
                includingPropertiesForKeys: nil
            ).count,
            2
        )
    }

    func testQuarantinedMapsDoNotConsumeActiveLogicalMapCapacity() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(
            root: root,
            maximumCheckpointsPerMap: 2,
            maximumLogicalMaps: 2
        )
        let first = try await repository.saveCheckpoint(
            archive: Data("map-1".utf8),
            captureIdentity: ARCaptureIdentity(status: .confirmed),
            savedAt: Date(timeIntervalSince1970: 1)
        )
        let second = try await repository.saveCheckpoint(
            archive: Data("map-2".utf8),
            captureIdentity: ARCaptureIdentity(status: .confirmed),
            savedAt: Date(timeIntervalSince1970: 2)
        )
        let worldMaps = root.appendingPathComponent("WorldMaps", isDirectory: true)
        for metadata in [first, second] {
            let url = worldMaps.appendingPathComponent(
                "\(metadata.worldMapBlobID.uuidString.lowercased()).vispacemap"
            )
            try Data("corrupted".utf8).write(to: url, options: .atomic)
        }
        let quarantinedRestore = try await repository.loadLatestValidCheckpoint()
        XCTAssertNil(quarantinedRestore)

        let third = try await repository.saveCheckpoint(
            archive: Data("map-3".utf8),
            captureIdentity: ARCaptureIdentity(status: .confirmed),
            savedAt: Date(timeIntervalSince1970: 3)
        )
        let snapshot = try await repository.metadataSnapshot()

        XCTAssertEqual(
            snapshot.maps.filter { $0.availability == .quarantined }.count,
            2
        )
        XCTAssertEqual(
            snapshot.maps.filter { $0.availability == .active }.map(\.mapID),
            [third.mapID]
        )
    }

    func testMalformedMetadataCatalogIsPreservedInQuarantine() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadataURL = root.appendingPathComponent("spatial-metadata-v1.json")
        let malformed = Data("not-json".utf8)
        try malformed.write(to: metadataURL)
        let repository = makeRepository(root: root)

        let snapshot = try await repository.metadataSnapshot()

        XCTAssertTrue(snapshot.maps.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
        let quarantine = root.appendingPathComponent("Quarantine", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 2)
        let preservedURL = try XCTUnwrap(
            files.first { $0.lastPathComponent.hasSuffix("json.quarantined") }
        )
        XCTAssertEqual(try Data(contentsOf: preservedURL), malformed)
    }

    func testObjectMetadataRequiresMatchingActiveCoordinateFrame() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let identity = ARCaptureIdentity(status: .confirmed)
        let map = try await repository.saveCheckpoint(
            archive: Data("world-map".utf8),
            captureIdentity: identity
        )
        let object = try SpatialObject(
            semanticLabel: "chair",
            position: Vec3(x: 1, y: 0, z: -2),
            certainty: .confirmed,
            confidence: ConfidenceVector(
                semantic: ConfidenceScore(clamping: 0.9),
                geometry: ConfidenceScore(clamping: 0.9),
                tracking: ConfidenceScore(clamping: 0.9),
                place: ConfidenceScore(clamping: 0.9),
                identity: ConfidenceScore(clamping: 0.9),
                objectState: ConfidenceScore(clamping: 0.9),
                relation: ConfidenceScore(clamping: 0.9)
            ),
            firstSeenAt: 1,
            lastSeenAt: 2
        )
        let position = try FramedPosition(
            coordinateFrameID: identity.coordinateFrameID,
            value: object.position,
            observedAt: object.lastSeenAt,
            trackingQuality: .normal,
            uncertainty: .highConfidenceDepth
        )
        let metadata = try SpatialObjectMetadata(
            mapID: map.mapID,
            object: object,
            position: position
        )

        try await repository.upsertObjectMetadata(metadata)
        let saved = try await repository.metadataSnapshot()
        let restored = try await repository.loadLatestValidCheckpoint()

        XCTAssertEqual(saved.objects, [metadata])
        XCTAssertEqual(restored?.objects, [metadata])
    }

    func testOlderObjectMetadataCannotOverwriteNewerState() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let identity = ARCaptureIdentity(status: .confirmed)
        let map = try await repository.saveCheckpoint(
            archive: Data("world-map".utf8),
            captureIdentity: identity
        )
        let objectID = ObjectID()

        func metadata(at timestamp: TimeInterval, x: Double) throws -> SpatialObjectMetadata {
            let positionValue = try Vec3(x: x, y: 0, z: -2)
            let object = try SpatialObject(
                id: objectID,
                semanticLabel: "chair",
                position: positionValue,
                certainty: .confirmed,
                confidence: ConfidenceVector(
                    semantic: ConfidenceScore(clamping: 0.9),
                    geometry: ConfidenceScore(clamping: 0.9),
                    tracking: ConfidenceScore(clamping: 0.9),
                    place: ConfidenceScore(clamping: 0.9),
                    identity: ConfidenceScore(clamping: 0.9),
                    objectState: ConfidenceScore(clamping: 0.9)
                ),
                firstSeenAt: 1,
                lastSeenAt: timestamp
            )
            let position = try FramedPosition(
                coordinateFrameID: identity.coordinateFrameID,
                value: positionValue,
                observedAt: timestamp,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            )
            return try SpatialObjectMetadata(mapID: map.mapID, object: object, position: position)
        }

        let newer = try metadata(at: 3, x: 3)
        let older = try metadata(at: 2, x: 2)
        try await repository.upsertObjectMetadata(newer)

        do {
            try await repository.upsertObjectMetadata(older)
            XCTFail("Expected stale object update to be rejected")
        } catch {
            XCTAssertEqual(
                error as? WorldMapCheckpointRepositoryError,
                .staleObjectUpdate(objectID)
            )
        }
        let snapshot = try await repository.metadataSnapshot()
        XCTAssertEqual(snapshot.objects, [newer])
    }

    private func makeRepository(
        root: URL,
        maximumCheckpointsPerMap: Int = WorldMapCheckpointRepository
            .defaultMaximumCheckpointsPerMap,
        maximumLogicalMaps: Int = WorldMapCheckpointRepository.defaultMaximumLogicalMaps
    ) -> WorldMapCheckpointRepository {
        let blobStore = ARWorldMapBlobStore(
            directoryURL: root.appendingPathComponent("WorldMaps", isDirectory: true),
            maximumArchiveBytes: ARWorldMapArchiveCodec.maximumArchiveBytes,
            archiveValidator: { _ in }
        )
        return WorldMapCheckpointRepository(
            directoryURL: root,
            blobStore: blobStore,
            maximumCheckpointsPerMap: maximumCheckpointsPerMap,
            maximumLogicalMaps: maximumLogicalMaps
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vispace-checkpoint-tests-\(UUID().uuidString)")
    }
}

private func assertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    verify: (any Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
        verify(error)
    }
}
