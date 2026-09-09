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
    case removedHistoryCleanupUnavailable
}

/// Recognition output accepted by temporal memory. The contained Core
/// observations already bind promotion evidence and persistent Re-ID results;
/// this batch adds a stable ingestion identity and ordering sequence.
public struct TemporalSpatialRecognitionBatch: Hashable, Sendable {
    public let id: SpatialDeltaID
    public let sequence: UInt64
    public let observations: [TemporalSpatialObservation]
    public let expectedVisibleObjectIDs: [ObjectID]
    public let classificationCorrections: [ObjectClassificationCorrection]

    public init(
        id: SpatialDeltaID = SpatialDeltaID(),
        sequence: UInt64,
        observations: [TemporalSpatialObservation],
        expectedVisibleObjectIDs: [ObjectID],
        classificationCorrections: [ObjectClassificationCorrection] = []
    ) {
        self.id = id
        self.sequence = sequence
        self.observations = observations
        self.expectedVisibleObjectIDs = expectedVisibleObjectIDs
        self.classificationCorrections = classificationCorrections
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
    public typealias MetadataBatchWriter =
        @Sendable ([SpatialObjectMetadata]) async throws
        -> Void
    public typealias MetadataRemover = @Sendable ([SpatialObjectMetadata]) async throws -> Void
    public typealias PoseValidator = @Sendable (ARPoseSnapshot) -> Bool

    private struct MapFrameKey: Hashable, Sendable {
        let mapID: MapID
        let coordinateFrameID: CoordinateFrameID
    }

    private struct OperationLease: Sendable {
        let id: UUID
        let key: MapFrameKey
        let generation: UInt64
    }

    private struct OperationWaiter {
        let lease: OperationLease
        let continuation: CheckedContinuation<OperationLease, any Error>
    }

    // Actor isolation alone does not protect read/commit/project transactions
    // across awaits. Each map/frame keeps one owner through journal publication
    // and projection so an older recovery cannot replace a newer coordinator.
    private var activeOperations: [MapFrameKey: UUID] = [:]
    private var waitingOperations: [MapFrameKey: [OperationWaiter]] = [:]

    private let journalRepository: TemporalSpatialMemoryJournalRepository
    private let metadataProvider: MetadataProvider
    private let metadataWriter: MetadataWriter
    private let metadataBatchWriter: MetadataBatchWriter?
    private let metadataRemover: MetadataRemover?
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
        metadataBatchWriter = { metadata in
            _ = try await checkpointRepository.upsertObjectMetadataBatch(metadata)
        }
        metadataRemover = { try await checkpointRepository.removeObjectMetadataIfMatching($0) }
        self.policy = policy
        self.poseValidator = poseValidator
    }

    public init(
        journalRepository: TemporalSpatialMemoryJournalRepository,
        policy: TemporalSpatialMemoryPolicy = .default,
        metadataProvider: @escaping MetadataProvider,
        metadataWriter: @escaping MetadataWriter,
        metadataBatchWriter: MetadataBatchWriter? = nil,
        metadataRemover: MetadataRemover? = nil,
        poseValidator: PoseValidator? = nil
    ) {
        self.journalRepository = journalRepository
        self.policy = policy
        self.poseValidator = poseValidator
        self.metadataProvider = metadataProvider
        self.metadataWriter = metadataWriter
        self.metadataBatchWriter = metadataBatchWriter
        self.metadataRemover = metadataRemover
    }

    /// Restores a map from a compact checkpoint plus the bounded journal
    /// suffix. On first use only, already-validated checkpoint metadata seeds
    /// revision zero without fabricating promotion observations.
    public func recover(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID
    ) async throws -> TemporalSpatialMemorySnapshot {
        let key = MapFrameKey(mapID: mapID, coordinateFrameID: coordinateFrameID)
        let lease = try await acquireOperation(for: key)
        defer { releaseOperation(lease) }
        try validateGeneration(lease.generation)
        return try await recoverWhileOwningOperation(
            mapID: mapID, coordinateFrameID: coordinateFrameID, generation: lease.generation)
    }

