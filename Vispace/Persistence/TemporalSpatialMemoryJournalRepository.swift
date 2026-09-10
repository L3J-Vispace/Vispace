import Foundation
import VispaceCore

public enum TemporalSpatialMemoryJournalError: Error, Equatable, Sendable {
    case catalogTooLarge(actual: Int, maximum: Int)
    case unsupportedCatalogSchema(actual: UInt16)
    case invalidProvenance
    case invalidJournal
    case journalCapacityReached(maximum: Int)
    case entryCapacityReached(maximum: Int)
    case mapCoordinateFrameConflict(mapID: MapID)
    case policyConflict(mapID: MapID)
    case journalDiverged(mapID: MapID)
    case reclamationPending(mapID: MapID)
    case updateIdentifierCollision(SpatialDeltaID)
}

public enum TemporalSpatialMappingQuality: String, Codable, Hashable, Sendable {
    case extending
    case mapped
}

/// Persistable pose provenance deliberately excludes pixels, depth maps,
/// intrinsics, and other raw frame payloads.
public struct TemporalSpatialPoseProvenance: Codable, Hashable, Sendable {
    public let frameID: FrameID
    public let sessionRunGeneration: UInt64
    public let attachmentEpoch: UInt64
    public let captureSegmentID: CaptureSegmentID
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let capturedAt: TimeInterval
    public let sessionTimestamp: TimeInterval
    public let cameraTransform: Transform3D
    public let trackingQuality: SpatialTrackingQuality
    public let mappingQuality: TemporalSpatialMappingQuality

    public init(
        frameID: FrameID,
        sessionRunGeneration: UInt64,
        attachmentEpoch: UInt64,
        captureSegmentID: CaptureSegmentID,
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        capturedAt: TimeInterval,
        sessionTimestamp: TimeInterval,
        cameraTransform: Transform3D,
        trackingQuality: SpatialTrackingQuality,
        mappingQuality: TemporalSpatialMappingQuality
    ) throws {
        guard capturedAt.isFinite, capturedAt >= 0,
            sessionTimestamp.isFinite, sessionTimestamp >= 0,
            trackingQuality == .normal
        else {
            throw TemporalSpatialMemoryJournalError.invalidProvenance
        }
        self.frameID = frameID
        self.sessionRunGeneration = sessionRunGeneration
        self.attachmentEpoch = attachmentEpoch
        self.captureSegmentID = captureSegmentID
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        self.capturedAt = capturedAt
        self.sessionTimestamp = sessionTimestamp
        self.cameraTransform = cameraTransform
        self.trackingQuality = trackingQuality
        self.mappingQuality = mappingQuality
    }

    private enum CodingKeys: String, CodingKey {
        case frameID
        case sessionRunGeneration
        case attachmentEpoch
        case captureSegmentID
        case mapID
        case coordinateFrameID
        case capturedAt
        case sessionTimestamp
        case cameraTransform
        case trackingQuality
        case mappingQuality
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                frameID: container.decode(FrameID.self, forKey: .frameID),
                sessionRunGeneration: container.decode(
                    UInt64.self,
                    forKey: .sessionRunGeneration
                ),
                attachmentEpoch: container.decode(UInt64.self, forKey: .attachmentEpoch),
                captureSegmentID: container.decode(
                    CaptureSegmentID.self,
                    forKey: .captureSegmentID
                ),
                mapID: container.decode(MapID.self, forKey: .mapID),
                coordinateFrameID: container.decode(
                    CoordinateFrameID.self,
                    forKey: .coordinateFrameID
                ),
                capturedAt: container.decode(TimeInterval.self, forKey: .capturedAt),
                sessionTimestamp: container.decode(
                    TimeInterval.self,
                    forKey: .sessionTimestamp
                ),
                cameraTransform: container.decode(
                    Transform3D.self,
                    forKey: .cameraTransform
                ),
                trackingQuality: container.decode(
                    SpatialTrackingQuality.self,
                    forKey: .trackingQuality
                ),
                mappingQuality: container.decode(
                    TemporalSpatialMappingQuality.self,
                    forKey: .mappingQuality
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .capturedAt,
                in: container,
                debugDescription: "Temporal pose provenance is invalid."
            )
        }
    }
}

