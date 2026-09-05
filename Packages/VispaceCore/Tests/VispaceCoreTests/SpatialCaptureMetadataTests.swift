import Foundation
import Testing

@testable import VispaceCore

struct SpatialCaptureMetadataTests {
    @Test
    func framedPositionRejectsInvalidTimeAndRetainsProvenance() throws {
        let coordinateFrameID = CoordinateFrameID(rawValue: testUUID(100))
        let position = try FramedPosition(
            coordinateFrameID: coordinateFrameID,
            value: vec(1, 2, 3),
            observedAt: 42,
            trackingQuality: .normal,
            uncertainty: .highConfidenceDepth
        )

        #expect(position.coordinateFrameID == coordinateFrameID)
        #expect(position.observedAt == 42)
        #expect(position.uncertainty == .highConfidenceDepth)

        #expect(throws: SpatialCaptureMetadataError.invalidTimestamp) {
            _ = try FramedPosition(
                coordinateFrameID: coordinateFrameID,
                value: .zero,
                observedAt: .nan,
                trackingQuality: .normal,
                uncertainty: .unknown
            )
        }
    }

    @Test
    func currentSchemaRoundTrips() throws {
        let document = try makeDocument()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let encoded = try encoder.encode(document)
        let decoded = try SpatialMetadataMigrator.decodeAndMigrate(encoded)

        #expect(decoded == document)
        #expect(decoded.schemaVersion == SpatialMetadataDocument.currentSchemaVersion)
    }

    @Test
    func objectMetadataRejectsCoordinatePayloadMismatch() throws {
        let object = makeObject(id: objectID(120), position: vec(1, 2, 3))
        let framedPosition = try FramedPosition(
            coordinateFrameID: CoordinateFrameID(rawValue: testUUID(121)),
            value: vec(9, 9, 9),
            observedAt: object.lastSeenAt,
            trackingQuality: .normal,
            uncertainty: .highConfidenceDepth
        )

        #expect(throws: SpatialCaptureMetadataError.objectPositionMismatch) {
            _ = try SpatialObjectMetadata(
                mapID: MapID(rawValue: testUUID(122)),
                object: object,
                position: framedPosition
            )
        }
    }

    @Test
    func objectMetadataRejectsObservationTimeMismatch() throws {
        let object = makeObject(id: objectID(123), position: vec(1, 2, 3))
        let framedPosition = try FramedPosition(
            coordinateFrameID: CoordinateFrameID(rawValue: testUUID(124)),
            value: object.position,
            observedAt: object.lastSeenAt + 1,
            trackingQuality: .normal,
            uncertainty: .highConfidenceDepth
        )

        #expect(throws: SpatialCaptureMetadataError.objectObservationTimeMismatch) {
            _ = try SpatialObjectMetadata(
                mapID: MapID(rawValue: testUUID(125)),
                object: object,
                position: framedPosition
            )
        }
    }

    @Test
    func legacyV0FixtureMigratesDeterministically() throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "spatial-metadata-v0",
                withExtension: "json"
            )
        )
        let migrated = try SpatialMetadataMigrator.decodeAndMigrate(Data(contentsOf: fixtureURL))

        #expect(migrated.schemaVersion == SpatialMetadataDocument.currentSchemaVersion)
        #expect(migrated.maps.count == 1)
        #expect(migrated.maps[0].mapID.rawValue == testUUID(201))
        #expect(migrated.maps[0].coordinateFrameID.rawValue == testUUID(202))
        #expect(migrated.maps[0].latestSegmentID.rawValue == testUUID(203))
        #expect(migrated.maps[0].worldMapBlobID == testUUID(204))
        #expect(migrated.maps[0].availability == .active)
        #expect(migrated.objects.isEmpty)
    }

    @Test
    func futureSchemaFailsClosed() {
        let fixture = Data(#"{"schemaVersion":99,"maps":[],"objects":[]}"#.utf8)

        #expect(throws: SpatialCaptureMetadataError.unsupportedSchemaVersion(99)) {
            _ = try SpatialMetadataMigrator.decodeAndMigrate(fixture)
        }
    }

    @Test
    func decodingCannotBypassTimestampValidation() throws {
        let document = try makeDocument()
        let encoded = try JSONEncoder().encode(document)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var mutated = json
        var maps = try #require(mutated["maps"] as? [[String: Any]])
        maps[0]["updatedAt"] = -1
        mutated["maps"] = maps
        let invalid = try JSONSerialization.data(withJSONObject: mutated)

        #expect(throws: SpatialCaptureMetadataError.malformedDocument) {
            _ = try SpatialMetadataMigrator.decodeAndMigrate(invalid)
        }
    }

    @Test
    func decodingRejectsOrphanedObjectReference() throws {
        let valid = try makeDocument()
        let object = try #require(valid.objects.first)
        let orphan = try SpatialObjectMetadata(
            mapID: MapID(rawValue: testUUID(999)),
            object: object.object,
            position: object.position
        )
        let invalid = SpatialMetadataDocument(maps: valid.maps, objects: [orphan])

        #expect(throws: SpatialCaptureMetadataError.orphanedObject) {
            _ = try SpatialMetadataMigrator.decodeAndMigrate(
                JSONEncoder().encode(invalid)
            )
        }
    }

    @Test
    func decodingRejectsDuplicateCheckpointBlobReference() throws {
        let valid = try makeDocument()
        let first = try #require(valid.maps.first)
        let duplicate = try SpatialMapMetadata(
            mapID: first.mapID,
            coordinateFrameID: first.coordinateFrameID,
            latestSegmentID: CaptureSegmentID(rawValue: testUUID(998)),
            worldMapBlobID: first.worldMapBlobID,
            createdAt: first.createdAt,
            updatedAt: first.updatedAt + 1
        )
        let invalid = SpatialMetadataDocument(
            maps: [first, duplicate],
            objects: valid.objects
        )

        #expect(throws: SpatialCaptureMetadataError.duplicateWorldMapBlobID) {
            _ = try SpatialMetadataMigrator.decodeAndMigrate(
                JSONEncoder().encode(invalid)
            )
        }
    }

    private func makeDocument() throws -> SpatialMetadataDocument {
        let mapID = MapID(rawValue: testUUID(101))
        let coordinateFrameID = CoordinateFrameID(rawValue: testUUID(102))
        let segmentID = CaptureSegmentID(rawValue: testUUID(103))
        let map = try SpatialMapMetadata(
            mapID: mapID,
            coordinateFrameID: coordinateFrameID,
            latestSegmentID: segmentID,
            worldMapBlobID: testUUID(104),
            createdAt: 10,
            updatedAt: 20
        )
        let object = makeObject(id: objectID(105), position: vec(1, 2, 3))
        let position = try FramedPosition(
            coordinateFrameID: coordinateFrameID,
            value: object.position,
            observedAt: object.lastSeenAt,
            trackingQuality: .normal,
            uncertainty: .mediumConfidenceDepth
        )
        return SpatialMetadataDocument(
            maps: [map],
            objects: [
                try SpatialObjectMetadata(mapID: mapID, object: object, position: position)
            ]
        )
    }
}
