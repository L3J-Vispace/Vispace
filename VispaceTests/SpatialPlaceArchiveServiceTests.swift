import CryptoKit
import Foundation
import VispaceCore
import XCTest

@testable import Vispace

final class SpatialPlaceArchiveServiceTests: XCTestCase {
    private let codec = SpatialPlaceArchiveCodec(archiveValidator: { _ in })

    func testEncryptedRoundTripPreservesPlaceObjectsAndUserName() throws {
        let candidate = try fixture()
        let export = try codec.seal(candidate)
        let restored = try codec.open(export.encryptedData, recoveryKey: export.recoveryKey)
        XCTAssertEqual(restored.metadata, candidate.metadata)
        XCTAssertEqual(restored.archive, candidate.archive)
        XCTAssertEqual(restored.objects, candidate.objects)
        XCTAssertEqual(restored.objects.first?.object.displayName, "창가 의자")
        XCTAssertEqual(Data(base64Encoded: export.recoveryKey)?.count, 32)
        XCTAssertNil(export.encryptedData.range(of: Data("창가 의자".utf8)))
        let other = try codec.seal(candidate)
        XCTAssertNotEqual(export.recoveryKey, other.recoveryKey)
        XCTAssertNotEqual(export.encryptedData, other.encryptedData)
    }