public struct TemporalSpatialMemoryJournalEntry: Codable, Hashable, Sendable {
    public let provenance: TemporalSpatialPoseProvenance
    public let update: TemporalSpatialUpdate
    public let delta: TemporalSpatialDelta

    public init(
        provenance: TemporalSpatialPoseProvenance,
        update: TemporalSpatialUpdate,
        delta: TemporalSpatialDelta
    ) throws {
        let (expectedRevision, revisionOverflow) =
            delta.baseRevision.addingReportingOverflow(1)
        guard !revisionOverflow,
            update.id == delta.id,
            update.baseRevision == delta.baseRevision,
            delta.newRevision == expectedRevision,
            update.sequence == delta.sequence,
            update.timestamp == delta.timestamp,
            update.clock == delta.clock,
            update.clock.map({
                $0.captureSegmentID == provenance.captureSegmentID
                    && $0.monotonicTimestamp == provenance.sessionTimestamp
            }) ?? true,
            update.mapID == delta.mapID,
            update.coordinateFrameID == delta.coordinateFrameID,
            provenance.mapID == update.mapID,
            provenance.coordinateFrameID == update.coordinateFrameID,
            provenance.capturedAt == update.timestamp,
            delta.spatialDelta.id == update.id,
            delta.spatialDelta.baseRevision == update.baseRevision
        else {
            throw TemporalSpatialMemoryJournalError.invalidJournal
        }
        self.provenance = provenance
        self.update = update
        self.delta = delta
    }

    private enum CodingKeys: String, CodingKey {
        case provenance
        case update
        case delta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                provenance: container.decode(
                    TemporalSpatialPoseProvenance.self,
                    forKey: .provenance
                ),
                update: container.decode(TemporalSpatialUpdate.self, forKey: .update),
                delta: container.decode(TemporalSpatialDelta.self, forKey: .delta)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .delta,
                in: container,
                debugDescription: "Temporal journal entry failed provenance validation."
            )
        }
    }
}

public struct TemporalSpatialMemoryJournalRecovery: Codable, Hashable, Sendable {
    public let policy: TemporalSpatialMemoryPolicy
    public let snapshot: TemporalSpatialMemorySnapshot
    public let replayedEntryCount: Int
    public let pendingRemovedObjects: [SpatialObjectMetadata]
}

public struct TemporalSpatialMemoryJournalRecord: Codable, Hashable, Sendable {
    public static let absoluteMaximumEntryCount = 1_024

    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let policy: TemporalSpatialMemoryPolicy
    public let checkpoint: TemporalSpatialMemorySnapshot
    public let entries: [TemporalSpatialMemoryJournalEntry]
    public let pendingRemovedObjects: [SpatialObjectMetadata]
    private let validatedSnapshot: TemporalSpatialMemorySnapshot

    public init(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        policy: TemporalSpatialMemoryPolicy,
        checkpoint: TemporalSpatialMemorySnapshot,
        entries: [TemporalSpatialMemoryJournalEntry],
        pendingRemovedObjects: [SpatialObjectMetadata] = []
    ) throws {
        guard entries.count <= Self.absoluteMaximumEntryCount,
            checkpoint.mapID == mapID,
            checkpoint.coordinateFrameID == coordinateFrameID,
            entries.allSatisfy({
                $0.update.mapID == mapID
                    && $0.update.coordinateFrameID == coordinateFrameID
            })
        else {
            throw TemporalSpatialMemoryJournalError.invalidJournal
        }
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        self.policy = policy
        self.checkpoint = checkpoint
        self.entries = entries
        let recovered = try Self.replay(checkpoint: checkpoint, policy: policy, entries: entries)
        guard pendingRemovedObjects.count <= policy.maximumObjectCount,
            Set(pendingRemovedObjects.map { $0.object.id }).count == pendingRemovedObjects.count,
            pendingRemovedObjects.isEmpty || entries.isEmpty,
            pendingRemovedObjects.allSatisfy({ metadata in
                TemporalSpatialMemorySnapshot.isReclaimableRemovedObject(metadata)
                    && metadata.mapID == mapID && metadata.position.coordinateFrameID == coordinateFrameID
                    && recovered.metadata(for: metadata.object.id) == nil
            }) else { throw TemporalSpatialMemoryJournalError.invalidJournal }
        validatedSnapshot = recovered
        self.pendingRemovedObjects = pendingRemovedObjects.sorted { $0.object.id < $1.object.id }
    }

