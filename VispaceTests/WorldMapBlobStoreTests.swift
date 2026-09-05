import Foundation
import XCTest

@testable import Vispace

final class WorldMapBlobStoreTests: XCTestCase {
    func testEnvelopeRoundTripAndDuplicateProtection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = envelopeTestStore(directoryURL: directory, maximumArchiveBytes: 1_024)
        let id = WorldMapBlobID()
        let archive = Data("secure-world-map-fixture".utf8)

        let record = try await store.saveArchive(archive, id: id)
        try assertSpatialDirectoryPolicy(at: directory)
        XCTAssertEqual(record.byteCount, archive.count)
        XCTAssertEqual(record.sha256.count, 64)
        let containsBlob = await store.contains(id: id)
        let loadedArchive = try await store.loadArchive(id: id)
        XCTAssertTrue(containsBlob)
        XCTAssertEqual(loadedArchive, archive)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ),
            [record.fileURL]
        )

        await assertThrowsErrorAsync {
            _ = try await store.saveArchive(archive, id: id)
        } verify: { error in
            XCTAssertEqual(error as? WorldMapBlobStoreError, .blobAlreadyExists)
        }
    }

    func testEmptyAndOversizedArchivesFailClosed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = envelopeTestStore(directoryURL: directory, maximumArchiveBytes: 4)

        await assertThrowsErrorAsync {
            _ = try await store.saveArchive(Data())
        } verify: { error in
            XCTAssertEqual(error as? WorldMapBlobStoreError, .emptyArchive)
        }

        await assertThrowsErrorAsync {
            _ = try await store.saveArchive(Data(repeating: 0xA5, count: 5))
        } verify: { error in
            XCTAssertEqual(
                error as? WorldMapBlobStoreError,
                .archiveTooLarge(actual: 5, maximum: 4)
            )
        }
    }

    func testExistingBlobReadRepairsDirectoryPolicyWithoutChangingArchive() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = envelopeTestStore(directoryURL: directory)
        let archive = Data("existing-world-map".utf8)
        let record = try await store.saveArchive(archive)
        let encoded = try Data(contentsOf: record.fileURL)
        try resetSpatialDirectoryPolicy(at: directory)

        let loaded = try await store.loadArchive(id: record.id)

        XCTAssertEqual(loaded, archive)
        XCTAssertEqual(try Data(contentsOf: record.fileURL), encoded)
        try assertSpatialDirectoryPolicy(at: directory)
    }

    func testBlobEnumerationRepairsExistingDirectoryPolicy() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = envelopeTestStore(directoryURL: directory)
        let record = try await store.saveArchive(Data("existing-world-map".utf8))
        try resetSpatialDirectoryPolicy(at: directory)

        let ids = try await store.activeBlobIDs()

        XCTAssertEqual(ids, [record.id])
        try assertSpatialDirectoryPolicy(at: directory)
    }

    func testDanglingDestinationIsNeverReplaced() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let id = WorldMapBlobID()
        let destination = directory.appendingPathComponent(
            "\(id.rawValue.uuidString.lowercased()).vispacemap"
        )
        let missingTarget = directory.appendingPathComponent("missing-target")
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: missingTarget
        )
        let store = envelopeTestStore(directoryURL: directory)

        await assertThrowsErrorAsync {
            _ = try await store.saveArchive(Data("valid".utf8), id: id)
        } verify: { error in
            XCTAssertEqual(error as? WorldMapBlobStoreError, .blobAlreadyExists)
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.path),
            missingTarget.path
        )
    }

    func testCorruptedBlobIsRejected() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = envelopeTestStore(directoryURL: directory)
        let id = WorldMapBlobID()
        let record = try await store.saveArchive(Data("valid".utf8), id: id)
        try Data("corrupted".utf8).write(to: record.fileURL, options: .atomic)

        await assertThrowsErrorAsync {
            _ = try await store.loadArchive(id: id)
        } verify: { error in
            XCTAssertEqual(error as? WorldMapBlobStoreError, .invalidEnvelope)
        }
    }

    func testSupersededRemovalValidatesBeforeDeleting() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = envelopeTestStore(directoryURL: directory)
        let record = try await store.saveArchive(Data("valid".utf8))
        try Data("corrupted".utf8).write(to: record.fileURL, options: .atomic)

        await assertThrowsErrorAsync {
            try await store.removeSupersededArchive(id: record.id)
        } verify: { error in
            XCTAssertEqual(error as? WorldMapBlobStoreError, .invalidEnvelope)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.fileURL.path))
    }

    func testQuarantinePreservesEncodedBlobAndReasonSidecar() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = envelopeTestStore(directoryURL: directory)
        let record = try await store.saveArchive(Data("valid".utf8))
        let encodedBefore = try Data(contentsOf: record.fileURL)

        let quarantine = try await store.quarantine(
            id: record.id,
            reason: "checksum mismatch",
            quarantinedAt: Date(timeIntervalSince1970: 50)
        )

        let remainsInActiveStore = await store.contains(id: record.id)
        XCTAssertFalse(remainsInActiveStore)
        XCTAssertEqual(try Data(contentsOf: quarantine.blobURL), encodedBefore)
        XCTAssertEqual(quarantine.reason, "checksum mismatch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.reasonURL.path))
        try assertSpatialDirectoryPolicy(at: quarantine.blobURL.deletingLastPathComponent())
    }

    func testArchiveTamperingTriggersChecksumMismatch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = envelopeTestStore(directoryURL: directory)
        let archive = Data("original-archive".utf8)
        let record = try await store.saveArchive(archive)
        let envelope = try decodeEnvelope(at: record.fileURL)
        let tamperedArchive = Data("tampered-archive".utf8)
        XCTAssertEqual(tamperedArchive.count, archive.count)
        try writeEnvelope(
            .init(
                magic: envelope.magic,
                version: envelope.version,
                id: envelope.id,
                createdAt: envelope.createdAt,
                archive: tamperedArchive,
                sha256: envelope.sha256
            ),
            to: record.fileURL
        )

        await assertThrowsErrorAsync {
            _ = try await store.loadArchive(id: record.id)
        } verify: { error in
            guard
                let storeError = error as? WorldMapBlobStoreError,
                case .checksumMismatch(let expected, let actual) = storeError
            else {
                XCTFail("Expected checksum mismatch, received \(error).")
                return
            }
            XCTAssertEqual(expected, record.sha256)
            XCTAssertNotEqual(actual, expected)
        }
    }

    func testEnvelopeVersionAndIdentityAreValidated() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = envelopeTestStore(directoryURL: directory)
        let record = try await store.saveArchive(Data("valid".utf8))
        let envelope = try decodeEnvelope(at: record.fileURL)

        try writeEnvelope(
            .init(
                magic: envelope.magic,
                version: envelope.version + 1,
                id: envelope.id,
                createdAt: envelope.createdAt,
                archive: envelope.archive,
                sha256: envelope.sha256
            ),
            to: record.fileURL
        )
        await assertThrowsErrorAsync {
            _ = try await store.loadArchive(id: record.id)
        } verify: { error in
            XCTAssertEqual(
                error as? WorldMapBlobStoreError,
                .unsupportedEnvelopeVersion(envelope.version + 1)
            )
        }

        try writeEnvelope(
            .init(
                magic: envelope.magic,
                version: envelope.version,
                id: WorldMapBlobID(),
                createdAt: envelope.createdAt,
                archive: envelope.archive,
                sha256: envelope.sha256
            ),
            to: record.fileURL
        )
        await assertThrowsErrorAsync {
            _ = try await store.loadArchive(id: record.id)
        } verify: { error in
            XCTAssertEqual(error as? WorldMapBlobStoreError, .invalidEnvelope)
        }
    }

    func testEncodedBlobReadIsBounded() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let maximumArchiveBytes = 4
        let envelopeAllowance = 1 * 1_024 * 1_024
        let maximumEncodedBlobBytes = maximumArchiveBytes + envelopeAllowance
        let store = envelopeTestStore(
            directoryURL: directory,
            maximumArchiveBytes: maximumArchiveBytes
        )
        let record = try await store.saveArchive(Data(repeating: 0x01, count: 4))
        try Data(repeating: 0xA5, count: maximumEncodedBlobBytes + 1)
            .write(to: record.fileURL, options: .atomic)

        await assertThrowsErrorAsync {
            _ = try await store.loadArchive(id: record.id)
        } verify: { error in
            XCTAssertEqual(
                error as? WorldMapBlobStoreError,
                .encodedBlobTooLarge(
                    actual: maximumEncodedBlobBytes + 1,
                    maximum: maximumEncodedBlobBytes
                )
            )
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vispace-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func envelopeTestStore(
        directoryURL: URL,
        maximumArchiveBytes: Int = ARWorldMapArchiveCodec.maximumArchiveBytes
    ) -> ARWorldMapBlobStore {
        ARWorldMapBlobStore(
            directoryURL: directoryURL,
            maximumArchiveBytes: maximumArchiveBytes,
            archiveValidator: { _ in }
        )
    }

    private func decodeEnvelope(at fileURL: URL) throws -> ARWorldMapBlobStore.Envelope {
        try PropertyListDecoder().decode(
            ARWorldMapBlobStore.Envelope.self,
            from: Data(contentsOf: fileURL)
        )
    }

    private func writeEnvelope(
        _ envelope: ARWorldMapBlobStore.Envelope,
        to fileURL: URL
    ) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(envelope).write(to: fileURL, options: .atomic)
    }

    func testPublicStoreRejectsBytesThatAreNotAnARWorldMap() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ARWorldMapBlobStore(directoryURL: directory)

        await assertThrowsErrorAsync {
            _ = try await store.saveArchive(Data("not-an-ar-world-map".utf8))
        } verify: { error in
            guard let archiveError = error as? ARWorldMapArchiveError else {
                XCTFail("Expected ARWorldMapArchiveError, received \(error).")
                return
            }
            switch archiveError {
            case .secureDecodeFailed, .decodedUnexpectedObject:
                break
            default:
                XCTFail("Unexpected archive error: \(archiveError).")
            }
        }
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
