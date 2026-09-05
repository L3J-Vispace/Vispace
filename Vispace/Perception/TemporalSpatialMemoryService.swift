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

    private struct MapFrameKey: Hashable, Sendable {
        let mapID: MapID
        let coordinateFrameID: CoordinateFrameID
    }

    private let journalRepository: TemporalSpatialMemoryJournalRepository
    private let metadataProvider: MetadataProvider
    private let metadataWriter: MetadataWriter
    private let policy: TemporalSpatialMemoryPolicy
    private var coordinators: [MapFrameKey: TemporalSpatialMemoryCoordinator] = [:]
    private var projectionPending: Set<MapFrameKey> = []

    public init(
        checkpointRepository: WorldMapCheckpointRepository,
        journalRepository: TemporalSpatialMemoryJournalRepository,
        policy: TemporalSpatialMemoryPolicy = .default
    ) {
        self.journalRepository = journalRepository
        metadataProvider = {
            try await checkpointRepository.metadataSnapshot()
        }
        metadataWriter = { metadata in
            try await checkpointRepository.upsertObjectMetadata(metadata)
        }
        self.policy = policy
    }

    public init(
        journalRepository: TemporalSpatialMemoryJournalRepository,
        policy: TemporalSpatialMemoryPolicy = .default,
        metadataProvider: @escaping MetadataProvider,
        metadataWriter: @escaping MetadataWriter
    ) {
        self.journalRepository = journalRepository
        self.policy = policy
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
        let key = MapFrameKey(mapID: mapID, coordinateFrameID: coordinateFrameID)
        let document = try await validatedMetadataDocument(
            mapID: mapID,
            coordinateFrameID: coordinateFrameID
        )
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
                    forceProjection: true
                )
                projectionPending.remove(key)
            }
            return cached.snapshot
        }

        let coordinator: TemporalSpatialMemoryCoordinator
        if let recovery = try await journalRepository.recover(
            mapID: mapID,
            coordinateFrameID: coordinateFrameID
        ) {
            guard recovery.policy == policy else {
                throw TemporalSpatialMemoryServiceError.journalPolicyMismatch(mapID)
            }
            coordinator = try TemporalSpatialMemoryCoordinator(
                restoring: recovery.snapshot,
                policy: policy
            )
            try await reconcile(
                snapshot: recovery.snapshot,
                durableObjects: durableObjects
            )
        } else {
            coordinator = try TemporalSpatialMemoryCoordinator(
                mapID: mapID,
                coordinateFrameID: coordinateFrameID,
                restoringDurableObjects: durableObjects,
                policy: policy
            )
        }
        coordinators[key] = coordinator
        projectionPending.remove(key)
        return coordinator.snapshot
    }

    @discardableResult
    public func process(
        _ batch: TemporalSpatialRecognitionBatch,
        pose: ARPoseSnapshot
    ) async throws -> TemporalSpatialMemoryServiceResult {
        try Task.checkCancellation()
        let (mapID, mappingQuality) = try validatedPoseIdentity(pose)
        let key = MapFrameKey(
            mapID: mapID,
            coordinateFrameID: pose.coordinateFrameID
        )
        _ = try await recover(
            mapID: mapID,
            coordinateFrameID: pose.coordinateFrameID
        )
        guard let current = coordinators[key] else {
            throw TemporalSpatialMemoryServiceError.missingMappedIdentity
        }

        let update = try TemporalSpatialUpdate(
            id: batch.id,
            baseRevision: current.snapshot.revision,
            sequence: batch.sequence,
            timestamp: pose.capturedAt,
            mapID: mapID,
            coordinateFrameID: pose.coordinateFrameID,
            observations: batch.observations,
            expectedVisibleObjectIDs: batch.expectedVisibleObjectIDs
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
        let appendResult = try await journalRepository.append(
            entry,
            policy: policy,
            previousSnapshot: current.snapshot,
            resultingSnapshot: next.snapshot
        )
        switch appendResult {
        case .appended:
            coordinators[key] = next
        case .alreadyAppended(let recovered):
            guard recovered == next.snapshot else {
                throw TemporalSpatialMemoryJournalError.journalDiverged(mapID: mapID)
            }
            coordinators[key] = next
        }

        // The protected journal is the commit point. A cancellation or
        // filesystem error after this point is recoverable: the next `recover`
        // projects the journal snapshot back into checkpoint metadata.
        do {
            try await project(
                snapshot: next.snapshot,
                objectIDs: objectIDs(in: delta.spatialDelta.events)
            )
            projectionPending.remove(key)
        } catch {
            projectionPending.insert(key)
            throw TemporalSpatialMemoryServiceError.committedJournalProjectionPending
        }
        return .applied(delta)
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
        forceProjection: Bool = false
    ) async throws {
        let durableByID = Dictionary(
            uniqueKeysWithValues: durableObjects.map { ($0.object.id, $0) }
        )
        for (objectID, journalMetadata) in snapshot.objects.sorted(by: {
            $0.key < $1.key
        }) {
            if let durable = durableByID[objectID] {
                if durable == journalMetadata {
                    if !forceProjection {
                        continue
                    }
                } else {
                    guard
                        journalMetadata.object.stateUpdatedAt
                            > durable.object.stateUpdatedAt
                    else {
                        throw
                            TemporalSpatialMemoryServiceError
                            .durableMetadataAheadOfJournal(objectID)
                    }
                }
            }
            try Task.checkCancellation()
            try await metadataWriter(journalMetadata)
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
        objectIDs: Set<ObjectID>
    ) async throws {
        for objectID in objectIDs.sorted() {
            guard let metadata = snapshot.metadata(for: objectID) else {
                continue
            }
            try await metadataWriter(metadata)
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
