import Foundation
import VispaceCore

public enum TemporalSpatialMemoryServiceError: Error, Equatable, Sendable {
    case coordinateFrameUnconfirmed
    case missingMappedIdentity
    case trackingIsNotNormal
    case mappingIsNotReliable
    case invalidPoseTimestamp
    case unknownOrQuarantinedMap(MapID)
    case mapCoordinateFrameMismatch(MapID)
    case journalPolicyMismatch(MapID)
    case durableMetadataAheadOfJournal(ObjectID)
    case untrackedDurableObject(ObjectID)
    case committedJournalProjectionPending
    case captureAuthorityRequired
    case captureAuthorityMismatch
}

/// Recognition output accepted by temporal memory. The contained Core
/// observations already bind promotion evidence and persistent Re-ID results;
/// this batch adds a stable ingestion identity and ordering sequence.
public struct TemporalSpatialRecognitionBatch: Hashable, Sendable {
    public let id: SpatialDeltaID
    public let sequence: UInt64
    public let observations: [TemporalSpatialObservation]
    public let expectedVisibleObjectIDs: [ObjectID]

    public init(
        id: SpatialDeltaID = SpatialDeltaID(),
        sequence: UInt64,
        observations: [TemporalSpatialObservation],
        expectedVisibleObjectIDs: [ObjectID]
    ) {
        self.id = id
        self.sequence = sequence
        self.observations = observations
        self.expectedVisibleObjectIDs = expectedVisibleObjectIDs
    }
}

public enum TemporalSpatialMemoryServiceResult: Equatable, Sendable {
    case applied(TemporalSpatialDelta)
    case alreadyProcessed(TemporalSpatialMemorySnapshot)
}

