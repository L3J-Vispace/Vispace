import Foundation

public enum TemporalSpatialMemoryError: Error, Equatable, Sendable {
    case invalidPolicy
    case invalidTimestamp
    case observationIsNotConfirmed(ObjectID)
    case observationIsNotVisible(ObjectID)
    case duplicateObservation(ObjectID)
    case duplicateDurableObject(ObjectID)
    case duplicateExpectedObject(ObjectID)
    case tooManyObservations(maximum: Int)
    case tooManyExpectedObjects(maximum: Int)
    case mapMismatch(expected: MapID, actual: MapID)
    case coordinateFrameMismatch(
        expected: CoordinateFrameID,
        actual: CoordinateFrameID
    )
    case observationTimestampMismatch(ObjectID)
    case revisionConflict(expected: UInt64, actualBase: UInt64)
    case outOfOrderSequence(previous: UInt64, incoming: UInt64)
    case outOfOrderTimestamp(previous: TimeInterval, incoming: TimeInterval)
    case invalidClock
    case clockEpochConflict
    case clockEpochCapacityExceeded
    case unknownExpectedObject(ObjectID)
    case insufficientObservationConfidence(ObjectID)
    case promotionEvidenceMismatch(ObjectID)
    case identityNotConfirmed(ObjectID)
    case identityDecisionMismatch(ObjectID)
    case semanticLabelMismatch(ObjectID)
    case staleClassificationCorrection(ObjectID)
    case removedObjectCannotReappear(ObjectID)
    case objectCapacityExceeded(maximum: Int)
    case revisionOverflow
    case invalidSnapshot
    case snapshotObjectKeyMismatch(ObjectID)
    case unsupportedSchemaVersion(Int)
}

/// Safety and retention policy for temporal object memory. Every threshold is
/// evidence-based: miss counts cannot be replaced by elapsed time alone, and
/// elapsed time cannot be replaced by a burst of same-instant misses.
public struct TemporalSpatialMemoryPolicy: Codable, Hashable, Sendable {
    public static let maximumAllowedObjectCount = 4_096
    public static let maximumAllowedObservationCount = 1_024
    public static let maximumAllowedExpectedObjectCount = 4_096
    public static let maximumAllowedPendingMovementCount = 32
    public static let maximumAllowedRetainedDeltaCount = 1_024
    public static let maximumAllowedRememberedUpdateCount = 4_096

    public let minimumMissesForNotVisible: Int
    public let minimumMissesForLastSeen: Int
    public let minimumMissesForRemoval: Int
    public let notVisibleGraceInterval: TimeInterval
    public let lastSeenGraceInterval: TimeInterval
    public let removalGraceInterval: TimeInterval
    public let movementThreshold: Double
    public let movementClusterRadius: Double
    public let minimumMovementObservationCount: Int
    public let minimumMovementObservationInterval: TimeInterval
    public let minimumReidentificationScore: ConfidenceScore
    public let minimumReidentificationGeometryScore: ConfidenceScore
    public let minimumReidentificationContextScore: ConfidenceScore
    public let maximumObjectCount: Int
    public let maximumObservationsPerUpdate: Int
    public let maximumExpectedObjectsPerUpdate: Int
    public let maximumPendingMovementCount: Int
    public let maximumRetainedDeltaCount: Int
    public let maximumRememberedUpdateCount: Int

    public init(
        minimumMissesForNotVisible: Int = 2,
        minimumMissesForLastSeen: Int = 4,
        minimumMissesForRemoval: Int = 8,
        notVisibleGraceInterval: TimeInterval = 0.75,
        lastSeenGraceInterval: TimeInterval = 5,
        removalGraceInterval: TimeInterval = 30,
        movementThreshold: Double = 0.20,
        movementClusterRadius: Double = 0.12,
        minimumMovementObservationCount: Int = 3,
        minimumMovementObservationInterval: TimeInterval = 0.30,
        minimumReidentificationScore: ConfidenceScore = ConfidencePolicy.default.highThreshold,
        minimumReidentificationGeometryScore: ConfidenceScore = ConfidencePolicy.default
            .highThreshold,
        minimumReidentificationContextScore: ConfidenceScore = ConfidencePolicy.default
            .highThreshold,
        maximumObjectCount: Int = 2_048,
        maximumObservationsPerUpdate: Int = 256,
        maximumExpectedObjectsPerUpdate: Int = 512,
        maximumPendingMovementCount: Int = 8,
        maximumRetainedDeltaCount: Int = 64,
        maximumRememberedUpdateCount: Int = 128
    ) throws {
        let confidencePolicy = ConfidencePolicy.default
        guard minimumMissesForNotVisible >= 2,
            minimumMissesForNotVisible < minimumMissesForLastSeen,
            minimumMissesForLastSeen < minimumMissesForRemoval,
            notVisibleGraceInterval.isFinite,
            notVisibleGraceInterval >= 0,
            lastSeenGraceInterval.isFinite,
            lastSeenGraceInterval >= notVisibleGraceInterval,
            removalGraceInterval.isFinite,
            removalGraceInterval >= lastSeenGraceInterval,
            movementThreshold.isFinite,
            movementThreshold > 0,
            movementClusterRadius.isFinite,
            movementClusterRadius > 0,
            movementClusterRadius < movementThreshold,
            minimumMovementObservationCount >= 2,
            minimumMovementObservationInterval.isFinite,
            minimumMovementObservationInterval > 0,
            confidencePolicy.grade(for: minimumReidentificationScore) == .high,
            confidencePolicy.grade(for: minimumReidentificationGeometryScore) == .high,
            confidencePolicy.grade(for: minimumReidentificationContextScore) == .high,
            (1...Self.maximumAllowedObjectCount).contains(maximumObjectCount),
            (1...Self.maximumAllowedObservationCount).contains(maximumObservationsPerUpdate),
            (1...Self.maximumAllowedExpectedObjectCount).contains(
                maximumExpectedObjectsPerUpdate
            ),
            maximumPendingMovementCount >= minimumMovementObservationCount,
            maximumPendingMovementCount <= Self.maximumAllowedPendingMovementCount,
            (1...Self.maximumAllowedRetainedDeltaCount).contains(maximumRetainedDeltaCount),
            (1...Self.maximumAllowedRememberedUpdateCount).contains(
                maximumRememberedUpdateCount
            )
        else {
            throw TemporalSpatialMemoryError.invalidPolicy
        }

        self.minimumMissesForNotVisible = minimumMissesForNotVisible
        self.minimumMissesForLastSeen = minimumMissesForLastSeen
        self.minimumMissesForRemoval = minimumMissesForRemoval
        self.notVisibleGraceInterval = notVisibleGraceInterval
        self.lastSeenGraceInterval = lastSeenGraceInterval
        self.removalGraceInterval = removalGraceInterval
        self.movementThreshold = movementThreshold
        self.movementClusterRadius = movementClusterRadius
        self.minimumMovementObservationCount = minimumMovementObservationCount
        self.minimumMovementObservationInterval = minimumMovementObservationInterval
        self.minimumReidentificationScore = minimumReidentificationScore
        self.minimumReidentificationGeometryScore = minimumReidentificationGeometryScore
        self.minimumReidentificationContextScore = minimumReidentificationContextScore
        self.maximumObjectCount = maximumObjectCount
        self.maximumObservationsPerUpdate = maximumObservationsPerUpdate
        self.maximumExpectedObjectsPerUpdate = maximumExpectedObjectsPerUpdate
        self.maximumPendingMovementCount = maximumPendingMovementCount
        self.maximumRetainedDeltaCount = maximumRetainedDeltaCount
        self.maximumRememberedUpdateCount = maximumRememberedUpdateCount
    }

