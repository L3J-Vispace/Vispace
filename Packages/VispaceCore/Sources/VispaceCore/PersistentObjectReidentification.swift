import Foundation

public enum PersistentObjectReidentificationError: Error, Equatable, Sendable {
    case invalidPolicy
    case tooFewPromotionObservations(minimum: Int)
    case tooManyPromotionObservations(maximum: Int)
    case duplicatePromotionObservationID(ObservationID)
    case duplicatePromotionFrameID(FrameID)
    case promotionObservationIsUnmapped(ObservationID)
    case inconsistentPromotionSemanticClass
    case inconsistentPromotionMap
    case inconsistentPromotionCoordinateFrame
    case inconsistentPromotionCaptureSegment
    case insufficientPromotionDuration(minimum: TimeInterval)
    case insufficientPromotionConfidence
    case insufficientPromotionTrackingQuality(ObservationID)
    case promotedObjectIsNotConfirmed
    case insufficientPromotedObjectConfidence
    case promotionMetadataMismatch
    case tooManySpatialContextFeatures(maximum: Int)
    case duplicateSpatialContextFeature
    case selfReferentialSpatialContext
    case tooManyCandidateContexts(maximum: Int)
    case duplicateCandidateContext(ObjectID)
    case incomingObjectUsedAsCandidateContext
    case contextProvenanceMismatch(ObjectID)
    case tooManyVisualEvidenceItems(maximum: Int)
    case duplicateVisualEvidence(ObjectID)
    case incomingObjectUsedAsVisualEvidence
    case tooManyExistingObjects(maximum: Int)
    case duplicateExistingObject(ObjectID)
    case incomingObjectAlreadyExists(ObjectID)
    case candidateMapMismatch(ObjectID)
    case candidateCoordinateFrameMismatch(ObjectID)
    case candidateIsNotConfirmed(ObjectID)
    case insufficientCandidateConfidence(ObjectID)
    case unknownCandidateContext(ObjectID)
    case unknownVisualEvidence(ObjectID)
    case invalidCandidateEvaluation
}

/// A bounded, validated copy of the observations that produced one durable
/// object candidate. A count supplied by a caller is never accepted as proof:
/// the actual observation and frame identifiers must both be distinct.
public struct ObjectReidentificationPromotionEvidence: Codable, Hashable, Sendable {
    public static let minimumDistinctObservationCount = 3
    public static let minimumObservationDuration: TimeInterval = 0.30
    public static let maximumObservationCount = 32

    public let observations: [ObjectPromotionObservation]