    public func recoveredSnapshot() throws -> TemporalSpatialMemorySnapshot {
        validatedSnapshot
    }

    private static func replay(
        checkpoint: TemporalSpatialMemorySnapshot,
        policy: TemporalSpatialMemoryPolicy,
        entries: [TemporalSpatialMemoryJournalEntry]
    ) throws -> TemporalSpatialMemorySnapshot {
        var coordinator = try TemporalSpatialMemoryCoordinator(
            restoring: checkpoint,
            policy: policy
        )
        for entry in entries {
            guard case .applied(let replayedDelta) = try coordinator.apply(entry.update),
                replayedDelta == entry.delta
            else {
                throw TemporalSpatialMemoryJournalError.invalidJournal
            }
        }
        return coordinator.snapshot
    }

    private enum CodingKeys: String, CodingKey {
        case mapID
        case coordinateFrameID
        case policy
        case checkpoint
        case entries
        case pendingRemovedObjects
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                mapID: container.decode(MapID.self, forKey: .mapID),
                coordinateFrameID: container.decode(
                    CoordinateFrameID.self,
                    forKey: .coordinateFrameID
                ),
                policy: container.decode(
                    TemporalSpatialMemoryPolicy.self,
                    forKey: .policy
                ),
                checkpoint: container.decode(
                    TemporalSpatialMemorySnapshot.self,
                    forKey: .checkpoint
                ),
                entries: container.decode(
                    [TemporalSpatialMemoryJournalEntry].self,
                    forKey: .entries
                ),
                pendingRemovedObjects: container.decodeIfPresent(
                    [SpatialObjectMetadata].self, forKey: .pendingRemovedObjects) ?? []
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .entries,
                in: container,
                debugDescription: "Temporal journal cannot be replayed exactly."
            )
        }
    }
}

public struct TemporalSpatialMemoryJournalCatalog: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 4
    public static let absoluteMaximumJournalCount = 64

    public let schemaVersion: UInt16
    public fileprivate(set) var journals: [TemporalSpatialMemoryJournalRecord]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        journals: [TemporalSpatialMemoryJournalRecord] = []
    ) throws {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw TemporalSpatialMemoryJournalError.unsupportedCatalogSchema(
                actual: schemaVersion
            )
        }
        guard journals.count <= Self.absoluteMaximumJournalCount else {
            throw TemporalSpatialMemoryJournalError.journalCapacityReached(
                maximum: Self.absoluteMaximumJournalCount
            )
        }
        guard Set(journals.map(\.mapID)).count == journals.count else {
            throw TemporalSpatialMemoryJournalError.invalidJournal
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.journals = journals.sorted(by: Self.journalOrder)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case journals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
                journals: container.decode(
                    [TemporalSpatialMemoryJournalRecord].self,
                    forKey: .journals
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .journals,
                in: container,
                debugDescription: "Temporal journal catalog failed validation."
            )
        }
    }

    fileprivate static func journalOrder(
        _ lhs: TemporalSpatialMemoryJournalRecord,
        _ rhs: TemporalSpatialMemoryJournalRecord
    ) -> Bool {
        lhs.mapID < rhs.mapID
    }
}

public enum TemporalSpatialMemoryJournalAppendResult: Equatable, Sendable {
    case appended(TemporalSpatialMemorySnapshot)
    case alreadyAppended(TemporalSpatialMemorySnapshot)
}

