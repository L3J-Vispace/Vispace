import Foundation
import VispaceCore
import XCTest

@testable import Vispace

final class CoordinateAlignmentRepositoryTests: XCTestCase {
    func testRoundTripUsesDeterministicOrderAndDirectionalLoad() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CoordinateAlignmentRepository(directoryURL: root)
        let laterPair = try record(
            sourceMap: 30,
            sourceFrame: 130,
            targetMap: 40,
            targetFrame: 140,
            updatedAt: 4
        )
        let earlierPair = try record(
            sourceMap: 10,
            sourceFrame: 110,
            targetMap: 20,
            targetFrame: 120,
            updatedAt: 3
        )

        try await repository.upsertAlignment(laterPair)
        try await repository.upsertAlignment(earlierPair)
        try assertSpatialDirectoryPolicy(at: root)

        let listed = try await repository.listAlignments()
        let directional = try await repository.loadAlignment(
            sourceMapID: earlierPair.sourceMapID,
            targetMapID: earlierPair.targetMapID
        )
        let wrongDirection = try await repository.loadAlignment(
            sourceMapID: earlierPair.targetMapID,
            targetMapID: earlierPair.sourceMapID
        )
        let unordered = try await repository.loadAlignment(
            between: earlierPair.targetMapID,
            and: earlierPair.sourceMapID
        )
        XCTAssertEqual(listed, [earlierPair, laterPair])
        XCTAssertEqual(directional, earlierPair)
        XCTAssertNil(wrongDirection)
        XCTAssertEqual(unordered, earlierPair)