    public init(observations: [ObjectPromotionObservation]) throws {
        guard observations.count >= Self.minimumDistinctObservationCount else {
            throw PersistentObjectReidentificationError.tooFewPromotionObservations(
                minimum: Self.minimumDistinctObservationCount
            )
        }
        guard observations.count <= Self.maximumObservationCount else {
            throw PersistentObjectReidentificationError.tooManyPromotionObservations(
                maximum: Self.maximumObservationCount
            )
        }

        var observationIDs = Set<ObservationID>()
        var frameIDs = Set<FrameID>()
        for observation in observations {
            guard observationIDs.insert(observation.observationID).inserted else {
                throw
                    PersistentObjectReidentificationError
                    .duplicatePromotionObservationID(observation.observationID)
            }
            guard frameIDs.insert(observation.frameID).inserted else {
                throw
                    PersistentObjectReidentificationError
                    .duplicatePromotionFrameID(observation.frameID)
            }
            guard observation.mapID != nil else {
                throw
                    PersistentObjectReidentificationError
                    .promotionObservationIsUnmapped(observation.observationID)
            }
            guard observation.position.trackingQuality == .normal else {
                throw
                    PersistentObjectReidentificationError
                    .insufficientPromotionTrackingQuality(observation.observationID)
            }
        }

        guard Set(observations.map(\.semanticLabel)).count == 1 else {
            throw PersistentObjectReidentificationError.inconsistentPromotionSemanticClass
        }
        guard Set(observations.compactMap(\.mapID)).count == 1 else {
            throw PersistentObjectReidentificationError.inconsistentPromotionMap
        }
        guard Set(observations.map(\.coordinateFrameID)).count == 1 else {
            throw PersistentObjectReidentificationError
                .inconsistentPromotionCoordinateFrame
        }
        guard Set(observations.map(\.captureSegmentID)).count == 1 else {
            throw PersistentObjectReidentificationError.inconsistentPromotionCaptureSegment
        }

        let ordered = observations.sorted(by: Self.observationOrder)
        let duration = ordered.last!.position.observedAt - ordered.first!.position.observedAt
        guard duration >= Self.minimumObservationDuration else {
            throw PersistentObjectReidentificationError.insufficientPromotionDuration(
                minimum: Self.minimumObservationDuration
            )
        }

        let divisor = Double(ordered.count)
        let averageSemantic = ordered.reduce(0) { $0 + $1.semanticConfidence.value } / divisor
        let averageGeometry = ordered.reduce(0) { $0 + $1.geometryConfidence.value } / divisor
        let highThreshold = ConfidencePolicy.default.highThreshold.value
        guard averageSemantic >= highThreshold, averageGeometry >= highThreshold else {
            throw PersistentObjectReidentificationError.insufficientPromotionConfidence
        }

        self.observations = ordered
    }

    public var observationIDs: [ObservationID] {
        observations.map(\.observationID)
    }

    public var frameIDs: [FrameID] {
        observations.map(\.frameID)
    }

    public var semanticLabel: String {
        observations[0].semanticLabel
    }

    public var mapID: MapID {
        observations[0].mapID!
    }

    public var coordinateFrameID: CoordinateFrameID {
        observations[0].coordinateFrameID
    }

    public var captureSegmentID: CaptureSegmentID {
        observations[0].captureSegmentID
    }

    public var firstObservedAt: TimeInterval {
        observations[0].position.observedAt
    }

    public var lastObservedAt: TimeInterval {
        observations[observations.count - 1].position.observedAt
    }