/// Joins confirmed AR pose provenance, recognized objects, the durable world
/// map catalog, and the temporal journal. Every update is built and reduced in
/// a local copy; actor state changes only after the protected journal commit.
public actor TemporalSpatialMemoryService {
    public typealias MetadataProvider =
        @Sendable () async throws
        -> SpatialMetadataDocument
    public typealias MetadataWriter =
        @Sendable (SpatialObjectMetadata) async throws
        -> Void
    public typealias PoseValidator = @Sendable (ARPoseSnapshot) -> Bool

    private struct MapFrameKey: Hashable, Sendable {
        let mapID: MapID
        let coordinateFrameID: CoordinateFrameID
    }

    private let journalRepository: TemporalSpatialMemoryJournalRepository
    private let metadataProvider: MetadataProvider
    private let metadataWriter: MetadataWriter
    private let policy: TemporalSpatialMemoryPolicy
    private let poseValidator: PoseValidator?
    private var coordinators: [MapFrameKey: TemporalSpatialMemoryCoordinator] = [:]
    private var projectionPending: Set<MapFrameKey> = []
    private var resetGeneration: UInt64 = 0

    public init(
        checkpointRepository: WorldMapCheckpointRepository,
        journalRepository: TemporalSpatialMemoryJournalRepository,
        policy: TemporalSpatialMemoryPolicy = .default,
        poseValidator: PoseValidator? = nil
    ) {
        self.journalRepository = journalRepository
        metadataProvider = {
            try await checkpointRepository.metadataSnapshot()
        }
        metadataWriter = { metadata in
            try await checkpointRepository.upsertObjectMetadata(metadata)
        }
        self.policy = policy
        self.poseValidator = poseValidator
    }

    public init(
        journalRepository: TemporalSpatialMemoryJournalRepository,
        policy: TemporalSpatialMemoryPolicy = .default,
        metadataProvider: @escaping MetadataProvider,
        metadataWriter: @escaping MetadataWriter,
        poseValidator: PoseValidator? = nil
    ) {
        self.journalRepository = journalRepository
        self.policy = policy
        self.poseValidator = poseValidator
        self.metadataProvider = metadataProvider
        self.metadataWriter = metadataWriter
    }

    /// Restores a map from a compact checkpoint plus the bounded journal
    /// suffix. On first use only, already-validated checkpoint metadata seeds
    /// revision zero without fabricating promotion observations.
    public func recover(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID
    ) async throws -> TemporalSpatialMemorySnapshot {
        let generation = resetGeneration
        let key = MapFrameKey(mapID: mapID, coordinateFrameID: coordinateFrameID)
        let document = try await validatedMetadataDocument(
            mapID: mapID,
            coordinateFrameID: coordinateFrameID
        )
        try validateGeneration(generation)
        let durableObjects = objects(
            in: document,
            mapID: mapID,
            coordinateFrameID: coordinateFrameID
        )

        if let cached = coordinators[key] {
            let shouldRetryProjection = projectionPending.contains(key)
            if shouldRetryProjection {
                try await reconcile(
                    snapshot: cached.snapshot,
                    durableObjects: durableObjects,
                    generation: generation
                )
                try validateGeneration(generation)
                projectionPending.remove(key)
            }
            return cached.snapshot
        }

        let coordinator: TemporalSpatialMemoryCoordinator
        if let recovery = try await journalRepository.recover(
            mapID: mapID,
            coordinateFrameID: coordinateFrameID
        ) {
            try validateGeneration(generation)
            guard recovery.policy == policy else {
                throw TemporalSpatialMemoryServiceError.journalPolicyMismatch(mapID)
            }
            coordinator = try TemporalSpatialMemoryCoordinator(
                restoring: recovery.snapshot,
                policy: policy
            )
            try await reconcile(
                snapshot: recovery.snapshot,
                durableObjects: durableObjects,
                generation: generation
            )
        } else {
            coordinator = try TemporalSpatialMemoryCoordinator(
                mapID: mapID,
                coordinateFrameID: coordinateFrameID,
                restoringDurableObjects: durableObjects,
                policy: policy
            )
            // A portable import contains checkpoint metadata but intentionally
            // omits derived journals/relations. Rebuild those projections from
            // the validated seed without inventing observation evidence.
            try await reconcile(
                snapshot: coordinator.snapshot,
                durableObjects: durableObjects,
                generation: generation
            )
        }
        try validateGeneration(generation)
        coordinators[key] = coordinator
        projectionPending.remove(key)
        return coordinator.snapshot
    }

    @discardableResult
    public func process(
        _ batch: TemporalSpatialRecognitionBatch,
        pose: ARPoseSnapshot
    ) async throws -> TemporalSpatialMemoryServiceResult {
        let generation = resetGeneration
        try Task.checkCancellation()
        try validateCaptureAuthority(pose)
        let (mapID, mappingQuality) = try validatedPoseIdentity(pose)
        let key = MapFrameKey(
            mapID: mapID,
            coordinateFrameID: pose.coordinateFrameID
        )
        _ = try await recover(
            mapID: mapID,
            coordinateFrameID: pose.coordinateFrameID
        )
        try validateGeneration(generation)
        try validateCaptureAuthority(pose)
        guard let current = coordinators[key] else {
            throw TemporalSpatialMemoryServiceError.missingMappedIdentity
        }

        let previousClock = current.snapshot.latestClock
        guard poseValidator != nil || previousClock?.authorization != .currentCapture else {
            throw TemporalSpatialMemoryServiceError.captureAuthorityRequired
        }
        let epoch: UInt64
        if let previousClock, previousClock.captureSegmentID == pose.segmentID {
            epoch = previousClock.epoch
        } else {
            let (nextEpoch, overflow) = (previousClock?.epoch ?? 0).addingReportingOverflow(1)
            guard !overflow else { throw TemporalSpatialMemoryError.invalidClock }
            epoch = nextEpoch
        }
        let (nextSequence, sequenceOverflow) = (current.snapshot.latestSequence ?? 0)
            .addingReportingOverflow(1)
        guard !sequenceOverflow else { throw TemporalSpatialMemoryError.revisionOverflow }
        let clock = try TemporalSpatialClock(
            epoch: epoch, captureSegmentID: pose.segmentID, monotonicTimestamp: pose.timestamp,
            authorization: poseValidator == nil ? .recordedSegments : .currentCapture
        )

        let update = try TemporalSpatialUpdate(
            id: batch.id,
            baseRevision: current.snapshot.revision,
            sequence: max(nextSequence, batch.sequence),
            timestamp: pose.capturedAt,
            mapID: mapID,
            coordinateFrameID: pose.coordinateFrameID,
            observations: batch.observations,
            expectedVisibleObjectIDs: batch.expectedVisibleObjectIDs,
            clock: clock
        )
        var next = current
        let application = try next.apply(update)
        guard case .applied(let delta) = application else {
            return .alreadyProcessed(current.snapshot)
        }
        let provenance = try TemporalSpatialPoseProvenance(
            frameID: FrameID(rawValue: pose.id.rawValue),
            sessionRunGeneration: pose.sessionToken.sessionRunGeneration,
            attachmentEpoch: pose.sessionToken.attachmentEpoch,
            captureSegmentID: pose.segmentID,
            mapID: mapID,
            coordinateFrameID: pose.coordinateFrameID,
            capturedAt: pose.capturedAt,
            sessionTimestamp: pose.timestamp,
            cameraTransform: pose.cameraTransform.coreTransform(),
            trackingQuality: .normal,
            mappingQuality: mappingQuality
        )
        let entry = try TemporalSpatialMemoryJournalEntry(
            provenance: provenance,
            update: update,
            delta: delta
        )

        try Task.checkCancellation()
        try validateCaptureAuthority(pose)
        let validateBeforeCommit: @Sendable () throws -> Void = { [poseValidator] in
            if let poseValidator, !poseValidator(pose) {
                throw TemporalSpatialMemoryServiceError.captureAuthorityMismatch
            }
        }
        let appendResult = try await journalRepository.append(
            entry,
            policy: policy,
            previousSnapshot: current.snapshot,
            resultingSnapshot: next.snapshot,
            validateBeforeCommit: validateBeforeCommit
        )
        // Once append returns, the journal is durable even if this task was
        // cancelled during its synchronous file write. Publish recovery state
        // before observing cancellation, but never cross a real deletion reset.
        try validateResetGeneration(generation)
        switch appendResult {
        case .appended:
            coordinators[key] = next
        case .alreadyAppended(let recovered):
            guard recovered == next.snapshot else {
                throw TemporalSpatialMemoryJournalError.journalDiverged(mapID: mapID)
            }
            coordinators[key] = next
        }
        projectionPending.insert(key)
        try Task.checkCancellation()

        // The protected journal is the commit point. A cancellation or
        // filesystem error after this point is recoverable: the next `recover`
        // projects the journal snapshot back into checkpoint metadata.
        do {
            try await project(
                snapshot: next.snapshot,
                objectIDs: objectIDs(in: delta.spatialDelta.events),
                generation: generation
            )
            try validateGeneration(generation)
            projectionPending.remove(key)
        } catch {
            try validateResetGeneration(generation)
            if error is CancellationError { throw error }
            throw TemporalSpatialMemoryServiceError.committedJournalProjectionPending
        }
        return .applied(delta)
    }

    /// Call after ingestion has stopped and before deleting durable storage.
    /// In-flight recovery cannot repopulate an erased map's in-memory state.
    public func reset() {
        resetGeneration &+= 1
        coordinators.removeAll()
        projectionPending.removeAll()
    }

    private func validateGeneration(_ generation: UInt64) throws {
        try Task.checkCancellation()
        try validateResetGeneration(generation)
    }

    private func validateResetGeneration(_ generation: UInt64) throws {
        guard generation == resetGeneration else {
            throw CancellationError()
        }
    }

    private func validateCaptureAuthority(_ pose: ARPoseSnapshot) throws {
        if let poseValidator, !poseValidator(pose) {
            throw TemporalSpatialMemoryServiceError.captureAuthorityMismatch
        }
    }

    private func validatedPoseIdentity(
        _ pose: ARPoseSnapshot
    ) throws -> (MapID, TemporalSpatialMappingQuality) {
        guard pose.coordinateFrameStatus == .confirmed else {
            throw TemporalSpatialMemoryServiceError.coordinateFrameUnconfirmed
        }
        guard let mapID = pose.mapID else {
            throw TemporalSpatialMemoryServiceError.missingMappedIdentity
        }
        guard pose.trackingState == .normal else {
            throw TemporalSpatialMemoryServiceError.trackingIsNotNormal
        }
        let mappingQuality: TemporalSpatialMappingQuality
        switch pose.worldMappingStatus {
        case .mapped:
            mappingQuality = .mapped
        case .extending:
            mappingQuality = .extending
        case .notAvailable, .limited, .unknown:
            throw TemporalSpatialMemoryServiceError.mappingIsNotReliable
        }
        guard pose.capturedAt.isFinite, pose.capturedAt >= 0,
            pose.timestamp.isFinite, pose.timestamp >= 0
        else {
            throw TemporalSpatialMemoryServiceError.invalidPoseTimestamp
        }
        return (mapID, mappingQuality)
    }

    private func validatedMetadataDocument(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID
    ) async throws -> SpatialMetadataDocument {
        try Task.checkCancellation()
        let document = try await metadataProvider()
        try Task.checkCancellation()
        try document.validate()
        let matchingMaps = document.maps.filter { $0.mapID == mapID }
        guard matchingMaps.contains(where: { $0.availability == .active }) else {
            throw TemporalSpatialMemoryServiceError.unknownOrQuarantinedMap(mapID)
        }
        guard
            matchingMaps.allSatisfy({
                $0.coordinateFrameID == coordinateFrameID
            })
        else {
            throw TemporalSpatialMemoryServiceError.mapCoordinateFrameMismatch(mapID)
        }
        return document
    }

    private func objects(
        in document: SpatialMetadataDocument,
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID
    ) -> [SpatialObjectMetadata] {
        document.objects
            .filter {
                $0.mapID == mapID
                    && $0.position.coordinateFrameID == coordinateFrameID
            }
            .sorted { $0.object.id < $1.object.id }
    }

    private func reconcile(
        snapshot: TemporalSpatialMemorySnapshot,
        durableObjects: [SpatialObjectMetadata],
        generation: UInt64
    ) async throws {
        let durableByID = Dictionary(
            uniqueKeysWithValues: durableObjects.map { ($0.object.id, $0) }
        )
        for (objectID, journalMetadata) in snapshot.objects.sorted(by: {
            $0.key < $1.key
        }) {
            if let durable = durableByID[objectID] {
                var comparableObject = durable.object
                try comparableObject.setDisplayName(journalMetadata.object.displayName)
                let comparableDurable = try SpatialObjectMetadata(
                    mapID: durable.mapID, object: comparableObject, position: durable.position
                )
                if comparableDurable != journalMetadata {
                    let newer: Bool
                    switch (journalMetadata.object.temporalRevision, durable.object.temporalRevision) {
                    case (.some(let incoming), .some(let existing)): newer = incoming > existing
                    case (.some, .none): newer = true
                    case (.none, .some): newer = false
                    case (.none, .none): newer = journalMetadata.object.stateUpdatedAt > durable.object.stateUpdatedAt
                    }
                    guard newer else {
                        throw
                            TemporalSpatialMemoryServiceError
                            .durableMetadataAheadOfJournal(objectID)
                    }
                }
            }
            // Equal object metadata does not prove that downstream projections
            // (such as scene relations) committed before a process interruption.
            // Reapply the complete idempotent writer on every cold recovery.
            try validateGeneration(generation)
            try await metadataWriter(journalMetadata)
            try validateGeneration(generation)
        }
        let journalIDs = Set(snapshot.objects.keys)
        if let untracked = durableObjects.lazy
            .map(\.object.id)
            .filter({ !journalIDs.contains($0) })
            .sorted()
            .first
        {
            throw TemporalSpatialMemoryServiceError.untrackedDurableObject(untracked)
        }
    }

    private func project(
        snapshot: TemporalSpatialMemorySnapshot,
        objectIDs: Set<ObjectID>,
        generation: UInt64
    ) async throws {
        for objectID in objectIDs.sorted() {
            try validateGeneration(generation)
            guard let metadata = snapshot.metadata(for: objectID) else {
                continue
            }
            try await metadataWriter(metadata)
            try validateGeneration(generation)
        }
    }

    private func objectIDs(in events: [ObjectEvent]) -> Set<ObjectID> {
        Set(
            events.compactMap { event -> ObjectID? in
                switch event {
                case .upsert(let object):
                    object.id
                case .observed(let objectID, _, _, _, _),
                    .becameNotVisible(let objectID, _),
                    .becameLastSeen(let objectID, _),
                    .moved(let objectID, _, _, _, _),
                    .removed(let objectID, _, _),
                    .discardProvisional(let objectID):
                    objectID
                }
            })
    }
}