    public static let `default` = try! Self()

    private enum CodingKeys: String, CodingKey {
        case minimumMissesForNotVisible
        case minimumMissesForLastSeen
        case minimumMissesForRemoval
        case notVisibleGraceInterval
        case lastSeenGraceInterval
        case removalGraceInterval
        case movementThreshold
        case movementClusterRadius
        case minimumMovementObservationCount
        case minimumMovementObservationInterval
        case minimumReidentificationScore
        case minimumReidentificationGeometryScore
        case minimumReidentificationContextScore
        case maximumObjectCount
        case maximumObservationsPerUpdate
        case maximumExpectedObjectsPerUpdate
        case maximumPendingMovementCount
        case maximumRetainedDeltaCount
        case maximumRememberedUpdateCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                minimumMissesForNotVisible: container.decode(
                    Int.self,
                    forKey: .minimumMissesForNotVisible
                ),
                minimumMissesForLastSeen: container.decode(
                    Int.self,
                    forKey: .minimumMissesForLastSeen
                ),
                minimumMissesForRemoval: container.decode(
                    Int.self,
                    forKey: .minimumMissesForRemoval
                ),
                notVisibleGraceInterval: container.decode(
                    TimeInterval.self,
                    forKey: .notVisibleGraceInterval
                ),
                lastSeenGraceInterval: container.decode(
                    TimeInterval.self,
                    forKey: .lastSeenGraceInterval
                ),
                removalGraceInterval: container.decode(
                    TimeInterval.self,
                    forKey: .removalGraceInterval
                ),
                movementThreshold: container.decode(Double.self, forKey: .movementThreshold),
                movementClusterRadius: container.decode(
                    Double.self,
                    forKey: .movementClusterRadius
                ),
                minimumMovementObservationCount: container.decode(
                    Int.self,
                    forKey: .minimumMovementObservationCount
                ),
                minimumMovementObservationInterval: container.decode(
                    TimeInterval.self,
                    forKey: .minimumMovementObservationInterval
                ),
                minimumReidentificationScore: container.decode(
                    ConfidenceScore.self,
                    forKey: .minimumReidentificationScore
                ),
                minimumReidentificationGeometryScore: container.decode(
                    ConfidenceScore.self,
                    forKey: .minimumReidentificationGeometryScore
                ),
                minimumReidentificationContextScore: container.decode(
                    ConfidenceScore.self,
                    forKey: .minimumReidentificationContextScore
                ),
                maximumObjectCount: container.decode(Int.self, forKey: .maximumObjectCount),
                maximumObservationsPerUpdate: container.decode(
                    Int.self,
                    forKey: .maximumObservationsPerUpdate
                ),
                maximumExpectedObjectsPerUpdate: container.decode(
                    Int.self,
                    forKey: .maximumExpectedObjectsPerUpdate
                ),
                maximumPendingMovementCount: container.decode(
                    Int.self,
                    forKey: .maximumPendingMovementCount
                ),
                maximumRetainedDeltaCount: container.decode(
                    Int.self,
                    forKey: .maximumRetainedDeltaCount
                ),
                maximumRememberedUpdateCount: container.decode(
                    Int.self,
                    forKey: .maximumRememberedUpdateCount
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .minimumMissesForNotVisible,
                in: container,
                debugDescription: "Temporal spatial memory policy is invalid."
            )
        }
    }
}

/// One already-promoted observation. A new object must carry a `genuinelyNew`
/// resolution; an existing object must carry a high-confidence
/// `confirmedExisting` resolution before it can update durable memory.
public struct TemporalSpatialObservation: Codable, Hashable, Sendable {
    public let metadata: SpatialObjectMetadata
    public let promotionEvidence: ObjectReidentificationPromotionEvidence
    public let identityDecision: PersistentObjectReidentificationDecision
    public let identitySupport: PersistentObjectIdentitySupport?

    /// The admission boundary can defer one weak observation before batching.
    /// Reduction repeats this same check; rolling promotion evidence never
    /// substitutes for the confidence of the current measurement.
    public var hasSufficientConfidenceForPersistence: Bool {
        let policy = ConfidencePolicy.default
        let confidence = metadata.object.confidence
        return metadata.position.trackingQuality == .normal
            && policy.grade(for: confidence.semantic) == .high
            && policy.grade(for: confidence.geometry) == .high
            && policy.grade(for: confidence.identity) == .high
            && policy.grade(for: confidence.objectState) == .high
    }

    public init(
        metadata: SpatialObjectMetadata,
        promotionEvidence: ObjectReidentificationPromotionEvidence,
        identityDecision: PersistentObjectReidentificationDecision,
        identitySupport: PersistentObjectIdentitySupport? = nil
    ) throws {
        guard metadata.object.certainty == .confirmed else {
            throw TemporalSpatialMemoryError.observationIsNotConfirmed(metadata.object.id)
        }
        guard metadata.object.presence == .visible else {
            throw TemporalSpatialMemoryError.observationIsNotVisible(metadata.object.id)
        }
        let supportedCorrection: Bool
        if case .confirmedExisting = identityDecision {
            supportedCorrection =
                metadata.object.detectorSemanticLabel == promotionEvidence.semanticLabel
                && identitySupport?.objectID == metadata.object.id
        } else {
            supportedCorrection = false
        }
        guard (promotionEvidence.semanticLabel == metadata.object.semanticLabel || supportedCorrection),
            promotionEvidence.mapID == metadata.mapID,
            promotionEvidence.coordinateFrameID == metadata.position.coordinateFrameID,
            promotionEvidence.lastObservedAt == metadata.position.observedAt
        else {
            throw TemporalSpatialMemoryError.promotionEvidenceMismatch(metadata.object.id)
        }
        self.metadata = metadata
        self.promotionEvidence = promotionEvidence
        self.identityDecision = identityDecision
        self.identitySupport = identitySupport
    }

    private enum CodingKeys: String, CodingKey {
        case metadata
        case promotionEvidence
        case identityDecision
        case identitySupport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                metadata: container.decode(SpatialObjectMetadata.self, forKey: .metadata),
                promotionEvidence: container.decode(
                    ObjectReidentificationPromotionEvidence.self,
                    forKey: .promotionEvidence
                ),
                identityDecision: container.decode(
                    PersistentObjectReidentificationDecision.self,
                    forKey: .identityDecision
                ),
                identitySupport: container.decodeIfPresent(
                    PersistentObjectIdentitySupport.self, forKey: .identitySupport)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .metadata,
                in: container,
                debugDescription: "Temporal observation must be a visible confirmed object."
            )
        }
    }
}

/// Versioned ordering evidence independent of the unmodified calendar capture
/// date. A new capture segment starts the next durable epoch; elapsed-time
/// evidence is never carried across that boundary.
public struct TemporalSpatialClock: Codable, Hashable, Sendable {
    public enum Authorization: String, Codable, Hashable, Sendable {
        /// Standalone reducers remember retired segment identifiers.
        case recordedSegments
        /// The ingestion boundary validated the exact currently active AR run.
        /// Replay trusts this durable admission decision, not a live session.
        case currentCapture
    }

    public let epoch: UInt64
    public let captureSegmentID: CaptureSegmentID
    public let monotonicTimestamp: TimeInterval
    public let authorization: Authorization

    public init(
        epoch: UInt64, captureSegmentID: CaptureSegmentID, monotonicTimestamp: TimeInterval,
        authorization: Authorization = .recordedSegments
    ) throws {
        guard epoch > 0, monotonicTimestamp.isFinite, monotonicTimestamp >= 0 else {
            throw TemporalSpatialMemoryError.invalidClock
        }
        self.epoch = epoch
        self.captureSegmentID = captureSegmentID
        self.monotonicTimestamp = monotonicTimestamp
        self.authorization = authorization
    }

