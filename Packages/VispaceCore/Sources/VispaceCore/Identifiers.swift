import Foundation

/// A UUID-backed identifier whose phantom tag prevents IDs from unrelated
/// domains from being mixed accidentally.
public struct TypedID<Tag>: RawRepresentable, Codable, Hashable, Comparable, Sendable,
    CustomStringConvertible
{
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else {
            return nil
        }
        self.init(rawValue: value)
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.description < rhs.description
    }
}

public enum FrameIDTag: Sendable {}
public enum SessionIDTag: Sendable {}
public enum MapIDTag: Sendable {}
public enum SpatialNodeIDTag: Sendable {}
public enum ObjectIDTag: Sendable {}
public enum TrackIDTag: Sendable {}
public enum ObservationIDTag: Sendable {}
public enum SpatialDeltaIDTag: Sendable {}

public typealias FrameID = TypedID<FrameIDTag>
public typealias SessionID = TypedID<SessionIDTag>
public typealias MapID = TypedID<MapIDTag>
public typealias SpatialNodeID = TypedID<SpatialNodeIDTag>
public typealias ObjectID = TypedID<ObjectIDTag>
public typealias TrackID = TypedID<TrackIDTag>
public typealias ObservationID = TypedID<ObservationIDTag>
public typealias SpatialDeltaID = TypedID<SpatialDeltaIDTag>
