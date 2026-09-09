import Foundation
import OSLog
import VispaceCore

public struct WorldMapRestoreCandidate: Sendable {
    public let metadata: SpatialMapMetadata
    public let archive: Data
    public let objects: [SpatialObjectMetadata]
}

public enum WorldMapCheckpointRepositoryError: Error, Equatable, Sendable {
    case metadataTooLarge(actual: Int, maximum: Int)
    case metadataFileUnavailable
    case unconfirmedCoordinateFrame
    case unknownOrQuarantinedMap
    case coordinateFrameMismatch
    case staleObjectUpdate(ObjectID)
    case objectAnnotationConflict(ObjectID)
    case logicalMapCapacityReached(maximum: Int)
    case importedMapAlreadyExists(MapID)
    case importedCoordinateFrameAlreadyExists(CoordinateFrameID)
    case importedObjectAlreadyExists(ObjectID)
}

/// Transaction boundary joining protected ARWorldMap blobs with versioned map
/// and object metadata. Blobs are committed first; the metadata catalog then
/// atomically publishes the checkpoint as a restore candidate.
public actor WorldMapCheckpointRepository {
    public static let maximumMetadataBytes = 16 * 1_024 * 1_024
    public static let defaultMaximumCheckpointsPerMap = 4
    public static let defaultMaximumLogicalMaps = 32

    private let directoryURL: URL
    private let metadataURL: URL
    private let blobStore: ARWorldMapBlobStore
    private let fileManager: FileManager
    private let maximumCheckpointsPerMap: Int
    private let maximumLogicalMaps: Int
    private let operationGate = AsyncOperationGate()
    private let logger = Logger(
        subsystem: "com.l3j.vispace",
        category: "world-map-checkpoints"
    )

    public init(
        directoryURL: URL,
        blobStore: ARWorldMapBlobStore? = nil,
        maximumCheckpointsPerMap: Int = WorldMapCheckpointRepository
            .defaultMaximumCheckpointsPerMap,
        maximumLogicalMaps: Int = WorldMapCheckpointRepository.defaultMaximumLogicalMaps,
        fileManager: FileManager = .default
    ) {
        let standardizedDirectory = directoryURL.standardizedFileURL
        self.directoryURL = standardizedDirectory
        metadataURL = standardizedDirectory.appendingPathComponent(
            "spatial-metadata-v1.json",
            isDirectory: false
        )
        self.fileManager = fileManager
        self.maximumCheckpointsPerMap = max(2, maximumCheckpointsPerMap)
        self.maximumLogicalMaps = max(1, maximumLogicalMaps)
        self.blobStore =
            blobStore
            ?? ARWorldMapBlobStore(
                directoryURL: standardizedDirectory.appendingPathComponent(
                    "WorldMaps",
                    isDirectory: true
                )
            )
    }

    @discardableResult
    public func saveCheckpoint(
        archive: Data,
        captureIdentity: ARCaptureIdentity,
        savedAt: Date = Date()
    ) async throws -> SpatialMapMetadata {
        try Task.checkCancellation()
        await operationGate.acquire()
        do {
            try Task.checkCancellation()
            let metadata = try await saveCheckpointLocked(
                archive: archive,
                captureIdentity: captureIdentity,
                savedAt: savedAt
            )
            await operationGate.release()
            return metadata
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func saveCheckpointLocked(
        archive: Data,
        captureIdentity: ARCaptureIdentity,
        savedAt: Date
    ) async throws -> SpatialMapMetadata {
        guard captureIdentity.status == .confirmed else {
            throw WorldMapCheckpointRepositoryError.unconfirmedCoordinateFrame
        }
        try Task.checkCancellation()
        var document = try loadDocumentRecoveringInvalidCatalog()
        await reconcileDetachedBlobs(referencedBy: document)
        try Task.checkCancellation()
        let mapID = captureIdentity.mapID ?? MapID()
        let logicalMapIDs = Set(
            document.maps.lazy
                .filter { $0.availability == .active }
                .map(\.mapID)
        )
        guard logicalMapIDs.contains(mapID) || logicalMapIDs.count < maximumLogicalMaps else {
            throw WorldMapCheckpointRepositoryError.logicalMapCapacityReached(
                maximum: maximumLogicalMaps
            )
        }
        if let mapID = captureIdentity.mapID,
            let existing = document.maps.first(where: { $0.mapID == mapID }),
            existing.coordinateFrameID != captureIdentity.coordinateFrameID
        {
            throw WorldMapCheckpointRepositoryError.coordinateFrameMismatch
        }
        let timestamp = max(0, savedAt.timeIntervalSince1970)
        guard timestamp.isFinite else {
            throw SpatialCaptureMetadataError.invalidTimestamp
        }
        let createdAt =
            document.maps
            .filter { $0.mapID == mapID }
            .map(\.createdAt)
            .min() ?? timestamp
        let latestUpdate = document.maps
            .filter { $0.mapID == mapID }
            .map(\.updatedAt)
            .max()
        let updatedAt: TimeInterval
        if let latestUpdate {
            let nextUpdate = latestUpdate.nextUp
            guard nextUpdate.isFinite else {
                throw SpatialCaptureMetadataError.invalidTimestamp
            }
            updatedAt = max(timestamp, nextUpdate)
        } else {
            updatedAt = max(createdAt, timestamp)
        }
        let blobID = WorldMapBlobID()
        let metadata = try SpatialMapMetadata(
            mapID: mapID,
            coordinateFrameID: captureIdentity.coordinateFrameID,
            latestSegmentID: captureIdentity.segmentID,
            worldMapBlobID: blobID.rawValue,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        document.maps.append(metadata)
        let activeForLogicalMap = document.maps
            .filter { $0.mapID == mapID && $0.availability == .active }
            .sorted { left, right in
                if left.updatedAt != right.updatedAt {
                    return left.updatedAt > right.updatedAt
                }
                return left.worldMapBlobID.uuidString > right.worldMapBlobID.uuidString
            }
        let superseded = Array(activeForLogicalMap.dropFirst(maximumCheckpointsPerMap))
        var removableBlobIDs: [UUID] = []
        var quarantineActions: [(id: UUID, reason: String)] = []
        for candidate in superseded {
            let candidateID = WorldMapBlobID(rawValue: candidate.worldMapBlobID)
            do {
                _ = try await blobStore.loadArchive(id: candidateID)
                removableBlobIDs.append(candidate.worldMapBlobID)
            } catch {
                try Task.checkCancellation()
                let reason = String(describing: error)
                if let blobError = error as? WorldMapBlobStoreError,
                    blobError == .blobNotFound
                {
                    if let index = document.maps.firstIndex(where: {
                        $0.worldMapBlobID == candidate.worldMapBlobID
                    }) {
                        document.maps[index] = try quarantinedMetadata(
                            from: candidate,
                            reason: reason
                        )
                    }
                    continue
                }
                guard Self.isDeterministicIntegrityFailure(error) else {
                    throw error
                }
                if let index = document.maps.firstIndex(where: {
                    $0.worldMapBlobID == candidate.worldMapBlobID
                }) {
                    document.maps[index] = try quarantinedMetadata(
                        from: candidate,
                        reason: reason
                    )
                }
                quarantineActions.append((candidate.worldMapBlobID, reason))
            }
        }
        let removableSet = Set(removableBlobIDs)
        document.maps.removeAll { removableSet.contains($0.worldMapBlobID) }

        try Task.checkCancellation()
        _ = try await blobStore.saveArchive(
            archive,
            id: blobID,
            createdAt: savedAt
        )
        try Task.checkCancellation()
        do {
            try commit(document)
        } catch {
            // The bytes are preserved for recovery/inspection. If this move is
            // interrupted, the next repository entry quarantines the detached
            // typed blob by comparing it with the durable catalog.
            _ = try? await blobStore.quarantine(
                id: blobID,
                reason: "Checkpoint catalog commit failed: \(String(describing: error))"
            )
            throw error
        }

        // The catalog is already durable. Maintenance failure must not report
        // the new checkpoint as failed; retry/reconciliation occurs on the next
        // repository entry and never deletes an unverified blob.
        for action in quarantineActions {
            _ = try? await blobStore.quarantine(
                id: WorldMapBlobID(rawValue: action.id),
                reason: action.reason
            )
        }
        for supersededBlobID in removableBlobIDs {
            let typedID = WorldMapBlobID(rawValue: supersededBlobID)
            do {
                try await blobStore.removeSupersededArchive(id: typedID)
            } catch {
                if Self.isDeterministicIntegrityFailure(error) {
                    _ = try? await blobStore.quarantine(
                        id: typedID,
                        reason: "Superseded checkpoint failed validation: \(String(describing: error))"
                    )
                }
            }
        }
        return metadata
    }

    /// Returns the newest valid checkpoint. Invalid candidates are preserved in
    /// quarantine with a reason, marked in metadata, and older checkpoints are
    /// tried in descending update order.
    public func loadLatestValidCheckpoint(mapID: MapID? = nil) async throws -> WorldMapRestoreCandidate? {
        try Task.checkCancellation()
        await operationGate.acquire()
        do {
            try Task.checkCancellation()
            let candidate = try await loadLatestValidCheckpointLocked(mapID: mapID)
            await operationGate.release()
            return candidate
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func loadLatestValidCheckpointLocked(mapID: MapID?) async throws -> WorldMapRestoreCandidate? {
        try Task.checkCancellation()
        var document = try loadDocumentRecoveringInvalidCatalog()
        await reconcileDetachedBlobs(referencedBy: document)
        try Task.checkCancellation()
        let orderedIndices = document.maps.indices
            .filter { document.maps[$0].availability == .active && (mapID == nil || document.maps[$0].mapID == mapID) }
            .sorted { lhs, rhs in
                let left = document.maps[lhs]
                let right = document.maps[rhs]
                if left.updatedAt != right.updatedAt {
                    return left.updatedAt > right.updatedAt
                }
                return left.worldMapBlobID.uuidString > right.worldMapBlobID.uuidString
            }

        var changed = false
        for index in orderedIndices {
            try Task.checkCancellation()
            let metadata = document.maps[index]
            let blobID = WorldMapBlobID(rawValue: metadata.worldMapBlobID)
            do {
                let archive = try await blobStore.loadArchive(id: blobID)
                try Task.checkCancellation()
                if changed {
                    try commit(document)
                }
                let objects = document.objects.filter { object in
                    object.mapID == metadata.mapID
                        && object.position.coordinateFrameID == metadata.coordinateFrameID
                }
                return WorldMapRestoreCandidate(
                    metadata: metadata,
                    archive: archive,
                    objects: objects
                )
            } catch {
                // This catch also receives the explicit cancellation check
                // immediately after a successful blob read. Never turn that
                // cancellation into a quarantine or catalog commit.
                try Task.checkCancellation()
                let reason = String(describing: error)
                if let blobError = error as? WorldMapBlobStoreError,
                    blobError == .blobNotFound
                {
                    document.maps[index] = try quarantinedMetadata(
                        from: metadata,
                        reason: reason
                    )
                    changed = true
                    continue
                }
                guard Self.isDeterministicIntegrityFailure(error) else {
                    if changed {
                        try commit(document)
                    }
                    throw error
                }
                // Publish the metadata state change only after the exact bytes
                // were successfully preserved in quarantine.
                _ = try await blobStore.quarantine(id: blobID, reason: reason)
                try Task.checkCancellation()
                document.maps[index] = try quarantinedMetadata(
                    from: metadata,
                    reason: reason
                )
                changed = true
            }
        }

        if changed {
            try Task.checkCancellation()
            try commit(document)
        }
        return nil
    }

    public func metadataSnapshot() async throws -> SpatialMetadataDocument {
        try Task.checkCancellation()
        await operationGate.acquire()
        do {
            try Task.checkCancellation()
            let document = try loadDocumentRecoveringInvalidCatalog()
            await reconcileDetachedBlobs(referencedBy: document)
            try Task.checkCancellation()
            await operationGate.release()
            return document
        } catch {
            await operationGate.release()
            throw error
        }
    }

    /// Annotation transaction: factual observation times and temporal revision
    /// stay unchanged, and concurrent perception updates keep their coordinates.
    @discardableResult
    public func renameObject(expected: SpatialObjectMetadata, displayName: String?) async throws -> SpatialObjectMetadata {
        try Task.checkCancellation()
        await operationGate.acquire()
        do {
            try Task.checkCancellation()
            var document = try loadDocumentRecoveringInvalidCatalog()
            guard document.maps.contains(where: { $0.mapID == expected.mapID && $0.availability == .active }),
                let index = document.objects.firstIndex(where: {
                    $0.mapID == expected.mapID && $0.object.id == expected.object.id
                }) else { throw WorldMapCheckpointRepositoryError.objectAnnotationConflict(expected.object.id) }
            let current = document.objects[index]
            guard current.object.presence != .removed, current.object.certainty == .confirmed,
                current.object.semanticLabel == expected.object.semanticLabel,
                current.object.displayName == expected.object.displayName,
                current.position.coordinateFrameID == expected.position.coordinateFrameID
            else { throw WorldMapCheckpointRepositoryError.objectAnnotationConflict(expected.object.id) }
            var object = current.object
            try object.setDisplayName(displayName)
            let renamed = try SpatialObjectMetadata(mapID: current.mapID, object: object, position: current.position)
            document.objects[index] = renamed
            try Task.checkCancellation()
            try commit(document)
            await operationGate.release()
            return renamed
        } catch {
            await operationGate.release()
            throw error
        }
    }

    public func upsertObjectMetadata(_ metadata: SpatialObjectMetadata) async throws {
        _ = try await upsertObjectMetadataBatch([metadata])
    }

    /// User-selected identity updates are compare-and-swap transactions. An
    /// exact retry acknowledges the durable record without duplicating it;
    /// stale selections cannot undo a rename, move, or deletion.
    @discardableResult
    public func commitUserObjectRegistration(
        _ metadata: SpatialObjectMetadata,
        replacing expected: SpatialObjectMetadata? = nil
    ) async throws -> SpatialMetadataDocument {
        try Task.checkCancellation()
        await operationGate.acquire()
        do {
            try Task.checkCancellation()
            var document = try loadDocumentRecoveringInvalidCatalog()
            let conflict = WorldMapCheckpointRepositoryError.objectAnnotationConflict(metadata.object.id)
            guard UserObjectRegistrationAccumulator.isManualRegistration(metadata),
                document.maps.contains(where: {
                    $0.mapID == metadata.mapID && $0.availability == .active
                        && $0.coordinateFrameID == metadata.position.coordinateFrameID
                })
            else { throw conflict }
            let index = document.objects.firstIndex { $0.object.id == metadata.object.id }
            if let index, document.objects[index] == metadata {
                await operationGate.release()
                return document
            }
            if let expected {
                guard let index, document.objects[index] == expected,
                    UserObjectRegistrationAccumulator.isManualRegistration(expected),
                    expected.mapID == metadata.mapID,
                    expected.position.coordinateFrameID == metadata.position.coordinateFrameID,
                    expected.object.id == metadata.object.id,
                    expected.object.displayName == metadata.object.displayName,
                    expected.object.firstSeenAt == metadata.object.firstSeenAt,
                    metadata.object.stateUpdatedAt > expected.object.stateUpdatedAt,
                    metadata.position.observedAt > expected.position.observedAt
                else { throw conflict }
                document.objects[index] = metadata
            } else {
                guard index == nil else { throw conflict }
                document.objects.append(metadata)
            }
            try Task.checkCancellation()
            try commit(document)
            await operationGate.release()
            return document
        } catch {
            await operationGate.release()
            throw error
        }
    }

    /// Applies one complete projection against a freshly loaded catalog. No
    /// object is published until every incoming update passes the same identity,
    /// revision and annotation checks as an individual observation. The returned
    /// document is the authoritative state at this transaction's commit point.
    @discardableResult
    public func upsertObjectMetadataBatch(
        _ metadata: [SpatialObjectMetadata]
    ) async throws -> SpatialMetadataDocument {
        try Task.checkCancellation()
        await operationGate.acquire()
        do {
            try Task.checkCancellation()
            var document = try loadDocumentRecoveringInvalidCatalog()
            await reconcileDetachedBlobs(referencedBy: document)
            try Task.checkCancellation()
            var changed = false
            for object in metadata {
                try Task.checkCancellation()
                if try mergeObjectMetadata(object, into: &document) {
                    changed = true
                }
            }
            try Task.checkCancellation()
            if changed { try commit(document) }
            await operationGate.release()
            return document
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func mergeObjectMetadata(
        _ metadata: SpatialObjectMetadata, into document: inout SpatialMetadataDocument
    ) throws -> Bool {
        let matchingMaps = document.maps.filter {
            $0.mapID == metadata.mapID && $0.availability == .active
        }
        guard !matchingMaps.isEmpty else {
            throw WorldMapCheckpointRepositoryError.unknownOrQuarantinedMap
        }
        guard
            matchingMaps.allSatisfy({
                $0.coordinateFrameID == metadata.position.coordinateFrameID
            })
        else {
            throw WorldMapCheckpointRepositoryError.coordinateFrameMismatch
        }

        if let index = document.objects.firstIndex(where: {
            $0.mapID == metadata.mapID && $0.object.id == metadata.object.id
        }) {
            let existing = document.objects[index]
            // The observation pipeline is not an annotation writer. Preserve
            // the latest user name even if an in-flight observation predates it.
            var observedObject = metadata.object
            try observedObject.setDisplayName(existing.object.displayName)
            let metadata = try SpatialObjectMetadata(
                mapID: metadata.mapID, object: observedObject, position: metadata.position
            )
            if existing == metadata {
                return false
            }
            let newer: Bool
            switch (metadata.object.temporalRevision, existing.object.temporalRevision) {
            case (.some(let incoming), .some(let previous)): newer = incoming > previous
            case (.some, .none): newer = true
            case (.none, .some): newer = false
            case (.none, .none): newer = metadata.object.stateUpdatedAt > existing.object.stateUpdatedAt
            }
            guard newer else {
                throw WorldMapCheckpointRepositoryError.staleObjectUpdate(metadata.object.id)
            }
            document.objects[index] = metadata
        } else {
            document.objects.append(metadata)
        }
        return true
    }

    /// Preserves typed blobs that are no longer reachable from the durable
    /// catalog (for example, a process stop between blob and catalog commits).
    /// It also retries moves for records whose catalog quarantine committed
    /// before their file move could complete.
    private func reconcileDetachedBlobs(
        referencedBy document: SpatialMetadataDocument
    ) async {
        for metadata in document.maps where metadata.availability == .quarantined {
            guard !Task.isCancelled else { return }
            let blobID = WorldMapBlobID(rawValue: metadata.worldMapBlobID)
            guard await blobStore.contains(id: blobID) else {
                continue
            }
            do {
                _ = try await blobStore.quarantine(
                    id: blobID,
                    reason: metadata.quarantineReason ?? "Checkpoint is quarantined."
                )
            } catch let error as WorldMapBlobStoreError where error == .blobNotFound {
                continue
            } catch {
                logger.error(
                    "Deferred checkpoint quarantine retry failed: \(String(describing: error), privacy: .private)"
                )
            }
        }

        let referencedIDs = Set(document.maps.map(\.worldMapBlobID))
        let activeBlobIDs: [WorldMapBlobID]
        guard !Task.isCancelled else { return }
        do {
            activeBlobIDs = try await blobStore.activeBlobIDs()
        } catch {
            logger.error(
                "Checkpoint orphan enumeration failed: \(String(describing: error), privacy: .private)"
            )
            return
        }
        for blobID in activeBlobIDs where !referencedIDs.contains(blobID.rawValue) {
            guard !Task.isCancelled else { return }
            do {
                _ = try await blobStore.quarantine(
                    id: blobID,
                    reason: "Checkpoint blob is not referenced by the metadata catalog."
                )
            } catch let error as WorldMapBlobStoreError where error == .blobNotFound {
                continue
            } catch {
                logger.error(
                    "Detached checkpoint quarantine failed: \(String(describing: error), privacy: .private)"
                )
            }
        }
    }

    private func quarantinedMetadata(
        from metadata: SpatialMapMetadata,
        reason: String
    ) throws -> SpatialMapMetadata {
        try SpatialMapMetadata(
            mapID: metadata.mapID,
            coordinateFrameID: metadata.coordinateFrameID,
            latestSegmentID: metadata.latestSegmentID,
            worldMapBlobID: metadata.worldMapBlobID,
            createdAt: metadata.createdAt,
            updatedAt: metadata.updatedAt,
            availability: .quarantined,
            quarantineReason: String(reason.prefix(2_048))
        )
    }

    private static func isDeterministicIntegrityFailure(_ error: any Error) -> Bool {
        if error is ARWorldMapArchiveError {
            return true
        }
        guard let error = error as? WorldMapBlobStoreError else {
            return false
        }
        switch error {
        case .emptyArchive,
            .archiveTooLarge,
            .encodedBlobTooLarge,
            .invalidEnvelope,
            .checksumMismatch,
            .postWriteVerificationFailed:
            return true
        case .blobAlreadyExists, .blobNotFound, .unsupportedEnvelopeVersion:
            return false
        }
    }

    private func loadDocumentRecoveringInvalidCatalog() throws -> SpatialMetadataDocument {
        try SpatialStorageDirectory.prepare(
            at: directoryURL,
            fileManager: fileManager,
            createIfMissing: false
        )
        try SpatialStorageDirectory.validatePath(at: metadataURL, fileManager: fileManager)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            try SpatialStorageDirectory.validatePath(at: backupURL, fileManager: fileManager)
            if fileManager.fileExists(atPath: backupURL.path) {
                return try recoverMetadataAfterCorruption(reason: "Primary catalog is missing; restoring its verified recovery copy.")
            }
            return SpatialMetadataDocument()
        }

        let data: Data
        do {
            data = try readBoundedMetadata()
        } catch let error as WorldMapCheckpointRepositoryError {
            return try recoverMetadataAfterCorruption(reason: String(describing: error))
        } catch {
            // Transient protection or filesystem failures are not evidence of
            // corruption and must not move a potentially valid catalog.
            throw error
        }

        do {
            try SpatialStorageDirectory.validateJSONSchemas(data, allowsLegacyRoot: true, maximumSchemaVersion: 2)
            return try SpatialMetadataMigrator.decodeAndMigrate(data)
        } catch let error as SpatialStorageError {
            throw error
        } catch {
            return try recoverMetadataAfterCorruption(reason: String(describing: error))
        }
    }

    /// Run while capture and perception have drained. Deleting bytes first
    /// keeps the catalog available to retry an interrupted explicit deletion.
    public func deleteMap(mapID: MapID) async throws {
        try Task.checkCancellation()
        await operationGate.acquire()
        do {
            try Task.checkCancellation()
            var document = try loadDocumentRecoveringInvalidCatalog()
            for metadata in document.maps where metadata.mapID == mapID {
                try await blobStore.deleteArchive(id: WorldMapBlobID(rawValue: metadata.worldMapBlobID))
                try Task.checkCancellation()
            }
            document.maps.removeAll { $0.mapID == mapID }
            document.objects.removeAll { $0.mapID == mapID }
            try commit(document, preservePrevious: false)
            await operationGate.release()
        } catch {
            await operationGate.release()
            throw error
        }
    }

    /// Imports one validated place as a new logical map. Existing map IDs are
    /// never overwritten. Only the new blob is eligible for rollback; the
    /// metadata catalog publishes the map and its objects in one atomic write.
    @discardableResult
    public func importPortableCheckpoint(_ candidate: WorldMapRestoreCandidate) async throws -> MapID {
        try Task.checkCancellation()
        guard !candidate.archive.isEmpty,
            candidate.archive.count <= SpatialPlaceArchiveCodec.maximumWorldMapBytes,
            candidate.objects.count <= SpatialPlaceArchiveCodec.maximumObjectCount
        else { throw SpatialPlaceArchiveError.fileTooLarge }
        await operationGate.acquire()
        do {
            try Task.checkCancellation()
            try SpatialStorageDirectory.prepare(at: directoryURL, fileManager: fileManager, createIfMissing: false)
            try SpatialStorageDirectory.validatePath(at: metadataURL, fileManager: fileManager)
            try SpatialStorageDirectory.validatePath(at: backupURL, fileManager: fileManager)
            var document = SpatialMetadataDocument()
            if fileManager.fileExists(atPath: metadataURL.path) {
                // Import is not a recovery operation. Invalid existing bytes
                // remain in place and require recovery before importing.
                let data = try readBoundedMetadata()
                try SpatialStorageDirectory.validateJSONSchemas(data, allowsLegacyRoot: true, maximumSchemaVersion: 2)
                document = try SpatialMetadataMigrator.decodeAndMigrate(data)
            } else if fileManager.fileExists(atPath: backupURL.path) {
                // A surviving recovery copy is evidence of an existing store,
                // not permission to overwrite it with a newly imported map.
                throw WorldMapCheckpointRepositoryError.metadataFileUnavailable
            }
            let mapID = candidate.metadata.mapID
            guard !document.maps.contains(where: { $0.mapID == mapID }) else {
                throw WorldMapCheckpointRepositoryError.importedMapAlreadyExists(mapID)
            }
            guard !document.maps.contains(where: { $0.coordinateFrameID == candidate.metadata.coordinateFrameID }) else {
                throw WorldMapCheckpointRepositoryError.importedCoordinateFrameAlreadyExists(candidate.metadata.coordinateFrameID)
            }
            let existingObjectIDs = Set(document.objects.map { $0.object.id })
            if let collision = candidate.objects.first(where: { existingObjectIDs.contains($0.object.id) }) {
                throw WorldMapCheckpointRepositoryError.importedObjectAlreadyExists(collision.object.id)
            }
            let existingMapIDs = Set(document.maps.filter { $0.availability == .active }.map(\.mapID))
            guard existingMapIDs.count < maximumLogicalMaps else {
                throw WorldMapCheckpointRepositoryError.logicalMapCapacityReached(maximum: maximumLogicalMaps)
            }
            guard candidate.metadata.availability == .active,
                candidate.metadata.quarantineReason == nil,
                candidate.objects.allSatisfy({ $0.mapID == mapID && $0.position.coordinateFrameID == candidate.metadata.coordinateFrameID })
            else { throw WorldMapCheckpointRepositoryError.coordinateFrameMismatch }
            let blobID = WorldMapBlobID()
            let metadata = try SpatialMapMetadata(
                mapID: mapID, coordinateFrameID: candidate.metadata.coordinateFrameID,
                latestSegmentID: candidate.metadata.latestSegmentID, worldMapBlobID: blobID.rawValue,
                createdAt: candidate.metadata.createdAt, updatedAt: candidate.metadata.updatedAt
            )
            document.maps.append(metadata)
            document.objects.append(contentsOf: candidate.objects)
            try document.validate()
            let encodedCount = try JSONEncoder().encode(document).count
            guard encodedCount <= Self.maximumMetadataBytes else {
                throw WorldMapCheckpointRepositoryError.metadataTooLarge(actual: encodedCount, maximum: Self.maximumMetadataBytes)
            }
            _ = try await blobStore.saveArchive(candidate.archive, id: blobID,
                createdAt: Date(timeIntervalSince1970: metadata.updatedAt))
            do {
                try Task.checkCancellation()
                try commit(document)
            } catch {
                // On process termination before rollback, normal repository
                // reconciliation preserves this unpublished typed blob in
                // quarantine. It can never become a restore candidate alone.
                try? await blobStore.deleteArchive(id: blobID)
                throw error
            }
            await operationGate.release()
            return mapID
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private var backupURL: URL { directoryURL.appendingPathComponent("spatial-metadata-v1.previous.json") }

    private func recoverMetadataAfterCorruption(reason: String) throws -> SpatialMetadataDocument {
        // Validate the backup before touching either file. An incompatible or
        // temporarily inaccessible backup is not evidence of corruption.
        var recovered: SpatialMetadataDocument?
        var backupData: Data?
        try SpatialStorageDirectory.validatePath(at: backupURL, fileManager: fileManager)
        if fileManager.fileExists(atPath: backupURL.path) {
            let data = try readBoundedMetadata(at: backupURL)
            do {
                try SpatialStorageDirectory.validateJSONSchemas(data, allowsLegacyRoot: true, maximumSchemaVersion: 2)
                recovered = try SpatialMetadataMigrator.decodeAndMigrate(data)
                backupData = data
            } catch let error as SpatialStorageError { throw error }
            catch { /* Preserve an invalid backup for explicit inspection. */ }
        }
        try quarantineMetadata(reason: reason)
        if let recovered, let backupData {
            try SpatialStorageDirectory.atomicWrite(backupData, to: metadataURL, directory: directoryURL, fileManager: fileManager)
            return recovered
        }
        return SpatialMetadataDocument()
    }

    private func readBoundedMetadata(at source: URL? = nil) throws -> Data {
        let source = source ?? metadataURL
        try SpatialStorageDirectory.validateRegularFile(at: source, fileManager: fileManager)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let readLimit = Self.maximumMetadataBytes + 1
        var data = Data()
        while data.count < readLimit {
            let remaining = readLimit - data.count
            guard
                let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                !chunk.isEmpty
            else {
                break
            }
            data.append(chunk)
        }
        guard data.count <= Self.maximumMetadataBytes else {
            throw WorldMapCheckpointRepositoryError.metadataTooLarge(
                actual: data.count,
                maximum: Self.maximumMetadataBytes
            )
        }
        return data
    }

    private func commit(_ document: SpatialMetadataDocument, preservePrevious: Bool = true) throws {
        try document.validate()
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumMetadataBytes else {
            throw WorldMapCheckpointRepositoryError.metadataTooLarge(
                actual: data.count,
                maximum: Self.maximumMetadataBytes
            )
        }
        let isInitialPublication = preservePrevious && !fileManager.fileExists(atPath: metadataURL.path)
        if !preservePrevious {
            // Update the recovery copy before publishing deletion, so even a
            // crash between these writes cannot recover a deleted place.
            try SpatialStorageDirectory.atomicWrite(data, to: backupURL, directory: directoryURL, fileManager: fileManager, reclaiming: !preservePrevious)
        } else if isInitialPublication {
            // Until the primary catalog is published, the last durable state
            // is empty. A failed first checkpoint/import must not leave a
            // recovery copy referring to its rolled-back or quarantined blob.
            let previous = try encoder.encode(SpatialMetadataDocument())
            try SpatialStorageDirectory.atomicWrite(previous, to: backupURL, directory: directoryURL, fileManager: fileManager)
        } else {
            let previous = try readBoundedMetadata()
            try SpatialStorageDirectory.validateJSONSchemas(previous, allowsLegacyRoot: true, maximumSchemaVersion: 2)
            _ = try SpatialMetadataMigrator.decodeAndMigrate(previous)
            try SpatialStorageDirectory.atomicWrite(previous, to: backupURL, directory: directoryURL, fileManager: fileManager, reclaiming: !preservePrevious)
        }
        try SpatialStorageDirectory.atomicWrite(
            data, to: metadataURL, directory: directoryURL, fileManager: fileManager, reclaiming: !preservePrevious
        )
        if isInitialPublication {
            // Publication already succeeded. Creating the first useful recovery
            // copy is maintenance: failure must never make callers roll back
            // the blob now referenced by the durable primary catalog.
            try? SpatialStorageDirectory.atomicWrite(data, to: backupURL, directory: directoryURL, fileManager: fileManager)
        }
    }

    private func quarantineMetadata(reason: String) throws {
        try SpatialStorageDirectory.validatePath(at: metadataURL, fileManager: fileManager)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return
        }
        try prepareDirectory()
        let quarantineDirectory = directoryURL.appendingPathComponent(
            "Quarantine",
            isDirectory: true
        )
        try SpatialStorageDirectory.prepare(
            at: quarantineDirectory,
            fileManager: fileManager
        )
        let nonce = UUID().uuidString.lowercased()
        let destination = quarantineDirectory.appendingPathComponent(
            "spatial-metadata-v1.\(nonce).json.quarantined",
            isDirectory: false
        )
        let reasonURL = quarantineDirectory.appendingPathComponent(
            "spatial-metadata-v1.\(nonce).reason.txt",
            isDirectory: false
        )
        let reasonData = Data(String(reason.prefix(2_048)).utf8)
        try reasonData.write(
            to: reasonURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        do {
            try fileManager.moveItem(at: metadataURL, to: destination)
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        } catch {
            try? fileManager.removeItem(at: reasonURL)
            throw error
        }
        try? SpatialStorageDirectory.maintainArtifacts(at: directoryURL, fileManager: fileManager)
    }

    private func prepareDirectory() throws {
        try SpatialStorageDirectory.prepare(at: directoryURL, fileManager: fileManager)
    }
}

/// Serializes repository transactions across suspension points. Swift actors
/// are reentrant, so an actor method that awaits the blob-store actor would
/// otherwise allow a second operation to load and later overwrite a stale
/// metadata document.
private actor AsyncOperationGate {
    private var isAvailable = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if isAvailable {
            isAvailable = false
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isAvailable = true
            return
        }
        waiters.removeFirst().resume()
    }
}

public enum VispaceStoragePaths {
    public static func spatialCaptureDirectory() -> URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Vispace", isDirectory: true)
            .appendingPathComponent("SpatialCapture", isDirectory: true)
    }
}