    private enum CodingKeys: String, CodingKey { case epoch, captureSegmentID, monotonicTimestamp, authorization }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            epoch: container.decode(UInt64.self, forKey: .epoch),
            captureSegmentID: container.decode(CaptureSegmentID.self, forKey: .captureSegmentID),
            monotonicTimestamp: container.decode(TimeInterval.self, forKey: .monotonicTimestamp),
            authorization: container.decodeIfPresent(Authorization.self, forKey: .authorization) ?? .recordedSegments
        )
    }
}

/// One complete coverage decision. `expectedVisibleObjectIDs` must contain only
/// objects that were actually inside a reliable detector/tracker coverage
/// region; absence outside that set is deliberately ignored.
public struct TemporalSpatialUpdate: Codable, Hashable, Sendable {
    public let id: SpatialDeltaID
    public let baseRevision: UInt64
    public let sequence: UInt64
    public let timestamp: TimeInterval
    public let clock: TemporalSpatialClock?
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let observations: [TemporalSpatialObservation]
    public let expectedVisibleObjectIDs: [ObjectID]
    public let classificationCorrections: [ObjectClassificationCorrection]

    public init(
        id: SpatialDeltaID = SpatialDeltaID(),
        baseRevision: UInt64,
        sequence: UInt64,
        timestamp: TimeInterval,
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        observations: [TemporalSpatialObservation],
        expectedVisibleObjectIDs: [ObjectID],
        clock: TemporalSpatialClock? = nil,
        classificationCorrections: [ObjectClassificationCorrection] = []
    ) throws {
        guard timestamp.isFinite, timestamp >= 0 else {
            throw TemporalSpatialMemoryError.invalidTimestamp
        }
        guard
            observations.count
                <= TemporalSpatialMemoryPolicy.maximumAllowedObservationCount
        else {
            throw TemporalSpatialMemoryError.tooManyObservations(
                maximum: TemporalSpatialMemoryPolicy.maximumAllowedObservationCount
            )
        }
        guard
            expectedVisibleObjectIDs.count
                <= TemporalSpatialMemoryPolicy.maximumAllowedExpectedObjectCount
        else {
            throw TemporalSpatialMemoryError.tooManyExpectedObjects(
                maximum: TemporalSpatialMemoryPolicy.maximumAllowedExpectedObjectCount
            )
        }

        var observedIDs = Set<ObjectID>()
        for observation in observations {
            let metadata = observation.metadata
            let objectID = metadata.object.id
            guard observedIDs.insert(objectID).inserted else {
                throw TemporalSpatialMemoryError.duplicateObservation(objectID)
            }
            guard metadata.mapID == mapID else {
                throw TemporalSpatialMemoryError.mapMismatch(
                    expected: mapID,
                    actual: metadata.mapID
                )
            }
            guard metadata.position.coordinateFrameID == coordinateFrameID else {
                throw TemporalSpatialMemoryError.coordinateFrameMismatch(
                    expected: coordinateFrameID,
                    actual: metadata.position.coordinateFrameID
                )
            }
            guard metadata.position.observedAt == timestamp else {
                throw TemporalSpatialMemoryError.observationTimestampMismatch(objectID)
            }
        }

        guard Set(expectedVisibleObjectIDs).count == expectedVisibleObjectIDs.count else {
            let duplicate = expectedVisibleObjectIDs.sorted().first { objectID in
                expectedVisibleObjectIDs.filter { $0 == objectID }.count > 1
            }!
            throw TemporalSpatialMemoryError.duplicateExpectedObject(duplicate)
        }

        self.id = id
        self.baseRevision = baseRevision
        self.sequence = sequence
        self.timestamp = timestamp
        self.clock = clock
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        self.observations = observations.sorted {
            $0.metadata.object.id < $1.metadata.object.id
        }
        guard classificationCorrections.count <= 32,
            Set(classificationCorrections.map(\.objectID)).count == classificationCorrections.count,
            Set(classificationCorrections.map(\.objectID)).isDisjoint(with: observedIDs),
            Set(classificationCorrections.map(\.objectID)).isDisjoint(with: expectedVisibleObjectIDs)
        else { throw TemporalSpatialMemoryError.invalidSnapshot }
        self.classificationCorrections = classificationCorrections
        self.expectedVisibleObjectIDs = expectedVisibleObjectIDs.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case baseRevision
        case sequence
        case timestamp
        case clock
        case mapID
        case coordinateFrameID
        case observations
        case expectedVisibleObjectIDs
        case classificationCorrections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(SpatialDeltaID.self, forKey: .id),
                baseRevision: container.decode(UInt64.self, forKey: .baseRevision),
                sequence: container.decode(UInt64.self, forKey: .sequence),
                timestamp: container.decode(TimeInterval.self, forKey: .timestamp),
                mapID: container.decode(MapID.self, forKey: .mapID),
                coordinateFrameID: container.decode(
                    CoordinateFrameID.self,
                    forKey: .coordinateFrameID
                ),
                observations: container.decode(
                    [TemporalSpatialObservation].self,
                    forKey: .observations
                ),
                expectedVisibleObjectIDs: container.decode(
                    [ObjectID].self,
                    forKey: .expectedVisibleObjectIDs
                ),
                clock: container.decodeIfPresent(TemporalSpatialClock.self, forKey: .clock),
                classificationCorrections: container.decodeIfPresent(
                    [ObjectClassificationCorrection].self, forKey: .classificationCorrections) ?? []
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .observations,
                in: container,
                debugDescription: "Temporal update provenance, timestamp, or capacity is invalid."
            )
        }
    }
}

public enum TemporalSpatialChange: Codable, Hashable, Sendable {
    case clockEpochStarted(epoch: UInt64, at: TimeInterval)
    case calendarClockMovedBackward(at: TimeInterval)
    case reclassified(objectID: ObjectID, from: String, to: String, at: TimeInterval)
    /// The durable object limit prevents only this new identity's admission;
    /// existing identities and visibility evidence in the batch still advance.
    case deferredDueToCapacity(objectID: ObjectID, at: TimeInterval)
    case added(object: SpatialObjectMetadata, at: TimeInterval)
    case moved(
        objectID: ObjectID,
        from: Vec3,
        to: Vec3,
        at: TimeInterval,
        confidence: ConfidenceScore
    )
    case stateChanged(
        objectID: ObjectID,
        from: ObjectPresence,
        to: ObjectPresence,
        at: TimeInterval
    )
    case missing(
        objectID: ObjectID,
        lastSeenPosition: Vec3,
        lastSeenAt: TimeInterval,
        detectedAt: TimeInterval
    )
    case removed(
        objectID: ObjectID,
        lastSeenPosition: Vec3,
        lastSeenAt: TimeInterval,
        removedAt: TimeInterval
    )
}

/// The only append-only output of one update. Full observations are not put in
/// history: downstream persistence can store this bounded delta and the latest
/// compact snapshot.
public struct TemporalSpatialDelta: Codable, Hashable, Sendable {
    public let id: SpatialDeltaID
    public let baseRevision: UInt64
    public let newRevision: UInt64
    public let sequence: UInt64
    public let timestamp: TimeInterval
    public let clock: TemporalSpatialClock?
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let spatialDelta: SpatialDelta
    public let changes: [TemporalSpatialChange]

    public var deferredObjectIDs: Set<ObjectID> {
        Set(changes.compactMap { change in
            if case .deferredDueToCapacity(let objectID, _) = change {
                return objectID
            }
            return nil
        })
    }

