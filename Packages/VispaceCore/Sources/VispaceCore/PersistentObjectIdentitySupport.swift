import Foundation

/// A sensor observation within one uninterrupted Vision tracking run. A track
/// identifier is intentionally absent: only independently checked image and
/// depth measurements can support the persistent identity.
public struct ContinuousObjectTrackingSample: Codable, Hashable, Sendable {
    public let frameID: FrameID
    public let position: FramedPosition
    public let captureSegmentID: CaptureSegmentID
    public let monotonicTimestamp: TimeInterval
    public let trackerConfidence: ConfidenceScore?
    public let geometryConfidence: ConfidenceScore
    public let associationMargin: Double
    public let bounds: AABB

    public init(
        frameID: FrameID, position: FramedPosition, captureSegmentID: CaptureSegmentID,
        monotonicTimestamp: TimeInterval, trackerConfidence: ConfidenceScore?,
        associationMargin: Double, bounds: AABB, geometryConfidence: ConfidenceScore = .zero
    ) {
        self.frameID = frameID
        self.position = position
        self.captureSegmentID = captureSegmentID
        self.monotonicTimestamp = monotonicTimestamp
        self.trackerConfidence = trackerConfidence
        self.geometryConfidence = geometryConfidence
        self.associationMargin = associationMargin
        self.bounds = bounds
    }
}

/// Supplemental identity authority is recorded in the same journal entry as
/// its observation. It is revalidated during replay against the exact prior
/// durable revision, instead of replacing spatial-context scores with ones.
public enum PersistentObjectIdentitySupport: Codable, Hashable, Sendable {
    case continuousTracking(objectID: ObjectID, samples: [ContinuousObjectTrackingSample])
    case userConfirmation(
        objectID: ObjectID, expectedTemporalRevision: UInt64?,
        mapID: MapID, coordinateFrameID: CoordinateFrameID,
        captureSegmentID: CaptureSegmentID, reviewedFrameID: FrameID,
        reviewedPosition: Vec3, reviewedAt: TimeInterval,
        confirmedAt: TimeInterval)

    public var objectID: ObjectID {
        switch self {
        case .continuousTracking(let objectID, _): objectID
        case .userConfirmation(let objectID, _, _, _, _, _, _, _, _): objectID
        }
    }

    public func validates(
        existing: SpatialObjectMetadata, incoming: SpatialObjectMetadata,
        promotionEvidence: ObjectReidentificationPromotionEvidence
    ) -> Bool {
        guard objectID == existing.object.id, existing.mapID == incoming.mapID,
            existing.position.coordinateFrameID == incoming.position.coordinateFrameID,
            existing.object.semanticLabel == incoming.object.semanticLabel,
            existing.object.certainty == .confirmed, existing.object.presence != .removed,
            incoming.position.trackingQuality == .normal
        else { return false }
        switch self {
        case .userConfirmation(
            _, let revision, let mapID, let frameID, let segmentID,
            let reviewedFrameID, let position, let reviewedAt, let confirmedAt):
            return revision == existing.object.temporalRevision && mapID == incoming.mapID
                && frameID == incoming.position.coordinateFrameID
                && segmentID == promotionEvidence.captureSegmentID
                && reviewedAt.isFinite && confirmedAt.isFinite
                && reviewedAt >= 0 && confirmedAt >= reviewedAt
                && incoming.position.observedAt >= confirmedAt
                && incoming.position.observedAt - reviewedAt <= 2
                && position.distance(to: incoming.position.value) <= 0.12
                && promotionEvidence.frameIDs.contains(reviewedFrameID)
        case .continuousTracking(_, let samples):
            guard (3...32).contains(samples.count),
                Set(samples.map(\.frameID)).count == samples.count,
                let anchorIndex = samples.firstIndex(where: {
                    $0.position == existing.position
                }), anchorIndex < samples.count - 1,
                samples.last?.position == incoming.position,
                samples.last?.frameID == promotionEvidence.frameIDs.last,
                samples.allSatisfy({ sample in
                    sample.position.coordinateFrameID == incoming.position.coordinateFrameID
                        && sample.captureSegmentID == promotionEvidence.captureSegmentID
                        && sample.position.trackingQuality == .normal
                        && sample.monotonicTimestamp.isFinite && sample.monotonicTimestamp >= 0
                        && sample.geometryConfidence >= ConfidencePolicy.default.highThreshold
                        && sample.associationMargin.isFinite && sample.associationMargin <= 1
                })
            else { return false }
            // Validate the complete window, not merely its last pair. A dropped
            // tracker, ambiguous crossing, or discontinuous jump breaks the chain.
            for index in 1..<samples.count {
                let previous = samples[index - 1]
                let sample = samples[index]
                let elapsed = sample.monotonicTimestamp - previous.monotonicTimestamp
                guard elapsed > 0, elapsed <= 0.6,
                    sample.position.observedAt > previous.position.observedAt,
                    sample.trackerConfidence.map({ $0.value >= 0.8 }) == true,
                    sample.associationMargin >= 0.15,
                    sample.position.value.distance(to: previous.position.value)
                        <= min(0.35, 2 * elapsed + 0.03),
                    Self.sizeSimilarity(previous.bounds, sample.bounds) >= 0.65
                else { return false }
            }
            return true
        }
    }

    private static func sizeSimilarity(_ left: AABB, _ right: AABB) -> Double {
        let lhs = [left.max.x - left.min.x, left.max.y - left.min.y, left.max.z - left.min.z]
        let rhs = [right.max.x - right.min.x, right.max.y - right.min.y, right.max.z - right.min.z]
        return zip(lhs, rhs).map { a, b in
            max(a, b) <= 0 ? 1 : min(a, b) / max(a, b)
        }.min() ?? 0
    }
}

extension PersistentObjectReidentificationResolver {
    /// Resolve a nominated candidate only when the supplied independent
    /// authority verifies its actual existing revision and current evidence.
    public func resolveSupportedIdentity(
        incoming: SpatialObjectMetadata,
        promotionEvidence: ObjectReidentificationPromotionEvidence,
        support: PersistentObjectIdentitySupport, against existing: SpatialObjectMetadata
    ) throws -> PersistentObjectReidentificationDecision? {
        guard
            support.validates(
                existing: existing, incoming: incoming,
                promotionEvidence: promotionEvidence)
        else { return nil }
        return .confirmedExisting(
            try PersistentObjectReidentificationCandidate(
                objectID: existing.object.id, score: .one,
                geometryScore: ConfidenceScore(
                    clamping:
                        1 - existing.position.value.distance(to: incoming.position.value)
                        / policy.maximumPositionDistance),
                spatialContextScore: nil, visualSimilarity: nil,
                positionDistance: existing.position.value.distance(to: incoming.position.value)))
    }
}