/// Atomic, protected, bounded journal for temporal spatial state. It persists
/// only validated updates, their deterministic deltas, compact checkpoints,
/// and pose provenance; camera/depth frame types are intentionally absent.
public actor TemporalSpatialMemoryJournalRepository {
    public static let catalogFileName = "temporal-spatial-memory-v1.json"
    public static let maximumCatalogBytes = 16 * 1_024 * 1_024
    public static let defaultMaximumJournalCount = 32
    public static let defaultMaximumEntriesPerJournal = 64

    private let directoryURL: URL
    private let catalogURL: URL
    private let fileManager: FileManager
    private let maximumJournalCount: Int
    private let maximumEntriesPerJournal: Int
    private let catalogByteLimit: Int
    // The bytes are compared after a fresh bounded read. External replacement,
    // deletion, or corruption cannot reuse a previously validated catalog.
    private var cachedCatalog: (data: Data, catalog: TemporalSpatialMemoryJournalCatalog)?

    #if DEBUG
    private var afterNextCommitForTesting: (@Sendable () async -> Void)?

    /// Suspends only after a real atomic journal publication, never instead of it.
    func setAfterNextCommitForTesting(_ hook: @escaping @Sendable () async -> Void) {
        afterNextCommitForTesting = hook
    }
    #endif

    public init(
        directoryURL: URL,
        maximumJournalCount: Int = TemporalSpatialMemoryJournalRepository
            .defaultMaximumJournalCount,
        maximumEntriesPerJournal: Int = TemporalSpatialMemoryJournalRepository
            .defaultMaximumEntriesPerJournal,
        maximumCatalogBytes: Int = TemporalSpatialMemoryJournalRepository.maximumCatalogBytes,
        fileManager: FileManager = .default
    ) {
        let standardizedDirectory = directoryURL.standardizedFileURL
        self.directoryURL = standardizedDirectory
        catalogURL = standardizedDirectory.appendingPathComponent(
            Self.catalogFileName,
            isDirectory: false
        )
        self.maximumJournalCount = min(
            max(1, maximumJournalCount),
            TemporalSpatialMemoryJournalCatalog.absoluteMaximumJournalCount
        )
        self.maximumEntriesPerJournal = min(
            max(1, maximumEntriesPerJournal),
            TemporalSpatialMemoryJournalRecord.absoluteMaximumEntryCount
        )
        catalogByteLimit = min(max(1, maximumCatalogBytes), Self.maximumCatalogBytes)
        self.fileManager = fileManager
    }

    public func catalogSnapshot() async throws -> TemporalSpatialMemoryJournalCatalog {
        try Task.checkCancellation()
        let catalog = try loadCatalogRecoveringInvalidData()
        try Task.checkCancellation()
        try validateConfiguredCapacity(catalog)
        return catalog
    }

    public func recover(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID
    ) async throws -> TemporalSpatialMemoryJournalRecovery? {
        let catalog = try await catalogSnapshot()
        guard let record = catalog.journals.first(where: { $0.mapID == mapID }) else {
            return nil
        }
        guard record.coordinateFrameID == coordinateFrameID else {
            throw TemporalSpatialMemoryJournalError.mapCoordinateFrameConflict(
                mapID: mapID
            )
        }
        let snapshot = try record.recoveredSnapshot()
        return TemporalSpatialMemoryJournalRecovery(
            policy: record.policy,
            snapshot: snapshot,
            replayedEntryCount: record.entries.count,
            pendingRemovedObjects: record.pendingRemovedObjects
        )
    }

    @discardableResult
    public func append(
        _ entry: TemporalSpatialMemoryJournalEntry,
        policy: TemporalSpatialMemoryPolicy,
        previousSnapshot: TemporalSpatialMemorySnapshot,
        resultingSnapshot: TemporalSpatialMemorySnapshot,
        validateBeforeCommit: (@Sendable () throws -> Void)? = nil
    ) async throws -> TemporalSpatialMemoryJournalAppendResult {
        try Task.checkCancellation()
        try validateBeforeCommit?()
        var catalog = try loadCatalogRecoveringInvalidData()
        try Task.checkCancellation()
        try validateConfiguredCapacity(catalog)
        let mapID = entry.update.mapID
        let coordinateFrameID = entry.update.coordinateFrameID
        guard previousSnapshot.mapID == mapID,
            resultingSnapshot.mapID == mapID,
            previousSnapshot.coordinateFrameID == coordinateFrameID,
            resultingSnapshot.coordinateFrameID == coordinateFrameID
        else {
            throw TemporalSpatialMemoryJournalError.invalidJournal
        }

        let index = catalog.journals.firstIndex(where: { $0.mapID == mapID })
        if let index {
            let existing = catalog.journals[index]
            guard existing.coordinateFrameID == coordinateFrameID else {
                throw TemporalSpatialMemoryJournalError.mapCoordinateFrameConflict(
                    mapID: mapID
                )
            }
            guard existing.policy == policy else {
                throw TemporalSpatialMemoryJournalError.policyConflict(mapID: mapID)
            }
            guard existing.pendingRemovedObjects.isEmpty else {
                throw TemporalSpatialMemoryJournalError.reclamationPending(mapID: mapID)
            }
            if let prior = existing.entries.first(where: { $0.update.id == entry.update.id }) {
                guard prior == entry else {
                    throw TemporalSpatialMemoryJournalError.updateIdentifierCollision(
                        entry.update.id
                    )
                }
                return .alreadyAppended(try existing.recoveredSnapshot())
            }

            let recovered = try existing.recoveredSnapshot()
            // Compaction may have folded the last append into the checkpoint.
            // Verify the full transition before acknowledging its exact retry.
            if recovered == resultingSnapshot {
                try verify(entry, policy: policy, previousSnapshot: previousSnapshot,
                    resultingSnapshot: resultingSnapshot)
                return .alreadyAppended(recovered)
            }
            guard recovered == previousSnapshot else {
                throw TemporalSpatialMemoryJournalError.journalDiverged(mapID: mapID)
            }
            try verify(
                entry,
                policy: policy,
                previousSnapshot: previousSnapshot,
                resultingSnapshot: resultingSnapshot
            )
            let proposedEntries = existing.entries + [entry]
            if proposedEntries.count > maximumEntriesPerJournal {
                catalog.journals[index] = try TemporalSpatialMemoryJournalRecord(
                    mapID: mapID,
                    coordinateFrameID: coordinateFrameID,
                    policy: policy,
                    checkpoint: resultingSnapshot,
                    entries: []
                )
            } else {
                catalog.journals[index] = try TemporalSpatialMemoryJournalRecord(
                    mapID: mapID,
                    coordinateFrameID: coordinateFrameID,
                    policy: policy,
                    checkpoint: existing.checkpoint,
                    entries: proposedEntries
                )
            }
        } else {
            guard catalog.journals.count < maximumJournalCount else {
                throw TemporalSpatialMemoryJournalError.journalCapacityReached(
                    maximum: maximumJournalCount
                )
            }
            try verify(
                entry,
                policy: policy,
                previousSnapshot: previousSnapshot,
                resultingSnapshot: resultingSnapshot
            )
            catalog.journals.append(
                try TemporalSpatialMemoryJournalRecord(
                    mapID: mapID,
                    coordinateFrameID: coordinateFrameID,
                    policy: policy,
                    checkpoint: previousSnapshot,
                    entries: [entry]
                )
            )
        }

        catalog.journals.sort(by: TemporalSpatialMemoryJournalCatalog.journalOrder)
        try Task.checkCancellation()
        try validateBeforeCommit?()
        try commit(catalog, validateBeforeCommit: validateBeforeCommit)
        #if DEBUG
        let hook = afterNextCommitForTesting
        afterNextCommitForTesting = nil
        await hook?()
        #endif
        return .appended(resultingSnapshot)
    }

    private func verify(
        _ entry: TemporalSpatialMemoryJournalEntry,
        policy: TemporalSpatialMemoryPolicy,
        previousSnapshot: TemporalSpatialMemorySnapshot,
        resultingSnapshot: TemporalSpatialMemorySnapshot
    ) throws {
        var coordinator = try TemporalSpatialMemoryCoordinator(
            restoring: previousSnapshot,
            policy: policy
        )
        guard case .applied(let replayedDelta) = try coordinator.apply(entry.update),
            replayedDelta == entry.delta,
            coordinator.snapshot == resultingSnapshot
        else {
            throw TemporalSpatialMemoryJournalError.invalidJournal
        }
    }

    public func deleteMap(mapID: MapID) async throws {
        try Task.checkCancellation()
        var catalog = try loadCatalogRecoveringInvalidData()
        catalog.journals.removeAll { $0.mapID == mapID }
        try Task.checkCancellation()
        try commit(catalog, reclaiming: true)
    }

    /// Journal publication is the reclamation commit point. Exact removed
    /// metadata is retained as an intent until its separate projection is erased.
    public func beginRemovedObjectReclamation(
        expectedSnapshot: TemporalSpatialMemorySnapshot,
        policy: TemporalSpatialMemoryPolicy,
        expectedRemovedObjects: [SpatialObjectMetadata]? = nil
    ) async throws -> [SpatialObjectMetadata] {
        try Task.checkCancellation()
        var catalog = try loadCatalogRecoveringInvalidData()
        let mapID = expectedSnapshot.mapID
        let existingIndex = catalog.journals.firstIndex { $0.mapID == mapID }
        if let existingIndex {
            let existing = catalog.journals[existingIndex]
            guard existing.policy == policy,
                existing.coordinateFrameID == expectedSnapshot.coordinateFrameID,
                try existing.recoveredSnapshot() == expectedSnapshot
            else { throw TemporalSpatialMemoryJournalError.journalDiverged(mapID: mapID) }
            guard existing.pendingRemovedObjects.isEmpty else {
                throw TemporalSpatialMemoryJournalError.reclamationPending(mapID: mapID)
            }
        }
        let journalRemoved = expectedSnapshot.reclaimableRemovedObjects
        let removed = expectedRemovedObjects ?? journalRemoved
        guard Set(removed.map { $0.object.id }) == Set(journalRemoved.map { $0.object.id }),
            removed.count == journalRemoved.count else { throw TemporalSpatialMemoryJournalError.invalidJournal }
        for metadata in removed {
            guard let journalMetadata = expectedSnapshot.metadata(for: metadata.object.id) else {
                throw TemporalSpatialMemoryJournalError.invalidJournal
            }
            var comparableObject = metadata.object
            try comparableObject.setDisplayName(journalMetadata.object.displayName)
            guard try SpatialObjectMetadata(mapID: metadata.mapID, object: comparableObject,
                position: metadata.position) == journalMetadata else {
                throw TemporalSpatialMemoryJournalError.journalDiverged(mapID: mapID)
            }
        }
        guard !removed.isEmpty else { return [] }
        let record = try TemporalSpatialMemoryJournalRecord(
            mapID: mapID, coordinateFrameID: expectedSnapshot.coordinateFrameID,
            policy: policy, checkpoint: expectedSnapshot.reclaimingRemovedObjectHistory(),
            entries: [], pendingRemovedObjects: removed)
        if let existingIndex { catalog.journals[existingIndex] = record }
        else { catalog.journals.append(record) }
        catalog.journals.sort(by: TemporalSpatialMemoryJournalCatalog.journalOrder)
        try commit(catalog, reclaiming: true)
        return removed
    }

    public func completeRemovedObjectReclamation(
        mapID: MapID, coordinateFrameID: CoordinateFrameID,
        expectedRemovedObjects: [SpatialObjectMetadata]
    ) async throws {
        try Task.checkCancellation()
        var catalog = try loadCatalogRecoveringInvalidData()
        guard let index = catalog.journals.firstIndex(where: { $0.mapID == mapID }) else {
            throw TemporalSpatialMemoryJournalError.journalDiverged(mapID: mapID)
        }
        let record = catalog.journals[index]
        guard record.coordinateFrameID == coordinateFrameID,
            record.pendingRemovedObjects == expectedRemovedObjects.sorted(by: { $0.object.id < $1.object.id })
        else { throw TemporalSpatialMemoryJournalError.journalDiverged(mapID: mapID) }
        guard !record.pendingRemovedObjects.isEmpty else { return }
        catalog.journals[index] = try TemporalSpatialMemoryJournalRecord(
            mapID: mapID, coordinateFrameID: coordinateFrameID,
            policy: record.policy, checkpoint: record.recoveredSnapshot(), entries: [])
        try commit(catalog, reclaiming: true)
    }

    private func loadCatalogRecoveringInvalidData() throws
        -> TemporalSpatialMemoryJournalCatalog
    {
        try SpatialStorageDirectory.prepare(
            at: directoryURL,
            fileManager: fileManager,
            createIfMissing: false
        )
        try SpatialStorageDirectory.validatePath(at: catalogURL, fileManager: fileManager)
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            cachedCatalog = nil
            return try TemporalSpatialMemoryJournalCatalog()
        }
        let data: Data
        do {
            data = try readBoundedCatalog()
        } catch let error as TemporalSpatialMemoryJournalError {
            guard case .catalogTooLarge = error else {
                throw error
            }
            try quarantineCatalog(reason: String(describing: error))
            return try TemporalSpatialMemoryJournalCatalog()
        } catch {
            throw error
        }

        do {
            if let cachedCatalog, cachedCatalog.data == data { return cachedCatalog.catalog }
            try SpatialStorageDirectory.validateJSONSchemas(data, maximumSchemaVersion: 4,
                                                           maximumNestedSchemaVersion: 3)
            let catalog = try JSONDecoder().decode(
                TemporalSpatialMemoryJournalCatalog.self,
                from: data
            )
            cachedCatalog = (data, catalog)
            return catalog
        } catch let error as SpatialStorageError {
            throw error
        } catch {
            try quarantineCatalog(reason: String(describing: error))
            return try TemporalSpatialMemoryJournalCatalog()
        }
    }

    private func readBoundedCatalog() throws -> Data {
        try SpatialStorageDirectory.validateRegularFile(at: catalogURL, fileManager: fileManager)
        let handle = try FileHandle(forReadingFrom: catalogURL)
        defer { try? handle.close() }
        let readLimit = Self.maximumCatalogBytes + 1
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
        guard data.count <= Self.maximumCatalogBytes else {
            throw TemporalSpatialMemoryJournalError.catalogTooLarge(
                actual: data.count,
                maximum: Self.maximumCatalogBytes
            )
        }
        return data
    }

    private func validateConfiguredCapacity(
        _ catalog: TemporalSpatialMemoryJournalCatalog
    ) throws {
        guard catalog.journals.count <= maximumJournalCount else {
            throw TemporalSpatialMemoryJournalError.journalCapacityReached(
                maximum: maximumJournalCount
            )
        }
        guard
            catalog.journals.allSatisfy({
                $0.entries.count <= maximumEntriesPerJournal
            })
        else {
            throw TemporalSpatialMemoryJournalError.entryCapacityReached(
                maximum: maximumEntriesPerJournal
            )
        }
    }

    private func commit(
        _ proposed: TemporalSpatialMemoryJournalCatalog,
        reclaiming: Bool = false,
        validateBeforeCommit: (@Sendable () throws -> Void)? = nil
    ) throws {
        var catalog = proposed
        try validateConfiguredCapacity(catalog)
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(catalog)
        if data.count > catalogByteLimit {
            // Compact by bytes as well as entry count. Only redundant replay
            // history is folded away; every place's exact latest state remains.
            catalog.journals = try catalog.journals.map { record in
                try Task.checkCancellation()
                guard !record.entries.isEmpty else { return record }
                return try TemporalSpatialMemoryJournalRecord(
                    mapID: record.mapID, coordinateFrameID: record.coordinateFrameID,
                    policy: record.policy, checkpoint: record.recoveredSnapshot(), entries: []
                )
            }
            data = try encoder.encode(catalog)
        }
        guard data.count <= catalogByteLimit else {
            throw TemporalSpatialMemoryJournalError.catalogTooLarge(
                actual: data.count,
                maximum: catalogByteLimit
            )
        }
        try Task.checkCancellation()
        try validateBeforeCommit?()
        try SpatialStorageDirectory.atomicWrite(
            data, to: catalogURL, directory: directoryURL, fileManager: fileManager, reclaiming: reclaiming
        )
        cachedCatalog = (data, catalog)
    }

    private func quarantineCatalog(reason: String) throws {
        cachedCatalog = nil
        try SpatialStorageDirectory.validatePath(at: catalogURL, fileManager: fileManager)
        guard fileManager.fileExists(atPath: catalogURL.path) else {
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
            "temporal-spatial-memory-v1.\(nonce).json.quarantined",
            isDirectory: false
        )
        let reasonURL = quarantineDirectory.appendingPathComponent(
            "temporal-spatial-memory-v1.\(nonce).reason.txt",
            isDirectory: false
        )
        try Data(String(reason.prefix(2_048)).utf8).write(
            to: reasonURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        do {
            try fileManager.moveItem(at: catalogURL, to: destination)
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
