import VispaceCore
import XCTest

@testable import Vispace

final class ObjectReidentificationContextBuilderTests: XCTestCase {
    func testUnrelatedLandmarksDoNotConsumeIdentityCandidateBudget() throws {
        let mapID = MapID()
        let frameID = CoordinateFrameID()
        let incoming = try metadata(
            id: ObjectID(), label: "chair", position: .zero, mapID: mapID, frameID: frameID
        )
        let candidate = try metadata(
            id: ObjectID(), label: "chair", position: Vec3(x: 0.02, y: 0, z: 0),
            mapID: mapID, frameID: frameID
        )
        let landmarks = try (0..<200).map { index in
            try metadata(
                id: ObjectID(), label: "table", position: Vec3(x: 1 + Double(index), y: 0, z: 0),
                mapID: mapID, frameID: frameID
            )
        }
        let bundle = try ObjectReidentificationContextBuilder().makeContexts(
            for: incoming, existingObjects: landmarks + [candidate]
        )
        XCTAssertEqual(bundle.eligibleExistingObjects.map(\.object.id), [candidate.object.id])
        XCTAssertEqual(bundle.candidates.count, 1)
        XCTAssertFalse(bundle.incoming.features.isEmpty)
        XCTAssertLessThanOrEqual(
            bundle.incoming.features.count,
            ObjectReidentificationSpatialContext.maximumFeatureCount
        )
    }

    func testSameClassCandidateCannotActAsItsOwnContextEvidence() throws {
        let mapID = MapID()
        let frameID = CoordinateFrameID()
        let incoming = try metadata(
            id: ObjectID(),
            label: "chair",
            position: Vec3(x: 0, y: 0, z: 0),
            mapID: mapID,
            frameID: frameID
        )
        let candidate = try metadata(
            id: ObjectID(),
            label: "chair",
            position: Vec3(x: 0.02, y: 0, z: 0.01),
            mapID: mapID,
            frameID: frameID
        )
        let landmark = try metadata(
            id: ObjectID(),
            label: "table",
            position: Vec3(x: 1, y: 0, z: 0),
            mapID: mapID,
            frameID: frameID
        )

        let bundle = try ObjectReidentificationContextBuilder().makeContexts(
            for: incoming,
            existingObjects: [candidate, landmark]
        )

        let candidateContext = try XCTUnwrap(bundle.candidates.first)
        XCTAssertEqual(bundle.incoming.features, candidateContext.features)
        XCTAssertTrue(
            bundle.incoming.features.allSatisfy {
                $0.reference != .object(candidate.object.id)
            }
        )
        XCTAssertTrue(
            bundle.incoming.features.contains {
                $0.reference == .object(landmark.object.id)
            }
        )
    }

    func testWeakRemovedAndCrossFrameObjectsAreExcluded() throws {
        let mapID = MapID()
        let frameID = CoordinateFrameID()
        let incoming = try metadata(
            id: ObjectID(),
            label: "chair",
            position: .zero,
            mapID: mapID,
            frameID: frameID
        )
        let removed = try metadata(
            id: ObjectID(),
            label: "table",
            position: Vec3(x: 1, y: 0, z: 0),
            mapID: mapID,
            frameID: frameID,
            presence: .removed
        )
        let otherFrame = try metadata(
            id: ObjectID(),
            label: "table",
            position: Vec3(x: -1, y: 0, z: 0),
            mapID: mapID,
            frameID: CoordinateFrameID()
        )

        let bundle = try ObjectReidentificationContextBuilder().makeContexts(
            for: incoming,
            existingObjects: [removed, otherFrame]
        )

        XCTAssertTrue(bundle.eligibleExistingObjects.isEmpty)
        XCTAssertTrue(bundle.incoming.features.isEmpty)
    }

    private func metadata(
        id: ObjectID,
        label: String,
        position: Vec3,
        mapID: MapID,
        frameID: CoordinateFrameID,
        presence: ObjectPresence = .visible
    ) throws -> SpatialObjectMetadata {
        let object = try SpatialObject(
            id: id,
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
            lastSeenAt: 1
        )
        return try SpatialObjectMetadata(
            mapID: mapID,
            object: object,
            position: FramedPosition(
                coordinateFrameID: frameID,
                value: position,
                observedAt: 1,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            )
        )
    }
}
