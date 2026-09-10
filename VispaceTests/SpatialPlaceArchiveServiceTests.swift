import CryptoKit
import Foundation
import VispaceCore
import XCTest

@testable import Vispace

final class SpatialPlaceArchiveServiceTests: XCTestCase {
    private let codec = SpatialPlaceArchiveCodec(archiveValidator: { _ in })

    func testLegacyVersionOneStillImportsWithOriginalBounds() throws {
        let candidate = try fixture()
        let manifest = try manifestDictionary(candidate)
        let legacy = try encryptedFixture(manifest: manifest)
        let restored = try codec.open(legacy.data, recoveryKey: legacy.key)
        XCTAssertEqual(restored.metadata, candidate.metadata)
        XCTAssertEqual(restored.objects, candidate.objects)
        XCTAssertEqual(restored.archive, candidate.archive)
        var oversized = Data("VISPACE-PLACE".utf8) + Data([0, 1])
        oversized.append(Data(repeating: 0, count: SpatialPlaceArchiveCodec.legacyMaximumEncryptedFileBytes))
        XCTAssertThrowsError(try codec.open(oversized, recoveryKey: legacy.key)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .fileTooLarge)
        }
    }

    func testChunkedRoundTripExportsMapBeyondLegacyThirtyTwoMiB() throws {
        let source = try fixture()
        let bytes = Data(repeating: 0xA7, count: SpatialPlaceArchiveCodec.legacyMaximumWorldMapBytes + 17)
        let candidate = WorldMapRestoreCandidate(metadata: source.metadata, archive: bytes, objects: source.objects)
        let exported = try codec.seal(candidate)
        XCTAssertEqual(exported.encryptedData[Data("VISPACE-PLACE".utf8).count + 1], 2)
        let restored = try codec.open(exported.encryptedData, recoveryKey: exported.recoveryKey)
        XCTAssertEqual(restored.archive, bytes)
        XCTAssertEqual(restored.objects, source.objects)
        XCTAssertEqual(SpatialPlaceArchiveCodec.maximumWorldMapBytes, ARWorldMapArchiveCodec.maximumArchiveBytes)
    }

    func testChunkAuthenticationRejectsReorderTruncationTrailingDataAndManifestSplicing() throws {
        let source = try fixture()
        let candidate = WorldMapRestoreCandidate(metadata: source.metadata,
            archive: Data(repeating: 0x71, count: SpatialPlaceArchiveCodec.archiveChunkBytes * 2 + 17), objects: source.objects)
        let exported = try codec.seal(candidate)
        let headerCount = Data("VISPACE-PLACE".utf8).count + 2
        let manifestLength = exported.encryptedData[headerCount..<(headerCount + 4)].reduce(0) { ($0 << 8) | Int($1) }
        let chunkStart = headerCount + 4 + manifestLength
        let chunkBytes = SpatialPlaceArchiveCodec.archiveChunkBytes + 28
        var reordered = exported.encryptedData
        let first = reordered.subdata(in: chunkStart..<(chunkStart + chunkBytes))
        let second = reordered.subdata(in: (chunkStart + chunkBytes)..<(chunkStart + chunkBytes * 2))
        reordered.replaceSubrange(chunkStart..<(chunkStart + chunkBytes), with: second)
        reordered.replaceSubrange((chunkStart + chunkBytes)..<(chunkStart + chunkBytes * 2), with: first)
        XCTAssertThrowsError(try codec.open(reordered, recoveryKey: exported.recoveryKey)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .authenticationFailed)
        }
        for malformed in [Data(exported.encryptedData.dropLast()), exported.encryptedData + Data([0])] {
            XCTAssertThrowsError(try codec.open(malformed, recoveryKey: exported.recoveryKey)) {
                XCTAssertEqual($0 as? SpatialPlaceArchiveError, .invalidDocument)
            }
        }
        // Re-encrypting even an identical manifest with the SAME key must not
        // make the existing chunks valid for a different manifest ciphertext.
        let key = SymmetricKey(data: try XCTUnwrap(Data(base64Encoded: exported.recoveryKey)))
        let header = Data(exported.encryptedData.prefix(headerCount))
        let originalManifest = exported.encryptedData.subdata(in: (headerCount + 4)..<chunkStart)
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: originalManifest), using: key, authenticating: header)
        let replacement = try XCTUnwrap(AES.GCM.seal(plaintext, using: key, authenticating: header).combined)
        var spliced = exported.encryptedData
        spliced.replaceSubrange((headerCount + 4)..<chunkStart, with: replacement)
        XCTAssertThrowsError(try codec.open(spliced, recoveryKey: exported.recoveryKey)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .authenticationFailed)
        }
        var changedManifest = exported.encryptedData
        changedManifest[headerCount + 4] ^= 1
        XCTAssertThrowsError(try codec.open(changedManifest, recoveryKey: exported.recoveryKey)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .authenticationFailed)
        }
    }

    func testChunkedAuthenticatedBoundsFailBeforeMetadataAndSecureArchiveDecoding() throws {
        let invalidLength = try chunkedFixture(manifest: ["schemaVersion": 1], claimedArchiveLength: UInt64.max)
        XCTAssertThrowsError(try codec.open(invalidLength.data, recoveryKey: invalidLength.key)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .fileTooLarge)
        }
        let excessiveObjects = try chunkedFixture(manifest: [
            "schemaVersion": 1, "metadata": [:],
            "objects": Array(repeating: NSNull(), count: SpatialPlaceArchiveCodec.maximumObjectCount + 1)
        ])
        XCTAssertThrowsError(try codec.open(excessiveObjects.data, recoveryKey: excessiveObjects.key)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .fileTooLarge)
        }
        let source = try fixture()
        let incorrectDigest = try chunkedFixture(manifest: manifestDictionary(source), validChecksum: false)
        XCTAssertThrowsError(try codec.open(incorrectDigest.data, recoveryKey: incorrectDigest.key)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .checksumMismatch)
        }
        var oversizedManifest = Data("VISPACE-PLACE".utf8) + Data([0, 2, 255, 255, 255, 255])
        oversizedManifest.append(Data(repeating: 0, count: 50))
        XCTAssertThrowsError(try codec.open(oversizedManifest, recoveryKey: incorrectDigest.key)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .invalidDocument)
        }
    }

    func testManualRecordsBeyondAutomaticCapacityRoundTripAndImport() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = try manualFixture(count: 2_049)
        XCTAssertEqual(candidate.objects.filter { UserObjectRegistrationAccumulator.isManualRegistration($0) }.count, 2_049)
        let exported = try codec.seal(candidate)
        let restored = try codec.open(exported.encryptedData, recoveryKey: exported.recoveryKey)
        XCTAssertEqual(restored.objects, candidate.objects)
        let repository = makeRepository(root)
        let mapID = try await repository.importPortableCheckpoint(restored)
        let reloaded = try await repository.loadLatestValidCheckpoint(mapID: mapID)
        XCTAssertEqual(reloaded?.objects.count, candidate.objects.count)
    }

    func testAutomaticCapacityStillRejectsBeforeSecureArchiveDecodeAndStoreCreation() async throws {
        let source = try fixture()
        let record = try XCTUnwrap(source.objects.first)
        let objects = try (0...SpatialPlaceArchiveCodec.maximumAutomaticObjectCount).map { _ in
            var object = record.object
            object = try SpatialObject(id: ObjectID(), semanticLabel: object.semanticLabel, position: object.position,
                certainty: object.certainty, confidence: object.confidence, firstSeenAt: object.firstSeenAt,
                lastSeenAt: object.lastSeenAt, temporalRevision: object.temporalRevision)
            return try SpatialObjectMetadata(mapID: source.metadata.mapID, object: object, position: record.position)
        }
        let candidate = WorldMapRestoreCandidate(metadata: source.metadata, archive: source.archive, objects: objects)
        XCTAssertThrowsError(try codec.seal(candidate)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .fileTooLarge)
        }
        let crafted = try chunkedFixture(manifest: manifestDictionary(candidate))
        XCTAssertThrowsError(try codec.open(crafted.data, recoveryKey: crafted.key)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .fileTooLarge)
        }
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await makeRepository(root).importPortableCheckpoint(candidate); XCTFail("Expected automatic object limit") }
        catch { XCTAssertEqual(error as? SpatialPlaceArchiveError, .fileTooLarge) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testCancellationInterruptsArchiveChunkEncryptionAndDecryption() throws {
        let source = try fixture()
        let candidate = WorldMapRestoreCandidate(metadata: source.metadata,
            archive: Data(repeating: 0x31, count: SpatialPlaceArchiveCodec.archiveChunkBytes * 5), objects: source.objects)
        for decrypts in [false, true] {
            let counter = ArchiveCancellationCounter(cancelAt: 5)
            let cancellable = SpatialPlaceArchiveCodec(archiveValidator: { _ in }, checkCancellation: { try counter.check() })
            if decrypts {
                let exported = try codec.seal(candidate)
                XCTAssertThrowsError(try cancellable.open(exported.encryptedData, recoveryKey: exported.recoveryKey)) {
                    XCTAssertTrue($0 is CancellationError)
                }
            } else {
                XCTAssertThrowsError(try cancellable.seal(candidate)) { XCTAssertTrue($0 is CancellationError) }
            }
            XCTAssertEqual(counter.count, 5)
        }
    }

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
        future[Data("VISPACE-PLACE".utf8).count + 1] = 3
        XCTAssertThrowsError(try codec.open(future, recoveryKey: export.recoveryKey)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .unsupportedVersion(3))
        }
        let crafted = try encryptedFixture(manifest: ["schemaVersion": 99])
        XCTAssertThrowsError(try codec.open(crafted.data, recoveryKey: crafted.key)) {
            XCTAssertEqual($0 as? SpatialPlaceArchiveError, .unsupportedVersion(99))
        }
    }

    func testObjectLimitIsCheckedBeforeMalformedObjectOrMetadataDecode() throws {
        let crafted = try encryptedFixture(manifest: [
            "schemaVersion": 1, "metadata": [:],
            "objects": Array(repeating: NSNull(), count: SpatialPlaceArchiveCodec.legacyMaximumObjectCount + 1)
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

    func testFirstImportPrimaryWriteFailureRecoversEmptyCatalogAndAllowsRetry() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("spatial-metadata-v1.json")
        let collisionState = ArchiveCatalogCollisionState(target: primary, writeOrdinal: 2)
        let repository = makeRepository(root, collisionState: collisionState)
        let candidate = try fixture()

        do {
            _ = try await repository.importPortableCheckpoint(candidate)
            XCTFail("Expected the primary catalog write to fail")
        } catch {
            XCTAssertTrue(collisionState.didInjectCollision)
        }
        let backup = root.appendingPathComponent("spatial-metadata-v1.previous.json")
        let previous = try SpatialMetadataMigrator.decodeAndMigrate(Data(contentsOf: backup))
        XCTAssertTrue(previous.maps.isEmpty)
        XCTAssertTrue(previous.objects.isEmpty)
        XCTAssertEqual(try activeBlobNames(in: root), [])

        // Remove only the directory created by the fault injector. Recovery
        // must see the state from before the attempted import.
        try FileManager.default.removeItem(at: primary)
        let reopened = makeRepository(root)
        let recovered = try await reopened.metadataSnapshot()
        XCTAssertTrue(recovered.maps.isEmpty)
        XCTAssertTrue(recovered.objects.isEmpty)
        let importedID = try await reopened.importPortableCheckpoint(candidate)
        XCTAssertEqual(importedID, candidate.metadata.mapID)
    }

    func testFirstCheckpointPrimaryWriteFailureCannotRecoverAttemptedMap() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("spatial-metadata-v1.json")
        let collisionState = ArchiveCatalogCollisionState(target: primary, writeOrdinal: 2)
        let repository = makeRepository(root, collisionState: collisionState)

        do {
            _ = try await repository.saveCheckpoint(archive: Data("first".utf8),
                captureIdentity: ARCaptureIdentity(status: .confirmed))
            XCTFail("Expected the primary catalog write to fail")
        } catch {
            XCTAssertTrue(collisionState.didInjectCollision)
        }
        try FileManager.default.removeItem(at: primary)
        let recovered = try await makeRepository(root).metadataSnapshot()
        XCTAssertTrue(recovered.maps.isEmpty)
        XCTAssertTrue(recovered.objects.isEmpty)
        XCTAssertEqual(try activeBlobNames(in: root), [])
    }

    func testFirstImportBackupMaintenanceFailureKeepsPublishedMapAndBlob() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = root.appendingPathComponent("spatial-metadata-v1.previous.json")
        let collisionState = ArchiveCatalogCollisionState(target: backup, writeOrdinal: 3)
        let repository = makeRepository(root, collisionState: collisionState)
        let candidate = try fixture()

        let importedID = try await repository.importPortableCheckpoint(candidate)
        XCTAssertTrue(collisionState.didInjectCollision)
        XCTAssertEqual(importedID, candidate.metadata.mapID)
        try FileManager.default.removeItem(at: backup)
        let restored = try await makeRepository(root).loadLatestValidCheckpoint(mapID: importedID)
        XCTAssertEqual(restored?.archive, candidate.archive)
        XCTAssertEqual(restored?.objects, candidate.objects)
        XCTAssertEqual(try activeBlobNames(in: root).count, 1)
    }

    func testFirstCheckpointBackupMaintenanceFailureKeepsPublishedMapAndBlob() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = root.appendingPathComponent("spatial-metadata-v1.previous.json")
        let collisionState = ArchiveCatalogCollisionState(target: backup, writeOrdinal: 3)
        let repository = makeRepository(root, collisionState: collisionState)
        let archive = Data("first".utf8)

        let saved = try await repository.saveCheckpoint(archive: archive,
            captureIdentity: ARCaptureIdentity(status: .confirmed))
        XCTAssertTrue(collisionState.didInjectCollision)
        try FileManager.default.removeItem(at: backup)
        let restored = try await makeRepository(root).loadLatestValidCheckpoint(mapID: saved.mapID)
        XCTAssertEqual(restored?.archive, archive)
        XCTAssertEqual(try activeBlobNames(in: root), ["\(saved.worldMapBlobID.uuidString.lowercased()).vispacemap"])
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

    private func manualFixture(count: Int) throws -> WorldMapRestoreCandidate {
        let source = try fixture()
        let records = try (0..<count).map { index in
            let object = try SpatialObject(semanticLabel: UserObjectRegistrationAccumulator.semanticLabel,
                position: .zero, certainty: .confirmed, presence: .lastSeen,
                confidence: ConfidenceVector(semantic: .one, geometry: .one, tracking: .one,
                    identity: .one, objectState: .one),
                firstSeenAt: 1, lastSeenAt: 2, displayName: "직접 기억 \(index)")
            return try SpatialObjectMetadata(mapID: source.metadata.mapID, object: object,
                position: FramedPosition(coordinateFrameID: source.metadata.coordinateFrameID, value: .zero,
                    observedAt: 2, trackingQuality: .normal, uncertainty: .highConfidenceDepth))
        }
        return WorldMapRestoreCandidate(metadata: source.metadata, archive: source.archive, objects: source.objects + records)
    }

    private func manifestDictionary(_ candidate: WorldMapRestoreCandidate) throws -> [String: Any] {
        ["schemaVersion": 1,
         "metadata": try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate.metadata)),
         "objects": try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate.objects))]
    }

    /// Independent v2 fixture encoder for authenticated malformed manifests.
    private func chunkedFixture(manifest: [String: Any], claimedArchiveLength: UInt64? = nil,
                                validChecksum: Bool = true) throws -> (data: Data, key: String) {
        let archive = Data("world-map-fixture".utf8)
        func integer(_ value: UInt64, bytes: Int) -> Data {
            Data((0..<bytes).reversed().map { UInt8((value >> ($0 * 8)) & 255) })
        }
        let key = SymmetricKey(size: .bits256)
        let header = Data("VISPACE-PLACE".utf8) + Data([0, 2])
        var plaintext = integer(claimedArchiveLength ?? UInt64(archive.count), bytes: 8)
        plaintext.append(validChecksum ? Data(SHA256.hash(data: archive)) : Data(repeating: 0, count: 32))
        plaintext.append(try JSONSerialization.data(withJSONObject: manifest))
        let encryptedManifest = try XCTUnwrap(AES.GCM.seal(plaintext, using: key, authenticating: header).combined)
        var data = header + integer(UInt64(encryptedManifest.count), bytes: 4) + encryptedManifest
        let aad = header + Data(SHA256.hash(data: encryptedManifest)) + integer(0, bytes: 8)
        data.append(try XCTUnwrap(AES.GCM.seal(archive, using: key, authenticating: aad).combined))
        return (data, key.withUnsafeBytes { Data($0).base64EncodedString() })
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

    private func makeRepository(
        _ directory: URL, failCatalogWrites: Bool = false,
        collisionState: ArchiveCatalogCollisionState? = nil
    ) -> WorldMapCheckpointRepository {
        let blobs = ARWorldMapBlobStore(directoryURL: directory.appendingPathComponent("WorldMaps"),
            maximumArchiveBytes: ARWorldMapArchiveCodec.maximumArchiveBytes, archiveValidator: { _ in })
        if let collisionState {
            return WorldMapCheckpointRepository(directoryURL: directory, blobStore: blobs,
                fileManager: ArchiveCatalogCollisionFileManager(state: collisionState))
        }
        if failCatalogWrites {
            return WorldMapCheckpointRepository(directoryURL: directory, blobStore: blobs,
                fileManager: ArchiveFullDiskFileManager())
        }
        return WorldMapCheckpointRepository(directoryURL: directory, blobStore: blobs,
            fileManager: FileManager())
    }

    private func activeBlobNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("WorldMaps").path)
            .filter { $0.hasSuffix(".vispacemap") }
            .sorted()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vispace-portable-tests-\(UUID().uuidString)")
    }
}