    fileprivate init(
        update: TemporalSpatialUpdate,
        newRevision: UInt64,
        spatialEvents: [ObjectEvent],
        changes: [TemporalSpatialChange]
    ) {
        id = update.id
        baseRevision = update.baseRevision
        self.newRevision = newRevision
        sequence = update.sequence
        timestamp = update.timestamp
        clock = update.clock
        mapID = update.mapID
        coordinateFrameID = update.coordinateFrameID
        spatialDelta = SpatialDelta(
            id: update.id,
            baseRevision: update.baseRevision,
            events: spatialEvents
        )
        self.changes = changes
    }
}

public struct TemporalObjectLifecycleEvidence: Codable, Hashable, Sendable {
    public let consecutiveMissCount: Int
    public let firstMissedAt: TimeInterval?
    public let lastMissedAt: TimeInterval?
    public let pendingMovementObservationCount: Int
}

private struct TemporalMovementSample: Codable, Hashable, Sendable {
    let position: FramedPosition
    let bounds: AABB?
    let confidence: ConfidenceVector
    let reidentificationConfidence: ConfidenceScore
    let monotonicTimestamp: TimeInterval?
}

private struct TemporalObjectState: Codable, Hashable, Sendable {
    var metadata: SpatialObjectMetadata
    var stablePosition: Vec3
    var consecutiveMissCount: Int
    var firstMissedAt: TimeInterval?
    var lastMissedAt: TimeInterval?
    var pendingMovementSamples: [TemporalMovementSample]

    init(metadata: SpatialObjectMetadata) {
        self.metadata = metadata
        stablePosition = metadata.position.value
        consecutiveMissCount = 0
        firstMissedAt = nil
        lastMissedAt = nil
        pendingMovementSamples = []
    }
}

public struct TemporalSpatialMemorySnapshot: Codable, Hashable, Sendable {
    private static let schemaVersion = 3

    public fileprivate(set) var revision: UInt64
    public fileprivate(set) var latestSequence: UInt64?
    public fileprivate(set) var latestTimestamp: TimeInterval?
    public fileprivate(set) var latestClock: TemporalSpatialClock?
    public fileprivate(set) var retiredCaptureSegmentIDs: Set<CaptureSegmentID>
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    fileprivate var objectStates: [ObjectID: TemporalObjectState]
    public fileprivate(set) var recentDeltas: [TemporalSpatialDelta]
    fileprivate var rememberedUpdateIDs: [SpatialDeltaID]

    fileprivate init(mapID: MapID, coordinateFrameID: CoordinateFrameID) {
        revision = 0
        latestSequence = nil
        latestTimestamp = nil
        latestClock = nil
        retiredCaptureSegmentIDs = []
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        objectStates = [:]
        recentDeltas = []
        rememberedUpdateIDs = []
    }

    public var objects: [ObjectID: SpatialObjectMetadata] {
        objectStates.mapValues(\.metadata)
    }

    public var rememberedUpdateCount: Int {
        rememberedUpdateIDs.count
    }

    public func metadata(for objectID: ObjectID) -> SpatialObjectMetadata? {
        objectStates[objectID]?.metadata
    }

    public func lifecycleEvidence(
        for objectID: ObjectID
    ) -> TemporalObjectLifecycleEvidence? {
        objectStates[objectID].map { state in
            TemporalObjectLifecycleEvidence(
                consecutiveMissCount: state.consecutiveMissCount,
                firstMissedAt: state.firstMissedAt,
                lastMissedAt: state.lastMissedAt,
                pendingMovementObservationCount: state.pendingMovementSamples.count
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case revision
        case latestSequence
        case latestTimestamp
        case latestClock
        case retiredCaptureSegmentIDs
        case mapID
        case coordinateFrameID
        case objectStates
        case recentDeltas
        case rememberedUpdateIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.schemaVersion).contains(version) else {
            throw TemporalSpatialMemoryError.unsupportedSchemaVersion(version)
        }
        revision = try container.decode(UInt64.self, forKey: .revision)
        latestSequence = try container.decodeIfPresent(UInt64.self, forKey: .latestSequence)
        latestTimestamp = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .latestTimestamp
        )
        latestClock = try container.decodeIfPresent(TemporalSpatialClock.self, forKey: .latestClock)
        if version == 1 {
            retiredCaptureSegmentIDs = []
        } else {
            retiredCaptureSegmentIDs = try container.decode(
                Set<CaptureSegmentID>.self, forKey: .retiredCaptureSegmentIDs
            )
        }
        guard (version > 1 || latestClock == nil),
            version >= 3 || latestClock?.authorization != .currentCapture else {
            throw TemporalSpatialMemoryError.invalidSnapshot
        }
        mapID = try container.decode(MapID.self, forKey: .mapID)
        coordinateFrameID = try container.decode(
            CoordinateFrameID.self,
            forKey: .coordinateFrameID
        )
        objectStates = try container.decode(
            [ObjectID: TemporalObjectState].self,
            forKey: .objectStates
        )
        recentDeltas = try container.decode(
            [TemporalSpatialDelta].self,
            forKey: .recentDeltas
        )
        rememberedUpdateIDs = try container.decode(
            [SpatialDeltaID].self,
            forKey: .rememberedUpdateIDs
        )

        guard objectStates.count <= TemporalSpatialMemoryPolicy.maximumAllowedObjectCount,
            retiredCaptureSegmentIDs.count <= 4_096,
            latestClock.map({ clock in
                !retiredCaptureSegmentIDs.contains(clock.captureSegmentID)
                    && (clock.authorization == .currentCapture
                        ? retiredCaptureSegmentIDs.isEmpty
                        : clock.epoch == UInt64(retiredCaptureSegmentIDs.count) + 1)
            }) ?? retiredCaptureSegmentIDs.isEmpty,
            recentDeltas.count
                <= TemporalSpatialMemoryPolicy.maximumAllowedRetainedDeltaCount,
            rememberedUpdateIDs.count
                <= TemporalSpatialMemoryPolicy.maximumAllowedRememberedUpdateCount,
            Set(rememberedUpdateIDs).count == rememberedUpdateIDs.count,
            latestTimestamp.map({ $0.isFinite && $0 >= 0 }) ?? true
        else {
            throw TemporalSpatialMemoryError.invalidSnapshot
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(latestSequence, forKey: .latestSequence)
        try container.encodeIfPresent(latestTimestamp, forKey: .latestTimestamp)
        try container.encodeIfPresent(latestClock, forKey: .latestClock)
        try container.encode(retiredCaptureSegmentIDs.sorted(), forKey: .retiredCaptureSegmentIDs)
        try container.encode(mapID, forKey: .mapID)
        try container.encode(coordinateFrameID, forKey: .coordinateFrameID)
        try container.encode(objectStates, forKey: .objectStates)
        try container.encode(recentDeltas, forKey: .recentDeltas)
        try container.encode(rememberedUpdateIDs, forKey: .rememberedUpdateIDs)
    }
}

public enum TemporalSpatialMemoryApplicationResult: Equatable, Sendable {
    case applied(TemporalSpatialDelta)
    case alreadyApplied(currentRevision: UInt64)
}

/// Deterministic lifecycle coordinator for one map and one coordinate frame.
/// It accepts only already-promoted/re-identified observations, records only a
/// bounded delta history, and never infers absence outside explicit coverage.
public struct TemporalSpatialMemoryCoordinator: Sendable {
    public let policy: TemporalSpatialMemoryPolicy
    public private(set) var snapshot: TemporalSpatialMemorySnapshot

