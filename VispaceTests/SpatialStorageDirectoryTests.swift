import Foundation
import VispaceCore
import XCTest

@testable import Vispace

final class SpatialStorageDirectoryTests: XCTestCase {
    func testFutureCatalogSchemasStayInPlaceForEveryRepository() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for fixture in SpatialCatalogFixture.allCases {
            let directory = root.appendingPathComponent(fixture.fileName)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.emptyCatalogData()) as? [String: Any])
            object["schemaVersion"] = 99
            let data = try JSONSerialization.data(withJSONObject: object)
            let file = directory.appendingPathComponent(fixture.fileName)
            try data.write(to: file)
            for _ in 0..<2 {
                do { _ = try await fixture.recordCount(at: directory); XCTFail("Expected compatibility failure") }
                catch { XCTAssertEqual(error as? SpatialStorageError, .unsupportedSchema(actual: 99)) }
                XCTAssertEqual(try Data(contentsOf: file), data)
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Quarantine").path))
            }
        }
    }

    func testCatalogAndDirectorySymlinksCannotReachExternalData() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("external.json")
        let bytes = try JSONEncoder().encode(PlaceMemoryCatalogSnapshot())
        try bytes.write(to: external)
        let directory = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(PlaceMemoryRepository.catalogFileName), withDestinationURL: external)
        do { _ = try await PlaceMemoryRepository(directoryURL: directory).catalogSnapshot(); XCTFail("Expected link rejection") }
        catch { XCTAssertEqual(error as? SpatialStorageError, .unsafePath) }
        let link = root.appendingPathComponent("linked-store")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        XCTAssertThrowsError(try SpatialStorageDirectory.prepare(at: link)) { error in
            XCTAssertEqual(error as? SpatialStorageError, .unsafePath)
        }
        XCTAssertEqual(try Data(contentsOf: external), bytes)
    }

    func testLowDiskSpaceRejectsAtomicWriteWithoutReplacingCatalog() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try SpatialStorageDirectory.prepare(at: root)
        let destination = root.appendingPathComponent("catalog.json")
        let original = Data("original".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try SpatialStorageDirectory.atomicWrite(
            Data("replacement".utf8), to: destination, directory: root,
            fileManager: FullDiskSpatialFileManager()
        )) { error in
            guard let storageError = error as? SpatialStorageError, case .insufficientFreeSpace = storageError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testDeletionCanUseReservedHeadroomWhileStillRequiringAtomicWriteSpace() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try SpatialStorageDirectory.prepare(at: root)
        let destination = root.appendingPathComponent("catalog.json")
        try Data(repeating: 1, count: 100).write(to: destination)
        let reduced = Data("{}".utf8)
        let manager = FullDiskSpatialFileManager(freeBytes: 10)
        XCTAssertThrowsError(try SpatialStorageDirectory.atomicWrite(reduced, to: destination, directory: root, fileManager: manager))
        try SpatialStorageDirectory.atomicWrite(reduced, to: destination, directory: root, fileManager: manager, reclaiming: true)
        XCTAssertEqual(try Data(contentsOf: destination), reduced)
        XCTAssertThrowsError(try SpatialStorageDirectory.atomicWrite(Data(repeating: 0, count: 11), to: destination, directory: root, fileManager: manager, reclaiming: true))
        XCTAssertEqual(try Data(contentsOf: destination), reduced)
    }

    func testFractionalSchemaDoesNotTruncateToSupportedVersion() throws {
        XCTAssertThrowsError(try SpatialStorageDirectory.validateJSONSchemas(Data("{\"schemaVersion\":1.9}".utf8))) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertThrowsError(try SpatialStorageDirectory.validateJSONSchemas(Data("{\"schemaVersion\":1,\"schema\":{\"version\":2}}".utf8))) { error in
            XCTAssertEqual(error as? SpatialStorageError, .unsupportedSchema(actual: 2))
        }
    }

    func testMaintenanceBoundsQuarantineAndPreservesUnknownFiles() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let quarantine = root.appendingPathComponent("Quarantine")
        try SpatialStorageDirectory.prepare(at: quarantine)
        let now = Date()
        for index in 0..<70 {
            let file = quarantine.appendingPathComponent("place-memory-v1.\(UUID().uuidString).json.quarantined")
            try Data([UInt8(index)]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(index) - 100)], ofItemAtPath: file.path)
        }
        let unknown = quarantine.appendingPathComponent("keep.reason.txt")
        try Data("keep".utf8).write(to: unknown)
        let staged = root.appendingPathComponent(".\(UUID().uuidString).\(UUID().uuidString).staged")
        try Data("abandoned".utf8).write(to: staged)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90_000)], ofItemAtPath: staged.path)
        try SpatialStorageDirectory.maintainArtifacts(at: root, now: now)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: quarantine.path).count, 65)
        XCTAssertEqual(try Data(contentsOf: unknown), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
    func testPolicyRequestsProtectionForNewAndExistingDirectories() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = RecordingSpatialProtectionFileManager()
        try SpatialStorageDirectory.prepare(at: root, fileManager: manager)
        let initialRequests = manager.requestedProtection.count
        XCTAssertGreaterThan(initialRequests, 0)
        try SpatialStorageDirectory.prepare(at: root, fileManager: manager, createIfMissing: false)
        XCTAssertGreaterThan(manager.requestedProtection.count, initialRequests)
        XCTAssertTrue(
            manager.requestedProtection.allSatisfy {
                $0 == FileProtectionType.completeUntilFirstUserAuthentication.rawValue
            })
        try assertSpatialDirectoryPolicy(at: root)
    }

    func testEffectiveFileProtectionOnPhysicalDevice() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("iOS Simulator does not implement physical-device Data Protection attributes.")
        #else
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try SpatialStorageDirectory.prepare(at: root)
            try assertSpatialDirectoryPolicy(at: root)
        #endif
    }

    func testNewArbitraryDirectoryIsProtectedWithoutChangingItsParent() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try setSpatialBackupExclusion(false, at: root)
        let sibling = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sibling)
        let store = root.appendingPathComponent("custom-store", isDirectory: true)

        try SpatialStorageDirectory.prepare(at: store)

        try assertSpatialDirectoryPolicy(at: store)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.path), [])
        XCTAssertEqual(try Data(contentsOf: sibling), Data("keep".utf8))
        XCTAssertEqual(
            try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            false
        )
    }

    func testExistingDirectoryIsRepairedWithoutTouchingChildren() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try resetSpatialDirectoryPolicy(at: root)
        let child = root.appendingPathComponent("Quarantine")
        try Data("not-a-directory".utf8).write(
            to: child,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )

        try SpatialStorageDirectory.prepare(at: root, createIfMissing: false)
        try SpatialStorageDirectory.prepare(at: root, createIfMissing: false)

        try assertSpatialDirectoryPolicy(at: root)
        XCTAssertEqual(try Data(contentsOf: child), Data("not-a-directory".utf8))
        try assertSpatialProtection(at: child, expected: .completeUnlessOpen)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Quarantine"])
    }

    func testExistingDirectoryModeDoesNotCreateMissingStores() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try SpatialStorageDirectory.prepare(at: root, createIfMissing: false)
        for fixture in SpatialCatalogFixture.allCases {
            let count = try await fixture.recordCount(at: root)
            XCTAssertEqual(count, 0)
        }
        let blobs = ARWorldMapBlobStore(directoryURL: root)
        let ids = try await blobs.activeBlobIDs()
        XCTAssertEqual(ids, [])
        do {
            _ = try await blobs.loadArchive(id: WorldMapBlobID())
            XCTFail("Expected a missing blob")
        } catch {
            XCTAssertEqual(error as? WorldMapBlobStoreError, .blobNotFound)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testEveryCatalogReadRepairsExistingPolicyWithoutRewritingData() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for fixture in SpatialCatalogFixture.allCases {
            let directory = root.appendingPathComponent(fixture.fileName, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let catalog = directory.appendingPathComponent(fixture.fileName)
            let original = try fixture.emptyCatalogData()
            try original.write(to: catalog)
            try resetSpatialDirectoryPolicy(at: directory)

            let count = try await fixture.recordCount(at: directory)

            XCTAssertEqual(count, 0, fixture.fileName)
            try assertSpatialDirectoryPolicy(at: directory)
            XCTAssertEqual(try Data(contentsOf: catalog), original, fixture.fileName)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: directory.path),
                [fixture.fileName]
            )
        }
    }

    func testPolicyFailurePropagatesWithoutQuarantiningOrChangingCatalogs() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for fixture in SpatialCatalogFixture.allCases {
            let directory = root.appendingPathComponent(fixture.fileName, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let catalog = directory.appendingPathComponent(fixture.fileName)
            let original = try fixture.emptyCatalogData()
            try original.write(to: catalog)
            do {
                _ = try await fixture.recordCount(
                    at: directory,
                    failProtection: true
                )
                XCTFail("Expected directory protection failure for \(fixture.fileName)")
            } catch {
                XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
                XCTAssertEqual(
                    (error as NSError).code,
                    CocoaError.Code.fileWriteNoPermission.rawValue
                )
            }
            XCTAssertEqual(try Data(contentsOf: catalog), original, fixture.fileName)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: directory.path),
                [fixture.fileName]
            )
        }
    }

    func testEveryCatalogQuarantineIsProtectedAndPreservesCorruptBytes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = Data("not-valid-json".utf8)
        for fixture in SpatialCatalogFixture.allCases {
            let directory = root.appendingPathComponent(fixture.fileName, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let quarantine = directory.appendingPathComponent("Quarantine", isDirectory: true)
            // Exercise both creation and repair of a quarantine from an older version.
            for existingQuarantine in [false, true] {
                if existingQuarantine {
                    try resetSpatialDirectoryPolicy(at: quarantine)
                }
                try corrupt.write(to: directory.appendingPathComponent(fixture.fileName))

                let count = try await fixture.recordCount(at: directory)

                XCTAssertEqual(count, 0)
                try assertSpatialDirectoryPolicy(at: directory)
                try assertSpatialDirectoryPolicy(at: quarantine)
                let preserved = try FileManager.default.contentsOfDirectory(
                    at: quarantine,
                    includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "quarantined" }
                XCTAssertEqual(preserved.count, existingQuarantine ? 2 : 1)
                for file in preserved {
                    XCTAssertEqual(try Data(contentsOf: file), corrupt)
                }
            }
        }
    }

    func testPolicyRejectsRegularFileWithoutReplacingIt() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocked = root.appendingPathComponent("blocked")
        try Data("keep".utf8).write(to: blocked)

        XCTAssertThrowsError(try SpatialStorageDirectory.prepare(at: blocked))

        XCTAssertEqual(try Data(contentsOf: blocked), Data("keep".utf8))
    }

    func testBlobPolicyFailurePreventsReadsAndPublishing() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ARWorldMapBlobStore(
            directoryURL: root,
            maximumArchiveBytes: 1_024,
            archiveValidator: { _ in }
        )
        let saved = try await store.saveArchive(Data("keep".utf8))
        let original = try Data(contentsOf: saved.fileURL)
        let blocked = ARWorldMapBlobStore(
            directoryURL: root,
            maximumArchiveBytes: 1_024,
            fileManager: FailingSpatialProtectionFileManager(),
            archiveValidator: { _ in }
        )

        do {
            _ = try await blocked.loadArchive(id: saved.id)
            XCTFail("Expected protection failure before reading the blob")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, CocoaError.Code.fileWriteNoPermission.rawValue)
        }
        do {
            _ = try await blocked.saveArchive(Data("new".utf8))
            XCTFail("Expected protection failure before publishing a blob")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, CocoaError.Code.fileWriteNoPermission.rawValue)
        }
        XCTAssertEqual(try Data(contentsOf: saved.fileURL), original)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            [saved.fileURL.lastPathComponent]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "vispace-storage-policy-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private final class FullDiskSpatialFileManager: FileManager, @unchecked Sendable {
    private let freeBytes: Int64
    init(freeBytes: Int64 = 0) {
        self.freeBytes = freeBytes
        super.init()
    }
    override func attributesOfFileSystem(forPath path: String) throws -> [FileAttributeKey: Any] {
        [.systemFreeSize: NSNumber(value: freeBytes)]
    }
}