        let catalogURL = root.appendingPathComponent(
            CoordinateAlignmentRepository.catalogFileName
        )
        let firstBytes = try Data(contentsOf: catalogURL)
        try await repository.upsertAlignment(earlierPair)
        XCTAssertEqual(try Data(contentsOf: catalogURL), firstBytes)
    }

    func testRecordRejectsResultWhoseFramesDoNotMatch() throws {
        let result = try alignmentResult(sourceFrame: 101, targetFrame: 102)
        XCTAssertThrowsError(
            try CoordinateAlignmentRecord(
                sourceMapID: mapID(1),
                sourceCoordinateFrameID: frameID(999),
                targetMapID: mapID(2),
                targetCoordinateFrameID: frameID(102),
                result: result,
                createdAt: 1,
                updatedAt: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? CoordinateAlignmentRepositoryError,
                .resultFrameMismatch(
                    expectedSource: self.frameID(999),
                    actualSource: self.frameID(101),
                    expectedTarget: self.frameID(102),
                    actualTarget: self.frameID(102)
                )
            )
        }
    }

    func testCommittedAlignmentRejectsChangedResultOrContextAtomically() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CoordinateAlignmentRepository(directoryURL: root)
        let original = try record(
            sourceMap: 1,
            sourceFrame: 101,
            targetMap: 2,
            targetFrame: 102,
            updatedAt: 2
        )
        try await repository.upsertAlignment(original)

        let stale = try record(
            sourceMap: 1,
            sourceFrame: 101,
            targetMap: 2,
            targetFrame: 102,
            updatedAt: 2,
            translationX: 3
        )
        await assertThrowsCoordinateAlignmentError(
            { try await repository.upsertAlignment(stale) },
            equals: .immutableAlignmentConflict(
                sourceMapID: original.sourceMapID,
                targetMapID: original.targetMapID
            )
        )

        let contextConflict = try record(
            sourceMap: 1,
            sourceFrame: 201,
            targetMap: 2,
            targetFrame: 202,
            updatedAt: 4
        )
        await assertThrowsCoordinateAlignmentError(
            { try await repository.upsertAlignment(contextConflict) },
            equals: .immutableAlignmentConflict(
                sourceMapID: original.sourceMapID,
                targetMapID: original.targetMapID
            )
        )

        let inverse = try record(
            sourceMap: 2,
            sourceFrame: 102,
            targetMap: 1,
            targetFrame: 101,
            updatedAt: 4
        )
        await assertThrowsCoordinateAlignmentError(
            { try await repository.upsertAlignment(inverse) },
            equals: .immutableAlignmentConflict(
                sourceMapID: original.sourceMapID,
                targetMapID: original.targetMapID
            )
        )
        let persisted = try await repository.listAlignments()
        XCTAssertEqual(persisted, [original])
    }

    func testNewerValidatedResultCannotMoveCommittedCoordinates() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CoordinateAlignmentRepository(directoryURL: root)
        let original = try record(
            sourceMap: 1,
            sourceFrame: 101,
            targetMap: 2,
            targetFrame: 102,
            updatedAt: 2
        )
        let refined = try record(
            sourceMap: 1,
            sourceFrame: 101,
            targetMap: 2,
            targetFrame: 102,
            updatedAt: 3,
            translationX: 2.25
        )

        try await repository.upsertAlignment(original)
        await assertThrowsCoordinateAlignmentError(
            { try await repository.upsertAlignment(refined) },
            equals: .immutableAlignmentConflict(
                sourceMapID: original.sourceMapID,
                targetMapID: original.targetMapID
            )
        )

        let loaded = try await repository.loadAlignment(
            sourceMapID: refined.sourceMapID,
            targetMapID: refined.targetMapID
        )
        XCTAssertEqual(loaded, original)
    }

    func testReverseEquivalentRetryCanonicalizesAndDoesNotWriteAgain() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CoordinateAlignmentRepository(directoryURL: root)
        let original = try record(
            sourceMap: 1,
            sourceFrame: 101,
            targetMap: 2,
            targetFrame: 102,
            updatedAt: 2
        )
        let reverse = try CoordinateAlignmentRecord(
            sourceMapID: original.targetMapID,
            sourceCoordinateFrameID: original.targetCoordinateFrameID,
            targetMapID: original.sourceMapID,
            targetCoordinateFrameID: original.sourceCoordinateFrameID,
            result: original.result.inverted(),
            createdAt: 10,
            updatedAt: 11
        )

        let initialCommit = try await repository.commitIfAbsent(original)
        XCTAssertEqual(initialCommit, .committed(original))
        let catalogURL = root.appendingPathComponent(
            CoordinateAlignmentRepository.catalogFileName
        )
        let firstBytes = try Data(contentsOf: catalogURL)
        let reverseRetry = try await repository.commitIfAbsent(reverse)
        XCTAssertEqual(reverseRetry, .alreadyCommitted(original))

        XCTAssertEqual(try Data(contentsOf: catalogURL), firstBytes)
        let alignments = try await repository.listAlignments()
        XCTAssertEqual(alignments, [original])
        XCTAssertTrue(try XCTUnwrap(alignments.first).isCanonical)
    }

    func testConsistentABBCAndACCycleIsCommittedUsingCorrectCompositionOrder() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CoordinateAlignmentRepository(directoryURL: root)
        let sourceToMiddle = rigidTransform(
            yaw: .pi / 6,
            translation: vec(1.0, 0.2, -0.5)
        )
        let middleToTarget = rigidTransform(
            yaw: -.pi / 8,
            translation: vec(-0.3, 0.1, 1.2)
        )
        let sourceToTarget = try middleToTarget * sourceToMiddle
        let first = try record(
            sourceMap: 1,
            sourceFrame: 101,
            targetMap: 2,
            targetFrame: 102,
            updatedAt: 2,
            transform: sourceToMiddle
        )
        let second = try record(
            sourceMap: 2,
            sourceFrame: 102,
            targetMap: 3,
            targetFrame: 103,
            updatedAt: 3,
            transform: middleToTarget
        )
        let closing = try record(
            sourceMap: 1,
            sourceFrame: 101,
            targetMap: 3,
            targetFrame: 103,
            updatedAt: 4,
            transform: sourceToTarget
        )

        try await repository.upsertAlignment(first)
        try await repository.upsertAlignment(second)
        let closingCommit = try await repository.commitIfAbsent(closing)
        XCTAssertEqual(closingCommit, .committed(closing))
        let committed = try await repository.listAlignments()
        XCTAssertEqual(committed.count, 3)
    }

    func testInconsistentClosingCycleIsRejectedWithoutChangingCatalog() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CoordinateAlignmentRepository(directoryURL: root)
        let sourceToMiddle = rigidTransform(
            yaw: .pi / 6,
            translation: vec(1.0, 0.2, -0.5)
        )
        let middleToTarget = rigidTransform(
            yaw: -.pi / 8,
            translation: vec(-0.3, 0.1, 1.2)
        )
        let inconsistent = rigidTransform(
            yaw: .pi / 3,
            translation: vec(4.0, 0.3, -2.0)
        )
        let first = try record(
            sourceMap: 1,
            sourceFrame: 101,
            targetMap: 2,
            targetFrame: 102,
            updatedAt: 2,
            transform: sourceToMiddle
        )
        let second = try record(
            sourceMap: 2,
            sourceFrame: 102,
            targetMap: 3,
            targetFrame: 103,
            updatedAt: 3,
            transform: middleToTarget
        )
        let closing = try record(
            sourceMap: 1,
            sourceFrame: 101,
            targetMap: 3,
            targetFrame: 103,
            updatedAt: 4,
            transform: inconsistent
        )
        try await repository.upsertAlignment(first)
        try await repository.upsertAlignment(second)

        await assertThrowsCoordinateAlignmentError(
            { try await repository.commitIfAbsent(closing) },
            equals: .inconsistentAlignmentCycle(
                sourceMapID: closing.sourceMapID,
                targetMapID: closing.targetMapID
            )
        )
        let persisted = try await repository.listAlignments()
        XCTAssertEqual(persisted, [first, second])
    }

    func testMapCannotBeReboundToAnotherCoordinateFrame() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CoordinateAlignmentRepository(directoryURL: root)
        let first = try record(
            sourceMap: 1,
            sourceFrame: 101,
            targetMap: 2,
            targetFrame: 102,
            updatedAt: 2
        )
        let conflicting = try record(
            sourceMap: 1,
            sourceFrame: 999,
            targetMap: 3,
            targetFrame: 103,
            updatedAt: 3
        )
        try await repository.upsertAlignment(first)

        await assertThrowsCoordinateAlignmentError(
            { try await repository.upsertAlignment(conflicting) },
            equals: .mapCoordinateFrameConflict(mapID: first.sourceMapID)
        )
        let persisted = try await repository.listAlignments()
        XCTAssertEqual(persisted, [first])
    }

    func testCapacityIsBoundedAndConfiguredLimitCannotExceed128() async throws {
        XCTAssertEqual(
            CoordinateAlignmentCatalogSnapshot.absoluteMaximumAlignments,
            128
        )
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CoordinateAlignmentRepository(
            directoryURL: root,
            maximumAlignments: 1
        )
        let first = try record(
            sourceMap: 1,
            sourceFrame: 101,
            targetMap: 2,
            targetFrame: 102,
            updatedAt: 2
        )
        let second = try record(
            sourceMap: 3,
            sourceFrame: 103,
            targetMap: 4,
            targetFrame: 104,
            updatedAt: 2
        )
        try await repository.upsertAlignment(first)

        await assertThrowsCoordinateAlignmentError(
            { try await repository.upsertAlignment(second) },
            equals: .alignmentCapacityReached(maximum: 1)
        )
        let persisted = try await repository.listAlignments()
        XCTAssertEqual(persisted, [first])
    }

    func testTamperedFrameBindingIsQuarantinedInsteadOfTrusted() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CoordinateAlignmentRepository(directoryURL: root)
        let original = try record(
            sourceMap: 1,
            sourceFrame: 101,
            targetMap: 2,
            targetFrame: 102,
            updatedAt: 2
        )
        try await repository.upsertAlignment(original)
        let catalogURL = root.appendingPathComponent(
            CoordinateAlignmentRepository.catalogFileName
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))
                as? [String: Any]
        )
        var alignments = try XCTUnwrap(object["alignments"] as? [[String: Any]])
        alignments[0]["sourceCoordinateFrameID"] = try jsonObject(frameID(999))
        object["alignments"] = alignments
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: catalogURL, options: .atomic)

        let recovered = try await repository.listAlignments()
        XCTAssertTrue(recovered.isEmpty)
        try assertOneQuarantinedCatalog(in: root)
    }

    func testTamperedInverseDuplicateIsQuarantinedInsteadOfAmbiguous() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CoordinateAlignmentRepository(directoryURL: root)
        let original = try record(
            sourceMap: 1,
            sourceFrame: 101,
            targetMap: 2,
            targetFrame: 102,
            updatedAt: 2
        )
        let inverse = try record(
            sourceMap: 2,
            sourceFrame: 102,
            targetMap: 1,
            targetFrame: 101,
            updatedAt: 2
        )
        try await repository.upsertAlignment(original)
        let catalogURL = root.appendingPathComponent(
            CoordinateAlignmentRepository.catalogFileName
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))
                as? [String: Any]
        )
        var alignments = try XCTUnwrap(object["alignments"] as? [Any])
        alignments.append(try jsonObject(inverse))
        object["alignments"] = alignments
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: catalogURL, options: .atomic)

        let recovered = try await repository.listAlignments()
        XCTAssertTrue(recovered.isEmpty)
        try assertOneQuarantinedCatalog(in: root)
    }

    func testMalformedAndOversizedCatalogsAreQuarantined() async throws {
        let malformedRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: malformedRoot) }
        try FileManager.default.createDirectory(
            at: malformedRoot,
            withIntermediateDirectories: true
        )
        let malformedURL = malformedRoot.appendingPathComponent(
            CoordinateAlignmentRepository.catalogFileName
        )
        try Data("not-json".utf8).write(to: malformedURL)
        let malformedRepository = CoordinateAlignmentRepository(
            directoryURL: malformedRoot
        )
        let malformedRecovered = try await malformedRepository.listAlignments()
        XCTAssertTrue(malformedRecovered.isEmpty)
        try assertOneQuarantinedCatalog(in: malformedRoot)

        let oversizedRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: oversizedRoot) }
        try FileManager.default.createDirectory(
            at: oversizedRoot,
            withIntermediateDirectories: true
        )
        let oversizedURL = oversizedRoot.appendingPathComponent(
            CoordinateAlignmentRepository.catalogFileName
        )
        try Data(
            repeating: 0x41,
            count: CoordinateAlignmentRepository.maximumCatalogBytes + 1
        ).write(to: oversizedURL)
        let oversizedRepository = CoordinateAlignmentRepository(
            directoryURL: oversizedRoot
        )
        let oversizedRecovered = try await oversizedRepository.listAlignments()
        XCTAssertTrue(oversizedRecovered.isEmpty)
        try assertOneQuarantinedCatalog(in: oversizedRoot)
    }

    func testCancelledUpsertDoesNotPublishCatalog() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CoordinateAlignmentRepository(directoryURL: root)
        let value = try record(
            sourceMap: 1,
            sourceFrame: 101,
            targetMap: 2,
            targetFrame: 102,
            updatedAt: 2
        )
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            try await repository.upsertAlignment(value)
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
                    CoordinateAlignmentRepository.catalogFileName
                ).path
            )
        )
    }

    private func record(
        sourceMap: Int,
        sourceFrame: Int,
        targetMap: Int,
        targetFrame: Int,
        updatedAt: TimeInterval,
        translationX: Double = 2,
        transform: Transform3D? = nil
    ) throws -> CoordinateAlignmentRecord {
        let result = try alignmentResult(
            sourceFrame: sourceFrame,
            targetFrame: targetFrame,
            translationX: translationX,
            transform: transform
        )
        return try CoordinateAlignmentRecord(
            sourceMapID: mapID(sourceMap),
            sourceCoordinateFrameID: frameID(sourceFrame),
            targetMapID: mapID(targetMap),
            targetCoordinateFrameID: frameID(targetFrame),
            result: result,
            createdAt: 1,
            updatedAt: updatedAt
        )
    }

    private func alignmentResult(
        sourceFrame: Int,
        targetFrame: Int,
        translationX: Double = 2,
        transform: Transform3D? = nil
    ) throws -> CoordinateFrameAlignmentResult {
        let sourceFrameID = frameID(sourceFrame)
        let targetFrameID = frameID(targetFrame)
        let sourceToTarget =
            transform
            ?? rigidTransform(
                yaw: 0,
                translation: vec(translationX, 0.4, -1.2)
            )
        let sourcePoints = [
            vec(0, 0, 0),
            vec(2, 0.2, 0.1),
            vec(0.2, 0.9, 1.7),
            vec(-1.1, 0.5, -0.8),
        ]
        let correspondences = try sourcePoints.enumerated().map { index, point in
            try CoordinateFrameAlignmentCorrespondence(
                source: CoordinateFrameAlignmentSourcePoint(
                    objectID: objectID(10_000 + sourceFrame * 10 + index),
                    coordinateFrameID: sourceFrameID,
                    semanticLabel: "object-\(index)",
                    position: point
                ),
                target: CoordinateFrameAlignmentTargetPoint(
                    objectID: objectID(20_000 + targetFrame * 10 + index),
                    coordinateFrameID: targetFrameID,
                    semanticLabel: "object-\(index)",
                    position: try sourceToTarget.transformed(point)
                ),
                identityConfidence: .one
            )
        }
        return try CoordinateFrameAlignmentEstimator().estimate(
            correspondences: correspondences
        )
    }

    private func rigidTransform(yaw: Double, translation: Vec3) -> Transform3D {
        let cosine = cos(yaw)
        let sine = sin(yaw)
        return try! Transform3D(rowMajorElements: [
            cosine, 0, sine, translation.x,
            0, 1, 0, translation.y,
            -sine, 0, cosine, translation.z,
            0, 0, 0, 1,
        ])
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func assertOneQuarantinedCatalog(
        in root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let quarantine = root.appendingPathComponent("Quarantine", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 2, file: file, line: line)
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

    private func mapID(_ value: Int) -> MapID {
        MapID(rawValue: testUUID(value))
    }

    private func frameID(_ value: Int) -> CoordinateFrameID {
        CoordinateFrameID(rawValue: testUUID(1_000_000 + value))
    }

    private func objectID(_ value: Int) -> ObjectID {
        ObjectID(rawValue: testUUID(2_000_000 + value))
    }

    private func vec(_ x: Double, _ y: Double, _ z: Double) -> Vec3 {
        try! Vec3(x: x, y: y, z: z)
    }

    private func testUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "vispace-coordinate-alignment-tests-\(UUID().uuidString)"
        )
    }
}

private func assertThrowsCoordinateAlignmentError<T>(
    _ expression: () async throws -> T,
    equals expected: CoordinateAlignmentRepositoryError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
        XCTAssertEqual(
            error as? CoordinateAlignmentRepositoryError,
            expected,
            file: file,
            line: line
        )
    }
}
