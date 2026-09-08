import VispaceCore
import XCTest
import simd

@testable import Vispace

final class ARPlaceFingerprintBuilderTests: XCTestCase {
    func testIncludesCameraVisualHistogramWhenProviderSuppliesIt() throws {
        let visual = try NormalizedPlaceHistogram(values: Array(repeating: 1.0 / 16, count: 16))
        let fingerprint = try ARPlaceFingerprintBuilder().makeFingerprint(
            from: makeSnapshot(), objects: [], visualHistogram: visual
        )
        XCTAssertEqual(fingerprint.visualHistogram, visual)
    }

    func testRejectsIncompleteSurfaceState() throws {
        let snapshot = makeSnapshot(isCurrentSessionData: false)

        XCTAssertThrowsError(
            try ARPlaceFingerprintBuilder().makeFingerprint(from: snapshot, objects: [])
        ) { error in
            XCTAssertEqual(
                error as? ARPlaceFingerprintBuilderError,
                .incompleteSurfaceSnapshot
            )
        }
    }

    func testBuildsBoundedAggregateFingerprintWithoutVisualPayload() throws {
        let frameID = CoordinateFrameID()
        let snapshot = makeSnapshot(coordinateFrameID: frameID)
        let object = try makeObject(
            coordinateFrameID: frameID,
            label: "chair",
            position: Vec3(x: 0.5, y: 0.4, z: 0.5)
        )

        let fingerprint = try ARPlaceFingerprintBuilder().makeFingerprint(
            from: snapshot,
            objects: [object]
        )

        XCTAssertNil(fingerprint.visualHistogram)
        XCTAssertEqual(fingerprint.geometryHistogram?.values.count, 12)
        XCTAssertEqual(fingerprint.structureHistogram?.values.count, 12)
        XCTAssertEqual(fingerprint.objectLayoutHistogram?.values.count, 16)
        XCTAssertEqual(fingerprint.spatialOccupancyHistogram?.values.count, 32)
        XCTAssertEqual(fingerprint.observedObjectCount, 1)
        let geometry = try XCTUnwrap(fingerprint.geometryHistogram)
        XCTAssertEqual(geometry.values.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testFingerprintIsInvariantToGlobalTranslation() throws {
        let frameID = CoordinateFrameID()
        let original = makeSnapshot(coordinateFrameID: frameID)
        let translated = makeSnapshot(
            coordinateFrameID: frameID,
            translation: SIMD3<Float>(11, -2, 7)
        )

        let lhs = try ARPlaceFingerprintBuilder().makeFingerprint(
            from: original,
            objects: []
        )
        let rhs = try ARPlaceFingerprintBuilder().makeFingerprint(
            from: translated,
            objects: []
        )

        XCTAssertEqual(lhs.geometryHistogram, rhs.geometryHistogram)
        XCTAssertEqual(lhs.structureHistogram, rhs.structureHistogram)
        XCTAssertEqual(lhs.spatialOccupancyHistogram, rhs.spatialOccupancyHistogram)
        XCTAssertEqual(lhs.coarseExtent, rhs.coarseExtent)
    }

    func testOnlyConfirmedNonRemovedObjectsEnterLayout() throws {
        let frameID = CoordinateFrameID()
        let otherFrameID = CoordinateFrameID()
        let snapshot = makeSnapshot(coordinateFrameID: frameID)
        let confirmed = try makeObject(
            coordinateFrameID: frameID,
            label: "chair",
            position: Vec3(x: 0, y: 0, z: 0)
        )
        let provisional = try makeObject(
            coordinateFrameID: frameID,
            label: "table",
            position: Vec3(x: 1, y: 0, z: 0),
            certainty: .provisional
        )
        let removed = try makeObject(
            coordinateFrameID: frameID,
            label: "lamp",
            position: Vec3(x: 2, y: 0, z: 0),
            presence: .removed
        )
        let wrongFrame = try makeObject(
            coordinateFrameID: otherFrameID,
            label: "sofa",
            position: Vec3(x: 3, y: 0, z: 0)
        )

        let fingerprint = try ARPlaceFingerprintBuilder().makeFingerprint(
            from: snapshot,
            objects: [confirmed, provisional, removed, wrongFrame]
        )

        XCTAssertEqual(fingerprint.observedObjectCount, 1)
    }

    func testStructureDifferenceReducesSimilarity() throws {
        let frameID = CoordinateFrameID()
        let floor = makeSnapshot(coordinateFrameID: frameID, classification: .floor)
        let wall = makeSnapshot(coordinateFrameID: frameID, classification: .wall)
        let builder = ARPlaceFingerprintBuilder()

        let floorFingerprint = try builder.makeFingerprint(from: floor, objects: [])
        let wallFingerprint = try builder.makeFingerprint(from: wall, objects: [])
        let comparison = try PlaceFingerprintComparator().compare(
            floorFingerprint,
            wallFingerprint
        )

        let structureScore = try XCTUnwrap(comparison.structure.score)
        let geometryScore = try XCTUnwrap(comparison.geometry.score)
        XCTAssertLessThan(structureScore.value, 1)
        XCTAssertEqual(geometryScore.value, 1, accuracy: 1e-9)
    }

    private func makeSnapshot(
        coordinateFrameID: CoordinateFrameID = CoordinateFrameID(),
        translation: SIMD3<Float> = .zero,
        classification: ARPlaneClassificationSnapshot = .floor,
        isCurrentSessionData: Bool = true
    ) -> ARSurfaceStateSnapshot {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        let planeID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let wallID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let floor = ARPlaneObservationSnapshot(
            anchorID: planeID,
            transform: Matrix4x4Snapshot(transform),
            center: SIMD3<Float>(0, 0, 0),
            extent: SIMD3<Float>(4, 0, 4),
            extentRotationOnYAxis: 0,
            boundaryVertices: [
                SIMD3<Float>(-2, 0, -2),
                SIMD3<Float>(2, 0, -2),
                SIMD3<Float>(2, 0, 2),
                SIMD3<Float>(-2, 0, 2),
            ],
            alignment: .horizontal,
            classification: classification
        )
        let wall = ARPlaneObservationSnapshot(
            anchorID: wallID,
            transform: Matrix4x4Snapshot(transform),
            center: SIMD3<Float>(0, 1.25, -2),
            extent: SIMD3<Float>(4, 0, 2.5),
            extentRotationOnYAxis: 0,
            boundaryVertices: [
                SIMD3<Float>(-2, 0, 0),
                SIMD3<Float>(2, 0, 0),
                SIMD3<Float>(2, 2.5, 0),
                SIMD3<Float>(-2, 2.5, 0),
            ],
            alignment: .vertical,
            classification: .wall
        )
        return ARSurfaceStateSnapshot(
            coordinateFrameID: coordinateFrameID,
            segmentID: CaptureSegmentID(),
            mapID: MapID(),
            coordinateFrameStatus: .confirmed,
            revision: 1,
            timestamp: 1,
            planes: [planeID: floor, wallID: wall],
            meshes: [:],
            unresolvedFailures: [],
            isCurrentSessionData: isCurrentSessionData
        )
    }

    private func makeObject(
        coordinateFrameID: CoordinateFrameID,
        label: String,
        position: Vec3,
        certainty: ObjectCertainty = .confirmed,
        presence: ObjectPresence = .visible
    ) throws -> SpatialObjectMetadata {
        let object = try SpatialObject(
            semanticLabel: label,
            position: position,
            certainty: certainty,
            presence: presence,
            confidence: ConfidenceVector(
                semantic: .one,
                geometry: .one,
                tracking: .one,
                identity: .one
            ),
            firstSeenAt: 1,
            lastSeenAt: 1
        )
        let framedPosition = try FramedPosition(
            coordinateFrameID: coordinateFrameID,
            value: position,
            observedAt: 1,
            trackingQuality: .normal,
            uncertainty: .highConfidenceDepth
        )
        return try SpatialObjectMetadata(
            mapID: MapID(),
            object: object,
            position: framedPosition
        )
    }
}