    private static let schemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case observations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported object re-identification evidence schema."
            )
        }
        do {
            try self.init(
                observations: container.decode(
                    [ObjectPromotionObservation].self,
                    forKey: .observations
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .observations,
                in: container,
                debugDescription: "Promotion evidence violates identity or provenance rules."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(observations, forKey: .observations)
    }

    private static func observationOrder(
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
}

/// One stable scene-graph fact surrounding an object. The reference must be a
/// different entity; self-relations are not independent identity evidence.
public struct ObjectReidentificationSpatialFeature: Codable, Hashable, Comparable, Sendable {
    public let predicate: SpatialRelationPredicate
    public let reference: SceneEntityID

    public init(predicate: SpatialRelationPredicate, reference: SceneEntityID) {
        self.predicate = predicate
        self.reference = reference
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.predicate.rawValue != rhs.predicate.rawValue {
            return lhs.predicate.rawValue < rhs.predicate.rawValue
        }
        return lhs.reference < rhs.reference
    }
}

/// Bounded spatial context derived from a scene graph in one map coordinate
/// frame. It intentionally stores facts rather than a caller-computed score.
public struct ObjectReidentificationSpatialContext: Codable, Hashable, Sendable {
    public static let maximumFeatureCount = 64

    public let objectID: ObjectID
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let features: [ObjectReidentificationSpatialFeature]

    public init(
        objectID: ObjectID,
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        features: [ObjectReidentificationSpatialFeature]
    ) throws {
        guard features.count <= Self.maximumFeatureCount else {
            throw PersistentObjectReidentificationError.tooManySpatialContextFeatures(
                maximum: Self.maximumFeatureCount
            )
        }
        guard Set(features).count == features.count else {
            throw PersistentObjectReidentificationError.duplicateSpatialContextFeature
        }
        guard !features.contains(where: { $0.reference == .object(objectID) }) else {
            throw PersistentObjectReidentificationError.selfReferentialSpatialContext
        }
        self.objectID = objectID
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        self.features = features.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case objectID
        case mapID
        case coordinateFrameID
        case features
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                objectID: container.decode(ObjectID.self, forKey: .objectID),
                mapID: container.decode(MapID.self, forKey: .mapID),
                coordinateFrameID: container.decode(
                    CoordinateFrameID.self,
                    forKey: .coordinateFrameID
                ),
                features: container.decode(
                    [ObjectReidentificationSpatialFeature].self,
                    forKey: .features
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .features,
                in: container,
                debugDescription: "Spatial context is unbounded, duplicated, or self-referential."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(objectID, forKey: .objectID)
        try container.encode(mapID, forKey: .mapID)
        try container.encode(coordinateFrameID, forKey: .coordinateFrameID)
        try container.encode(features, forKey: .features)
    }
}

/// Optional, candidate-specific output of an image embedding or appearance
/// matcher. It can improve ranking but can never replace geometry or context.
public struct ObjectReidentificationVisualEvidence: Codable, Hashable, Sendable {
    public let objectID: ObjectID
    public let similarity: ConfidenceScore

    public init(objectID: ObjectID, similarity: ConfidenceScore) {
        self.objectID = objectID
        self.similarity = similarity
    }
}

/// A complete request for resolving one just-promoted object. Construction
/// binds the multi-frame evidence and incoming spatial context to the durable
/// metadata before any existing object is considered.
public struct PersistentObjectReidentificationRequest: Codable, Hashable, Sendable {
    public static let maximumCandidateEvidenceCount = 256

    public let promotedObject: SpatialObjectMetadata
    public let promotionEvidence: ObjectReidentificationPromotionEvidence
    public let incomingContext: ObjectReidentificationSpatialContext
    public let candidateContexts: [ObjectReidentificationSpatialContext]
    public let visualEvidence: [ObjectReidentificationVisualEvidence]

    public init(
        promotedObject: SpatialObjectMetadata,
        promotionEvidence: ObjectReidentificationPromotionEvidence,
        incomingContext: ObjectReidentificationSpatialContext,
        candidateContexts: [ObjectReidentificationSpatialContext] = [],
        visualEvidence: [ObjectReidentificationVisualEvidence] = []
    ) throws {
        guard promotedObject.object.certainty == .confirmed else {
            throw PersistentObjectReidentificationError.promotedObjectIsNotConfirmed
        }
        guard Self.hasHighPersistentConfidence(promotedObject.object) else {
            throw PersistentObjectReidentificationError
                .insufficientPromotedObjectConfidence
        }
        guard promotionEvidence.semanticLabel == promotedObject.object.semanticLabel,
            promotionEvidence.mapID == promotedObject.mapID,
            promotionEvidence.coordinateFrameID
                == promotedObject.position.coordinateFrameID,
            promotionEvidence.firstObservedAt == promotedObject.object.firstSeenAt,
            promotionEvidence.lastObservedAt == promotedObject.object.lastSeenAt,
            promotionEvidence.lastObservedAt == promotedObject.position.observedAt
        else {
            throw PersistentObjectReidentificationError.promotionMetadataMismatch
        }
        guard incomingContext.objectID == promotedObject.object.id,
            incomingContext.mapID == promotedObject.mapID,
            incomingContext.coordinateFrameID
                == promotedObject.position.coordinateFrameID
        else {
            throw
                PersistentObjectReidentificationError
                .contextProvenanceMismatch(incomingContext.objectID)
        }
        guard candidateContexts.count <= Self.maximumCandidateEvidenceCount else {
            throw PersistentObjectReidentificationError.tooManyCandidateContexts(
                maximum: Self.maximumCandidateEvidenceCount
            )
        }
        guard visualEvidence.count <= Self.maximumCandidateEvidenceCount else {
            throw PersistentObjectReidentificationError.tooManyVisualEvidenceItems(
                maximum: Self.maximumCandidateEvidenceCount
            )
        }

        var contextIDs = Set<ObjectID>()
        for context in candidateContexts {
            guard context.objectID != promotedObject.object.id else {
                throw PersistentObjectReidentificationError
                    .incomingObjectUsedAsCandidateContext
            }
            guard contextIDs.insert(context.objectID).inserted else {
                throw
                    PersistentObjectReidentificationError
                    .duplicateCandidateContext(context.objectID)
            }
            guard context.mapID == promotedObject.mapID,
                context.coordinateFrameID == promotedObject.position.coordinateFrameID
            else {
                throw
                    PersistentObjectReidentificationError
                    .contextProvenanceMismatch(context.objectID)
            }
        }

        var visualIDs = Set<ObjectID>()
        for item in visualEvidence {
            guard item.objectID != promotedObject.object.id else {
                throw PersistentObjectReidentificationError
                    .incomingObjectUsedAsVisualEvidence
            }
            guard visualIDs.insert(item.objectID).inserted else {
                throw
                    PersistentObjectReidentificationError
                    .duplicateVisualEvidence(item.objectID)
            }
        }

        self.promotedObject = promotedObject
        self.promotionEvidence = promotionEvidence
        self.incomingContext = incomingContext
        self.candidateContexts = candidateContexts.sorted { $0.objectID < $1.objectID }
        self.visualEvidence = visualEvidence.sorted { $0.objectID < $1.objectID }
    }

    private enum CodingKeys: String, CodingKey {
        case promotedObject
        case promotionEvidence
        case incomingContext
        case candidateContexts
        case visualEvidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                promotedObject: container.decode(
                    SpatialObjectMetadata.self,
                    forKey: .promotedObject
                ),
                promotionEvidence: container.decode(
                    ObjectReidentificationPromotionEvidence.self,
                    forKey: .promotionEvidence
                ),
                incomingContext: container.decode(
                    ObjectReidentificationSpatialContext.self,
                    forKey: .incomingContext
                ),
                candidateContexts: container.decode(
                    [ObjectReidentificationSpatialContext].self,
                    forKey: .candidateContexts
                ),
                visualEvidence: container.decode(
                    [ObjectReidentificationVisualEvidence].self,
                    forKey: .visualEvidence
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .promotedObject,
                in: container,
                debugDescription: "Re-identification request violates promotion or provenance rules."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(promotedObject, forKey: .promotedObject)
        try container.encode(promotionEvidence, forKey: .promotionEvidence)
        try container.encode(incomingContext, forKey: .incomingContext)
        try container.encode(candidateContexts, forKey: .candidateContexts)
        try container.encode(visualEvidence, forKey: .visualEvidence)
    }

    fileprivate static func hasHighPersistentConfidence(_ object: SpatialObject) -> Bool {
        let policy = ConfidencePolicy.default
        return policy.grade(for: object.confidence.semantic) == .high
            && policy.grade(for: object.confidence.geometry) == .high
            && policy.grade(for: object.confidence.identity) == .high
            && policy.grade(for: object.confidence.objectState) == .high
    }
}

public struct PersistentObjectReidentificationPolicy: Codable, Hashable, Sendable {
    public let maximumPositionDistance: Double
    public let minimumCandidateGeometryScore: ConfidenceScore
    public let minimumConfirmationGeometryScore: ConfidenceScore
    public let minimumConfirmationSpatialContextScore: ConfidenceScore
    public let confirmationThreshold: ConfidenceScore
    public let ambiguityMargin: ConfidenceScore
    public let geometryWeight: Double
    public let spatialContextWeight: Double
    public let visualWeight: Double
    public let maximumCandidateCount: Int

    public init(
        maximumPositionDistance: Double = 0.75,
        minimumCandidateGeometryScore: ConfidenceScore = ConfidenceScore(clamping: 0.25),
        minimumConfirmationGeometryScore: ConfidenceScore = ConfidencePolicy.default.highThreshold,
        minimumConfirmationSpatialContextScore: ConfidenceScore = ConfidencePolicy.default.highThreshold,
        confirmationThreshold: ConfidenceScore = ConfidencePolicy.default.highThreshold,
        ambiguityMargin: ConfidenceScore = ConfidenceScore(clamping: 0.10),
        geometryWeight: Double = 0.45,
        spatialContextWeight: Double = 0.45,
        visualWeight: Double = 0.10,
        maximumCandidateCount: Int = 128
    ) throws {
        let confidencePolicy = ConfidencePolicy.default
        let weights = [geometryWeight, spatialContextWeight, visualWeight]
        let weightTotal = weights.reduce(0, +)
        guard maximumPositionDistance.isFinite,
            maximumPositionDistance > 0,
            minimumCandidateGeometryScore < minimumConfirmationGeometryScore,
            confidencePolicy.grade(for: minimumConfirmationGeometryScore) == .high,
            confidencePolicy.grade(for: minimumConfirmationSpatialContextScore) == .high,
            confidencePolicy.grade(for: confirmationThreshold) == .high,
            weights.allSatisfy({ $0.isFinite && $0 >= 0 }),
            geometryWeight > 0,
            spatialContextWeight > 0,
            weightTotal.isFinite,
            weightTotal > 0,
            maximumCandidateCount > 0,
            maximumCandidateCount
                <= PersistentObjectReidentificationRequest
                .maximumCandidateEvidenceCount
        else {
            throw PersistentObjectReidentificationError.invalidPolicy
        }
        self.maximumPositionDistance = maximumPositionDistance
        self.minimumCandidateGeometryScore = minimumCandidateGeometryScore
        self.minimumConfirmationGeometryScore = minimumConfirmationGeometryScore
        self.minimumConfirmationSpatialContextScore = minimumConfirmationSpatialContextScore
        self.confirmationThreshold = confirmationThreshold
        self.ambiguityMargin = ambiguityMargin
        self.geometryWeight = geometryWeight
        self.spatialContextWeight = spatialContextWeight
        self.visualWeight = visualWeight
        self.maximumCandidateCount = maximumCandidateCount
    }

    public static let `default` = try! Self()

    private enum CodingKeys: String, CodingKey {
        case maximumPositionDistance
        case minimumCandidateGeometryScore
        case minimumConfirmationGeometryScore
        case minimumConfirmationSpatialContextScore
        case confirmationThreshold
        case ambiguityMargin
        case geometryWeight
        case spatialContextWeight
        case visualWeight
        case maximumCandidateCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                maximumPositionDistance: container.decode(
                    Double.self,
                    forKey: .maximumPositionDistance
                ),
                minimumCandidateGeometryScore: container.decode(
                    ConfidenceScore.self,
                    forKey: .minimumCandidateGeometryScore
                ),
                minimumConfirmationGeometryScore: container.decode(
                    ConfidenceScore.self,
                    forKey: .minimumConfirmationGeometryScore
                ),
                minimumConfirmationSpatialContextScore: container.decode(
                    ConfidenceScore.self,
                    forKey: .minimumConfirmationSpatialContextScore
                ),
                confirmationThreshold: container.decode(
                    ConfidenceScore.self,
                    forKey: .confirmationThreshold
                ),
                ambiguityMargin: container.decode(
                    ConfidenceScore.self,
                    forKey: .ambiguityMargin
                ),
                geometryWeight: container.decode(Double.self, forKey: .geometryWeight),
                spatialContextWeight: container.decode(
                    Double.self,
                    forKey: .spatialContextWeight
                ),
                visualWeight: container.decode(Double.self, forKey: .visualWeight),
                maximumCandidateCount: container.decode(
                    Int.self,
                    forKey: .maximumCandidateCount
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .maximumPositionDistance,
                in: container,
                debugDescription: "Persistent object re-identification policy is invalid."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maximumPositionDistance, forKey: .maximumPositionDistance)
        try container.encode(
            minimumCandidateGeometryScore,
            forKey: .minimumCandidateGeometryScore
        )
        try container.encode(
            minimumConfirmationGeometryScore,
            forKey: .minimumConfirmationGeometryScore
        )
        try container.encode(
            minimumConfirmationSpatialContextScore,
            forKey: .minimumConfirmationSpatialContextScore
        )
        try container.encode(confirmationThreshold, forKey: .confirmationThreshold)
        try container.encode(ambiguityMargin, forKey: .ambiguityMargin)
        try container.encode(geometryWeight, forKey: .geometryWeight)
        try container.encode(spatialContextWeight, forKey: .spatialContextWeight)
        try container.encode(visualWeight, forKey: .visualWeight)
        try container.encode(maximumCandidateCount, forKey: .maximumCandidateCount)
    }
}

public struct PersistentObjectReidentificationCandidate: Codable, Hashable, Sendable {
    public let objectID: ObjectID
    public let score: ConfidenceScore
    public let geometryScore: ConfidenceScore
    public let spatialContextScore: ConfidenceScore?
    public let visualSimilarity: ConfidenceScore?
    public let positionDistance: Double

    public init(
        objectID: ObjectID,
        score: ConfidenceScore,
        geometryScore: ConfidenceScore,
        spatialContextScore: ConfidenceScore?,
        visualSimilarity: ConfidenceScore?,
        positionDistance: Double
    ) throws {
        guard positionDistance.isFinite, positionDistance >= 0 else {
            throw PersistentObjectReidentificationError.invalidCandidateEvaluation
        }
        self.objectID = objectID
        self.score = score
        self.geometryScore = geometryScore
        self.spatialContextScore = spatialContextScore
        self.visualSimilarity = visualSimilarity
        self.positionDistance = positionDistance
    }

    private enum CodingKeys: String, CodingKey {
        case objectID
        case score
        case geometryScore
        case spatialContextScore
        case visualSimilarity
        case positionDistance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                objectID: container.decode(ObjectID.self, forKey: .objectID),
                score: container.decode(ConfidenceScore.self, forKey: .score),
                geometryScore: container.decode(
                    ConfidenceScore.self,
                    forKey: .geometryScore
                ),
                spatialContextScore: container.decodeIfPresent(
                    ConfidenceScore.self,
                    forKey: .spatialContextScore
                ),
                visualSimilarity: container.decodeIfPresent(
                    ConfidenceScore.self,
                    forKey: .visualSimilarity
                ),
                positionDistance: container.decode(
                    Double.self,
                    forKey: .positionDistance
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .positionDistance,
                in: container,
                debugDescription: "Candidate distance must be finite and nonnegative."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(objectID, forKey: .objectID)
        try container.encode(score, forKey: .score)
        try container.encode(geometryScore, forKey: .geometryScore)
        try container.encodeIfPresent(spatialContextScore, forKey: .spatialContextScore)
        try container.encodeIfPresent(visualSimilarity, forKey: .visualSimilarity)
        try container.encode(positionDistance, forKey: .positionDistance)
    }
}

public enum PersistentObjectReidentificationDecision: Codable, Hashable, Sendable {
    case confirmedExisting(PersistentObjectReidentificationCandidate)
    case ambiguousCandidates([PersistentObjectReidentificationCandidate])
    case genuinelyNew
}

/// Stateless deterministic matcher for persistent objects inside one map.
/// Semantic equality and 3D proximity produce candidates; only high geometry,
/// high scene context, a high aggregate, and a clear ranking margin can reuse
/// an existing permanent identity.
public struct PersistentObjectReidentificationResolver: Sendable {
    public let policy: PersistentObjectReidentificationPolicy

    public init(policy: PersistentObjectReidentificationPolicy = .default) {
        self.policy = policy
    }

    public func resolve(
        _ request: PersistentObjectReidentificationRequest,
        against existingObjects: [SpatialObjectMetadata]
    ) throws -> PersistentObjectReidentificationDecision {
        guard existingObjects.count <= policy.maximumCandidateCount else {
            throw PersistentObjectReidentificationError.tooManyExistingObjects(
                maximum: policy.maximumCandidateCount
            )
        }

        var existingByID: [ObjectID: SpatialObjectMetadata] = [:]
        for candidate in existingObjects {
            let objectID = candidate.object.id
            guard existingByID.updateValue(candidate, forKey: objectID) == nil else {
                throw
                    PersistentObjectReidentificationError
                    .duplicateExistingObject(objectID)
            }
            guard objectID != request.promotedObject.object.id else {
                throw
                    PersistentObjectReidentificationError
                    .incomingObjectAlreadyExists(objectID)
            }
            guard candidate.mapID == request.promotedObject.mapID else {
                throw PersistentObjectReidentificationError.candidateMapMismatch(objectID)
            }
            guard
                candidate.position.coordinateFrameID
                    == request.promotedObject.position.coordinateFrameID
            else {
                throw
                    PersistentObjectReidentificationError
                    .candidateCoordinateFrameMismatch(objectID)
            }
            guard candidate.object.certainty == .confirmed else {
                throw
                    PersistentObjectReidentificationError
                    .candidateIsNotConfirmed(objectID)
            }
            guard
                PersistentObjectReidentificationRequest
                    .hasHighPersistentConfidence(candidate.object)
            else {
                throw
                    PersistentObjectReidentificationError
                    .insufficientCandidateConfidence(objectID)
            }
        }

        let contextByID = Dictionary(
            uniqueKeysWithValues: request.candidateContexts.map { ($0.objectID, $0) }
        )
        for objectID in contextByID.keys where existingByID[objectID] == nil {
            throw PersistentObjectReidentificationError.unknownCandidateContext(objectID)
        }
        let visualByID = Dictionary(
            uniqueKeysWithValues: request.visualEvidence.map { ($0.objectID, $0.similarity) }
        )
        for objectID in visualByID.keys where existingByID[objectID] == nil {
            throw PersistentObjectReidentificationError.unknownVisualEvidence(objectID)
        }

        var candidates: [PersistentObjectReidentificationCandidate] = []
        for metadata in existingObjects where metadata.object.presence != .removed {
            guard
                metadata.object.semanticLabel
                    == request.promotedObject.object.semanticLabel
            else {
                continue
            }

            let distance = Self.safeDistance(
                request.promotedObject.position.value,
                metadata.position.value
            )
            guard distance.isFinite, distance <= policy.maximumPositionDistance else {
                continue
            }
            let geometry = geometryScore(
                incoming: request.promotedObject.object,
                candidate: metadata.object,
                positionDistance: distance
            )
            guard geometry >= policy.minimumCandidateGeometryScore else {
                continue
            }

            let context = contextByID[metadata.object.id].flatMap {
                spatialContextScore(
                    incoming: request.incomingContext,
                    candidate: $0
                )
            }
            let visual = visualByID[metadata.object.id]
            let aggregate = aggregateScore(
                geometry: geometry,
                spatialContext: context,
                visual: visual
            )
            candidates.append(
                try PersistentObjectReidentificationCandidate(
                    objectID: metadata.object.id,
                    score: aggregate,
                    geometryScore: geometry,
                    spatialContextScore: context,
                    visualSimilarity: visual,
                    positionDistance: distance
                )
            )
        }

        candidates.sort(by: Self.candidateOrder)
        guard let best = candidates.first else {
            return .genuinelyNew
        }

        let clearsAmbiguityMargin: Bool
        if candidates.count > 1 {
            clearsAmbiguityMargin =
                best.score.value - candidates[1].score.value
                >= policy.ambiguityMargin.value
        } else {
            clearsAmbiguityMargin = true
        }

        if best.geometryScore >= policy.minimumConfirmationGeometryScore,
            let spatialContextScore = best.spatialContextScore,
            spatialContextScore >= policy.minimumConfirmationSpatialContextScore,
            best.score >= policy.confirmationThreshold,
            clearsAmbiguityMargin
        {
            return .confirmedExisting(best)
        }
        return .ambiguousCandidates(candidates)
    }

    private func geometryScore(
        incoming: SpatialObject,
        candidate: SpatialObject,
        positionDistance: Double
    ) -> ConfidenceScore {
        let positionScore = ConfidenceScore(
            clamping: 1 - positionDistance / policy.maximumPositionDistance
        )
        guard let incomingBounds = incoming.bounds,
            let candidateBounds = candidate.bounds
        else {
            return positionScore
        }
        let sizeScore = Self.sizeSimilarity(incomingBounds, candidateBounds)
        return ConfidenceScore(
            clamping: positionScore.value * 0.70 + sizeScore.value * 0.30
        )
    }

    private func spatialContextScore(
        incoming: ObjectReidentificationSpatialContext,
        candidate: ObjectReidentificationSpatialContext
    ) -> ConfidenceScore? {
        let incomingFeatures = Set(incoming.features)
        let candidateFeatures = Set(candidate.features)
        guard !incomingFeatures.isEmpty, !candidateFeatures.isEmpty else {
            return nil
        }
        let intersection = incomingFeatures.intersection(candidateFeatures).count
        let union = incomingFeatures.union(candidateFeatures).count
        return ConfidenceScore(clamping: Double(intersection) / Double(union))
    }

    private func aggregateScore(
        geometry: ConfidenceScore,
        spatialContext: ConfidenceScore?,
        visual: ConfidenceScore?
    ) -> ConfidenceScore {
        var weighted = geometry.value * policy.geometryWeight
        weighted += (spatialContext?.value ?? 0) * policy.spatialContextWeight
        var weight = policy.geometryWeight + policy.spatialContextWeight
        if let visual, policy.visualWeight > 0 {
            weighted += visual.value * policy.visualWeight
            weight += policy.visualWeight
        }
        return ConfidenceScore(clamping: weighted / weight)
    }

    private static func safeDistance(_ lhs: Vec3, _ rhs: Vec3) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        let dz = lhs.z - rhs.z
        guard dx.isFinite, dy.isFinite, dz.isFinite else {
            return .infinity
        }
        return hypot(hypot(dx, dy), dz)
    }

    private static func sizeSimilarity(_ lhs: AABB, _ rhs: AABB) -> ConfidenceScore {
        let left = dimensions(of: lhs)
        let right = dimensions(of: rhs)
        guard left.allSatisfy(\.isFinite), right.allSatisfy(\.isFinite) else {
            return .zero
        }
        let similarities = zip(left, right).map { leftValue, rightValue -> Double in
            let maximum = Swift.max(leftValue, rightValue)
            if maximum == 0 {
                return 1
            }
            return Swift.min(leftValue, rightValue) / maximum
        }
        return ConfidenceScore(
            clamping: similarities.reduce(0, +) / Double(similarities.count)
        )
    }

    private static func dimensions(of bounds: AABB) -> [Double] {
        [
            bounds.max.x - bounds.min.x,
            bounds.max.y - bounds.min.y,
            bounds.max.z - bounds.min.z,
        ]
    }

    private static func candidateOrder(
        _ lhs: PersistentObjectReidentificationCandidate,
        _ rhs: PersistentObjectReidentificationCandidate
    ) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        if lhs.geometryScore != rhs.geometryScore {
            return lhs.geometryScore > rhs.geometryScore
        }
        return lhs.objectID < rhs.objectID
    }
}