    public init(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        policy: TemporalSpatialMemoryPolicy = .default
    ) {
        self.policy = policy
        snapshot = TemporalSpatialMemorySnapshot(
            mapID: mapID,
            coordinateFrameID: coordinateFrameID
        )
    }

    /// Seeds a new temporal journal from metadata that already crossed the
    /// durable checkpoint repository's validation boundary. This is intended
    /// only for first journal creation or legacy migration; subsequent state
    /// is restored from the replayable journal snapshot.
    public init(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        restoringDurableObjects objects: [SpatialObjectMetadata],
        policy: TemporalSpatialMemoryPolicy = .default
    ) throws {
        guard objects.count <= policy.maximumObjectCount else {
            throw TemporalSpatialMemoryError.objectCapacityExceeded(
                maximum: policy.maximumObjectCount
            )
        }
        self.policy = policy
        var restored = TemporalSpatialMemorySnapshot(
            mapID: mapID,
            coordinateFrameID: coordinateFrameID
        )
        for metadata in objects.sorted(by: { $0.object.id < $1.object.id }) {
            let objectID = metadata.object.id
            guard restored.objectStates[objectID] == nil else {
                throw TemporalSpatialMemoryError.duplicateDurableObject(objectID)
            }
            guard metadata.mapID == mapID else {
                throw TemporalSpatialMemoryError.mapMismatch(
                    expected: mapID,
                    actual: metadata.mapID
                )
            }
            guard metadata.position.coordinateFrameID == coordinateFrameID else {
                throw TemporalSpatialMemoryError.coordinateFrameMismatch(
                    expected: coordinateFrameID,
                    actual: metadata.position.coordinateFrameID
                )
            }
            guard metadata.object.certainty == .confirmed else {
                throw TemporalSpatialMemoryError.observationIsNotConfirmed(objectID)
            }
            restored.objectStates[objectID] = TemporalObjectState(metadata: metadata)
        }
        // Imported current metadata may outlive its derived journal. Continue
        // above its durable revision instead of reusing revision one.
        if let durableRevision = objects.compactMap({ $0.object.temporalRevision }).max() {
            restored.revision = durableRevision
            restored.latestSequence = durableRevision
            restored.latestTimestamp = objects.map(\.object.stateUpdatedAt).max()
        }
        snapshot = restored
        try validate(restored)
    }

    public init(
        restoring snapshot: TemporalSpatialMemorySnapshot,
        policy: TemporalSpatialMemoryPolicy = .default
    ) throws {
        self.policy = policy
        self.snapshot = snapshot
        try validate(snapshot)
    }

    @discardableResult
    public mutating func apply(
        _ update: TemporalSpatialUpdate
    ) throws -> TemporalSpatialMemoryApplicationResult {
        if snapshot.rememberedUpdateIDs.contains(update.id) {
            return .alreadyApplied(currentRevision: snapshot.revision)
        }
        guard update.baseRevision == snapshot.revision else {
            throw TemporalSpatialMemoryError.revisionConflict(
                expected: snapshot.revision,
                actualBase: update.baseRevision
            )
        }
        guard update.mapID == snapshot.mapID else {
            throw TemporalSpatialMemoryError.mapMismatch(
                expected: snapshot.mapID,
                actual: update.mapID
            )
        }
        guard update.coordinateFrameID == snapshot.coordinateFrameID else {
            throw TemporalSpatialMemoryError.coordinateFrameMismatch(
                expected: snapshot.coordinateFrameID,
                actual: update.coordinateFrameID
            )
        }
        if let latestSequence = snapshot.latestSequence,
            update.sequence <= latestSequence
        {
            throw TemporalSpatialMemoryError.outOfOrderSequence(
                previous: latestSequence,
                incoming: update.sequence
            )
        }
        let startsClockEpoch = try validateClock(update)
        guard update.observations.count <= policy.maximumObservationsPerUpdate else {
            throw TemporalSpatialMemoryError.tooManyObservations(
                maximum: policy.maximumObservationsPerUpdate
            )
        }
        guard
            update.expectedVisibleObjectIDs.count
                <= policy.maximumExpectedObjectsPerUpdate
        else {
            throw TemporalSpatialMemoryError.tooManyExpectedObjects(
                maximum: policy.maximumExpectedObjectsPerUpdate
            )
        }

        try validateObservations(update.observations)
        let incomingNewIDs = Set(
            update.observations.compactMap { observation -> ObjectID? in
                if case .genuinelyNew = observation.identityDecision {
                    return observation.metadata.object.id
                }
                return nil
            }
        )
        let knownAfterUpdate = Set(snapshot.objectStates.keys).union(incomingNewIDs)
        for objectID in update.expectedVisibleObjectIDs
        where !knownAfterUpdate.contains(objectID) {
            throw TemporalSpatialMemoryError.unknownExpectedObject(objectID)
        }
        let availableSlots = policy.maximumObjectCount - snapshot.objectStates.count
        let orderedNewIDs = incomingNewIDs.subtracting(snapshot.objectStates.keys).sorted()
        let deferredIDs = Set(orderedNewIDs.dropFirst(availableSlots))

        let (newRevision, overflow) = snapshot.revision.addingReportingOverflow(1)
        guard !overflow else {
            throw TemporalSpatialMemoryError.revisionOverflow
        }
        let observationRevision = update.clock == nil ? nil : newRevision
        var working = snapshot
        var spatialEvents: [ObjectEvent] = []
        var changes: [TemporalSpatialChange] = deferredIDs.sorted().map {
            .deferredDueToCapacity(objectID: $0, at: update.timestamp)
        }
        let calendarMovedBackward = update.clock != nil
            && snapshot.latestTimestamp.map { update.timestamp < $0 } == true
        if update.clock?.authorization == .currentCapture {
            // Live authority supersedes tombstones: old work cannot acquire
            // a new epoch merely by presenting an unseen segment identifier.
            working.retiredCaptureSegmentIDs.removeAll()
        }
        if startsClockEpoch || calendarMovedBackward {
            if startsClockEpoch, update.clock?.authorization != .currentCapture,
                let previous = working.latestClock {
                working.retiredCaptureSegmentIDs.insert(previous.captureSegmentID)
            }
            for objectID in Array(working.objectStates.keys) {
                guard var state = working.objectStates[objectID] else { continue }
                resetMissEvidence(in: &state)
                state.pendingMovementSamples.removeAll()
                working.objectStates[objectID] = state
            }
            if startsClockEpoch, let clock = update.clock {
                changes.append(.clockEpochStarted(epoch: clock.epoch, at: update.timestamp))
            } else {
                changes.append(.calendarClockMovedBackward(at: update.timestamp))
            }
        }
        for correction in update.classificationCorrections {
            guard var state = working.objectStates[correction.objectID],
                state.metadata.object.presence != .removed,
                state.metadata.object.semanticLabel == correction.expectedSemanticLabel,
                state.metadata.object.temporalRevision == correction.expectedTemporalRevision
            else { throw TemporalSpatialMemoryError.staleClassificationCorrection(correction.objectID) }
            let previousLabel = state.metadata.object.semanticLabel
            guard previousLabel != correction.semanticLabel else { continue }
            var object = state.metadata.object
            object.detectorSemanticLabel = object.detectorSemanticLabel ?? previousLabel
            object.semanticLabel = correction.semanticLabel
            object.temporalRevision = observationRevision ?? object.temporalRevision
            object.stateUpdatedAt = update.timestamp
            try object.setDisplayName(correction.displayName)
            state.metadata = try SpatialObjectMetadata(
                mapID: state.metadata.mapID,
                object: object, position: state.metadata.position)
            state.pendingMovementSamples.removeAll()
            working.objectStates[correction.objectID] = state
            spatialEvents.append(.upsert(object))
            changes.append(
                .reclassified(
                    objectID: object.id, from: previousLabel,
                    to: object.semanticLabel, at: update.timestamp))
        }
        let observedIDs = Set(update.observations.map { $0.metadata.object.id })

        for observation in update.observations
        where !deferredIDs.contains(observation.metadata.object.id) {
            try applyObservation(
                observation,
                monotonicTimestamp: update.clock?.monotonicTimestamp,
                temporalRevision: observationRevision,
                to: &working,
                spatialEvents: &spatialEvents,
                changes: &changes
            )
        }

        for objectID in update.expectedVisibleObjectIDs
        where !observedIDs.contains(objectID) {
            try applyMiss(
                objectID,
                at: update.timestamp,
                elapsedTimestamp: update.clock?.monotonicTimestamp ?? update.timestamp,
                temporalRevision: observationRevision,
                to: &working,
                spatialEvents: &spatialEvents,
                changes: &changes
            )
        }

        if update.clock != nil {
            var changedIDs: [ObjectID] = []
            for objectID in working.objectStates.keys.sorted() {
                guard var state = working.objectStates[objectID],
                    state.metadata != snapshot.objectStates[objectID]?.metadata
                else { continue }
                var object = state.metadata.object
                object.temporalRevision = newRevision
                state.metadata = try SpatialObjectMetadata(
                    mapID: state.metadata.mapID, object: object, position: state.metadata.position
                )
                working.objectStates[objectID] = state
                changedIDs.append(objectID)
            }
            // Full revision-addressed upserts are the v2 reducer contract.
            // Calendar-only events cannot safely order a backward clock jump.
            spatialEvents = changedIDs.compactMap { working.objectStates[$0].map { .upsert($0.metadata.object) } }
            changes = changes.map { change in
                if case .added(let metadata, let time) = change,
                    let committed = working.objectStates[metadata.object.id]?.metadata
                { return .added(object: committed, at: time) }
                return change
            }
        }
        let delta = TemporalSpatialDelta(
            update: update,
            newRevision: newRevision,
            spatialEvents: spatialEvents,
            changes: changes
        )
        working.revision = newRevision
        working.latestSequence = update.sequence
        working.latestTimestamp = update.timestamp
        working.latestClock = update.clock
        working.recentDeltas.append(delta)
        trim(
            &working.recentDeltas,
            maximumCount: policy.maximumRetainedDeltaCount
        )
        working.rememberedUpdateIDs.append(update.id)
        trim(
            &working.rememberedUpdateIDs,
            maximumCount: policy.maximumRememberedUpdateCount
        )
        snapshot = working
        return .applied(delta)
    }

