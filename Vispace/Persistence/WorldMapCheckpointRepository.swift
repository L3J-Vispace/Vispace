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
    case logicalMapCapacityReached(maximum: Int)
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
    public func loadLatestValidCheckpoint() async throws -> WorldMapRestoreCandidate? {
        try Task.checkCancellation()
        await operationGate.acquire()
        do {
            try Task.checkCancellation()
            let candidate = try await loadLatestValidCheckpointLocked()
            await operationGate.release()
            return candidate
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func loadLatestValidCheckpointLocked() async throws -> WorldMapRestoreCandidate? {
        try Task.checkCancellation()
        var document = try loadDocumentRecoveringInvalidCatalog()
        await reconcileDetachedBlobs(referencedBy: document)
        try Task.checkCancellation()
        let orderedIndices = document.maps.indices
            .filter { document.maps[$0].availability == .active }
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

    public func upsertObjectMetadata(_ metadata: SpatialObjectMetadata) async throws {
        try Task.checkCancellation()
        await operationGate.acquire()
        do {
            try Task.checkCancellation()
            try await upsertObjectMetadataLocked(metadata)
            await operationGate.release()
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func upsertObjectMetadataLocked(_ metadata: SpatialObjectMetadata) async throws {
        var document = try loadDocumentRecoveringInvalidCatalog()
        await reconcileDetachedBlobs(referencedBy: document)
        // An ARSession lifecycle reset cancels the originating perception task.
        // Recheck after every suspension and immediately before the atomic
        // catalog write so an old run cannot publish late coordinates.
        try Task.checkCancellation()
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
            if existing == metadata {
                return
            }
            guard metadata.object.stateUpdatedAt > existing.object.stateUpdatedAt else {
                throw WorldMapCheckpointRepositoryError.staleObjectUpdate(metadata.object.id)
            }
            document.objects[index] = metadata
        } else {
            document.objects.append(metadata)
        }
        try Task.checkCancellation()
        try commit(document)
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
                    "Deferred checkpoint quarantine retry failed: \(String(describing: error), privacy: .public)"
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
                "Checkpoint orphan enumeration failed: \(String(describing: error), privacy: .public)"
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
                    "Detached checkpoint quarantine failed: \(String(describing: error), privacy: .public)"
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
            .unsupportedEnvelopeVersion,
            .invalidEnvelope,
            .checksumMismatch,
            .postWriteVerificationFailed:
            return true
        case .blobAlreadyExists, .blobNotFound:
            return false
        }
    }

    private func loadDocumentRecoveringInvalidCatalog() throws -> SpatialMetadataDocument {
        try SpatialStorageDirectory.prepare(
            at: directoryURL,
            fileManager: fileManager,
            createIfMissing: false
        )
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return SpatialMetadataDocument()
        }

        let data: Data
        do {
            data = try readBoundedMetadata()
        } catch let error as WorldMapCheckpointRepositoryError {
            try quarantineMetadata(reason: String(describing: error))
            return SpatialMetadataDocument()
        } catch {
            // Transient protection or filesystem failures are not evidence of
            // corruption and must not move a potentially valid catalog.
            throw error
        }

        do {
            return try SpatialMetadataMigrator.decodeAndMigrate(data)
        } catch {
            try quarantineMetadata(reason: String(describing: error))
            return SpatialMetadataDocument()
        }
    }

    private func readBoundedMetadata() throws -> Data {
        let handle = try FileHandle(forReadingFrom: metadataURL)
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

    private func commit(_ document: SpatialMetadataDocument) throws {
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
        try data.write(
            to: metadataURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
    }

    private func quarantineMetadata(reason: String) throws {
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
        } catch {
            try? fileManager.removeItem(at: reasonURL)
            throw error
        }
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
