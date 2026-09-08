import Foundation

/// Validation failures for repeated object-observation promotion.
public enum ObjectObservationPromotionError: Error, Equatable, Sendable {
    case invalidNormalizedBoundingBox
    case emptySemanticLabel
    case positionCoordinateFrameMismatch
    case mapCoordinateFrameMismatch
    case mapRegistryCapacityExceeded
    case conflictingObservationID
    case invalidPolicy
}

/// An axis-aligned image-space rectangle whose coordinates are normalized to
/// the closed `0...1` range. Adapters must provide every rectangle in the same
/// display orientation with a top-left origin before association.
public struct NormalizedBoundingBox2D: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    /// Creates a nonempty normalized rectangle fully contained by the image.
    public init(x: Double, y: Double, width: Double, height: Double) throws {
        let values = [x, y, width, height]
        guard values.allSatisfy(\.isFinite),
            x >= 0,
            y >= 0,
            width > 0,
            height > 0,
            x + width <= 1,
            y + height <= 1
        else {
            throw ObjectObservationPromotionError.invalidNormalizedBoundingBox
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Intersection-over-union with another normalized rectangle.
    public func intersectionOverUnion(with other: Self) -> Double {
        let overlapWidth = Swift.max(
            0,
            Swift.min(x + width, other.x + other.width) - Swift.max(x, other.x)
        )
        let overlapHeight = Swift.max(
            0,
            Swift.min(y + height, other.y + other.height) - Swift.max(y, other.y)
        )
        let intersectionArea = overlapWidth * overlapHeight
        let unionArea = width * height + other.width * other.height - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    /// Euclidean distance between rectangle centers in normalized image units.
    public func centerDistance(to other: Self) -> Double {
        let dx = (x + width * 0.5) - (other.x + other.width * 0.5)
        let dy = (y + height * 0.5) - (other.y + other.height * 0.5)
        return (dx * dx + dy * dy).squareRoot()
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case width
        case height
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                x: container.decode(Double.self, forKey: .x),
                y: container.decode(Double.self, forKey: .y),
                width: container.decode(Double.self, forKey: .width),
                height: container.decode(Double.self, forKey: .height)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .x,
                in: container,
                debugDescription: "Bounding box must be finite, nonempty, and inside 0...1."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }
}

/// One transient detector/depth observation. Neither `observationID` nor
/// `trackID` is ever reused as a durable `ObjectID`.
public struct ObjectPromotionObservation: Codable, Hashable, Sendable {
    public let observationID: ObservationID
    public let frameID: FrameID
    public let trackID: TrackID?
    public let semanticLabel: String
    public let coordinateFrameID: CoordinateFrameID
    public let captureSegmentID: CaptureSegmentID
    public let mapID: MapID?
    public let boundingBox: NormalizedBoundingBox2D
    public let position: FramedPosition
    public let bounds: AABB?
    public let semanticConfidence: ConfidenceScore
    public let geometryConfidence: ConfidenceScore

    /// Creates an observation while enforcing coordinate provenance and a
    /// nonempty semantic label.
    public init(
        observationID: ObservationID,
        frameID: FrameID,
        trackID: TrackID? = nil,
        semanticLabel: String,
        coordinateFrameID: CoordinateFrameID,
        captureSegmentID: CaptureSegmentID,
        mapID: MapID?,
        boundingBox: NormalizedBoundingBox2D,
        position: FramedPosition,
        bounds: AABB? = nil,
        semanticConfidence: ConfidenceScore,
        geometryConfidence: ConfidenceScore
    ) throws {
        let normalizedLabel = semanticLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else {
            throw ObjectObservationPromotionError.emptySemanticLabel
        }
        guard position.coordinateFrameID == coordinateFrameID else {
            throw ObjectObservationPromotionError.positionCoordinateFrameMismatch
        }
        self.observationID = observationID
        self.frameID = frameID
        self.trackID = trackID
        self.semanticLabel = normalizedLabel
        self.coordinateFrameID = coordinateFrameID
        self.captureSegmentID = captureSegmentID
        self.mapID = mapID
        self.boundingBox = boundingBox
        self.position = position
        self.bounds = bounds
        self.semanticConfidence = semanticConfidence
        self.geometryConfidence = geometryConfidence
    }

    private enum CodingKeys: String, CodingKey {
        case observationID
        case frameID
        case trackID
        case semanticLabel
        case coordinateFrameID
        case captureSegmentID
        case mapID
        case boundingBox
        case position
        case bounds
        case semanticConfidence
        case geometryConfidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                observationID: container.decode(ObservationID.self, forKey: .observationID),
                frameID: container.decode(FrameID.self, forKey: .frameID),
                trackID: container.decodeIfPresent(TrackID.self, forKey: .trackID),
                semanticLabel: container.decode(String.self, forKey: .semanticLabel),
                coordinateFrameID: container.decode(
                    CoordinateFrameID.self,
                    forKey: .coordinateFrameID
                ),
                captureSegmentID: container.decode(
                    CaptureSegmentID.self,
                    forKey: .captureSegmentID
                ),
                mapID: container.decodeIfPresent(MapID.self, forKey: .mapID),
                boundingBox: container.decode(
                    NormalizedBoundingBox2D.self,
                    forKey: .boundingBox
                ),
                position: container.decode(FramedPosition.self, forKey: .position),
                bounds: container.decodeIfPresent(AABB.self, forKey: .bounds),
                semanticConfidence: container.decode(
                    ConfidenceScore.self,
                    forKey: .semanticConfidence
                ),
                geometryConfidence: container.decode(
                    ConfidenceScore.self,
                    forKey: .geometryConfidence
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .coordinateFrameID,
                in: container,
                debugDescription: "Observation label or coordinate provenance is invalid."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(observationID, forKey: .observationID)
        try container.encode(frameID, forKey: .frameID)
        try container.encodeIfPresent(trackID, forKey: .trackID)
        try container.encode(semanticLabel, forKey: .semanticLabel)
        try container.encode(coordinateFrameID, forKey: .coordinateFrameID)
        try container.encode(captureSegmentID, forKey: .captureSegmentID)
        try container.encodeIfPresent(mapID, forKey: .mapID)
        try container.encode(boundingBox, forKey: .boundingBox)
        try container.encode(position, forKey: .position)
        try container.encodeIfPresent(bounds, forKey: .bounds)
        try container.encode(semanticConfidence, forKey: .semanticConfidence)
        try container.encode(geometryConfidence, forKey: .geometryConfidence)
    }
}

/// Thresholds used both to associate repeated observations and to decide when
/// provisional evidence is strong enough to create a durable object identity.
public struct ObjectObservationPromotionPolicy: Codable, Hashable, Sendable {
    public let minimumDistinctFrames: Int
    public let minimumObservationInterval: TimeInterval
    public let minimumObservationDuration: TimeInterval
    public let maximumAssociationTimeGap: TimeInterval
    public let maximumAssociationDistance3D: Double
    public let minimumAssociationScore: ConfidenceScore
    public let minimumBoundingBoxIoU: Double
    public let maximumBoundingBoxCenterDistance: Double
    public let maximumMeanSquaredPositionDeviation: Double
    public let minimumAverageSemanticConfidence: ConfidenceScore
    public let minimumAverageGeometryConfidence: ConfidenceScore
    public let minimumPromotedObjectConfidence: ConfidenceScore
    public let minimumMappedObservations: Int
    public let minimumAssociationScoreMargin: Double
    public let maximumCandidateAge: TimeInterval
    public let maximumCandidateCount: Int
    public let maximumObservationsPerCandidate: Int
    public let maximumKnownMapCount: Int

    /// Creates a policy. The frame and mapped-observation floors cannot be
    /// weakened below three and two respectively.
    public init(
        minimumDistinctFrames: Int = 3,
        minimumObservationInterval: TimeInterval = 0.10,
        minimumObservationDuration: TimeInterval = 0.30,
        maximumAssociationTimeGap: TimeInterval = 2,
        maximumAssociationDistance3D: Double = 0.35,
        minimumAssociationScore: ConfidenceScore = ConfidenceScore(clamping: 0.50),
        minimumBoundingBoxIoU: Double = 0.20,
        maximumBoundingBoxCenterDistance: Double = 0.18,
        maximumMeanSquaredPositionDeviation: Double = 0.01,
        minimumAverageSemanticConfidence: ConfidenceScore = ConfidenceScore(clamping: 0.80),
        minimumAverageGeometryConfidence: ConfidenceScore = ConfidenceScore(clamping: 0.80),
        minimumPromotedObjectConfidence: ConfidenceScore = ConfidencePolicy.default.highThreshold,
        minimumMappedObservations: Int = 2,
        minimumAssociationScoreMargin: Double = 0.08,
        maximumCandidateAge: TimeInterval = 5,
        maximumCandidateCount: Int = 64,
        maximumObservationsPerCandidate: Int = 32,
        maximumKnownMapCount: Int = 128
    ) throws {
        let finiteValues = [
            minimumObservationInterval,
            minimumObservationDuration,
            maximumAssociationTimeGap,
            maximumAssociationDistance3D,
            minimumBoundingBoxIoU,
            maximumBoundingBoxCenterDistance,
            maximumMeanSquaredPositionDeviation,
            minimumAssociationScoreMargin,
            maximumCandidateAge,
        ]
        guard minimumDistinctFrames >= 3,
            minimumMappedObservations >= 2,
            finiteValues.allSatisfy(\.isFinite),
            minimumObservationInterval > 0,
            minimumObservationDuration > 0,
            maximumAssociationTimeGap >= minimumObservationInterval,
            maximumAssociationDistance3D > 0,
            (0...1).contains(minimumBoundingBoxIoU),
            maximumBoundingBoxCenterDistance > 0,
            maximumMeanSquaredPositionDeviation >= 0,
            minimumPromotedObjectConfidence >= ConfidencePolicy.default.highThreshold,
            (0...1).contains(minimumAssociationScoreMargin),
            maximumCandidateAge >= minimumObservationDuration,
            maximumCandidateCount > 0,
            maximumObservationsPerCandidate >= minimumDistinctFrames,
            maximumKnownMapCount > 0
        else {
            throw ObjectObservationPromotionError.invalidPolicy
        }
        self.minimumDistinctFrames = minimumDistinctFrames
        self.minimumObservationInterval = minimumObservationInterval
        self.minimumObservationDuration = minimumObservationDuration
        self.maximumAssociationTimeGap = maximumAssociationTimeGap
        self.maximumAssociationDistance3D = maximumAssociationDistance3D
        self.minimumAssociationScore = minimumAssociationScore
        self.minimumBoundingBoxIoU = minimumBoundingBoxIoU
        self.maximumBoundingBoxCenterDistance = maximumBoundingBoxCenterDistance
        self.maximumMeanSquaredPositionDeviation = maximumMeanSquaredPositionDeviation
        self.minimumAverageSemanticConfidence = minimumAverageSemanticConfidence
        self.minimumAverageGeometryConfidence = minimumAverageGeometryConfidence
        self.minimumPromotedObjectConfidence = minimumPromotedObjectConfidence
        self.minimumMappedObservations = minimumMappedObservations
        self.minimumAssociationScoreMargin = minimumAssociationScoreMargin
        self.maximumCandidateAge = maximumCandidateAge
        self.maximumCandidateCount = maximumCandidateCount
        self.maximumObservationsPerCandidate = maximumObservationsPerCandidate
        self.maximumKnownMapCount = maximumKnownMapCount
    }

    public static let `default` = try! Self()

    private enum CodingKeys: String, CodingKey {
        case minimumDistinctFrames
        case minimumObservationInterval
        case minimumObservationDuration
        case maximumAssociationTimeGap
        case maximumAssociationDistance3D
        case minimumAssociationScore
        case minimumBoundingBoxIoU
        case maximumBoundingBoxCenterDistance
        case maximumMeanSquaredPositionDeviation
        case minimumAverageSemanticConfidence
        case minimumAverageGeometryConfidence
        case minimumPromotedObjectConfidence
        case minimumMappedObservations
        case minimumAssociationScoreMargin
        case maximumCandidateAge
        case maximumCandidateCount
        case maximumObservationsPerCandidate
        case maximumKnownMapCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                minimumDistinctFrames: container.decode(
                    Int.self,
                    forKey: .minimumDistinctFrames
                ),
                minimumObservationInterval: container.decode(
                    TimeInterval.self,
                    forKey: .minimumObservationInterval
                ),
                minimumObservationDuration: container.decode(
                    TimeInterval.self,
                    forKey: .minimumObservationDuration
                ),
                maximumAssociationTimeGap: container.decode(
                    TimeInterval.self,
                    forKey: .maximumAssociationTimeGap
                ),
                maximumAssociationDistance3D: container.decode(
                    Double.self,
                    forKey: .maximumAssociationDistance3D
                ),
                minimumAssociationScore: container.decode(
                    ConfidenceScore.self,
                    forKey: .minimumAssociationScore
                ),
                minimumBoundingBoxIoU: container.decode(
                    Double.self,
                    forKey: .minimumBoundingBoxIoU
                ),
                maximumBoundingBoxCenterDistance: container.decode(
                    Double.self,
                    forKey: .maximumBoundingBoxCenterDistance
                ),
                maximumMeanSquaredPositionDeviation: container.decode(
                    Double.self,
                    forKey: .maximumMeanSquaredPositionDeviation
                ),
                minimumAverageSemanticConfidence: container.decode(
                    ConfidenceScore.self,
                    forKey: .minimumAverageSemanticConfidence
                ),
                minimumAverageGeometryConfidence: container.decode(
                    ConfidenceScore.self,
                    forKey: .minimumAverageGeometryConfidence
                ),
                minimumPromotedObjectConfidence: container.decode(
                    ConfidenceScore.self,
                    forKey: .minimumPromotedObjectConfidence
                ),
                minimumMappedObservations: container.decode(
                    Int.self,
                    forKey: .minimumMappedObservations
                ),
                minimumAssociationScoreMargin: container.decode(
                    Double.self,
                    forKey: .minimumAssociationScoreMargin
                ),
                maximumCandidateAge: container.decode(
                    TimeInterval.self,
                    forKey: .maximumCandidateAge
                ),
                maximumCandidateCount: container.decode(
                    Int.self,
                    forKey: .maximumCandidateCount
                ),
                maximumObservationsPerCandidate: container.decode(
                    Int.self,
                    forKey: .maximumObservationsPerCandidate
                ),
                maximumKnownMapCount: container.decode(
                    Int.self,
                    forKey: .maximumKnownMapCount
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .minimumDistinctFrames,
                in: container,
                debugDescription: "Object observation promotion policy is invalid."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(minimumDistinctFrames, forKey: .minimumDistinctFrames)
        try container.encode(minimumObservationInterval, forKey: .minimumObservationInterval)
        try container.encode(minimumObservationDuration, forKey: .minimumObservationDuration)
        try container.encode(maximumAssociationTimeGap, forKey: .maximumAssociationTimeGap)
        try container.encode(maximumAssociationDistance3D, forKey: .maximumAssociationDistance3D)
        try container.encode(minimumAssociationScore, forKey: .minimumAssociationScore)
        try container.encode(minimumBoundingBoxIoU, forKey: .minimumBoundingBoxIoU)
        try container.encode(
            maximumBoundingBoxCenterDistance,
            forKey: .maximumBoundingBoxCenterDistance
        )
        try container.encode(
            maximumMeanSquaredPositionDeviation,
            forKey: .maximumMeanSquaredPositionDeviation
        )
        try container.encode(
            minimumAverageSemanticConfidence,
            forKey: .minimumAverageSemanticConfidence
        )
        try container.encode(
            minimumAverageGeometryConfidence,
            forKey: .minimumAverageGeometryConfidence
        )
        try container.encode(
            minimumPromotedObjectConfidence,
            forKey: .minimumPromotedObjectConfidence
        )
        try container.encode(minimumMappedObservations, forKey: .minimumMappedObservations)
        try container.encode(
            minimumAssociationScoreMargin,
            forKey: .minimumAssociationScoreMargin
        )
        try container.encode(maximumCandidateAge, forKey: .maximumCandidateAge)
        try container.encode(maximumCandidateCount, forKey: .maximumCandidateCount)
        try container.encode(
            maximumObservationsPerCandidate,
            forKey: .maximumObservationsPerCandidate
        )
        try container.encode(maximumKnownMapCount, forKey: .maximumKnownMapCount)
    }
}

/// Observable, ID-free progress for one provisional association candidate.
public struct ObjectObservationPromotionProgress: Codable, Hashable, Sendable {
    /// The first transient observation ID; it is not a durable object ID.
    public let candidateID: ObservationID
    public let distinctFrameCount: Int
    public let temporallyQualifiedFrameCount: Int
    public let observationDuration: TimeInterval
    public let mappedObservationCount: Int
    public let meanSquaredPositionDeviation: Double
    public let averageSemanticConfidence: ConfidenceScore
    public let averageGeometryConfidence: ConfidenceScore
}

/// Result of ingesting one transient observation.
public enum ObjectObservationPromotionOutcome: Codable, Hashable, Sendable {
    case pending(ObjectObservationPromotionProgress)
    case ignoredDuplicateFrame(ObjectObservationPromotionProgress)
    case ignoredDuplicateObservation(ObservationID)
    case ambiguous(candidateIDs: [ObservationID])
    case promoted(SpatialObjectMetadata)
    case alreadyPromoted(SpatialObjectMetadata)
}

/// Stateful, platform-neutral gate that associates repeated observations and
/// creates a permanent `ObjectID` only after every policy requirement passes.
public struct ObjectObservationPromoter: Codable, Sendable {
    private static let stateSchemaVersion = 1

    public let policy: ObjectObservationPromotionPolicy

    private var candidates: [Candidate]
    private var recentObservations: [ObjectPromotionObservation]
    private var registeredMaps: [RegisteredMap]

    public init(policy: ObjectObservationPromotionPolicy = .default) {
        self.policy = policy
        candidates = []
        recentObservations = []
        registeredMaps = []
    }

    /// Number of provisional or already-promoted association clusters retained
    /// by this promoter.
    public var candidateCount: Int {
        candidates.count
    }

    /// Stable transient candidate identifiers in deterministic order. These
    /// identifiers are observation IDs and must not be persisted as objects.
    public var candidateIDs: [ObservationID] {
        candidates.map(\.id).sorted()
    }

    /// Returns the bounded, ordered observations that created a promoted
    /// durable identity. Evidence is unavailable for provisional candidates
    /// and is intended for a second-stage persistent re-identification gate.
    public func promotionEvidence(
        for objectID: ObjectID
    ) -> [ObjectPromotionObservation]? {
        guard
            let candidate = candidates.first(where: {
                $0.promotedMetadata?.object.id == objectID
            })
        else {
            return nil
        }
        return candidate.observations.sorted(by: observationComesBefore)
    }

    /// Removes all transient association state. Call this when the owning
    /// capture lifecycle is discarded.
    public mutating func reset() {
        candidates.removeAll(keepingCapacity: false)
        recentObservations.removeAll(keepingCapacity: false)
        registeredMaps.removeAll(keepingCapacity: false)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case policy
        case candidates
        case recentObservations
        case registeredMaps
    }

    /// Decodes versioned transient state and rejects any state that bypasses
    /// the same frame, map, confidence, or capacity invariants used at runtime.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.stateSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported object promotion state schema."
            )
        }
        policy = try container.decode(
            ObjectObservationPromotionPolicy.self,
            forKey: .policy
        )
        candidates = try container.decode([Candidate].self, forKey: .candidates)
        recentObservations = try container.decode(
            [ObjectPromotionObservation].self,
            forKey: .recentObservations
        )
        registeredMaps = try container.decode(
            [RegisteredMap].self,
            forKey: .registeredMaps
        )
        guard stateIsValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .candidates,
                in: container,
                debugDescription: "Object promotion state violates provenance or capacity rules."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.stateSchemaVersion, forKey: .schemaVersion)
        try container.encode(policy, forKey: .policy)
        try container.encode(candidates, forKey: .candidates)
        try container.encode(recentObservations, forKey: .recentObservations)
        try container.encode(registeredMaps, forKey: .registeredMaps)
    }

    /// Associates and records one observation. Ambiguous and duplicate input
    /// never mutates candidate evidence. Promotion can occur only once for a
    /// candidate; later matches return its existing durable metadata.
    public mutating func ingest(
        _ observation: ObjectPromotionObservation
    ) throws -> ObjectObservationPromotionOutcome {
        // Work on a value copy so rejected map/ID conflicts leave all state
        // unchanged, including deterministic expiry.
        var working = self
        let outcome = try working.ingestValidated(observation)
        self = working
        return outcome
    }

    private mutating func ingestValidated(
        _ observation: ObjectPromotionObservation
    ) throws -> ObjectObservationPromotionOutcome {
        pruneExpiredState(relativeTo: observation.position.observedAt)

        if let existing = recordedObservation(with: observation.observationID) {
            guard existing == observation else {
                throw ObjectObservationPromotionError.conflictingObservationID
            }
            return .ignoredDuplicateObservation(observation.observationID)
        }
        guard !candidates.contains(where: { $0.id == observation.observationID }) else {
            throw ObjectObservationPromotionError.conflictingObservationID
        }

        try registerMapProvenance(from: observation)

        let matches = candidates.indices.compactMap { index -> AssociationMatch? in
            guard
                let score = associationScore(
                    observation,
                    candidate: candidates[index]
                )
            else {
                return nil
            }
            return AssociationMatch(index: index, score: score)
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return candidates[lhs.index].id < candidates[rhs.index].id
        }

        guard let best = matches.first else {
            makeRoomForCandidate()
            let candidate = Candidate(observation: observation)
            candidates.append(candidate)
            recordRecent(observation)
            return .pending(progress(for: candidate))
        }

        if matches.count > 1,
            best.score - matches[1].score < policy.minimumAssociationScoreMargin
        {
            recordRecent(observation)
            return .ambiguous(
                candidateIDs: matches.map { candidates[$0.index].id }.sorted()
            )
        }

        var candidate = candidates[best.index]
        guard !candidate.observations.contains(where: { $0.frameID == observation.frameID }) else {
            recordRecent(observation)
            return .ignoredDuplicateFrame(progress(for: candidate))
        }

        candidate.observations.append(observation)
        if candidate.latchedMapID == nil {
            candidate.latchedMapID = observation.mapID
        }
        trimObservations(in: &candidate)
        if let metadata = candidate.promotedMetadata {
            candidates[best.index] = candidate
            recordRecent(observation)
            return .alreadyPromoted(metadata)
        }

        let outcome: ObjectObservationPromotionOutcome
        if let metadata = try promotedMetadata(for: candidate) {
            candidate.promotedMetadata = metadata
            outcome = .promoted(metadata)
        } else {
            outcome = .pending(progress(for: candidate))
        }
        candidates[best.index] = candidate
        recordRecent(observation)
        return outcome
    }

    private func associationScore(
        _ observation: ObjectPromotionObservation,
        candidate: Candidate
    ) -> Double? {
        guard candidate.semanticKey == semanticKey(observation.semanticLabel),
            candidate.coordinateFrameID == observation.coordinateFrameID,
            candidate.captureSegmentID == observation.captureSegmentID,
            mapsAreCompatible(candidate: candidate, observation: observation)
        else {
            return nil
        }

        let closestTimeGap =
            candidate.observations.map {
                abs($0.position.observedAt - observation.position.observedAt)
            }.min() ?? .infinity
        guard closestTimeGap <= policy.maximumAssociationTimeGap else {
            return nil
        }

        // Once promoted, this remains only a transient association window.
        // Follow its latest observation so sustained motion does not split it
        // merely by moving away from a rolling mean. Durable identity reuse
        // still requires the separate persistent resolver and memory evidence.
        let representativePosition = candidate.promotedMetadata == nil
            ? meanPosition(of: candidate.observations)
            : candidate.observations.last!.position.value
        let distance3D = euclideanDistance(
            representativePosition,
            observation.position.value
        )
        guard distance3D <= policy.maximumAssociationDistance3D else {
            return nil
        }

        let maximumIoU =
            candidate.observations.map {
                $0.boundingBox.intersectionOverUnion(with: observation.boundingBox)
            }.max() ?? 0
        let minimumCenterDistance =
            candidate.observations.map {
                $0.boundingBox.centerDistance(to: observation.boundingBox)
            }.min() ?? .infinity
        guard
            maximumIoU >= policy.minimumBoundingBoxIoU
                || minimumCenterDistance <= policy.maximumBoundingBoxCenterDistance
        else {
            return nil
        }

        let spatialScore =
            1
            - Swift.min(
                1,
                distance3D / policy.maximumAssociationDistance3D
            )
        let centerScore =
            1
            - Swift.min(
                1,
                minimumCenterDistance / policy.maximumBoundingBoxCenterDistance
            )
        let imageScore = Swift.max(maximumIoU, centerScore)
        let candidateTrackIDs = Set(candidate.observations.compactMap(\.trackID))
        let trackScore: Double
        if let trackID = observation.trackID, !candidateTrackIDs.isEmpty {
            trackScore = candidateTrackIDs.contains(trackID) ? 1 : 0
        } else {
            trackScore = 0.5
        }
        let score = spatialScore * 0.55 + imageScore * 0.35 + trackScore * 0.10
        guard score >= policy.minimumAssociationScore.value else {
            return nil
        }
        return score
    }

    private func mapsAreCompatible(
        candidate: Candidate,
        observation: ObjectPromotionObservation
    ) -> Bool {
        guard let mapID = observation.mapID else {
            return true
        }
        return candidate.latchedMapID == nil || candidate.latchedMapID == mapID
    }

    private func promotedMetadata(for candidate: Candidate) throws -> SpatialObjectMetadata? {
        let observations = temporallyQualified(candidate.observations)
        guard observations.count >= policy.minimumDistinctFrames else {
            return nil
        }

        let duration = observationDuration(of: observations)
        let position = meanPosition(of: observations)
        let variance = meanSquaredPositionDeviation(
            observations,
            from: position
        )
        let averageSemantic = averageConfidence(
            observations.map(\.semanticConfidence)
        )
        let averageGeometry = averageConfidence(
            observations.map(\.geometryConfidence)
        )
        let stability = positionStabilityConfidence(for: variance)
        let aggregateConfidence = Swift.min(
            averageSemantic,
            Swift.min(averageGeometry, stability)
        )
        let mapped = latchedMap(in: observations)
        let bounds = conservativeBounds(in: observations)
        guard duration >= policy.minimumObservationDuration,
            variance <= policy.maximumMeanSquaredPositionDeviation,
            averageSemantic >= policy.minimumAverageSemanticConfidence,
            averageGeometry >= policy.minimumAverageGeometryConfidence,
            aggregateConfidence >= policy.minimumPromotedObjectConfidence,
            let mapped,
            mapped.count >= policy.minimumMappedObservations
        else {
            return nil
        }

        let firstSeenAt = candidate.observations.map(\.position.observedAt).min()!
        let lastSeenAt = candidate.observations.map(\.position.observedAt).max()!
        let framedPosition = try FramedPosition(
            coordinateFrameID: candidate.coordinateFrameID,
            value: position,
            observedAt: lastSeenAt,
            trackingQuality: conservativeTrackingQuality(of: observations),
            uncertainty: .unknown
        )
        let confidence = ConfidenceVector(
            semantic: averageSemantic,
            geometry: averageGeometry,
            tracking: averageTrackingConfidence(of: observations),
            identity: aggregateConfidence,
            objectState: aggregateConfidence
        )
        let object = try SpatialObject(
            id: ObjectID(),
            semanticLabel: candidate.semanticLabel,
            position: position,
            bounds: bounds,
            certainty: .confirmed,
            confidence: confidence,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt
        )
        return try SpatialObjectMetadata(
            mapID: mapped.mapID,
            object: object,
            position: framedPosition
        )
    }

    private func conservativeBounds(
        in observations: [ObjectPromotionObservation]
    ) -> AABB? {
        let bounds = observations.compactMap(\.bounds)
        guard bounds.count >= policy.minimumMappedObservations,
            let minimumX = bounds.map(\.min.x).min(),
            let minimumY = bounds.map(\.min.y).min(),
            let minimumZ = bounds.map(\.min.z).min(),
            let maximumX = bounds.map(\.max.x).max(),
            let maximumY = bounds.map(\.max.y).max(),
            let maximumZ = bounds.map(\.max.z).max(),
            let minimum = try? Vec3(x: minimumX, y: minimumY, z: minimumZ),
            let maximum = try? Vec3(x: maximumX, y: maximumY, z: maximumZ)
        else {
            return nil
        }
        return try? AABB(min: minimum, max: maximum)
    }

    private func progress(for candidate: Candidate) -> ObjectObservationPromotionProgress {
        let observations = temporallyQualified(candidate.observations)
        let position = meanPosition(of: observations)
        return ObjectObservationPromotionProgress(
            candidateID: candidate.id,
            distinctFrameCount: candidate.observations.count,
            temporallyQualifiedFrameCount: observations.count,
            observationDuration: observationDuration(of: observations),
            mappedObservationCount: latchedMap(in: observations)?.count ?? 0,
            meanSquaredPositionDeviation: meanSquaredPositionDeviation(
                observations,
                from: position
            ),
            averageSemanticConfidence: averageConfidence(
                observations.map(\.semanticConfidence)
            ),
            averageGeometryConfidence: averageConfidence(
                observations.map(\.geometryConfidence)
            )
        )
    }

    private func temporallyQualified(
        _ observations: [ObjectPromotionObservation]
    ) -> [ObjectPromotionObservation] {
        let sorted = observations.sorted { lhs, rhs in
            if lhs.position.observedAt != rhs.position.observedAt {
                return lhs.position.observedAt < rhs.position.observedAt
            }
            return lhs.frameID < rhs.frameID
        }
        var qualified: [ObjectPromotionObservation] = []
        for observation in sorted {
            guard let last = qualified.last else {
                qualified.append(observation)
                continue
            }
            if observation.position.observedAt - last.position.observedAt
                >= policy.minimumObservationInterval
            {
                qualified.append(observation)
            }
        }
        return qualified
    }

    private func observationDuration(
        of observations: [ObjectPromotionObservation]
    ) -> TimeInterval {
        guard let first = observations.first, let last = observations.last else {
            return 0
        }
        return Swift.max(0, last.position.observedAt - first.position.observedAt)
    }

    private func latchedMap(
        in observations: [ObjectPromotionObservation]
    ) -> (mapID: MapID, count: Int)? {
        let mapped = observations.compactMap(\.mapID)
        guard let mapID = mapped.first,
            mapped.allSatisfy({ $0 == mapID })
        else {
            return nil
        }
        return (mapID, mapped.count)
    }

    private func meanPosition(of observations: [ObjectPromotionObservation]) -> Vec3 {
        guard !observations.isEmpty else {
            return .zero
        }
        let divisor = Double(observations.count)
        let x = observations.reduce(0) { $0 + $1.position.value.x / divisor }
        let y = observations.reduce(0) { $0 + $1.position.value.y / divisor }
        let z = observations.reduce(0) { $0 + $1.position.value.z / divisor }
        return try! Vec3(x: x, y: y, z: z)
    }

    private func meanSquaredPositionDeviation(
        _ observations: [ObjectPromotionObservation],
        from mean: Vec3
    ) -> Double {
        guard !observations.isEmpty else {
            return 0
        }
        return observations.reduce(0) { partial, observation in
            let distance = euclideanDistance(observation.position.value, mean)
            return partial + distance * distance / Double(observations.count)
        }
    }

    private func euclideanDistance(_ lhs: Vec3, _ rhs: Vec3) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        let dz = lhs.z - rhs.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    private func averageConfidence(_ values: [ConfidenceScore]) -> ConfidenceScore {
        guard !values.isEmpty else {
            return .zero
        }
        let divisor = Double(values.count)
        return ConfidenceScore(clamping: values.reduce(0) { $0 + $1.value / divisor })
    }

    private func positionStabilityConfidence(for variance: Double) -> ConfidenceScore {
        guard variance.isFinite else {
            return .zero
        }
        guard policy.maximumMeanSquaredPositionDeviation > 0 else {
            return variance == 0 ? .one : .zero
        }
        return ConfidenceScore(
            clamping: 1 - variance / policy.maximumMeanSquaredPositionDeviation
        )
    }

    private func averageTrackingConfidence(
        of observations: [ObjectPromotionObservation]
    ) -> ConfidenceScore {
        let values = observations.map { observation -> Double in
            switch observation.position.trackingQuality {
            case .unavailable:
                return 0
            case .limited:
                return 0.5
            case .normal:
                return 1
            }
        }
        guard !values.isEmpty else {
            return .zero
        }
        return ConfidenceScore(
            clamping: values.reduce(0, +) / Double(values.count)
        )
    }

    private func conservativeTrackingQuality(
        of observations: [ObjectPromotionObservation]
    ) -> SpatialTrackingQuality {
        if observations.contains(where: { $0.position.trackingQuality == .unavailable }) {
            return .unavailable
        }
        if observations.contains(where: { $0.position.trackingQuality == .limited }) {
            return .limited
        }
        return .normal
    }

    private func semanticKey(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func recordedObservation(
        with observationID: ObservationID
    ) -> ObjectPromotionObservation? {
        for candidate in candidates {
            if let observation = candidate.observations.first(where: {
                $0.observationID == observationID
            }) {
                return observation
            }
        }
        return recentObservations.first(where: { $0.observationID == observationID })
    }

    private mutating func registerMapProvenance(
        from observation: ObjectPromotionObservation
    ) throws {
        guard let mapID = observation.mapID else {
            return
        }
        if let existing = registeredMaps.first(where: { $0.mapID == mapID }) {
            guard existing.coordinateFrameID == observation.coordinateFrameID else {
                throw ObjectObservationPromotionError.mapCoordinateFrameMismatch
            }
            return
        }
        guard registeredMaps.count < policy.maximumKnownMapCount else {
            throw ObjectObservationPromotionError.mapRegistryCapacityExceeded
        }
        registeredMaps.append(
            RegisteredMap(
                mapID: mapID,
                coordinateFrameID: observation.coordinateFrameID
            )
        )
        registeredMaps.sort { $0.mapID < $1.mapID }
    }

    private mutating func pruneExpiredState(relativeTo timestamp: TimeInterval) {
        candidates.removeAll { candidate in
            let age = timestamp - candidate.lastObservedAt
            return age.isFinite && age > policy.maximumCandidateAge
        }
        recentObservations.removeAll { observation in
            let age = timestamp - observation.position.observedAt
            return age.isFinite && age > policy.maximumCandidateAge
        }
    }

    private mutating func makeRoomForCandidate() {
        while candidates.count >= policy.maximumCandidateCount {
            guard
                let evictionIndex = candidates.indices.min(by: { lhs, rhs in
                    let left = candidates[lhs]
                    let right = candidates[rhs]
                    if left.lastObservedAt != right.lastObservedAt {
                        return left.lastObservedAt < right.lastObservedAt
                    }
                    return left.id < right.id
                })
            else {
                return
            }
            candidates.remove(at: evictionIndex)
        }
    }

    private func trimObservations(in candidate: inout Candidate) {
        candidate.observations.sort(by: observationComesBefore)
        let overflow =
            candidate.observations.count
            - policy.maximumObservationsPerCandidate
        if overflow > 0 {
            candidate.observations.removeFirst(overflow)
        }
    }

    private mutating func recordRecent(_ observation: ObjectPromotionObservation) {
        recentObservations.append(observation)
        recentObservations.sort { lhs, rhs in
            if lhs.position.observedAt != rhs.position.observedAt {
                return lhs.position.observedAt > rhs.position.observedAt
            }
            return lhs.observationID < rhs.observationID
        }
        let overflow = recentObservations.count - recentObservationCapacity
        if overflow > 0 {
            recentObservations.removeLast(overflow)
        }
    }

    private var recentObservationCapacity: Int {
        let product = policy.maximumCandidateCount.multipliedReportingOverflow(
            by: policy.maximumObservationsPerCandidate
        )
        return product.overflow ? Int.max : Swift.max(1, product.partialValue)
    }

    private func observationComesBefore(
        _ lhs: ObjectPromotionObservation,
        _ rhs: ObjectPromotionObservation
    ) -> Bool {
        if lhs.position.observedAt != rhs.position.observedAt {
            return lhs.position.observedAt < rhs.position.observedAt
        }
        if lhs.frameID != rhs.frameID {
            return lhs.frameID < rhs.frameID
        }
        return lhs.observationID < rhs.observationID
    }

    private var stateIsValid: Bool {
        guard candidates.count <= policy.maximumCandidateCount,
            recentObservations.count <= recentObservationCapacity,
            registeredMaps.count <= policy.maximumKnownMapCount,
            Set(candidates.map(\.id)).count == candidates.count,
            Set(recentObservations.map(\.observationID)).count
                == recentObservations.count,
            Set(registeredMaps.map(\.mapID)).count == registeredMaps.count
        else {
            return false
        }

        let mapFrames = Dictionary(
            uniqueKeysWithValues: registeredMaps.map {
                ($0.mapID, $0.coordinateFrameID)
            }
        )
        var observationIDs = Set<ObservationID>()
        var promotedObjectIDs = Set<ObjectID>()
        for candidate in candidates {
            guard !candidate.observations.isEmpty,
                candidate.observations.count <= policy.maximumObservationsPerCandidate,
                candidate.semanticKey == semanticKey(candidate.semanticLabel),
                Set(candidate.observations.map(\.frameID)).count
                    == candidate.observations.count
            else {
                return false
            }

            let candidateMapIDs = Set(candidate.observations.compactMap(\.mapID))
            guard candidateMapIDs.count <= 1,
                candidateMapIDs.isEmpty
                    || candidateMapIDs == Set([candidate.latchedMapID].compactMap { $0 }),
                candidate.latchedMapID != nil || candidateMapIDs.isEmpty
            else {
                return false
            }
            for observation in candidate.observations {
                guard observationIDs.insert(observation.observationID).inserted,
                    semanticKey(observation.semanticLabel) == candidate.semanticKey,
                    observation.coordinateFrameID == candidate.coordinateFrameID,
                    observation.captureSegmentID == candidate.captureSegmentID
                else {
                    return false
                }
                if let mapID = observation.mapID,
                    mapFrames[mapID] != observation.coordinateFrameID
                {
                    return false
                }
            }

            if let metadata = candidate.promotedMetadata {
                guard promotedObjectIDs.insert(metadata.object.id).inserted,
                    metadata.object.certainty == .confirmed,
                    metadata.position.coordinateFrameID == candidate.coordinateFrameID,
                    metadata.object.lastSeenAt == metadata.position.observedAt,
                    metadata.object.confidence.identity
                        >= ConfidencePolicy.default.highThreshold,
                    metadata.object.confidence.objectState
                        >= ConfidencePolicy.default.highThreshold,
                    mapFrames[metadata.mapID] == candidate.coordinateFrameID,
                    candidate.latchedMapID == metadata.mapID
                else {
                    return false
                }
            }
        }
        for observation in recentObservations {
            if let mapID = observation.mapID,
                mapFrames[mapID] != observation.coordinateFrameID
            {
                return false
            }
            if let candidateObservation = candidates.lazy.compactMap({ candidate in
                candidate.observations.first(where: {
                    $0.observationID == observation.observationID
                })
            }).first,
                candidateObservation != observation
            {
                return false
            }
        }
        return true
    }

    private struct AssociationMatch: Sendable {
        let index: Int
        let score: Double
    }

    private struct Candidate: Codable, Sendable {
        let id: ObservationID
        let semanticLabel: String
        let semanticKey: String
        let coordinateFrameID: CoordinateFrameID
        let captureSegmentID: CaptureSegmentID
        var latchedMapID: MapID?
        var observations: [ObjectPromotionObservation]
        var promotedMetadata: SpatialObjectMetadata?

        var lastObservedAt: TimeInterval {
            observations.map(\.position.observedAt).max() ?? 0
        }

        init(observation: ObjectPromotionObservation) {
            id = observation.observationID
            semanticLabel = observation.semanticLabel
            semanticKey = observation.semanticLabel.lowercased()
            coordinateFrameID = observation.coordinateFrameID
            captureSegmentID = observation.captureSegmentID
            latchedMapID = observation.mapID
            observations = [observation]
            promotedMetadata = nil
        }
    }

    private struct RegisteredMap: Codable, Sendable {
        let mapID: MapID
        let coordinateFrameID: CoordinateFrameID
    }
}
