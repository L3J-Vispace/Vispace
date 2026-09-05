import Foundation

public enum SpatialCaptureMetadataError: Error, Equatable, Sendable {
    case invalidTimestamp
    case invalidSchemaVersion(Int)
    case unsupportedSchemaVersion(Int)
    case malformedDocument
    case objectPositionMismatch
    case objectObservationTimeMismatch
    case duplicateWorldMapBlobID
    case inconsistentMapCoordinateFrame
    case orphanedObject
    case duplicateObject
}

/// A platform-neutral tracking state stored beside every durable coordinate.
public enum SpatialTrackingQuality: String, Codable, Hashable, Sendable {
    case unavailable
    case limited
    case normal
}

/// Qualitative uncertainty evidence. This intentionally does not invent a
/// metric error radius before device-specific calibration exists.
public enum SpatialPositionUncertainty: String, Codable, Hashable, Sendable {
    case unavailable
    case lowConfidenceDepth
    case mediumConfidenceDepth
    case highConfidenceDepth
    case raycastEstimate
    case unknown
}

/// A point is only meaningful together with its coordinate frame, time,
/// tracking quality, and uncertainty evidence.
public struct FramedPosition: Codable, Hashable, Sendable {
    public let coordinateFrameID: CoordinateFrameID
    public let value: Vec3
    public let observedAt: TimeInterval
    public let trackingQuality: SpatialTrackingQuality
    public let uncertainty: SpatialPositionUncertainty

    public init(
        coordinateFrameID: CoordinateFrameID,
        value: Vec3,
        observedAt: TimeInterval,
        trackingQuality: SpatialTrackingQuality,
        uncertainty: SpatialPositionUncertainty
    ) throws {
        guard observedAt.isFinite, observedAt >= 0 else {
            throw SpatialCaptureMetadataError.invalidTimestamp
        }
        self.coordinateFrameID = coordinateFrameID
        self.value = value
        self.observedAt = observedAt
        self.trackingQuality = trackingQuality
        self.uncertainty = uncertainty
    }

    private enum CodingKeys: String, CodingKey {
        case coordinateFrameID
        case value
        case observedAt
        case trackingQuality
        case uncertainty
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                coordinateFrameID: container.decode(
                    CoordinateFrameID.self,
                    forKey: .coordinateFrameID
                ),
                value: container.decode(Vec3.self, forKey: .value),
                observedAt: container.decode(TimeInterval.self, forKey: .observedAt),
                trackingQuality: container.decode(
                    SpatialTrackingQuality.self,
                    forKey: .trackingQuality
                ),
                uncertainty: container.decode(
                    SpatialPositionUncertainty.self,
                    forKey: .uncertainty
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .observedAt,
                in: container,
                debugDescription: "Position timestamp must be finite and nonnegative."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(coordinateFrameID, forKey: .coordinateFrameID)
        try container.encode(value, forKey: .value)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(trackingQuality, forKey: .trackingQuality)
        try container.encode(uncertainty, forKey: .uncertainty)
    }
}

public struct SpatialMapMetadata: Codable, Hashable, Sendable {
    public enum Availability: String, Codable, Hashable, Sendable {
        case active
        case quarantined
    }

    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let latestSegmentID: CaptureSegmentID
    public let worldMapBlobID: UUID
    public let createdAt: TimeInterval
    public let updatedAt: TimeInterval
    public let availability: Availability
    public let quarantineReason: String?

    public init(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        latestSegmentID: CaptureSegmentID,
        worldMapBlobID: UUID,
        createdAt: TimeInterval,
        updatedAt: TimeInterval,
        availability: Availability = .active,
        quarantineReason: String? = nil
    ) throws {
        guard createdAt.isFinite, createdAt >= 0,
            updatedAt.isFinite, updatedAt >= createdAt
        else {
            throw SpatialCaptureMetadataError.invalidTimestamp
        }
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        self.latestSegmentID = latestSegmentID
        self.worldMapBlobID = worldMapBlobID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.availability = availability
        self.quarantineReason = quarantineReason
    }

