import VispaceCore
import XCTest

@testable import Vispace

final class PlaceCoordinateAlignmentResolverTests: XCTestCase {
    func testCrossFrameAlignmentRunsFromCurrentCaptureIntoCandidateFrame() throws {
        let fixture = Fixture()
        let sourcePoints = try [
            Vec3(x: 0, y: 0, z: 0),
            Vec3(x: 2, y: 0, z: 0),
            Vec3(x: 0, y: 0, z: 2),
        ]
        let sourceToTarget = try Transform3D(rowMajorElements: [
            0, 0, 1, 10,
            0, 1, 0, 0.5,
            -1, 0, 0, -2,
            0, 0, 0, 1,
        ])
        let objects = try fixture.pairedObjects(
            sourcePoints: sourcePoints,
            targetPoints: sourcePoints.map { try sourceToTarget.transformed($0) }
        )

        let result = fixture.resolver.resolve(
            current: fixture.snapshot(),
            candidate: try fixture.candidate(),
            objects: objects
        )

        XCTAssertEqual(result.sourceMapID, fixture.sourceMapID)
        XCTAssertEqual(result.targetMapID, fixture.targetMapID)
        XCTAssertEqual(result.sourceCoordinateFrameID, fixture.sourceFrameID)
        XCTAssertEqual(result.targetCoordinateFrameID, fixture.targetFrameID)
        let alignment = try XCTUnwrap(result.validatedAlignment)
        XCTAssertEqual(alignment.sourceCoordinateFrameID, fixture.sourceFrameID)
        XCTAssertEqual(alignment.targetCoordinateFrameID, fixture.targetFrameID)
        assertTransformsEqual(alignment.sourceToTarget, sourceToTarget)
        guard case .aligned(let transform, let confidence) = result.evidence else {
            return XCTFail("Expected validated aligned evidence")
        }
        XCTAssertEqual(transform, alignment.sourceToTarget)
        XCTAssertEqual(confidence, alignment.confidence)
        assertVectorsEqual(
            try transform.transformed(sourcePoints[1]),
            try sourceToTarget.transformed(sourcePoints[1])
        )
    }

    func testSameCoordinateFrameReturnsExactIdentityWithoutSyntheticAlignment() throws {
        let fixture = Fixture()
        let candidate = try fixture.candidate(coordinateFrameID: fixture.sourceFrameID)

        let result = fixture.resolver.resolve(
            current: fixture.snapshot(),
            candidate: candidate,
            objects: []
        )

        XCTAssertNil(result.validatedAlignment)
        XCTAssertEqual(
            result.evidence,
            .aligned(sourceToCandidate: .identity, confidence: .one)
        )
    }

    func testMissingCurrentMapAndSelfMapStayUnresolved() throws {
        let fixture = Fixture()
        let missingMap = fixture.resolver.resolve(
            current: fixture.snapshot(includesMap: false),
            candidate: try fixture.candidate(),
            objects: []
        )
        let selfMap = fixture.resolver.resolve(
            current: fixture.snapshot(),
            candidate: try fixture.candidate(mapID: fixture.sourceMapID),
            objects: []
        )

        assertUnresolved(missingMap)
        assertUnresolved(selfMap)
    }

    func testStaleOrUnconfirmedSurfaceSnapshotStaysUnresolved() throws {
        let fixture = Fixture()

        let result = fixture.resolver.resolve(
            current: fixture.snapshot(isCurrentSessionData: false),
            candidate: try fixture.candidate(coordinateFrameID: fixture.sourceFrameID),
            objects: []
        )

        assertUnresolved(result)
    }

    func testInsufficientAndDegenerateCorrespondencesStayUnresolved() throws {
        let fixture = Fixture()
        let sourcePoints = try [
            Vec3(x: 0, y: 0, z: 0),
            Vec3(x: 1, y: 0, z: 0),
        ]
        let insufficient = fixture.resolver.resolve(
            current: fixture.snapshot(),
            candidate: try fixture.candidate(),
            objects: try fixture.pairedObjects(
                sourcePoints: sourcePoints,
                targetPoints: sourcePoints
            )
        )

        let collinear = try [
            Vec3(x: 0, y: 0, z: 0),
            Vec3(x: 1, y: 0, z: 0),
            Vec3(x: 2, y: 0, z: 0),
        ]
        let degenerate = fixture.resolver.resolve(
            current: fixture.snapshot(),
            candidate: try fixture.candidate(),
            objects: try fixture.pairedObjects(
                sourcePoints: collinear,
                targetPoints: collinear
            )
        )

        assertUnresolved(insufficient)
        assertUnresolved(degenerate)
    }