func assertSpatialDirectoryPolicy(
    at directory: URL,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let freshURL = URL(fileURLWithPath: directory.path, isDirectory: true)
    XCTAssertEqual(
        try freshURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
        true,
        file: file,
        line: line
    )
    try assertSpatialProtection(
        at: directory,
        expected: .completeUntilFirstUserAuthentication,
        file: file,
        line: line
    )
}

private func assertSpatialProtection(
    at url: URL,
    expected: FileProtectionType,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let value = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
    let rawValue = (value as? FileProtectionType)?.rawValue ?? (value as? String)
    #if targetEnvironment(simulator)
        // The simulator returned nil for this OS-only attribute in the
        // validation run. Backup-exclusion assertions above still run, and a
        // separate spy verifies the protection request. Device proof is kept
        // as an explicitly skipped test, never reported as simulated proof.
        if rawValue == nil { return }
    #endif
    XCTAssertEqual(rawValue, expected.rawValue, file: file, line: line)
}

func resetSpatialDirectoryPolicy(at directory: URL) throws {
    try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.none],
        ofItemAtPath: directory.path
    )
    try setSpatialBackupExclusion(false, at: directory)
}

private func setSpatialBackupExclusion(_ excluded: Bool, at directory: URL) throws {
    var url = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = excluded
    try url.setResourceValues(values)
}