private final class ArchiveCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAt: Int
    private var checks = 0
    var count: Int { lock.withLock { checks } }
    init(cancelAt: Int) { self.cancelAt = cancelAt }
    func check() throws {
        let cancelled = lock.withLock { checks += 1; return checks == cancelAt }
        if cancelled { throw CancellationError() }
    }
}

private final class ArchiveFullDiskFileManager: FileManager, @unchecked Sendable {
    override func attributesOfFileSystem(forPath path: String) throws -> [FileAttributeKey: Any] {
        [.systemFreeSize: NSNumber(value: 0)]
    }
}

/// Only this lock-protected state is shared with the test. The FileManager
/// instance itself is freshly created for, and owned by, the repository actor.
private final class ArchiveCatalogCollisionState: @unchecked Sendable {
    private let target: URL
    private let writeOrdinal: Int
    private let lock = NSLock()
    private var admissionCount = 0
    private var injected = false

    var didInjectCollision: Bool { lock.withLock { injected } }

    init(target: URL, writeOrdinal: Int) {
        self.target = target
        self.writeOrdinal = writeOrdinal
    }

    func nextCollisionTarget() -> URL? {
        lock.withLock {
            admissionCount += 1
            return admissionCount == writeOrdinal ? target : nil
        }
    }

    func recordCollision() {
        lock.withLock { injected = true }
    }
}

/// Forces an actual atomic Data.write failure by placing a directory at the
/// selected catalog destination immediately before its filesystem write.
/// Blob writes use a separate FileManager and cannot consume this ordinal.
private final class ArchiveCatalogCollisionFileManager: FileManager, @unchecked Sendable {
    private let state: ArchiveCatalogCollisionState

    init(state: ArchiveCatalogCollisionState) {
        self.state = state
        super.init()
    }

    override func attributesOfFileSystem(forPath path: String) throws -> [FileAttributeKey: Any] {
        var attributes = try super.attributesOfFileSystem(forPath: path)
        // Admission must reach Data.write, rather than fail a space-policy
        // precondition before exercising the real destination collision.
        attributes[.systemFreeSize] = NSNumber(value: Int64.max)
        if let target = state.nextCollisionTarget() {
            if fileExists(atPath: target.path) { try removeItem(at: target) }
            try createDirectory(at: target, withIntermediateDirectories: false)
            try Data("write-collision".utf8).write(to: target.appendingPathComponent("sentinel"))
            state.recordCollision()
        }
        return attributes
    }
}