    func testHighResidualCorrespondencesStayUnresolved() throws {
        let fixture = Fixture()
        let sourcePoints = try [
            Vec3(x: 0, y: 0, z: 0),
            Vec3(x: 2, y: 0, z: 0),
            Vec3(x: 0, y: 0, z: 2),
            Vec3(x: 2, y: 0, z: 2),
        ]
        let targetPoints = try [
            Vec3(x: 10, y: 0, z: 10),
            Vec3(x: 12, y: 0, z: 10),
            Vec3(x: 10, y: 0, z: 12),
            Vec3(x: 30, y: 0, z: 30),
        ]

        let result = fixture.resolver.resolve(
            current: fixture.snapshot(),
            candidate: try fixture.candidate(),
            objects: try fixture.pairedObjects(
                sourcePoints: sourcePoints,
                targetPoints: targetPoints
            )
        )

        assertUnresolved(result)
    }

    func testHistoricalSourceLandmarksCannotProduceAlignment() throws {
        let fixture = Fixture()
        let points = try [
            Vec3(x: 0, y: 0, z: 0),
            Vec3(x: 2, y: 0, z: 0),
            Vec3(x: 0, y: 0, z: 2),
        ]

        for presence in [ObjectPresence.notVisible, .lastSeen] {
            let result = fixture.resolver.resolve(
                current: fixture.snapshot(),
                candidate: try fixture.candidate(),
                objects: try fixture.pairedObjects(
                    sourcePoints: points,
                    targetPoints: points,
                    sourcePresence: presence
                )
            )

            assertUnresolved(result)
        }
    }

    func testNonRemovedHistoricalTargetLandmarksRemainEligible() throws {
        let fixture = Fixture()
        let points = try [
            Vec3(x: 0, y: 0, z: 0),
            Vec3(x: 2, y: 0, z: 0),
            Vec3(x: 0, y: 0, z: 2),
        ]

        let result = fixture.resolver.resolve(
            current: fixture.snapshot(),
            candidate: try fixture.candidate(),
            objects: try fixture.pairedObjects(
                sourcePoints: points,
                targetPoints: points.map {
                    try Vec3(x: $0.x + 4, y: $0.y, z: $0.z - 3)
                },
                targetPresence: .lastSeen
            )
        )

        XCTAssertNotNil(result.validatedAlignment)
        guard case .aligned = result.evidence else {
            return XCTFail("Expected historical target landmarks to remain eligible")
        }
    }

    func testResolutionInitializerRejectsMismatchedDirectionAndEvidence() throws {
        let fixture = Fixture()
        let sourcePoints = try [
            Vec3(x: 0, y: 0, z: 0),
            Vec3(x: 2, y: 0, z: 0),
            Vec3(x: 0, y: 0, z: 2),
        ]
        let objects = try fixture.pairedObjects(
            sourcePoints: sourcePoints,
            targetPoints: sourcePoints.map {
                try Vec3(x: $0.x + 4, y: $0.y, z: $0.z - 3)
            }
        )
        let valid = fixture.resolver.resolve(
            current: fixture.snapshot(),
            candidate: try fixture.candidate(),
            objects: objects
        )
        let alignment = try XCTUnwrap(valid.validatedAlignment)

        XCTAssertThrowsError(
            try PlaceCoordinateAlignmentResolution(
                sourceMapID: fixture.sourceMapID,
                targetMapID: fixture.targetMapID,
                sourceCoordinateFrameID: fixture.targetFrameID,
                targetCoordinateFrameID: fixture.sourceFrameID,
                evidence: valid.evidence,
                validatedAlignment: alignment
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaceCoordinateAlignmentResolutionError,
                .alignmentFrameDirectionMismatch
            )
        }

        XCTAssertThrowsError(
            try PlaceCoordinateAlignmentResolution(
                sourceMapID: fixture.sourceMapID,
                targetMapID: fixture.targetMapID,
                sourceCoordinateFrameID: fixture.sourceFrameID,
                targetCoordinateFrameID: fixture.sourceFrameID,
                evidence: .aligned(
                    sourceToCandidate: alignment.sourceToTarget,
                    confidence: alignment.confidence
                ),
                validatedAlignment: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaceCoordinateAlignmentResolutionError,
                .invalidIdentityEvidence
            )
        }
    }
}

private func assertUnresolved(
    _ resolution: PlaceCoordinateAlignmentResolution,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(resolution.evidence, .unresolved, file: file, line: line)
    XCTAssertNil(resolution.validatedAlignment, file: file, line: line)
}