    private enum CodingKeys: String, CodingKey {
        case mapID
        case coordinateFrameID
        case latestSegmentID
        case worldMapBlobID
        case createdAt
        case updatedAt
        case availability
        case quarantineReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                mapID: container.decode(MapID.self, forKey: .mapID),
                coordinateFrameID: container.decode(
                    CoordinateFrameID.self,
                    forKey: .coordinateFrameID
                ),
                latestSegmentID: container.decode(
                    CaptureSegmentID.self,
                    forKey: .latestSegmentID
                ),
                worldMapBlobID: container.decode(UUID.self, forKey: .worldMapBlobID),
                createdAt: container.decode(TimeInterval.self, forKey: .createdAt),
                updatedAt: container.decode(TimeInterval.self, forKey: .updatedAt),
                availability: container.decode(Availability.self, forKey: .availability),
                quarantineReason: container.decodeIfPresent(
                    String.self,
                    forKey: .quarantineReason
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .updatedAt,
                in: container,
                debugDescription: "Map timestamps must be finite and ordered."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mapID, forKey: .mapID)
        try container.encode(coordinateFrameID, forKey: .coordinateFrameID)
        try container.encode(latestSegmentID, forKey: .latestSegmentID)
        try container.encode(worldMapBlobID, forKey: .worldMapBlobID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(availability, forKey: .availability)
        try container.encodeIfPresent(quarantineReason, forKey: .quarantineReason)
    }
}

/// Durable object metadata is separate from transient Vision tracking IDs.
/// The wrapped object retains semantic/state facts while `position` enforces
/// the coordinate provenance required for persistence.
public struct SpatialObjectMetadata: Codable, Hashable, Sendable {
    public let mapID: MapID
    public let object: SpatialObject
    public let position: FramedPosition

    public init(mapID: MapID, object: SpatialObject, position: FramedPosition) throws {
        guard object.position == position.value else {
            throw SpatialCaptureMetadataError.objectPositionMismatch
        }
        guard object.lastSeenAt == position.observedAt else {
            throw SpatialCaptureMetadataError.objectObservationTimeMismatch
        }
        self.mapID = mapID
        self.object = object
        self.position = position
    }

    private enum CodingKeys: String, CodingKey {
        case mapID
        case object
        case position
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                mapID: container.decode(MapID.self, forKey: .mapID),
                object: container.decode(SpatialObject.self, forKey: .object),
                position: container.decode(FramedPosition.self, forKey: .position)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .position,
                in: container,
                debugDescription: "Object and framed position/time values must match."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mapID, forKey: .mapID)
        try container.encode(object, forKey: .object)
        try container.encode(position, forKey: .position)
    }
}

public struct SpatialMetadataDocument: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public var maps: [SpatialMapMetadata]
    public var objects: [SpatialObjectMetadata]

    public init(
        maps: [SpatialMapMetadata] = [],
        objects: [SpatialObjectMetadata] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.maps = maps
        self.objects = objects
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case maps
        case objects
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.currentSchemaVersion).contains(version) else {
            throw SpatialCaptureMetadataError.invalidSchemaVersion(version)
        }
        // v1 contains calendar-ordered objects; their nil temporalRevision is
        // preserved until a protected v2 journal update explicitly migrates it.
        schemaVersion = Self.currentSchemaVersion
        maps = try container.decode([SpatialMapMetadata].self, forKey: .maps)
        objects = try container.decode([SpatialObjectMetadata].self, forKey: .objects)
        try validate()
    }

    /// Verifies cross-record invariants that member-wise Codable decoding
    /// cannot enforce. A logical map may have multiple checkpoint blobs, but
    /// every checkpoint must stay in one coordinate frame and every object
    /// must resolve to that same frame.
    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SpatialCaptureMetadataError.invalidSchemaVersion(schemaVersion)
        }

        var blobIDs = Set<UUID>()
        var mapFrames: [MapID: CoordinateFrameID] = [:]
        for map in maps {
            guard blobIDs.insert(map.worldMapBlobID).inserted else {
                throw SpatialCaptureMetadataError.duplicateWorldMapBlobID
            }
            if let existingFrame = mapFrames[map.mapID] {
                guard existingFrame == map.coordinateFrameID else {
                    throw SpatialCaptureMetadataError.inconsistentMapCoordinateFrame
                }
            } else {
                mapFrames[map.mapID] = map.coordinateFrameID
            }
        }

        var objectKeys = Set<ObjectRecordKey>()
        for object in objects {
            guard let mapFrame = mapFrames[object.mapID] else {
                throw SpatialCaptureMetadataError.orphanedObject
            }
            guard mapFrame == object.position.coordinateFrameID else {
                throw SpatialCaptureMetadataError.inconsistentMapCoordinateFrame
            }
            guard
                objectKeys.insert(
                    ObjectRecordKey(mapID: object.mapID, objectID: object.object.id)
                ).inserted
            else {
                throw SpatialCaptureMetadataError.duplicateObject
            }
        }
    }

    private struct ObjectRecordKey: Hashable {
        let mapID: MapID
        let objectID: ObjectID
    }
}