private final class FailingSpatialProtectionFileManager: FileManager, @unchecked Sendable {
    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class RecordingSpatialProtectionFileManager: FileManager, @unchecked Sendable {
    var requestedProtection: [String] = []

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            requestedProtection.append(protection.rawValue)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

private enum SpatialCatalogFixture: CaseIterable {
    case worldMaps, places, alignments, sceneGraphs, journals

    var fileName: String {
        switch self {
        case .worldMaps: "spatial-metadata-v1.json"
        case .places: PlaceMemoryRepository.catalogFileName
        case .alignments: CoordinateAlignmentRepository.catalogFileName
        case .sceneGraphs: SceneGraphRepository.catalogFileName
        case .journals: TemporalSpatialMemoryJournalRepository.catalogFileName
        }
    }

    func emptyCatalogData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        switch self {
        case .worldMaps:
            return try encoder.encode(SpatialMetadataDocument())
        case .places:
            return try encoder.encode(PlaceMemoryCatalogSnapshot())
        case .alignments:
            return try encoder.encode(CoordinateAlignmentCatalogSnapshot())
        case .sceneGraphs:
            return try encoder.encode(SceneGraphCatalogSnapshot())
        case .journals:
            return try encoder.encode(TemporalSpatialMemoryJournalCatalog())
        }
    }

    func recordCount(at directory: URL, failProtection: Bool = false) async throws -> Int {
        // Each actor receives its own manager. Do not transfer a caller-owned
        // non-Sendable Foundation reference into a repository actor.
        let fileManager: FileManager =
            failProtection
            ? FailingSpatialProtectionFileManager() : FileManager()
        switch self {
        case .worldMaps:
            let catalog = try await WorldMapCheckpointRepository(
                directoryURL: directory,
                fileManager: fileManager
            ).metadataSnapshot()
            return catalog.maps.count + catalog.objects.count
        case .places:
            let catalog = try await PlaceMemoryRepository(
                directoryURL: directory,
                fileManager: fileManager
            ).catalogSnapshot()
            return catalog.fingerprints.count + catalog.associationStates.count
        case .alignments:
            return try await CoordinateAlignmentRepository(
                directoryURL: directory,
                fileManager: fileManager
            ).catalogSnapshot().alignments.count
        case .sceneGraphs:
            return try await SceneGraphRepository(
                directoryURL: directory,
                fileManager: fileManager
            ).catalogSnapshot().records.count
        case .journals:
            return try await TemporalSpatialMemoryJournalRepository(
                directoryURL: directory,
                fileManager: fileManager
            ).catalogSnapshot().journals.count
        }
    }
}