    func testWrongKeyAndChangedCiphertextCannotOpen() throws {
        let export = try codec.seal(fixture())
        let wrongKey = Data(repeating: 0, count: 32).base64EncodedString()
        XCTAssertThrowsError(try codec.open(export.encryptedData, recoveryKey: wrongKey)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .authenticationFailed)
        }
        var altered = export.encryptedData
        altered[altered.count - 1] ^= 1
        XCTAssertThrowsError(try codec.open(altered, recoveryKey: export.recoveryKey)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .authenticationFailed)
        }
        XCTAssertThrowsError(try codec.open(export.encryptedData, recoveryKey: "invalid")) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .invalidRecoveryKey)
        }
    }

    func testUnsupportedEnvelopeAndManifestVersionsFailExplicitly() throws {
        let export = try codec.seal(fixture())
        var future = export.encryptedData
        future[Data("VISPACE-PLACE".utf8).count + 1] = 2
        XCTAssertThrowsError(try codec.open(future, recoveryKey: export.recoveryKey)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .unsupportedVersion(2))
        }
        let crafted = try encryptedFixture(manifest: ["schemaVersion": 99])
        XCTAssertThrowsError(try codec.open(crafted.data, recoveryKey: crafted.key)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .unsupportedVersion(99))
        }
    }

    func testObjectLimitIsCheckedBeforeMalformedObjectOrMetadataDecode() throws {
        let crafted = try encryptedFixture(manifest: [
            "schemaVersion": 1, "metadata": [:],
            "objects": Array(repeating: NSNull(), count: SpatialPlaceArchiveCodec.maximumObjectCount + 1)
        ])
        XCTAssertThrowsError(try codec.open(crafted.data, recoveryKey: crafted.key)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .fileTooLarge)
        }
    }

    func testLengthAndFileBoundsFailBeforeModelDecode() throws {
        let crafted = try encryptedFixture(manifest: ["schemaVersion": 1], manifestLength: UInt32.max)
        XCTAssertThrowsError(try codec.open(crafted.data, recoveryKey: crafted.key)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .invalidDocument)
        }
        let oversized = Data(repeating: 0, count: SpatialPlaceArchiveCodec.maximumEncryptedFileBytes + 1)
        XCTAssertThrowsError(try codec.open(oversized, recoveryKey: crafted.key)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .fileTooLarge)
        }
    }

    func testDirectRepositoryImportEnforcesObjectCapacityBeforeCreatingStore() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture()
        let oversized = WorldMapRestoreCandidate(metadata: source.metadata, archive: source.archive,
            objects: Array(repeating: try XCTUnwrap(source.objects.first), count: SpatialPlaceArchiveCodec.maximumObjectCount + 1))
        do { _ = try await makeRepository(root).importPortableCheckpoint(oversized); XCTFail("Expected object limit") }
        catch { XCTAssertEqual(error as? SpatialPlaceArchiveError, .fileTooLarge) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testChecksumAndSecureArchiveTypeAreIndependentlyRequired() throws {
        let candidate = try fixture()
        let metadata = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate.metadata))
        let objects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate.objects))
        let corrupted = try encryptedFixture(manifest: ["schemaVersion": 1, "metadata": metadata, "objects": objects], validChecksum: false)
        XCTAssertThrowsError(try codec.open(corrupted.data, recoveryKey: corrupted.key)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .checksumMismatch)
        }
        XCTAssertThrowsError(try SpatialPlaceArchiveCodec().seal(candidate))
        let encrypted = try codec.seal(candidate)
        XCTAssertThrowsError(try SpatialPlaceArchiveCodec().open(encrypted.encryptedData, recoveryKey: encrypted.recoveryKey))
    }

    func testSelectedFileImportsOnceWithoutChangingSourceOrExistingPlaces() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = makeRepository(root.appendingPathComponent("target"))
        let existing = try await repository.saveCheckpoint(archive: Data("existing".utf8), captureIdentity: ARCaptureIdentity(status: .confirmed))
        let candidate = try fixture()
        let sourceRepository = makeRepository(root.appendingPathComponent("source"))
        _ = try await sourceRepository.importPortableCheckpoint(candidate)
        let sourceService = SpatialPlaceArchiveService(repository: sourceRepository, codec: codec)
        let export = try await sourceService.exportPlace(mapID: candidate.metadata.mapID)
        let selected = root.appendingPathComponent("selected.vispaceplace")
        try export.encryptedData.write(to: selected)
        let service = SpatialPlaceArchiveService(repository: repository, codec: codec)
        let importedID = try await service.importPlace(from: selected, recoveryKey: export.recoveryKey)
        XCTAssertEqual(importedID, candidate.metadata.mapID)
        let restored = try await repository.loadLatestValidCheckpoint(mapID: importedID)
        XCTAssertEqual(restored?.objects, candidate.objects)
        XCTAssertEqual(restored?.archive, candidate.archive)
        let temporalService = TemporalSpatialMemoryService(checkpointRepository: repository,
            journalRepository: TemporalSpatialMemoryJournalRepository(directoryURL: root.appendingPathComponent("target")))
        let recovered = try await temporalService.recover(mapID: importedID, coordinateFrameID: candidate.metadata.coordinateFrameID)
        XCTAssertEqual(recovered.revision, 1_000)
        guard case .applied(let delta) = try await temporalService.process(
            TemporalSpatialRecognitionBatch(sequence: 1, observations: [], expectedVisibleObjectIDs: []),
            pose: temporalTestPose(mapID: importedID, coordinateFrameID: candidate.metadata.coordinateFrameID,
                capturedAt: 100, sessionTimestamp: 1, sequence: 1)
        ) else { return XCTFail("Expected update after portable recovery") }
        XCTAssertEqual(delta.newRevision, 1_001)
        let original = try await repository.loadLatestValidCheckpoint(mapID: existing.mapID)
        XCTAssertEqual(original?.archive, Data("existing".utf8))
        let catalogFile = root.appendingPathComponent("target/spatial-metadata-v1.json")
        let before = try Data(contentsOf: catalogFile)
        do { _ = try await service.importPlace(from: selected, recoveryKey: export.recoveryKey); XCTFail("Expected duplicate rejection") }
        catch { XCTAssertEqual(error as? WorldMapCheckpointRepositoryError, .importedMapAlreadyExists(importedID)) }
        XCTAssertEqual(try Data(contentsOf: catalogFile), before)
        XCTAssertEqual(try Data(contentsOf: selected), export.encryptedData)
    }

    func testImportRejectsSurvivingBackupWithoutOverwritingRecoveryData() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root)
        _ = try await repository.saveCheckpoint(archive: Data("existing".utf8), captureIdentity: ARCaptureIdentity(status: .confirmed))
        let metadata = root.appendingPathComponent("spatial-metadata-v1.json")
        let backup = root.appendingPathComponent("spatial-metadata-v1.previous.json")
        let before = try Data(contentsOf: backup)
        try FileManager.default.removeItem(at: metadata)
        do { _ = try await repository.importPortableCheckpoint(fixture()); XCTFail("Expected recovery-required rejection") }
        catch { XCTAssertEqual(error as? WorldMapCheckpointRepositoryError, .metadataFileUnavailable) }
        XCTAssertEqual(try Data(contentsOf: backup), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        let recovered = try await makeRepository(root).metadataSnapshot()
        XCTAssertEqual(recovered.maps.count, 1)
        XCTAssertEqual(try Data(contentsOf: metadata), before)
    }

    func testImportRejectsCoordinateFrameReuseAcrossDifferentMaps() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root)
        let candidate = try fixture()
        _ = try await repository.saveCheckpoint(archive: Data("existing".utf8), captureIdentity: ARCaptureIdentity(
            coordinateFrameID: candidate.metadata.coordinateFrameID, status: .confirmed))
        let catalog = root.appendingPathComponent("spatial-metadata-v1.json")
        let before = try Data(contentsOf: catalog)
        do { _ = try await repository.importPortableCheckpoint(candidate); XCTFail("Expected frame collision") }
        catch { XCTAssertEqual(error as? WorldMapCheckpointRepositoryError, .importedCoordinateFrameAlreadyExists(candidate.metadata.coordinateFrameID)) }
        XCTAssertEqual(try Data(contentsOf: catalog), before)
    }

    func testCatalogCommitFailureRollsBackOnlyNewImportBlob() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let normal = makeRepository(root)
        let saved = try await normal.saveCheckpoint(archive: Data("existing".utf8), captureIdentity: ARCaptureIdentity(status: .confirmed))
        let catalog = root.appendingPathComponent("spatial-metadata-v1.json")
        let before = try Data(contentsOf: catalog)
        let failing = makeRepository(root, failCatalogWrites: true)
        do { _ = try await failing.importPortableCheckpoint(fixture()); XCTFail("Expected commit failure") }
        catch { XCTAssertTrue(error is SpatialStorageError) }
        XCTAssertEqual(try Data(contentsOf: catalog), before)
        let blobFiles = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("WorldMaps").path)
            .filter { $0.hasSuffix(".vispacemap") }
        XCTAssertEqual(blobFiles, ["\(saved.worldMapBlobID.uuidString.lowercased()).vispacemap"])
    }

    func testImportRejectsGlobalObjectIDCollisionAcrossDifferentMaps() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root)
        let original = try fixture()
        _ = try await repository.importPortableCheckpoint(original)
        let incoming = try fixture()
        let sourceObject = try XCTUnwrap(original.objects.first).object
        let conflictingObject = try SpatialObjectMetadata(mapID: incoming.metadata.mapID, object: sourceObject,
            position: FramedPosition(coordinateFrameID: incoming.metadata.coordinateFrameID,
                value: sourceObject.position, observedAt: sourceObject.lastSeenAt,
                trackingQuality: .normal, uncertainty: .highConfidenceDepth))
        let collision = WorldMapRestoreCandidate(metadata: incoming.metadata, archive: incoming.archive, objects: [conflictingObject])
        let catalog = root.appendingPathComponent("spatial-metadata-v1.json")
        let before = try Data(contentsOf: catalog)
        do { _ = try await repository.importPortableCheckpoint(collision); XCTFail("Expected object collision") }
        catch { XCTAssertEqual(error as? WorldMapCheckpointRepositoryError, .importedObjectAlreadyExists(sourceObject.id)) }
        XCTAssertEqual(try Data(contentsOf: catalog), before)
    }

    private func fixture() throws -> WorldMapRestoreCandidate {
        let frameID = CoordinateFrameID()
        let metadata = try SpatialMapMetadata(mapID: MapID(), coordinateFrameID: frameID,
            latestSegmentID: CaptureSegmentID(), worldMapBlobID: UUID(), createdAt: 1, updatedAt: 2)
        let object = try SpatialObject(semanticLabel: "chair", position: Vec3(x: 1, y: 0, z: -1),
            certainty: .confirmed,
            confidence: ConfidenceVector(semantic: .one, geometry: .one, tracking: .one, place: .one,
                identity: .one, objectState: .one, relation: .one),
            firstSeenAt: 1_000, lastSeenAt: 1_001, displayName: "창가 의자", temporalRevision: 1_000)
        let record = try SpatialObjectMetadata(mapID: metadata.mapID, object: object,
            position: FramedPosition(coordinateFrameID: frameID, value: object.position, observedAt: 1_001,
                trackingQuality: .normal, uncertainty: .highConfidenceDepth))
        return WorldMapRestoreCandidate(metadata: metadata, archive: Data("world-map-fixture".utf8), objects: [record])
    }

    private func encryptedFixture(manifest: [String: Any], validChecksum: Bool = true, manifestLength: UInt32? = nil) throws -> (data: Data, key: String) {
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        let length = manifestLength ?? UInt32(manifestData.count)
        var plaintext = Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        plaintext.append(manifestData)
        let archive = Data("world-map-fixture".utf8)
        plaintext.append(archive)
        plaintext.append(validChecksum ? Data(SHA256.hash(data: archive)) : Data(repeating: 0, count: 32))
        let key = SymmetricKey(size: .bits256)
        let header = Data("VISPACE-PLACE".utf8) + Data([0, 1])
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        return (header + (try XCTUnwrap(sealed.combined)), key.withUnsafeBytes { Data($0).base64EncodedString() })
    }

    private func makeRepository(_ directory: URL, failCatalogWrites: Bool = false) -> WorldMapCheckpointRepository {
        let blobs = ARWorldMapBlobStore(directoryURL: directory.appendingPathComponent("WorldMaps"),
            maximumArchiveBytes: ARWorldMapArchiveCodec.maximumArchiveBytes, archiveValidator: { _ in })
        return WorldMapCheckpointRepository(directoryURL: directory, blobStore: blobs,
            fileManager: failCatalogWrites ? ArchiveFullDiskFileManager() : FileManager())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vispace-portable-tests-\(UUID().uuidString)")
    }
}

private final class ArchiveFullDiskFileManager: FileManager, @unchecked Sendable {
    override func attributesOfFileSystem(forPath path: String) throws -> [FileAttributeKey: Any] {
        [.systemFreeSize: NSNumber(value: 0)]
    }
}
