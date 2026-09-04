import Foundation

public enum SpatialMemoryError: Error, Equatable, Sendable {
    case provisionalObject(ObjectID)
}

public enum MemoryTier: Int, Codable, Comparable, CaseIterable, Sendable {
    case realtime = 1
    case localMap = 2
    case longTerm = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum MemoryLocationKind: String, Codable, Hashable, Sendable {
    case current
    case lastSeen
    case removed
}

public struct MemorySearchHit: Codable, Hashable, Sendable {
    public let object: SpatialObject
    public let tier: MemoryTier
    public let locationKind: MemoryLocationKind

    public init(object: SpatialObject, tier: MemoryTier, locationKind: MemoryLocationKind) {
        self.object = object
        self.tier = tier
        self.locationKind = locationKind
    }
}

/// In-memory model of the L1/L2/L3 lookup contract. Persistence adapters can
/// hydrate each tier independently without changing deterministic search order.
public struct HierarchicalSpatialMemory: Sendable {
    private var realtime: [ObjectID: SpatialObject]
    private var localMap: [ObjectID: SpatialObject]
    private var longTerm: [ObjectID: SpatialObject]

    public init(
        realtime: [ObjectID: SpatialObject] = [:],
        localMap: [ObjectID: SpatialObject] = [:],
        longTerm: [ObjectID: SpatialObject] = [:]
    ) throws {
        for layer in [realtime, localMap, longTerm] {
            for object in layer.values {
                guard object.certainty == .confirmed else {
                    throw SpatialMemoryError.provisionalObject(object.id)
                }
            }
        }
        self.realtime = realtime
        self.localMap = localMap
        self.longTerm = longTerm
    }

    public mutating func upsert(_ object: SpatialObject, in tier: MemoryTier) throws {
        guard object.certainty == .confirmed else {
            throw SpatialMemoryError.provisionalObject(object.id)
        }
        switch tier {
        case .realtime:
            realtime[object.id] = object
        case .localMap:
            localMap[object.id] = object
        case .longTerm:
            longTerm[object.id] = object
        }
    }

    public mutating func remove(_ objectID: ObjectID, from tier: MemoryTier) {
        switch tier {
        case .realtime:
            realtime.removeValue(forKey: objectID)
        case .localMap:
            localMap.removeValue(forKey: objectID)
        case .longTerm:
            longTerm.removeValue(forKey: objectID)
        }
    }

    /// Searches L1, then L2, then L3 and stops at the first tier with a match.
    public func search(
        semanticLabel: String,
        includeRemoved: Bool = false
    ) -> [MemorySearchHit] {
        let query = normalize(semanticLabel)
        guard !query.isEmpty else {
            return []
        }

        for tier in MemoryTier.allCases {
            let values = objects(in: tier).values
            let hits =
                values
                .filter { object in
                    normalize(object.semanticLabel) == query
                        && (includeRemoved || object.presence != .removed)
                }
                .map { object in
                    MemorySearchHit(
                        object: object,
                        tier: tier,
                        locationKind: locationKind(for: object.presence)
                    )
                }
                .sorted(by: rank)
            if !hits.isEmpty {
                return hits
            }
        }
        return []
    }

    private func objects(in tier: MemoryTier) -> [ObjectID: SpatialObject] {
        switch tier {
        case .realtime:
            return realtime
        case .localMap:
            return localMap
        case .longTerm:
            return longTerm
        }
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func locationKind(for presence: ObjectPresence) -> MemoryLocationKind {
        switch presence {
        case .visible:
            return .current
        case .notVisible, .lastSeen:
            return .lastSeen
        case .removed:
            return .removed
        }
    }

    private func rank(_ lhs: MemorySearchHit, _ rhs: MemorySearchHit) -> Bool {
        let lhsPresence = presenceRank(lhs.object.presence)
        let rhsPresence = presenceRank(rhs.object.presence)
        if lhsPresence != rhsPresence {
            return lhsPresence < rhsPresence
        }
        if lhs.object.confidence.objectState != rhs.object.confidence.objectState {
            return lhs.object.confidence.objectState > rhs.object.confidence.objectState
        }
        if lhs.object.lastSeenAt != rhs.object.lastSeenAt {
            return lhs.object.lastSeenAt > rhs.object.lastSeenAt
        }
        return lhs.object.id < rhs.object.id
    }

    private func presenceRank(_ presence: ObjectPresence) -> Int {
        switch presence {
        case .visible:
            return 0
        case .notVisible:
            return 1
        case .lastSeen:
            return 2
        case .removed:
            return 3
        }
    }
}