    private func validateClock(_ update: TemporalSpatialUpdate) throws -> Bool {
        guard let clock = update.clock else {
            guard snapshot.latestClock == nil else { throw TemporalSpatialMemoryError.clockEpochConflict }
            if let latestTimestamp = snapshot.latestTimestamp, update.timestamp <= latestTimestamp {
                throw TemporalSpatialMemoryError.outOfOrderTimestamp(previous: latestTimestamp, incoming: update.timestamp)
            }
            return false
        }
        guard snapshot.latestClock?.authorization != .currentCapture
            || clock.authorization == .currentCapture else {
            throw TemporalSpatialMemoryError.clockEpochConflict
        }
        guard clock.authorization == .currentCapture
            || !snapshot.retiredCaptureSegmentIDs.contains(clock.captureSegmentID) else {
            throw TemporalSpatialMemoryError.clockEpochConflict
        }
        guard let previous = snapshot.latestClock else {
            guard clock.epoch == 1 else { throw TemporalSpatialMemoryError.clockEpochConflict }
            return true
        }
        if clock.epoch == previous.epoch {
            guard clock.captureSegmentID == previous.captureSegmentID else {
                throw TemporalSpatialMemoryError.clockEpochConflict
            }
            let isCorrectionAtCurrentPose =
                !update.classificationCorrections.isEmpty
                && update.observations.isEmpty && update.expectedVisibleObjectIDs.isEmpty
                && clock.monotonicTimestamp == previous.monotonicTimestamp
            guard clock.monotonicTimestamp > previous.monotonicTimestamp || isCorrectionAtCurrentPose else {
                throw TemporalSpatialMemoryError.outOfOrderTimestamp(
                    previous: previous.monotonicTimestamp, incoming: clock.monotonicTimestamp
                )
            }
            return false
        }
        let (nextEpoch, overflow) = previous.epoch.addingReportingOverflow(1)
        guard !overflow, clock.epoch == nextEpoch,
            clock.captureSegmentID != previous.captureSegmentID else {
            throw TemporalSpatialMemoryError.clockEpochConflict
        }
        // Durable tombstones cannot be silently dropped: doing so would allow
        // old capture segments to be reintroduced as a fresh epoch.
        guard clock.authorization == .currentCapture || snapshot.retiredCaptureSegmentIDs.count < 4_096 else {
            throw TemporalSpatialMemoryError.clockEpochCapacityExceeded
        }
        return true
    }

    private func validateObservations(
        _ observations: [TemporalSpatialObservation]
    ) throws {
        for observation in observations {
            let metadata = observation.metadata
            let object = metadata.object
            guard metadata.mapID == snapshot.mapID else {
                throw TemporalSpatialMemoryError.mapMismatch(
                    expected: snapshot.mapID,
                    actual: metadata.mapID
                )
            }
            guard metadata.position.coordinateFrameID == snapshot.coordinateFrameID else {
                throw TemporalSpatialMemoryError.coordinateFrameMismatch(
                    expected: snapshot.coordinateFrameID,
                    actual: metadata.position.coordinateFrameID
                )
            }
            guard observation.hasSufficientConfidenceForPersistence
            else {
                throw TemporalSpatialMemoryError.insufficientObservationConfidence(object.id)
            }

            if let existing = snapshot.objectStates[object.id] {
                guard existing.metadata.object.presence != .removed else {
                    throw TemporalSpatialMemoryError.removedObjectCannotReappear(object.id)
                }
                guard existing.metadata.object.semanticLabel == object.semanticLabel else {
                    throw TemporalSpatialMemoryError.semanticLabelMismatch(object.id)
                }
                guard case .confirmedExisting(let candidate) = observation.identityDecision else {
                    throw TemporalSpatialMemoryError.identityNotConfirmed(object.id)
                }
                guard candidate.objectID == object.id else {
                    throw TemporalSpatialMemoryError.identityDecisionMismatch(object.id)
                }
                let supported =
                    observation.identitySupport?.validates(
                        existing: existing.metadata,
                        incoming: metadata, promotionEvidence: observation.promotionEvidence) == true
                let contextSupported =
                    candidate.geometryScore >= policy.minimumReidentificationGeometryScore
                    && candidate.spatialContextScore.map { $0 >= policy.minimumReidentificationContextScore }
                        == true
                guard candidate.score >= policy.minimumReidentificationScore,
                    supported || contextSupported
                else {
                    throw TemporalSpatialMemoryError.identityNotConfirmed(object.id)
                }
            } else {
                guard case .genuinelyNew = observation.identityDecision else {
                    throw TemporalSpatialMemoryError.identityDecisionMismatch(object.id)
                }
            }
        }
    }