/// Decodes the current schema and the one pre-release metadata shape used by
/// migration fixtures. Migration is deterministic and never creates new IDs.
public enum SpatialMetadataMigrator {
    public static func decodeAndMigrate(_ data: Data) throws -> SpatialMetadataDocument {
        let decoder = JSONDecoder()
        let probe: SchemaProbe
        do {
            probe = try decoder.decode(SchemaProbe.self, from: data)
        } catch {
            throw SpatialCaptureMetadataError.malformedDocument
        }

        do {
            switch probe.schemaVersion {
            case 1, SpatialMetadataDocument.currentSchemaVersion:
                return try decoder.decode(SpatialMetadataDocument.self, from: data)
            case 0:
                let legacy = try decoder.decode(LegacyDocumentV0.self, from: data)
                let map = try SpatialMapMetadata(
                    mapID: legacy.mapID,
                    coordinateFrameID: legacy.coordinateFrameID,
                    latestSegmentID: legacy.segmentID,
                    worldMapBlobID: legacy.worldMapBlobID,
                    createdAt: legacy.createdAt,
                    updatedAt: legacy.updatedAt,
                    availability: .active
                )
                let document = SpatialMetadataDocument(maps: [map], objects: legacy.objects)
                try document.validate()
                return document
            default:
                throw SpatialCaptureMetadataError.unsupportedSchemaVersion(probe.schemaVersion)
            }
        } catch let error as SpatialCaptureMetadataError {
            throw error
        } catch {
            throw SpatialCaptureMetadataError.malformedDocument
        }
    }

    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }

    private struct LegacyDocumentV0: Decodable {
        let schemaVersion: Int
        let mapID: MapID
        let coordinateFrameID: CoordinateFrameID
        let segmentID: CaptureSegmentID
        let worldMapBlobID: UUID
        let createdAt: TimeInterval
        let updatedAt: TimeInterval
        let objects: [SpatialObjectMetadata]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case mapID
            case coordinateFrameID
            case segmentID
            case worldMapBlobID
            case createdAt
            case updatedAt
            case objects
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            guard schemaVersion == 0 else {
                throw SpatialCaptureMetadataError.invalidSchemaVersion(schemaVersion)
            }
            mapID = try container.decode(MapID.self, forKey: .mapID)
            coordinateFrameID = try container.decode(
                CoordinateFrameID.self,
                forKey: .coordinateFrameID
            )
            segmentID = try container.decode(CaptureSegmentID.self, forKey: .segmentID)
            worldMapBlobID = try container.decode(UUID.self, forKey: .worldMapBlobID)
            createdAt = try container.decode(TimeInterval.self, forKey: .createdAt)
            updatedAt = try container.decode(TimeInterval.self, forKey: .updatedAt)
            objects = try container.decode([SpatialObjectMetadata].self, forKey: .objects)
        }
    }
}
