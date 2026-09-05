import Foundation

public enum SpatialObjectError: Error, Equatable, Sendable {
    case emptySemanticLabel
    case invalidTimestamp
    case invalidDisplayName
    case invalidTemporalRevision
}

public enum ObjectCertainty: String, Codable, Hashable, Sendable {
    case provisional
    case confirmed
}

public enum ObjectPresence: String, Codable, Hashable, Sendable {
    case visible
    case notVisible
    case lastSeen
    case removed
}

public struct SpatialObject: Codable, Hashable, Sendable {
    public static let maximumDisplayNameLength = 64
    public let id: ObjectID
    public var semanticLabel: String
    /// Original detector class retained after an explicit user correction.
    /// It is an observation alias, never independent physical identity proof.
    public var detectorSemanticLabel: String?
    public var nodeID: SpatialNodeID?
    public var position: Vec3
    public var bounds: AABB?
    public var certainty: ObjectCertainty
    public var presence: ObjectPresence
    public var confidence: ConfidenceVector
    public let firstSeenAt: TimeInterval
    public var lastSeenAt: TimeInterval
    /// Ordering timestamp for lifecycle mutations. This is distinct from
    /// `lastSeenAt`, which always means the time of the latest observation.
    public var stateUpdatedAt: TimeInterval
    /// User annotation; never replaces the detector's semantic class.
    public private(set) var displayName: String?
    public var temporalRevision: UInt64?
    public var displayLabel: String { displayName ?? semanticLabel }

    public init(
        id: ObjectID = ObjectID(),
        semanticLabel: String,
        nodeID: SpatialNodeID? = nil,
        position: Vec3,
        bounds: AABB? = nil,
        certainty: ObjectCertainty,
        presence: ObjectPresence = .visible,
        confidence: ConfidenceVector,
        firstSeenAt: TimeInterval,
        lastSeenAt: TimeInterval,
        stateUpdatedAt: TimeInterval? = nil,
        displayName: String? = nil,
        temporalRevision: UInt64? = nil,
        detectorSemanticLabel: String? = nil
    ) throws {
        let normalizedLabel = semanticLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedStateUpdatedAt = stateUpdatedAt ?? lastSeenAt
        guard !normalizedLabel.isEmpty else {
            throw SpatialObjectError.emptySemanticLabel
        }
        guard temporalRevision == nil || temporalRevision! > 0 else {
            throw SpatialObjectError.invalidTemporalRevision
        }
        guard firstSeenAt.isFinite, firstSeenAt >= 0,
            lastSeenAt.isFinite, lastSeenAt >= 0,
            resolvedStateUpdatedAt.isFinite, resolvedStateUpdatedAt >= 0,
            temporalRevision != nil || (lastSeenAt >= firstSeenAt && resolvedStateUpdatedAt >= lastSeenAt)
        else {
            throw SpatialObjectError.invalidTimestamp
        }

        self.id = id
        self.semanticLabel = normalizedLabel
        let detectorLabel = detectorSemanticLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard detectorLabel.map({ !$0.isEmpty && $0.count <= 64 }) ?? true else {
            throw SpatialObjectError.emptySemanticLabel
        }
        self.detectorSemanticLabel = detectorLabel
        self.nodeID = nodeID
        self.position = position
        self.bounds = bounds
        self.certainty = certainty
        self.presence = presence
        self.confidence = confidence
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.stateUpdatedAt = resolvedStateUpdatedAt
        self.displayName = nil
        self.temporalRevision = temporalRevision
        try setDisplayName(displayName)
    }

    public mutating func setDisplayName(_ value: String?) throws {
        let name = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { displayName = nil; return }
        guard name.count <= Self.maximumDisplayNameLength,
            name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
            name.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
        else { throw SpatialObjectError.invalidDisplayName }
        displayName = name
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case semanticLabel
        case detectorSemanticLabel
        case nodeID
        case position
        case bounds
        case certainty
        case presence
        case confidence
        case firstSeenAt
        case lastSeenAt
        case stateUpdatedAt
        case displayName
        case temporalRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ObjectID.self, forKey: .id),
                semanticLabel: container.decode(String.self, forKey: .semanticLabel),
                nodeID: container.decodeIfPresent(SpatialNodeID.self, forKey: .nodeID),
                position: container.decode(Vec3.self, forKey: .position),
                bounds: container.decodeIfPresent(AABB.self, forKey: .bounds),
                certainty: container.decode(ObjectCertainty.self, forKey: .certainty),
                presence: container.decode(ObjectPresence.self, forKey: .presence),
                confidence: container.decode(ConfidenceVector.self, forKey: .confidence),
                firstSeenAt: container.decode(TimeInterval.self, forKey: .firstSeenAt),
                lastSeenAt: container.decode(TimeInterval.self, forKey: .lastSeenAt),
                stateUpdatedAt: container.decode(TimeInterval.self, forKey: .stateUpdatedAt),
                displayName: container.decodeIfPresent(String.self, forKey: .displayName),
                temporalRevision: container.decodeIfPresent(UInt64.self, forKey: .temporalRevision),
                detectorSemanticLabel: container.decodeIfPresent(String.self, forKey: .detectorSemanticLabel)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .semanticLabel,
                in: container,
                debugDescription: "Spatial object contains an invalid label or timestamp."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(semanticLabel, forKey: .semanticLabel)
        try container.encodeIfPresent(detectorSemanticLabel, forKey: .detectorSemanticLabel)
        try container.encodeIfPresent(nodeID, forKey: .nodeID)
        try container.encode(position, forKey: .position)
        try container.encodeIfPresent(bounds, forKey: .bounds)
        try container.encode(certainty, forKey: .certainty)
        try container.encode(presence, forKey: .presence)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(firstSeenAt, forKey: .firstSeenAt)
        try container.encode(lastSeenAt, forKey: .lastSeenAt)
        try container.encode(stateUpdatedAt, forKey: .stateUpdatedAt)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(temporalRevision, forKey: .temporalRevision)
    }
}

public enum ObjectEvent: Codable, Hashable, Sendable {
    case upsert(SpatialObject)
    case observed(
        objectID: ObjectID,
        at: TimeInterval,
        position: Vec3,
        bounds: AABB?,
        confidence: ConfidenceVector
    )
    case becameNotVisible(objectID: ObjectID, at: TimeInterval)
    case becameLastSeen(objectID: ObjectID, at: TimeInterval)
    case moved(
        objectID: ObjectID,
        from: Vec3,
        to: Vec3,
        at: TimeInterval,
        confidence: ConfidenceScore
    )
    case removed(objectID: ObjectID, at: TimeInterval, confidence: ConfidenceScore)
    case discardProvisional(objectID: ObjectID)
}

public struct SpatialDelta: Codable, Hashable, Sendable {
    public let id: SpatialDeltaID
    public let baseRevision: UInt64
    public let events: [ObjectEvent]

    public init(
        id: SpatialDeltaID = SpatialDeltaID(),
        baseRevision: UInt64,
        events: [ObjectEvent]
    ) {
        self.id = id
        self.baseRevision = baseRevision
        self.events = events
    }
}
