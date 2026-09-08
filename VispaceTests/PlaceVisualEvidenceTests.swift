import CoreVideo
import Foundation
import VispaceCore
import XCTest
import simd

@testable import Vispace

final class PlaceVisualEvidenceTests: XCTestCase {
    func testRealCameraBufferProducesRevisionPinnedVisionFeatures() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip(
                "iOS 26.5 Simulator Vision returns identical Revision2 features for distinct images on CPU, "
                    + "and its GPU cannot create an Espresso context. Run this integration test on physical iOS."
            )
        #else
            let frame = try cameraFrame()
            let extractor = PlaceVisualCameraExtractor()
            let box = NormalizedBoundingBox(x: 0.15, y: 0.15, width: 0.7, height: 0.7)
            let first = try XCTUnwrap(extractor.descriptor(frame: frame, box: box))
            let second = try XCTUnwrap(extractor.descriptor(frame: frame, box: box))
            XCTAssertEqual(first.revision, 2)
            XCTAssertTrue(first.isValid)
            XCTAssertEqual(try XCTUnwrap(first.distance(to: first)), 0)
            XCTAssertEqual(try XCTUnwrap(first.distance(to: second)), 0, accuracy: 0.0001)
            // A changed real input must exceed the production landmark-match gate;
            // a constant-feature backend cannot satisfy the integration contract.
            let changed = try XCTUnwrap(extractor.descriptor(frame: cameraFrame(uniform: true), box: box))
            XCTAssertGreaterThan(try XCTUnwrap(first.distance(to: changed)), 0.12)
            let restored = try JSONDecoder().decode(
                PlaceVisualDescriptor.self, from: JSONEncoder().encode(first))
            XCTAssertEqual(restored, first)
        #endif
    }

    #if targetEnvironment(simulator)
        func testSimulatorDoesNotAdmitUnavailableCameraFeatures() throws {
            let extractor = PlaceVisualCameraExtractor()
            let box = NormalizedBoundingBox(x: 0.15, y: 0.15, width: 0.7, height: 0.7)
            XCTAssertNil(try extractor.descriptor(frame: cameraFrame(), box: box))
            XCTAssertNil(try extractor.descriptor(frame: cameraFrame(uniform: true), box: box))
        }
    #endif

    func testFreshDistinctCameraLandmarksAlignAcrossFramesAndPersist() async throws {
        let fixture = try VisualFixture()
        // The descriptor catalog survives a process boundary; source evidence
        // still comes only from new live captures, never catalog replay.
        let restored = try JSONDecoder().decode(
            [PlaceVisualLandmark].self, from: JSONEncoder().encode(fixture.target)
        )
        let matches = try fixture.match(target: restored)
        XCTAssertEqual(matches.count, 3)
        let resolved = PlaceCoordinateAlignmentResolver().resolve(
            current: fixture.surface(), candidate: fixture.candidate,
            verifiedVisualCorrespondences: matches
        )
        let alignment = try XCTUnwrap(resolved.validatedAlignment)
        XCTAssertEqual(
            try alignment.sourceToTarget.transformed(fixture.source[0].position).x, 10, accuracy: 1e-8)
        XCTAssertEqual(
            try alignment.sourceToTarget.transformed(fixture.source[0].position).z, -2, accuracy: 1e-8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CoordinateAlignmentRepository(directoryURL: directory)
        let record = try CoordinateAlignmentRecord(
            sourceMapID: fixture.sourceMap, sourceCoordinateFrameID: fixture.sourceFrame,
            targetMapID: fixture.targetMap, targetCoordinateFrameID: fixture.targetFrame,
            result: alignment, createdAt: 10, updatedAt: 10
        )
        _ = try await repository.commitIfAbsent(record)
        let restarted = CoordinateAlignmentRepository(directoryURL: directory)
        let saved = try await restarted.listAlignments()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].result, try record.canonicalized().result)
    }

    func testSimilarGeometryWithoutMatchingCameraAppearanceCannotAlign() throws {
        let fixture = try VisualFixture()
        let otherRoom = fixture.target.enumerated().map { index, record in
            record.replacing(appearance: VisualFixture.descriptor(index + 10))
        }
        XCTAssertTrue(try fixture.match(target: otherRoom).isEmpty)
        let differentScene = fixture.target.map { $0.replacing(scene: VisualFixture.descriptor(15)) }
        XCTAssertTrue(try fixture.match(target: differentScene).isEmpty)
    }

    func testRepeatedAppearanceAndCompetingSavedRoomsRemainAmbiguous() throws {
        let fixture = try VisualFixture()
        let repeated = fixture.target.map { $0.replacing(appearance: VisualFixture.descriptor(0)) }
        XCTAssertTrue(try fixture.match(target: repeated).isEmpty)
        let cloneMap = MapID()
        let clones = fixture.target.map { $0.replacing(mapID: cloneMap, objectID: ObjectID()) }
        let objects = try fixture.objects + clones.map(VisualFixture.metadata)
        let matches = try PlaceVisualCorrespondenceMatcher().correspondences(
            current: fixture.surface(), candidate: fixture.candidate, live: fixture.source,
            durable: fixture.target + clones, objects: objects
        )
        XCTAssertTrue(matches.isEmpty)
    }

    func testVerifiedRoomAliasesSurviveRepeatedVisitsButDifferentRoomStillCompetes() async throws {
        let fixture = try VisualFixture()
        let aliasMap = MapID()
        let aliasFrame = CoordinateFrameID()
        let alias = fixture.target.map {
            $0.replacing(mapID: aliasMap, frame: aliasFrame, objectID: ObjectID())
        }
        let thirdMap = MapID()
        let thirdFrame = CoordinateFrameID()
        let third = fixture.target.map {
            $0.replacing(mapID: thirdMap, frame: thirdFrame, objectID: ObjectID())
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CoordinateAlignmentRepository(directoryURL: directory)
        try await repository.commitIfAbsent(visualAlignment(from: fixture.target, to: alias))
        try await repository.commitIfAbsent(visualAlignment(from: alias, to: third))
        let restarted = CoordinateAlignmentRepository(directoryURL: directory)
        let catalog = try await restarted.catalogSnapshot()
        let durable = fixture.target + alias + third
        let objects = try fixture.objects + (alias + third).map(VisualFixture.metadata)
        let matcher = PlaceVisualCorrespondenceMatcher()
        func match(
            _ records: [PlaceVisualLandmark], _ objects: [SpatialObjectMetadata],
            _ catalog: CoordinateAlignmentCatalogSnapshot?
        ) throws -> [CoordinateFrameAlignmentCorrespondence] {
            try matcher.correspondences(
                current: fixture.surface(), candidate: fixture.candidate,
                live: fixture.source, durable: records, objects: objects, verifiedAlignments: catalog)
        }
        XCTAssertEqual(try match(durable, objects, catalog).count, 3)
        XCTAssertTrue(try match(durable, objects, nil).isEmpty)
        let unrelatedMap = MapID()
        let unrelated = fixture.target.map { $0.replacing(mapID: unrelatedMap, objectID: ObjectID()) }
        XCTAssertTrue(
            try match(durable + unrelated, objects + unrelated.map(VisualFixture.metadata), catalog).isEmpty)
        let repeated = fixture.target.map { $0.replacing(appearance: VisualFixture.descriptor(0)) }
        XCTAssertTrue(try match(repeated + alias + third, objects, catalog).isEmpty)
        let wrongFrame = alias.map { $0.replacing(frame: CoordinateFrameID()) }
        XCTAssertTrue(
            try match(
                fixture.target + wrongFrame,
                fixture.objects + wrongFrame.map(VisualFixture.metadata), catalog
            ).isEmpty)
        // Deleting a bridge retires its graph edges. A disconnected map must
        // become a competitor again, even if an older matcher used the group.
        try await restarted.deleteMap(mapID: aliasMap)
        let afterDeletion = try await restarted.catalogSnapshot()
        XCTAssertTrue(
            try match(
                fixture.target + third,
                fixture.objects + third.map(VisualFixture.metadata), afterDeletion
            ).isEmpty)
    }

    func testOldWrongSegmentSingleCaptureAndRemovedEvidenceFailClosed() throws {
        let fixture = try VisualFixture()
        XCTAssertTrue(try fixture.match(surface: fixture.surface(timestamp: 20)).isEmpty)
        XCTAssertTrue(try fixture.match(surface: fixture.surface(segment: CaptureSegmentID())).isEmpty)
        XCTAssertTrue(try fixture.match(source: fixture.source.map { $0.replacing(support: 1) }).isEmpty)
        XCTAssertTrue(try fixture.match(source: fixture.source.map { $0.replacing(timestamp: 20) }).isEmpty)
        XCTAssertTrue(
            try fixture.match(source: fixture.source.map { $0.replacing(frame: CoordinateFrameID()) }).isEmpty
        )
        let missingTargets = fixture.objects.filter { $0.mapID == fixture.sourceMap }
        XCTAssertTrue(
            try PlaceVisualCorrespondenceMatcher().correspondences(
                current: fixture.surface(), candidate: fixture.candidate, live: fixture.source,
                durable: fixture.target, objects: missingTargets
            ).isEmpty)
    }

    func testChangedDurablePositionOrLabelInvalidatesSavedAppearance() throws {
        let fixture = try VisualFixture()
        let changed = fixture.target.map { $0.replacing(position: try! Vec3(x: 30, y: 0, z: 30)) }
        XCTAssertTrue(try fixture.match(target: changed).isEmpty)
        XCTAssertTrue(
            try fixture.match(target: fixture.target.map { $0.replacing(label: "replacement") }).isEmpty)
    }

    func testDistinctVisualMatchesStillRejectCollinearAndInsufficientGeometry() throws {
        let fixture = try VisualFixture(collinear: true)
        let matches = try fixture.match()
        XCTAssertEqual(matches.count, 3)
        let resolver = PlaceCoordinateAlignmentResolver()
        XCTAssertEqual(
            resolver.resolve(
                current: fixture.surface(), candidate: fixture.candidate,
                verifiedVisualCorrespondences: matches
            ).evidence, .unresolved)
        XCTAssertEqual(
            resolver.resolve(
                current: fixture.surface(), candidate: fixture.candidate,
                verifiedVisualCorrespondences: Array(matches.prefix(2))
            ).evidence, .unresolved)
    }

    func testDescriptorValidationRejectsUnsupportedNonNormalizedAndNonFiniteInput() {
        XCTAssertFalse(PlaceVisualDescriptor(revision: 1, values: VisualFixture.descriptor(0).values).isValid)
        XCTAssertFalse(PlaceVisualDescriptor(revision: 2, values: [1]).isValid)
        XCTAssertFalse(PlaceVisualDescriptor(revision: 2, values: Array(repeating: 1, count: 64)).isValid)
        var values = VisualFixture.descriptor(0).values
        values[4] = .nan
        XCTAssertFalse(PlaceVisualDescriptor(revision: 2, values: values).isValid)
    }

    func testPortableObjectsPeopleAndAnimalsCannotEstablishRoomIdentity() {
        for label in ["person", "dog", "cat", "laptop", "backpack", "book", "bottle"] {
            XCTAssertFalse(PlaceVisualLandmark.admitsLabel(label))
        }
        for label in ["chair", "dining table", "sofa", "refrigerator"] {
            XCTAssertTrue(PlaceVisualLandmark.admitsLabel(label))
        }
    }

    func testDecoderRejectsOversizedAndUnnormalizedDescriptorsBeforeAdmission() throws {
        for values in [Array(repeating: Float(0), count: 4_097), Array(repeating: Float(1), count: 64)] {
            let data = try JSONEncoder().encode(PlaceVisualDescriptor(revision: 2, values: values))
            XCTAssertThrowsError(try JSONDecoder().decode(PlaceVisualDescriptor.self, from: data))
        }
    }

    func testProviderRestartCannotReplayDurableEvidenceAsLiveSourceAndDeletionRemovesFeatures() async throws {
        let fixture = try VisualFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        struct Catalog: Codable {
            let schemaVersion: Int
            let landmarks: [PlaceVisualLandmark]
        }
        let url = directory.appendingPathComponent(ARPlaceVisualEvidenceProvider.fileName)
        try JSONEncoder().encode(Catalog(schemaVersion: 1, landmarks: fixture.source + fixture.target)).write(
            to: url)
        let provider = ARPlaceVisualEvidenceProvider(directoryURL: directory)
        let result = try await provider.resolve(
            current: fixture.surface(), candidate: fixture.candidate, objects: fixture.objects)
        XCTAssertEqual(result.evidence, .unresolved)
        let histogram = await provider.visualHistogram(matching: fixture.surface())
        XCTAssertNil(histogram)
        try await provider.deleteMap(fixture.targetMap)
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        XCTAssertEqual(catalog.landmarks.count, 3)
        XCTAssertTrue(catalog.landmarks.allSatisfy { $0.mapID == fixture.sourceMap })
    }

    func testPlaceDeletionUsesReservedSpaceButStillRequiresRoomForAtomicReplacement() async throws {
        let fixture = try VisualFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        struct Catalog: Codable {
            let schemaVersion: Int
            let landmarks: [PlaceVisualLandmark]
        }
        let url = directory.appendingPathComponent(ARPlaceVisualEvidenceProvider.fileName)
        let original = try JSONEncoder().encode(Catalog(schemaVersion: 1, landmarks: fixture.source + fixture.target))
        let remaining = try JSONEncoder().encode(Catalog(schemaVersion: 1, landmarks: fixture.source))
        try original.write(to: url)
        let insufficient = ARPlaceVisualEvidenceProvider(
            directoryURL: directory,
            fileManager: VisualEvidenceDiskSpaceFileManager(freeBytes: Int64(remaining.count - 1)))
        do {
            try await insufficient.deleteMap(fixture.targetMap)
            XCTFail("Atomic deletion still needs space for the replacement catalog")
        } catch {
            XCTAssertEqual(error as? SpatialStorageError,
                           .insufficientFreeSpace(requiredBytes: Int64(remaining.count)))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)

        let enoughForDeletion = ARPlaceVisualEvidenceProvider(
            directoryURL: directory,
            fileManager: VisualEvidenceDiskSpaceFileManager(freeBytes: Int64(remaining.count)))
        try await enoughForDeletion.deleteMap(fixture.targetMap)
        let retained = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        XCTAssertEqual(retained.landmarks, fixture.source)
    }

    func testCorruptVisualCatalogIsPreservedAndDoesNotBlockPlaceDeletion() async throws {
        let fixture = try VisualFixture()
        struct Catalog: Encodable {
            let schemaVersion = 1
            let landmarks: [PlaceVisualLandmark]
        }
        let invalidLandmark = fixture.target[0].replacing(support: 0)
        let invalidCatalogs = try [
            Data("not-valid-json".utf8),
            JSONEncoder().encode(Catalog(landmarks: [fixture.target[0], fixture.target[0]])),
            JSONEncoder().encode(Catalog(landmarks: [invalidLandmark])),
        ]
        for original in invalidCatalogs {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(ARPlaceVisualEvidenceProvider.fileName)
            try original.write(to: url)
            let provider = ARPlaceVisualEvidenceProvider(directoryURL: directory)
            let result = try await provider.resolve(
                current: fixture.surface(), candidate: fixture.candidate, objects: fixture.objects)
            XCTAssertEqual(result.evidence, .unresolved)
            let quarantine = directory.appendingPathComponent("Quarantine")
            let preserved = try XCTUnwrap(FileManager.default.contentsOfDirectory(
                at: quarantine, includingPropertiesForKeys: nil).first { $0.pathExtension == "quarantined" })
            XCTAssertEqual(try Data(contentsOf: preserved), original)
            try await provider.deleteMap(fixture.targetMap)
            let remaining = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual((remaining["landmarks"] as? [Any])?.count, 0)
            XCTAssertEqual(try Data(contentsOf: preserved), original)
        }
    }

    func testFutureVisualCatalogAndReadFailureRemainInPlace() async throws {
        let fixture = try VisualFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(ARPlaceVisualEvidenceProvider.fileName)
        let original = Data("{\"schemaVersion\":99,\"landmarks\":[]}".utf8)
        try original.write(to: url)
        let provider = ARPlaceVisualEvidenceProvider(directoryURL: directory)
        do {
            try await provider.deleteMap(fixture.targetMap)
            XCTFail("A newer catalog must remain available to its writer")
        } catch {
            XCTAssertEqual(error as? SpatialStorageError, .unsupportedSchema(actual: 99))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let inaccessible = ARPlaceVisualEvidenceProvider(
            directoryURL: directory, fileManager: VisualEvidenceReadFailureFileManager(deniedPath: url.path))
        do {
            _ = try await inaccessible.resolve(
                current: fixture.surface(), candidate: fixture.candidate, objects: fixture.objects)
            XCTFail("A transient file error must propagate without recovery")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, CocoaError.Code.fileReadNoPermission.rawValue)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Quarantine").path))
    }

    func testOversizedFutureVisualCatalogRemainsInPlace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(ARPlaceVisualEvidenceProvider.fileName)
        var original = Data("{\"schemaVersion\":99,\"landmarks\":[]}".utf8)
        original.append(Data(repeating: 0x20, count: ARPlaceVisualEvidenceProvider.maximumBytes))
        try original.write(to: url)
        let provider = ARPlaceVisualEvidenceProvider(directoryURL: directory)
        do {
            try await provider.deleteMap(MapID())
            XCTFail("An unclassified oversized catalog must not enter quarantine")
        } catch {
            XCTAssertEqual(error as? SpatialStorageError,
                           .capacityExceeded(maximumBytes: Int64(ARPlaceVisualEvidenceProvider.maximumBytes)))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Quarantine").path))
    }

    private func visualAlignment(
        from source: [PlaceVisualLandmark], to target: [PlaceVisualLandmark]
    ) throws -> CoordinateAlignmentRecord {
        let correspondences = try zip(source, target).map { source, target in
            try CoordinateFrameAlignmentCorrespondence(
                source: CoordinateFrameAlignmentSourcePoint(
                    objectID: source.objectID,
                    coordinateFrameID: source.coordinateFrameID, semanticLabel: source.semanticLabel,
                    position: source.position),
                target: CoordinateFrameAlignmentTargetPoint(
                    objectID: target.objectID,
                    coordinateFrameID: target.coordinateFrameID, semanticLabel: target.semanticLabel,
                    position: target.position),
                identityConfidence: .one)
        }
        let result = try CoordinateFrameAlignmentEstimator().estimate(correspondences: correspondences)
        return try CoordinateAlignmentRecord(
            sourceMapID: source[0].mapID, sourceCoordinateFrameID: source[0].coordinateFrameID,
            targetMapID: target[0].mapID, targetCoordinateFrameID: target[0].coordinateFrameID,
            result: result, createdAt: 1, updatedAt: 1)
    }

    private func cameraFrame(uniform: Bool = false) throws -> ARFrameSnapshot {
        var buffer: CVPixelBuffer?
        let attributes =
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, 256, 256, kCVPixelFormatType_32BGRA, attributes, &buffer),
            kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(image, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(image))
        let rowBytes = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<256 {
            for x in 0..<256 {
                let offset = y * rowBytes + x * 4
                base.storeBytes(of: uniform ? UInt8(240) : UInt8(x), toByteOffset: offset, as: UInt8.self)
                base.storeBytes(of: uniform ? UInt8(30) : UInt8(y), toByteOffset: offset + 1, as: UInt8.self)
                base.storeBytes(
                    of: uniform ? UInt8(50) : UInt8((x / 16 + y / 16).isMultiple(of: 2) ? 220 : 20),
                    toByteOffset: offset + 2,
                    as: UInt8.self)
                base.storeBytes(of: UInt8(255), toByteOffset: offset + 3, as: UInt8.self)
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        return ARFrameSnapshot(
            pose: ARPoseSnapshot(
                id: ARFrameID(), sessionToken: .init(sessionRunGeneration: 1, attachmentEpoch: 1),
                coordinateFrameID: CoordinateFrameID(), segmentID: CaptureSegmentID(), mapID: MapID(),
                coordinateFrameStatus: .confirmed, capturedAt: 100, timestamp: 10,
                cameraTransform: Matrix4x4Snapshot(matrix_identity_float4x4),
                trackingState: .normal, worldMappingStatus: .mapped),
            imageOrientation: .up, capturedImage: ImmutablePixelBuffer(pixelBuffer: image),
            cameraIntrinsics: Matrix3x3Snapshot(matrix_identity_float3x3),
            cameraImageDimensions: ImageDimensions(width: 256, height: 256), displayTransform: nil,
            sceneDepth: nil, smoothedSceneDepth: nil)
    }
}

private final class VisualEvidenceDiskSpaceFileManager: FileManager, @unchecked Sendable {
    private let freeBytes: Int64

    init(freeBytes: Int64) {
        self.freeBytes = freeBytes
        super.init()
    }

    override func attributesOfFileSystem(forPath path: String) throws -> [FileAttributeKey: Any] {
        [.systemFreeSize: NSNumber(value: freeBytes)]
    }
}

private final class VisualEvidenceReadFailureFileManager: FileManager, @unchecked Sendable {
    private let deniedPath: String

    init(deniedPath: String) {
        self.deniedPath = deniedPath
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if path == deniedPath { throw CocoaError(.fileReadNoPermission) }
        return try super.attributesOfItem(atPath: path)
    }
}

private struct VisualFixture {
    let sourceMap: MapID
    let targetMap: MapID
    let sourceFrame: CoordinateFrameID
    let targetFrame: CoordinateFrameID
    let segment: CaptureSegmentID
    let source: [PlaceVisualLandmark]
    let target: [PlaceVisualLandmark]
    let objects: [SpatialObjectMetadata]
    let candidate: PlaceFingerprintRecord

    init(collinear: Bool = false) throws {
        let sourceMap = MapID()
        let targetMap = MapID()
        let sourceFrame = CoordinateFrameID()
        let targetFrame = CoordinateFrameID()
        let segment = CaptureSegmentID()
        self.sourceMap = sourceMap
        self.targetMap = targetMap
        self.sourceFrame = sourceFrame
        self.targetFrame = targetFrame
        self.segment = segment
        let points = try [
            Vec3(x: 0, y: 0, z: 0), Vec3(x: 2, y: 0, z: 0),
            Vec3(x: collinear ? 4 : 0, y: 0, z: collinear ? 0 : 2),
        ]
        let source = points.enumerated().map { index, point in
            PlaceVisualLandmark(
                mapID: sourceMap, coordinateFrameID: sourceFrame, segmentID: segment,
                frameID: UUID(), sessionRunGeneration: 2, attachmentEpoch: 1,
                objectID: ObjectID(), semanticLabel: ["chair", "lamp", "table"][index],
                position: point, capturedAt: 100, timestamp: 10, supportingCaptureCount: 2,
                appearance: Self.descriptor(index), sceneAppearance: Self.descriptor(20)
            )
        }
        let target = try source.map { sample in
            try sample.replacing(
                mapID: targetMap, frame: targetFrame, objectID: ObjectID(),
                position: Vec3(x: sample.position.x + 10, y: sample.position.y, z: sample.position.z - 2))
        }
        self.source = source
        self.target = target
        objects = try (source + target).map(Self.metadata)
        candidate = try PlaceFingerprintRecord(
            mapID: targetMap, coordinateFrameID: targetFrame,
            fingerprint: PlaceFingerprint(), createdAt: 1, updatedAt: 1)
    }

    func surface(timestamp: TimeInterval = 10.5, segment: CaptureSegmentID? = nil) -> ARSurfaceStateSnapshot {
        ARSurfaceStateSnapshot(
            coordinateFrameID: sourceFrame, segmentID: segment ?? self.segment,
            mapID: sourceMap, coordinateFrameStatus: .confirmed, revision: 1, timestamp: timestamp,
            planes: [:], meshes: [:], unresolvedFailures: [], isCurrentSessionData: true)
    }

    func match(
        source: [PlaceVisualLandmark]? = nil, target: [PlaceVisualLandmark]? = nil,
        surface: ARSurfaceStateSnapshot? = nil
    ) throws -> [CoordinateFrameAlignmentCorrespondence] {
        try PlaceVisualCorrespondenceMatcher().correspondences(
            current: surface ?? self.surface(), candidate: candidate, live: source ?? self.source,
            durable: target ?? self.target, objects: objects)
    }

    static func descriptor(_ index: Int) -> PlaceVisualDescriptor {
        var values = Array(repeating: Float(0), count: 64)
        values[index] = 1
        return PlaceVisualDescriptor(revision: 2, values: values)
    }

    static func metadata(_ sample: PlaceVisualLandmark) throws -> SpatialObjectMetadata {
        try SpatialObjectMetadata(
            mapID: sample.mapID,
            object: SpatialObject(
                id: sample.objectID, semanticLabel: sample.semanticLabel,
                position: sample.position, certainty: .confirmed, presence: .visible,
                confidence: ConfidenceVector(
                    semantic: .one, geometry: .one, tracking: .one, identity: .one, objectState: .one),
                firstSeenAt: 1, lastSeenAt: 100),
            position: FramedPosition(
                coordinateFrameID: sample.coordinateFrameID, value: sample.position,
                observedAt: 100, trackingQuality: .normal, uncertainty: .highConfidenceDepth))
    }
}

extension PlaceVisualLandmark {
    fileprivate func replacing(
        mapID: MapID? = nil, frame: CoordinateFrameID? = nil, objectID: ObjectID? = nil,
        position: Vec3? = nil, appearance: PlaceVisualDescriptor? = nil,
        scene: PlaceVisualDescriptor? = nil, support: Int? = nil, timestamp: TimeInterval? = nil,
        label: String? = nil
    ) -> Self {
        Self(
            mapID: mapID ?? self.mapID, coordinateFrameID: frame ?? coordinateFrameID,
            segmentID: segmentID, frameID: frameID, sessionRunGeneration: sessionRunGeneration,
            attachmentEpoch: attachmentEpoch, objectID: objectID ?? self.objectID,
            semanticLabel: label ?? semanticLabel, position: position ?? self.position,
            capturedAt: capturedAt, timestamp: timestamp ?? self.timestamp,
            supportingCaptureCount: support ?? supportingCaptureCount,
            appearance: appearance ?? self.appearance, sceneAppearance: scene ?? sceneAppearance)
    }
}