    private func recoverWhileOwningOperation(
        mapID: MapID, coordinateFrameID: CoordinateFrameID, generation: UInt64,
        projectsMetadata: Bool = true
    ) async throws -> TemporalSpatialMemorySnapshot {
        let key = MapFrameKey(mapID: mapID, coordinateFrameID: coordinateFrameID)
        let document = try await validatedMetadataDocument(
            mapID: mapID,
            coordinateFrameID: coordinateFrameID
        )
        try validateGeneration(generation)
        var durableObjects = objects(
            in: document,
            mapID: mapID,
            coordinateFrameID: coordinateFrameID
        )

        if let cached = coordinators[key] {
            let shouldRetryProjection = projectionPending.contains(key)
            if shouldRetryProjection || !projectsMetadata {
                try await reconcile(
                    snapshot: cached.snapshot,
                    durableObjects: durableObjects,
                    generation: generation,
                    publishesMetadata: projectsMetadata
                )
                try validateGeneration(generation)
                if projectsMetadata { projectionPending.remove(key) }
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
            if !recovery.pendingRemovedObjects.isEmpty {
                try await finishRemovedObjectReclamation(recovery.pendingRemovedObjects,
                    mapID: mapID, coordinateFrameID: coordinateFrameID, generation: generation)
                let refreshed = try await validatedMetadataDocument(mapID: mapID, coordinateFrameID: coordinateFrameID)
                try validateGeneration(generation)
                durableObjects = objects(in: refreshed, mapID: mapID, coordinateFrameID: coordinateFrameID)
            }
            coordinator = try TemporalSpatialMemoryCoordinator(
                restoring: recovery.snapshot,
                policy: policy
            )
            try await reconcile(
                snapshot: recovery.snapshot,
                durableObjects: durableObjects,
                generation: generation,
                publishesMetadata: projectsMetadata
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
                generation: generation,
                publishesMetadata: projectsMetadata
            )
        }
        try validateGeneration(generation)
        if projectsMetadata {
            coordinators[key] = coordinator
            projectionPending.remove(key)
        }
        return coordinator.snapshot
    }

    /// Call from the app's quiesced storage-maintenance boundary. Interrupted
    /// projection deletion remains journaled and is completed on cold recovery.
    @discardableResult
    public func reclaimRemovedObjectHistory(mapID: MapID, coordinateFrameID: CoordinateFrameID) async throws -> Int {
        guard metadataRemover != nil else { throw TemporalSpatialMemoryServiceError.removedHistoryCleanupUnavailable }
        let key = MapFrameKey(mapID: mapID, coordinateFrameID: coordinateFrameID)
        let lease = try await acquireOperation(for: key)
        defer { releaseOperation(lease) }
        let snapshot = try await recoverWhileOwningOperation(
            mapID: mapID, coordinateFrameID: coordinateFrameID, generation: lease.generation,
            projectsMetadata: false)
        let removed = snapshot.reclaimableRemovedObjects
        guard !removed.isEmpty else { return 0 }
        let document = try await validatedMetadataDocument(mapID: mapID, coordinateFrameID: coordinateFrameID)
        let byID = Dictionary(uniqueKeysWithValues: document.objects.map { ($0.object.id, $0) })
        let expected = removed.map { byID[$0.object.id] ?? $0 }
        try validateGeneration(lease.generation)
        let intents = try await journalRepository.beginRemovedObjectReclamation(
            expectedSnapshot: snapshot, policy: policy, expectedRemovedObjects: expected)
        // Publication can precede cancellation. Never retain the old coordinator
        // after the journal has committed the pruned snapshot.
        coordinators[key] = nil
        projectionPending.remove(key)
        try validateGeneration(lease.generation)
        try await finishRemovedObjectReclamation(intents, mapID: mapID,
            coordinateFrameID: coordinateFrameID, generation: lease.generation)
        // Normal projection replay is deferred until the next recovery. Requiring
        // an unrelated write here would make space reclamation depend on the
        // very capacity or projection failure the user is trying to recover from.
        return intents.count
    }

    private func finishRemovedObjectReclamation(
        _ intents: [SpatialObjectMetadata], mapID: MapID,
        coordinateFrameID: CoordinateFrameID, generation: UInt64
    ) async throws {
        guard let metadataRemover else { throw TemporalSpatialMemoryServiceError.removedHistoryCleanupUnavailable }
        try validateGeneration(generation)
        try await metadataRemover(intents)
        try validateGeneration(generation)
        try await journalRepository.completeRemovedObjectReclamation(mapID: mapID,
            coordinateFrameID: coordinateFrameID, expectedRemovedObjects: intents)
        try validateGeneration(generation)
    }

    @discardableResult
    public func process(
        _ batch: TemporalSpatialRecognitionBatch,
        pose: ARPoseSnapshot
    ) async throws -> TemporalSpatialMemoryServiceResult {
        try Task.checkCancellation()
        try validateCaptureAuthority(pose)
        let (mapID, _) = try validatedPoseIdentity(pose)
        let lease = try await acquireOperation(
            for: MapFrameKey(
                mapID: mapID, coordinateFrameID: pose.coordinateFrameID))
        defer { releaseOperation(lease) }
        try validateGeneration(lease.generation)
        return try await processWhileOwningOperation(batch, pose: pose, generation: lease.generation)
    }

    private func processWhileOwningOperation(
        _ batch: TemporalSpatialRecognitionBatch, pose: ARPoseSnapshot, generation: UInt64
    ) async throws -> TemporalSpatialMemoryServiceResult {
        try validateGeneration(generation)
        try validateCaptureAuthority(pose)
        let (mapID, mappingQuality) = try validatedPoseIdentity(pose)
        let key = MapFrameKey(
            mapID: mapID,
            coordinateFrameID: pose.coordinateFrameID
        )
        for observation in batch.observations where observation.identitySupport != nil {
            guard observation.promotionEvidence.captureSegmentID == pose.segmentID,
                observation.promotionEvidence.frameIDs.last == FrameID(rawValue: pose.id.rawValue)
            else {
                throw TemporalSpatialMemoryError.promotionEvidenceMismatch(observation.metadata.object.id)
            }
        }
        _ = try await recoverWhileOwningOperation(
            mapID: mapID,
            coordinateFrameID: pose.coordinateFrameID,
            generation: generation
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
            clock: clock,
            classificationCorrections: batch.classificationCorrections
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

    /// Corrects classification without manufacturing an observation or changing its location.
    @discardableResult
    public func correctClassification(
        objectID: ObjectID, semanticLabel: String,
        expectedTemporalRevision: UInt64?, pose: ARPoseSnapshot
    )
        async throws -> TemporalSpatialMemoryServiceResult
    {
        try validateCaptureAuthority(pose)
        let (mapID, _) = try validatedPoseIdentity(pose)
        let lease = try await acquireOperation(
            for: MapFrameKey(
                mapID: mapID, coordinateFrameID: pose.coordinateFrameID))
        defer { releaseOperation(lease) }
        try validateGeneration(lease.generation)
        let document = try await validatedMetadataDocument(
            mapID: mapID,
            coordinateFrameID: pose.coordinateFrameID)
        try validateGeneration(lease.generation)
        guard let metadata = document.objects.first(where: { $0.object.id == objectID }),
            metadata.mapID == mapID,
            metadata.position.coordinateFrameID == pose.coordinateFrameID,
            metadata.object.temporalRevision == expectedTemporalRevision
        else { throw TemporalSpatialMemoryError.staleClassificationCorrection(objectID) }
        let correction = try ObjectClassificationCorrection(
            objectID: objectID,
            expectedSemanticLabel: metadata.object.semanticLabel,
            expectedTemporalRevision: expectedTemporalRevision,
            semanticLabel: semanticLabel, displayName: metadata.object.displayName)
        return try await processWhileOwningOperation(
            TemporalSpatialRecognitionBatch(
                sequence: 0, observations: [],
                expectedVisibleObjectIDs: [], classificationCorrections: [correction]),
            pose: pose, generation: lease.generation)
    }

    /// Call after ingestion has stopped and before deleting durable storage.
    /// In-flight recovery cannot repopulate an erased map's in-memory state.
    public func reset() {
        resetGeneration &+= 1
        coordinators.removeAll()
        projectionPending.removeAll()
        activeOperations.removeAll()
        let cancelled = waitingOperations.values.flatMap { $0 }
        waitingOperations.removeAll()
        for waiter in cancelled { waiter.continuation.resume(throwing: CancellationError()) }
    }

    private func acquireOperation(for key: MapFrameKey) async throws -> OperationLease {
        let lease = OperationLease(id: UUID(), key: key, generation: resetGeneration)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if activeOperations[key] == nil {
                    activeOperations[key] = lease.id
                    continuation.resume(returning: lease)
                } else {
                    waitingOperations[key, default: []].append(
                        OperationWaiter(lease: lease, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaitingOperation(lease) }
        }
    }

    private func cancelWaitingOperation(_ lease: OperationLease) {
        guard let index = waitingOperations[lease.key]?.firstIndex(where: { $0.lease.id == lease.id }) else {
            return
        }
        let waiter = waitingOperations[lease.key]!.remove(at: index)
        if waitingOperations[lease.key]?.isEmpty == true { waitingOperations.removeValue(forKey: lease.key) }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseOperation(_ lease: OperationLease) {
        guard resetGeneration == lease.generation, activeOperations[lease.key] == lease.id else { return }
        if var waiting = waitingOperations[lease.key], !waiting.isEmpty {
            let next = waiting.removeFirst()
            waitingOperations[lease.key] = waiting.isEmpty ? nil : waiting
            activeOperations[lease.key] = next.lease.id
            next.continuation.resume(returning: next.lease)
        } else {
            activeOperations.removeValue(forKey: lease.key)
        }
    }

    var pendingOperationCountForTesting: Int {
        waitingOperations.values.reduce(0) { $0 + $1.count }
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
                    && !Self.isUserRegisteredPoint($0)
            }
            .sorted { $0.object.id < $1.object.id }
    }

    /// Explicitly named points are durable annotations, outside the automatic
    /// observation journal. Keep them in the repository for search/export and
    /// capacity accounting, but never seed or reconcile them as detector IDs.
    /// All other untracked durable objects still fail the journal invariant.
    private static func isUserRegisteredPoint(_ metadata: SpatialObjectMetadata) -> Bool {
        let object = metadata.object
        return object.semanticLabel == UserObjectRegistrationAccumulator.semanticLabel
            && object.displayName != nil && object.detectorSemanticLabel == nil
            && object.bounds == nil && object.presence == .lastSeen
            && object.temporalRevision == nil
    }

    private func reconcile(
        snapshot: TemporalSpatialMemorySnapshot,
        durableObjects: [SpatialObjectMetadata],
        generation: UInt64,
        publishesMetadata: Bool = true
    ) async throws {
        let durableByID = Dictionary(
            uniqueKeysWithValues: durableObjects.map { ($0.object.id, $0) }
        )
        let orderedObjects = snapshot.objects.sorted { $0.key < $1.key }
        for (objectID, journalMetadata) in orderedObjects {
            try validateGeneration(generation)
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
        guard publishesMetadata else { return }
        // Equal metadata does not prove that downstream projections committed.
        // Replay the whole validated snapshot, using a single catalog transaction
        // when the caller supplies a writer that also reconciles its projections.
        try validateGeneration(generation)
        if let metadataBatchWriter, !orderedObjects.isEmpty {
            try await metadataBatchWriter(orderedObjects.map(\.value))
            try validateGeneration(generation)
        } else {
            for (_, metadata) in orderedObjects {
                try validateGeneration(generation)
                try await metadataWriter(metadata)
                try validateGeneration(generation)
            }
        }
    }

    private func project(
        snapshot: TemporalSpatialMemorySnapshot,
        objectIDs: Set<ObjectID>,
        generation: UInt64
    ) async throws {
        let metadata = objectIDs.sorted().compactMap { snapshot.metadata(for: $0) }
        try validateGeneration(generation)
        if metadata.count > 1, let metadataBatchWriter {
            try await metadataBatchWriter(metadata)
            try validateGeneration(generation)
            return
        }
        for metadata in metadata {
            try validateGeneration(generation)
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
