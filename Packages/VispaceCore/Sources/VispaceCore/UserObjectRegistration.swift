import Foundation

public enum UserObjectRegistrationError: Error, Equatable, Sendable {
    case invalidName
    case invalidSample
    case identityChanged
    case inconsistentTime
    case unstablePosition
}

/// The complete capture identity, including the session attachment/run, is
/// required before several observations can support one user-named point.
public struct UserObjectRegistrationIdentity: Hashable, Sendable {
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let segmentID: CaptureSegmentID
    public let sessionRunGeneration: UInt64
    public let attachmentEpoch: UInt64

    public init(mapID: MapID, coordinateFrameID: CoordinateFrameID,
                segmentID: CaptureSegmentID, sessionRunGeneration: UInt64,
                attachmentEpoch: UInt64) {
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        self.segmentID = segmentID
        self.sessionRunGeneration = sessionRunGeneration
        self.attachmentEpoch = attachmentEpoch
    }
}

/// A single independent frame contributes at most one measured surface point.
/// This contains no camera image, appearance descriptor, or inferred volume.
public struct UserObjectRegistrationSample: Hashable, Sendable {
    public let frameID: FrameID
    public let identity: UserObjectRegistrationIdentity
    public let position: Vec3
    public let timestamp: TimeInterval
    public let capturedAt: TimeInterval
    public let trackingQuality: SpatialTrackingQuality
    public let uncertainty: SpatialPositionUncertainty
    public let isCoordinateFrameConfirmed: Bool

    public init(frameID: FrameID, identity: UserObjectRegistrationIdentity,
                position: Vec3, timestamp: TimeInterval, capturedAt: TimeInterval,
                trackingQuality: SpatialTrackingQuality,
                uncertainty: SpatialPositionUncertainty,
                isCoordinateFrameConfirmed: Bool) {
        self.frameID = frameID
        self.identity = identity
        self.position = position
        self.timestamp = timestamp
        self.capturedAt = capturedAt
        self.trackingQuality = trackingQuality
        self.uncertainty = uncertainty
        self.isCoordinateFrameConfirmed = isCoordinateFrameConfirmed
    }
}

/// Explicit user annotation supplies the name and identity assertion. Depth
/// supplies a last-seen surface point only, never an automatic classification
/// or the object's size. Current visibility must be established separately.
public struct UserObjectRegistrationAccumulator: Sendable {
    public static let semanticLabel = "user_registered_object"
    public let name: String
    public private(set) var sampleCount = 0
    private let objectID: ObjectID
    private var samples: [UserObjectRegistrationSample] = []
    private var completedMetadata: SpatialObjectMetadata?

    public init(name: String, objectID: ObjectID = ObjectID()) throws {
        let normalized = name.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            normalized.count <= SpatialObject.maximumDisplayNameLength,
            normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
            normalized.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
        else { throw UserObjectRegistrationError.invalidName }
        self.name = normalized
        self.objectID = objectID
    }

    public mutating func append(_ sample: UserObjectRegistrationSample) throws -> SpatialObjectMetadata? {
        guard completedMetadata == nil else { return nil }
        guard sample.isCoordinateFrameConfirmed,
            sample.trackingQuality == .normal,
            sample.uncertainty == .highConfidenceDepth,
            sample.timestamp.isFinite, sample.timestamp >= 0,
            sample.capturedAt.isFinite, sample.capturedAt >= 0,
            sample.position.x.isFinite, sample.position.y.isFinite, sample.position.z.isFinite
        else { throw UserObjectRegistrationError.invalidSample }

        if let first = samples.first, let previous = samples.last {
            guard sample.identity == first.identity else {
                throw UserObjectRegistrationError.identityChanged
            }
            guard !samples.contains(where: { $0.frameID == sample.frameID }) else { return nil }
            let monotonicDelta = sample.timestamp - previous.timestamp
            let calendarDelta = sample.capturedAt - previous.capturedAt
            guard monotonicDelta > 0, monotonicDelta <= 0.75,
                calendarDelta > 0,
                abs(calendarDelta - monotonicDelta) <= 0.25,
                abs((sample.capturedAt - first.capturedAt) - (sample.timestamp - first.timestamp)) <= 0.25
            else { throw UserObjectRegistrationError.inconsistentTime }
            // Require the same observed surface instead of averaging points on
            // different objects. The threshold is a stability gate, not a claim
            // that the depth sensor has a calibrated eight-centimeter error.
            guard samples.allSatisfy({ $0.position.distance(to: sample.position) <= 0.08 }) else {
                throw UserObjectRegistrationError.unstablePosition
            }
            // Three adjacent 60 fps frames are not a sustained observation.
            // This also bounds retained samples independently of frame rate.
            guard monotonicDelta >= 0.1 - 0.000_001 else { return nil }
        }

        samples.append(sample)
        sampleCount = samples.count
        guard let first = samples.first, samples.count >= 3,
            sample.timestamp - first.timestamp >= 0.3 - 0.000_001 else { return nil }

        // Select a point actually supplied by depth; do not fabricate a mean
        // between surfaces. Tie order is deterministic (earlier observation).
        let medoid = samples.enumerated().min { lhs, rhs in
            let left = samples.reduce(0.0) { $0 + $1.position.distance(to: lhs.element.position) }
            let right = samples.reduce(0.0) { $0 + $1.position.distance(to: rhs.element.position) }
            return left == right ? lhs.offset < rhs.offset : left < right
        }!.element
        let position = try FramedPosition(
            coordinateFrameID: sample.identity.coordinateFrameID,
            value: medoid.position,
            observedAt: medoid.capturedAt,
            trackingQuality: .normal,
            uncertainty: .highConfidenceDepth
        )
        let object = try SpatialObject(
            id: objectID, semanticLabel: Self.semanticLabel, position: medoid.position,
            bounds: nil, certainty: .confirmed, presence: .lastSeen,
            confidence: ConfidenceVector(
                // These are explicit user assertions, not model probabilities.
                semantic: .one, geometry: ConfidenceScore(clamping: 0.8),
                tracking: .one, place: .one, identity: .one, objectState: .one
            ),
            firstSeenAt: first.capturedAt, lastSeenAt: medoid.capturedAt,
            stateUpdatedAt: sample.capturedAt,
            displayName: name
        )
        let metadata = try SpatialObjectMetadata(mapID: sample.identity.mapID, object: object, position: position)
        completedMetadata = metadata
        samples.removeAll(keepingCapacity: false)
        return metadata
    }
}