private func assertTransformsEqual(
    _ lhs: Transform3D,
    _ rhs: Transform3D,
    accuracy: Double = 1e-9,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for (lhsElement, rhsElement) in zip(lhs.rowMajorElements, rhs.rowMajorElements) {
        XCTAssertEqual(lhsElement, rhsElement, accuracy: accuracy, file: file, line: line)
    }
}

private func assertVectorsEqual(
    _ lhs: Vec3,
    _ rhs: Vec3,
    accuracy: Double = 1e-9,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(lhs.z, rhs.z, accuracy: accuracy, file: file, line: line)
}

private struct Fixture {
    let sourceMapID = Fixture.mapID(1)
    let targetMapID = Fixture.mapID(2)
    let sourceFrameID = Fixture.frameID(1)
    let targetFrameID = Fixture.frameID(2)
    let resolver = PlaceCoordinateAlignmentResolver()

    func snapshot(
        includesMap: Bool = true,
        isCurrentSessionData: Bool = true
    ) -> ARSurfaceStateSnapshot {
        ARSurfaceStateSnapshot(
            coordinateFrameID: sourceFrameID,
            segmentID: CaptureSegmentID(rawValue: Fixture.uuid(namespace: 3, value: 1)),
            mapID: includesMap ? sourceMapID : nil,
            coordinateFrameStatus: .confirmed,
            revision: 1,
            timestamp: 1,
            planes: [:],
            meshes: [:],
            unresolvedFailures: [],
            isCurrentSessionData: isCurrentSessionData
        )
    }

    func candidate(
        mapID: MapID? = nil,
        coordinateFrameID: CoordinateFrameID? = nil
    ) throws -> PlaceFingerprintRecord {
        try PlaceFingerprintRecord(
            mapID: mapID ?? targetMapID,
            coordinateFrameID: coordinateFrameID ?? targetFrameID,
            fingerprint: PlaceFingerprint(),
            createdAt: 1,
            updatedAt: 1
        )
    }

    func pairedObjects(
        sourcePoints: [Vec3],
        targetPoints: [Vec3],
        sourcePresence: ObjectPresence = .visible,
        targetPresence: ObjectPresence = .visible
    ) throws -> [SpatialObjectMetadata] {
        precondition(sourcePoints.count == targetPoints.count)
        let labels = ["chair", "lamp", "sofa", "table", "plant"]
        return try sourcePoints.indices.flatMap { index in
            [
                try object(
                    mapID: sourceMapID,
                    frameID: sourceFrameID,
                    objectID: Fixture.objectID(namespace: 4, value: index),
                    label: labels[index],
                    position: sourcePoints[index],
                    presence: sourcePresence
                ),
                try object(
                    mapID: targetMapID,
                    frameID: targetFrameID,
                    objectID: Fixture.objectID(namespace: 5, value: index),
                    label: labels[index],
                    position: targetPoints[index],
                    presence: targetPresence
                ),
            ]
        }
    }

    private func object(
        mapID: MapID,
        frameID: CoordinateFrameID,
        objectID: ObjectID,
        label: String,
        position: Vec3,
        presence: ObjectPresence
    ) throws -> SpatialObjectMetadata {
        let object = try SpatialObject(
            id: objectID,
            semanticLabel: label,
            position: position,
            certainty: .confirmed,
            presence: presence,
            confidence: ConfidenceVector(
                semantic: .one,
                geometry: .one,
                tracking: .one,
                identity: .one,
                objectState: .one
            ),
            firstSeenAt: 1,
            lastSeenAt: 2
        )
        return try SpatialObjectMetadata(
            mapID: mapID,
            object: object,
            position: FramedPosition(
                coordinateFrameID: frameID,
                value: position,
                observedAt: 2,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            )
        )
    }

    static func mapID(_ value: Int) -> MapID {
        MapID(rawValue: uuid(namespace: 1, value: value))
    }

    static func frameID(_ value: Int) -> CoordinateFrameID {
        CoordinateFrameID(rawValue: uuid(namespace: 2, value: value))
    }

    static func objectID(namespace: Int, value: Int) -> ObjectID {
        ObjectID(rawValue: uuid(namespace: namespace, value: value))
    }

    static func uuid(namespace: Int, value: Int) -> UUID {
        UUID(
            uuid: (
                0, 0, 0, 0,
                0, 0,
                0, UInt8(namespace),
                0, 0,
                0, 0, 0, 0,
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF)
            ))
    }
}