    private func applyObservation(
        _ observation: TemporalSpatialObservation,
        monotonicTimestamp: TimeInterval?,
        temporalRevision: UInt64?,
        to state: inout TemporalSpatialMemorySnapshot,
        spatialEvents: inout [ObjectEvent],
        changes: inout [TemporalSpatialChange]
    ) throws {
        let incoming = observation.metadata
        let objectID = incoming.object.id
        guard var objectState = state.objectStates[objectID] else {
            state.objectStates[objectID] = TemporalObjectState(metadata: incoming)
            spatialEvents.append(.upsert(incoming.object))
            changes.append(.added(object: incoming, at: incoming.position.observedAt))
            return
        }

        let distanceFromStable = objectState.stablePosition.distance(
            to: incoming.position.value
        )
        if distanceFromStable >= policy.movementThreshold {
            guard
                case .confirmedExisting(let identityCandidate) =
                    observation.identityDecision
            else {
                throw TemporalSpatialMemoryError.identityNotConfirmed(objectID)
            }
            try stageMovement(
                incoming,
                reidentificationConfidence: identityCandidate.score,
                monotonicTimestamp: monotonicTimestamp,
                temporalRevision: temporalRevision,
                in: &objectState,
                spatialEvents: &spatialEvents,
                changes: &changes
            )
            if let support = observation.identitySupport, case .continuousTracking = support,
                objectState.metadata.position != incoming.position
            {
                // Verified live tracking maintains the measured position even
                // while movement-event hysteresis waits for a settled cluster.
                // This durable rolling anchor prevents long motion from losing
                // its identity when the bounded tracking window advances.
                let previousPresence = objectState.metadata.object.presence
                objectState.metadata = try refreshedMetadata(
                    existing: objectState.metadata,
                    from: incoming, temporalRevision: temporalRevision)
                spatialEvents.append(
                    .observed(
                        objectID: objectID, at: incoming.position.observedAt,
                        position: incoming.position.value, bounds: objectState.metadata.object.bounds,
                        confidence: incoming.object.confidence))
                if previousPresence != .visible {
                    changes.append(
                        .stateChanged(
                            objectID: objectID, from: previousPresence,
                            to: .visible, at: incoming.position.observedAt))
                }
            }
            resetMissEvidence(in: &objectState)
            state.objectStates[objectID] = objectState
            return
        }

        let previousPresence = objectState.metadata.object.presence
        objectState.metadata = try refreshedMetadata(
            existing: objectState.metadata,
            from: incoming,
            temporalRevision: temporalRevision
        )
        objectState.pendingMovementSamples.removeAll(keepingCapacity: true)
        resetMissEvidence(in: &objectState)
        state.objectStates[objectID] = objectState
        spatialEvents.append(
            .observed(
                objectID: objectID,
                at: incoming.position.observedAt,
                position: incoming.position.value,
                bounds: objectState.metadata.object.bounds,
                confidence: incoming.object.confidence
            )
        )
        if previousPresence != .visible {
            changes.append(
                .stateChanged(
                    objectID: objectID,
                    from: previousPresence,
                    to: .visible,
                    at: incoming.position.observedAt
                )
            )
        }
    }

    private func stageMovement(
        _ incoming: SpatialObjectMetadata,
        reidentificationConfidence: ConfidenceScore,
        monotonicTimestamp: TimeInterval?,
        temporalRevision: UInt64?,
        in state: inout TemporalObjectState,
        spatialEvents: inout [ObjectEvent],
        changes: inout [TemporalSpatialChange]
    ) throws {
        guard case .confirmed = incoming.object.certainty else {
            throw TemporalSpatialMemoryError.observationIsNotConfirmed(incoming.object.id)
        }
        let sample = TemporalMovementSample(
            position: incoming.position,
            bounds: incoming.object.bounds,
            confidence: incoming.object.confidence,
            reidentificationConfidence: reidentificationConfidence,
            monotonicTimestamp: monotonicTimestamp
        )

        if !state.pendingMovementSamples.isEmpty,
            state.pendingMovementSamples.allSatisfy({
                $0.position.value.distance(to: sample.position.value) <= policy.movementClusterRadius
            })
        {
            state.pendingMovementSamples.append(sample)
        } else {
            state.pendingMovementSamples = [sample]
        }
        trim(
            &state.pendingMovementSamples,
            maximumCount: policy.maximumPendingMovementCount
        )

        guard
            state.pendingMovementSamples.count
                >= policy.minimumMovementObservationCount,
            let first = state.pendingMovementSamples.first,
            let last = state.pendingMovementSamples.last,
            (last.monotonicTimestamp ?? last.position.observedAt)
                - (first.monotonicTimestamp ?? first.position.observedAt)
                >= policy.minimumMovementObservationInterval
        else {
            return
        }
        guard
            state.pendingMovementSamples.allSatisfy({ candidate in
                candidate.position.value.distance(to: last.position.value)
                    <= policy.movementClusterRadius
                    && candidate.reidentificationConfidence
                        >= policy.minimumReidentificationScore
            })
        else {
            return
        }

        let previousMetadata = state.metadata
        let previousPresence = previousMetadata.object.presence
        let previousStablePosition = state.stablePosition
        let committedMetadata = try refreshedMetadata(
            existing: previousMetadata,
            from: incoming,
            temporalRevision: temporalRevision
        )
        state.metadata = committedMetadata
        state.stablePosition = incoming.position.value
        state.pendingMovementSamples.removeAll(keepingCapacity: true)

        spatialEvents.append(
            .moved(
                objectID: incoming.object.id,
                from: previousMetadata.position.value,
                to: incoming.position.value,
                at: incoming.position.observedAt,
                confidence: incoming.object.confidence.objectState
            )
        )
        changes.append(
            .moved(
                objectID: incoming.object.id,
                from: previousStablePosition,
                to: incoming.position.value,
                at: incoming.position.observedAt,
                confidence: reidentificationConfidence
            )
        )
        if previousPresence != .visible {
            changes.append(
                .stateChanged(
                    objectID: incoming.object.id,
                    from: previousPresence,
                    to: .visible,
                    at: incoming.position.observedAt
                )
            )
        }
    }

    private func applyMiss(
        _ objectID: ObjectID,
        at timestamp: TimeInterval,
        elapsedTimestamp: TimeInterval,
        temporalRevision: UInt64?,
        to state: inout TemporalSpatialMemorySnapshot,
        spatialEvents: inout [ObjectEvent],
        changes: inout [TemporalSpatialChange]
    ) throws {
        guard var objectState = state.objectStates[objectID] else {
            throw TemporalSpatialMemoryError.unknownExpectedObject(objectID)
        }
        guard objectState.metadata.object.presence != .removed else {
            return
        }

        if objectState.consecutiveMissCount == 0 {
            objectState.firstMissedAt = elapsedTimestamp
        }
        objectState.consecutiveMissCount = min(
            objectState.consecutiveMissCount + 1,
            policy.minimumMissesForRemoval
        )
        objectState.lastMissedAt = elapsedTimestamp
        let elapsed = elapsedTimestamp - (objectState.firstMissedAt ?? elapsedTimestamp)
        let previousPresence = objectState.metadata.object.presence
        let nextPresence: ObjectPresence?
        switch previousPresence {
        case .visible
        where objectState.consecutiveMissCount >= policy.minimumMissesForNotVisible
            && elapsed >= policy.notVisibleGraceInterval:
            nextPresence = .notVisible
        case .notVisible
        where objectState.consecutiveMissCount >= policy.minimumMissesForLastSeen
            && elapsed >= policy.lastSeenGraceInterval:
            nextPresence = .lastSeen
        case .lastSeen
        where objectState.consecutiveMissCount >= policy.minimumMissesForRemoval
            && elapsed >= policy.removalGraceInterval:
            nextPresence = .removed
        default:
            nextPresence = nil
        }

        if let nextPresence {
            objectState.metadata = try metadataByChangingPresence(
                objectState.metadata,
                to: nextPresence,
                at: timestamp,
                temporalRevision: temporalRevision
            )
            changes.append(
                .stateChanged(
                    objectID: objectID,
                    from: previousPresence,
                    to: nextPresence,
                    at: timestamp
                )
            )
            switch nextPresence {
            case .notVisible:
                spatialEvents.append(.becameNotVisible(objectID: objectID, at: timestamp))
                changes.append(
                    .missing(
                        objectID: objectID,
                        lastSeenPosition: objectState.metadata.position.value,
                        lastSeenAt: objectState.metadata.position.observedAt,
                        detectedAt: timestamp
                    )
                )
            case .lastSeen:
                spatialEvents.append(.becameLastSeen(objectID: objectID, at: timestamp))
            case .removed:
                spatialEvents.append(
                    .removed(
                        objectID: objectID,
                        at: timestamp,
                        confidence: .one
                    )
                )
                changes.append(
                    .removed(
                        objectID: objectID,
                        lastSeenPosition: objectState.metadata.position.value,
                        lastSeenAt: objectState.metadata.position.observedAt,
                        removedAt: timestamp
                    )
                )
            case .visible:
                break
            }
        }
        state.objectStates[objectID] = objectState
    }

    private func refreshedMetadata(
        existing: SpatialObjectMetadata,
        from incoming: SpatialObjectMetadata,
        temporalRevision: UInt64?
    ) throws -> SpatialObjectMetadata {
        var object = existing.object
        object.temporalRevision = temporalRevision ?? object.temporalRevision
        object.nodeID = existing.object.nodeID ?? incoming.object.nodeID
        object.position = incoming.position.value
        object.bounds = incoming.object.bounds ?? existing.object.bounds
        object.presence = .visible
        object.confidence = incoming.object.confidence
        object.lastSeenAt = incoming.position.observedAt
        object.stateUpdatedAt = incoming.position.observedAt
        return try SpatialObjectMetadata(
            mapID: existing.mapID,
            object: object,
            position: incoming.position
        )
    }

    private func metadataByChangingPresence(
        _ metadata: SpatialObjectMetadata,
        to presence: ObjectPresence,
        at timestamp: TimeInterval,
        temporalRevision: UInt64?
    ) throws -> SpatialObjectMetadata {
        var object = metadata.object
        object.temporalRevision = temporalRevision ?? object.temporalRevision
        object.presence = presence
        object.stateUpdatedAt = timestamp
        return try SpatialObjectMetadata(
            mapID: metadata.mapID,
            object: object,
            position: metadata.position
        )
    }

    private func resetMissEvidence(in state: inout TemporalObjectState) {
        state.consecutiveMissCount = 0
        state.firstMissedAt = nil
        state.lastMissedAt = nil
    }

    private func trim<Element>(_ values: inout [Element], maximumCount: Int) {
        if values.count > maximumCount {
            values.removeFirst(values.count - maximumCount)
        }
    }

    private func validate(_ snapshot: TemporalSpatialMemorySnapshot) throws {
        guard snapshot.objectStates.count <= policy.maximumObjectCount,
            snapshot.retiredCaptureSegmentIDs.count <= 4_096,
            snapshot.latestClock.map({ !snapshot.retiredCaptureSegmentIDs.contains($0.captureSegmentID) }) ?? true,
            snapshot.latestClock.map({
                snapshot.revision > 0 && ($0.authorization == .currentCapture
                    ? snapshot.retiredCaptureSegmentIDs.isEmpty
                    : $0.epoch == UInt64(snapshot.retiredCaptureSegmentIDs.count) + 1)
            }) ?? snapshot.retiredCaptureSegmentIDs.isEmpty,
            snapshot.recentDeltas.count <= policy.maximumRetainedDeltaCount,
            snapshot.rememberedUpdateIDs.count <= policy.maximumRememberedUpdateCount,
            Set(snapshot.rememberedUpdateIDs).count == snapshot.rememberedUpdateIDs.count,
            (snapshot.revision == 0) == (snapshot.latestSequence == nil),
            (snapshot.revision == 0) == (snapshot.latestTimestamp == nil)
        else {
            throw TemporalSpatialMemoryError.invalidSnapshot
        }
        if let latestDeltaClock = snapshot.recentDeltas.last?.clock,
            snapshot.latestClock != latestDeltaClock {
            throw TemporalSpatialMemoryError.invalidSnapshot
        }

        for (objectID, state) in snapshot.objectStates {
            guard state.metadata.object.id == objectID else {
                throw TemporalSpatialMemoryError.snapshotObjectKeyMismatch(objectID)
            }
            guard state.metadata.mapID == snapshot.mapID else {
                throw TemporalSpatialMemoryError.mapMismatch(
                    expected: snapshot.mapID,
                    actual: state.metadata.mapID
                )
            }
            guard state.metadata.position.coordinateFrameID == snapshot.coordinateFrameID else {
                throw TemporalSpatialMemoryError.coordinateFrameMismatch(
                    expected: snapshot.coordinateFrameID,
                    actual: state.metadata.position.coordinateFrameID
                )
            }
            guard state.metadata.object.certainty == .confirmed,
                state.metadata.object.temporalRevision.map({ $0 > 0 && $0 <= snapshot.revision }) ?? true,
                state.consecutiveMissCount >= 0,
                state.consecutiveMissCount <= policy.minimumMissesForRemoval,
                state.pendingMovementSamples.count <= policy.maximumPendingMovementCount,
                (state.consecutiveMissCount == 0) == (state.firstMissedAt == nil),
                (state.consecutiveMissCount == 0) == (state.lastMissedAt == nil),
                state.firstMissedAt.map({ $0.isFinite && $0 >= 0 }) ?? true,
                state.lastMissedAt.map({ $0.isFinite && $0 >= 0 }) ?? true,
                state.lastMissedAt.map({ last in
                    state.firstMissedAt.map({ $0 <= last }) ?? false
                }) ?? true,
                snapshot.latestClock.map({ clock in
                    state.lastMissedAt.map({ $0 <= clock.monotonicTimestamp }) ?? true
                }) ?? true
            else {
                throw TemporalSpatialMemoryError.invalidSnapshot
            }
            for sample in state.pendingMovementSamples {
                guard sample.position.coordinateFrameID == snapshot.coordinateFrameID,
                    sample.position.trackingQuality == .normal,
                    sample.monotonicTimestamp.map({ $0.isFinite && $0 >= 0 }) ?? true,
                    snapshot.latestClock.map({ clock in
                        sample.monotonicTimestamp.map({ $0 <= clock.monotonicTimestamp }) ?? false
                    }) ?? true
                else {
                    throw TemporalSpatialMemoryError.invalidSnapshot
                }
            }
        }

        var previousRevision: UInt64?
        for delta in snapshot.recentDeltas {
            let (expectedRevision, revisionOverflow) =
                delta.baseRevision.addingReportingOverflow(1)
            guard delta.mapID == snapshot.mapID,
                delta.coordinateFrameID == snapshot.coordinateFrameID,
                !revisionOverflow,
                delta.newRevision == expectedRevision,
                delta.newRevision <= snapshot.revision,
                delta.spatialDelta.id == delta.id,
                delta.spatialDelta.baseRevision == delta.baseRevision,
                delta.timestamp.isFinite,
                delta.timestamp >= 0,
                previousRevision.map({ delta.newRevision > $0 }) ?? true
            else {
                throw TemporalSpatialMemoryError.invalidSnapshot
            }
            previousRevision = delta.newRevision
        }
    }
}
