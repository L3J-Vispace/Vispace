import Foundation
import VispaceCore

public enum PlaceMemoryRepositoryError: Error, Equatable, Sendable {
    case catalogTooLarge(actual: Int, maximum: Int)
    case unsupportedCatalogSchema(actual: UInt16)
    case unsupportedFingerprintSchema(actual: UInt16)
    case invalidTimestamp
    case invalidDateOrder
    case invalidAssociationPolicyVersion(actual: UInt16)
    case invalidAssociationState
    case fingerprintCapacityReached(maximum: Int)
    case associationStateCapacityReached(maximum: Int)
    case associationHistoryCapacityReached(maximum: Int)
    case mapCoordinateFrameConflict(mapID: MapID)
    case staleFingerprintUpdate(mapID: MapID)
    case associationContextConflict(id: PlaceAssociationStateID)
    case staleAssociationStateUpdate(id: PlaceAssociationStateID)
    case associationHistoryDiverged(id: PlaceAssociationStateID)
    case retiredAssociationState(id: PlaceAssociationStateID)
}

public enum PlaceAssociationHistoryRetention: Sendable {
    case preserveAll
    /// Retire older attempts containing no mutation proposal, atomically with
    /// admission of a newer attempt. Proposed mutations remain pinned because
    /// this catalog has no durable acknowledgement that they were executed.
    case retireOlderDeferredAttempts
}

/// A stable identifier for one bounded place-association attempt.
public struct PlaceAssociationStateID: RawRepresentable, Codable, Hashable, Comparable,
    Sendable, CustomStringConvertible
{
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.description < rhs.description
    }
}

/// Durable, privacy-preserving place data. `PlaceFingerprint` stores only
/// normalized aggregate bins, coarse extents, and counts; this record cannot
/// carry camera pixels, raw descriptors, feature points, or mesh vertices.
public struct PlaceFingerprintRecord: Codable, Hashable, Sendable {
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let fingerprint: PlaceFingerprint
    public let createdAt: TimeInterval
    public let updatedAt: TimeInterval

    public init(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        fingerprint: PlaceFingerprint,
        createdAt: TimeInterval,
        updatedAt: TimeInterval
    ) throws {
        guard fingerprint.schema == .v1 else {
            throw PlaceMemoryRepositoryError.unsupportedFingerprintSchema(
                actual: fingerprint.schema.version
            )
        }
        try Self.validateTimestamp(createdAt)
        try Self.validateTimestamp(updatedAt)
        guard createdAt <= updatedAt else {
            throw PlaceMemoryRepositoryError.invalidDateOrder
        }

        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        self.fingerprint = fingerprint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case mapID
        case coordinateFrameID
        case fingerprint
        case createdAt
        case updatedAt
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
                fingerprint: container.decode(PlaceFingerprint.self, forKey: .fingerprint),
                createdAt: container.decode(TimeInterval.self, forKey: .createdAt),
                updatedAt: container.decode(TimeInterval.self, forKey: .updatedAt)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .fingerprint,
                in: container,
                debugDescription: "Place fingerprint record failed validation."
            )
        }
    }

    private static func validateTimestamp(_ value: TimeInterval) throws {
        guard value.isFinite, value >= 0 else {
            throw PlaceMemoryRepositoryError.invalidTimestamp
        }
    }
}

/// A replayable association state. Persisting observations instead of the
/// reducer's private working buffers gives decoding a deterministic integrity
/// check and prevents an unverified snapshot from bypassing reducer invariants.
public struct PlaceAssociationStateRecord: Codable, Hashable, Sendable {
    public static let currentPolicyVersion: UInt16 = 1
    public static let maximumObservationHistory = 64

    public let id: PlaceAssociationStateID
    public let policyVersion: UInt16
    public let context: PlaceAssociationContext
    public let observations: [PlaceAssociationObservation]
    public let revision: UInt64
    public let latestSequence: UInt64?
    public let latestDecision: PlaceAssociationDecision
    public let createdAt: TimeInterval
    public let updatedAt: TimeInterval

    public init(
        id: PlaceAssociationStateID = PlaceAssociationStateID(),
        policyVersion: UInt16 = Self.currentPolicyVersion,
        context: PlaceAssociationContext,
        observations: [PlaceAssociationObservation],
        createdAt: TimeInterval,
        updatedAt: TimeInterval
    ) throws {
        guard policyVersion == Self.currentPolicyVersion else {
            throw PlaceMemoryRepositoryError.invalidAssociationPolicyVersion(
                actual: policyVersion
            )
        }
        guard observations.count <= Self.maximumObservationHistory else {
            throw PlaceMemoryRepositoryError.associationHistoryCapacityReached(
                maximum: Self.maximumObservationHistory
            )
        }
        try Self.validateTimestamp(createdAt)
        try Self.validateTimestamp(updatedAt)
        guard createdAt <= updatedAt else {
            throw PlaceMemoryRepositoryError.invalidDateOrder
        }

        let ordered = observations.sorted(by: Self.observationOrder)
        let reducer: PlaceMapAssociationReducer
        do {
            reducer = try PlaceMapAssociationReducer.replay(
                context: context,
                observations: ordered
            )
        } catch {
            throw PlaceMemoryRepositoryError.invalidAssociationState
        }

        self.id = id
        self.policyVersion = policyVersion
        self.context = context
        self.observations = ordered
        revision = reducer.snapshot.revision
        latestSequence = reducer.snapshot.latestSequence
        latestDecision = reducer.decision()
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case policyVersion
        case context
        case observations
        case revision
        case latestSequence
        case latestDecision
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedRevision = try container.decode(UInt64.self, forKey: .revision)
        let encodedLatestSequence = try container.decodeIfPresent(
            UInt64.self,
            forKey: .latestSequence
        )
        let encodedDecision = try container.decode(
            PlaceAssociationDecision.self,
            forKey: .latestDecision
        )
        do {
            try self.init(
                id: container.decode(PlaceAssociationStateID.self, forKey: .id),
                policyVersion: container.decode(UInt16.self, forKey: .policyVersion),
                context: container.decode(PlaceAssociationContext.self, forKey: .context),
                observations: container.decode(
                    [PlaceAssociationObservation].self,
                    forKey: .observations
                ),
                createdAt: container.decode(TimeInterval.self, forKey: .createdAt),
                updatedAt: container.decode(TimeInterval.self, forKey: .updatedAt)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .observations,
                in: container,
                debugDescription: "Place association state failed deterministic replay."
            )
        }

        guard revision == encodedRevision,
            latestSequence == encodedLatestSequence,
            latestDecision == encodedDecision
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .revision,
                in: container,
                debugDescription: "Stored association summary does not match replayed observations."
            )
        }
    }

    private static func observationOrder(
        _ lhs: PlaceAssociationObservation,
        _ rhs: PlaceAssociationObservation
    ) -> Bool {
        if lhs.sequence != rhs.sequence {
            return lhs.sequence < rhs.sequence
        }
        return lhs.id < rhs.id
    }

    fileprivate var containsOnlyDeferredDecisions: Bool {
        var reducer = PlaceMapAssociationReducer(context: context)
        for observation in observations {
            guard let application = try? reducer.apply(observation) else {
                return false
            }
            let decision: PlaceAssociationDecision
            switch application {
            case .applied(_, let value), .alreadyApplied(_, let value):
                decision = value
            }
            guard case .deferDecision = decision.mutation else {
                return false
            }
        }
        return true
    }

    private static func validateTimestamp(_ value: TimeInterval) throws {
        guard value.isFinite, value >= 0 else {
            throw PlaceMemoryRepositoryError.invalidTimestamp
        }
    }
}

public struct PlaceMemoryCatalogSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let absoluteMaximumFingerprints = 128
    public static let absoluteMaximumAssociationStates = 128

    public let schemaVersion: UInt16
    public fileprivate(set) var fingerprints: [PlaceFingerprintRecord]
    public fileprivate(set) var associationStates: [PlaceAssociationStateRecord]
    /// Unknown IDs at or below this creation time have been retired. Retained
    /// IDs are still allowed exact retries and valid append-only extensions.
    public fileprivate(set) var retiredAssociationCreatedAtThrough: TimeInterval?

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        fingerprints: [PlaceFingerprintRecord] = [],
        associationStates: [PlaceAssociationStateRecord] = [],
        retiredAssociationCreatedAtThrough: TimeInterval? = nil
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PlaceMemoryRepositoryError.unsupportedCatalogSchema(actual: schemaVersion)
        }
        guard fingerprints.count <= Self.absoluteMaximumFingerprints else {
            throw PlaceMemoryRepositoryError.fingerprintCapacityReached(
                maximum: Self.absoluteMaximumFingerprints
            )
        }
        guard associationStates.count <= Self.absoluteMaximumAssociationStates else {
            throw PlaceMemoryRepositoryError.associationStateCapacityReached(
                maximum: Self.absoluteMaximumAssociationStates
            )
        }
        guard Set(fingerprints.map(\.mapID)).count == fingerprints.count,
            Set(associationStates.map(\.id)).count == associationStates.count
        else {
            throw PlaceMemoryRepositoryError.invalidAssociationState
        }
        if let retiredAssociationCreatedAtThrough {
            guard retiredAssociationCreatedAtThrough.isFinite,
                retiredAssociationCreatedAtThrough >= 0
            else {
                throw PlaceMemoryRepositoryError.invalidTimestamp
            }
        }

        self.schemaVersion = schemaVersion
        self.fingerprints = fingerprints.sorted(by: Self.fingerprintOrder)
        self.associationStates = associationStates.sorted(by: Self.associationOrder)
        self.retiredAssociationCreatedAtThrough = retiredAssociationCreatedAtThrough
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case fingerprints
        case associationStates
        case retiredAssociationCreatedAtThrough
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
                fingerprints: container.decode(
                    [PlaceFingerprintRecord].self,
                    forKey: .fingerprints
                ),
                associationStates: container.decode(
                    [PlaceAssociationStateRecord].self,
                    forKey: .associationStates
                ),
                retiredAssociationCreatedAtThrough: container.decodeIfPresent(
                    TimeInterval.self, forKey: .retiredAssociationCreatedAtThrough
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Place memory catalog failed validation."
            )
        }
    }

    fileprivate static func fingerprintOrder(
        _ lhs: PlaceFingerprintRecord,
        _ rhs: PlaceFingerprintRecord
    ) -> Bool {
        if lhs.mapID != rhs.mapID {
            return lhs.mapID < rhs.mapID
        }
        return lhs.coordinateFrameID < rhs.coordinateFrameID
    }

    fileprivate static func associationOrder(
        _ lhs: PlaceAssociationStateRecord,
        _ rhs: PlaceAssociationStateRecord
    ) -> Bool {
        lhs.id < rhs.id
    }
}

/// Versioned JSON repository for Phase 2 place fingerprints and association
/// attempts. Actor isolation serializes read-modify-write transactions, while
/// each commit is an atomic, data-protected replacement.
public actor PlaceMemoryRepository {
    public static let catalogFileName = "place-memory-v1.json"
    public static let maximumCatalogBytes = 4 * 1_024 * 1_024
    public static let defaultMaximumFingerprints = 32
    public static let defaultMaximumAssociationStates = 32

    private let directoryURL: URL
    private let catalogURL: URL
    private let fileManager: FileManager
    private let maximumFingerprints: Int
    private let maximumAssociationStates: Int

    public init(
        directoryURL: URL,
        maximumFingerprints: Int = PlaceMemoryRepository.defaultMaximumFingerprints,
        maximumAssociationStates: Int = PlaceMemoryRepository
            .defaultMaximumAssociationStates,
        fileManager: FileManager = .default
    ) {
        let standardizedDirectory = directoryURL.standardizedFileURL
        self.directoryURL = standardizedDirectory
        catalogURL = standardizedDirectory.appendingPathComponent(
            Self.catalogFileName,
            isDirectory: false
        )
        self.maximumFingerprints = min(
            max(1, maximumFingerprints),
            PlaceMemoryCatalogSnapshot.absoluteMaximumFingerprints
        )
        self.maximumAssociationStates = min(
            max(1, maximumAssociationStates),
            PlaceMemoryCatalogSnapshot.absoluteMaximumAssociationStates
        )
        self.fileManager = fileManager
    }

    public func catalogSnapshot() async throws -> PlaceMemoryCatalogSnapshot {
        try Task.checkCancellation()
        let catalog = try loadCatalogRecoveringInvalidData()
        try Task.checkCancellation()
        try validateConfiguredCapacity(catalog)
        return catalog
    }

    public func listFingerprints() async throws -> [PlaceFingerprintRecord] {
        try await catalogSnapshot().fingerprints
    }

    public func loadFingerprint(mapID: MapID) async throws -> PlaceFingerprintRecord? {
        try await catalogSnapshot().fingerprints.first { $0.mapID == mapID }
    }

    public func upsertFingerprint(_ record: PlaceFingerprintRecord) async throws {
        try Task.checkCancellation()
        var catalog = try loadCatalogRecoveringInvalidData()
        try Task.checkCancellation()
        try validateConfiguredCapacity(catalog)

        if let index = catalog.fingerprints.firstIndex(where: { $0.mapID == record.mapID }) {
            let existing = catalog.fingerprints[index]
            guard existing.coordinateFrameID == record.coordinateFrameID else {
                throw PlaceMemoryRepositoryError.mapCoordinateFrameConflict(mapID: record.mapID)
            }
            if existing == record {
                return
            }
            guard record.createdAt == existing.createdAt,
                record.updatedAt > existing.updatedAt
            else {
                throw PlaceMemoryRepositoryError.staleFingerprintUpdate(mapID: record.mapID)
            }
            catalog.fingerprints[index] = record
        } else {
            guard catalog.fingerprints.count < maximumFingerprints else {
                throw PlaceMemoryRepositoryError.fingerprintCapacityReached(
                    maximum: maximumFingerprints
                )
            }
            catalog.fingerprints.append(record)
        }
        catalog.fingerprints.sort(by: PlaceMemoryCatalogSnapshot.fingerprintOrder)
        try Task.checkCancellation()
        try commit(catalog)
    }

    public func listAssociationStates() async throws -> [PlaceAssociationStateRecord] {
        try await catalogSnapshot().associationStates
    }

    public func loadAssociationState(
        id: PlaceAssociationStateID
    ) async throws -> PlaceAssociationStateRecord? {
        try await catalogSnapshot().associationStates.first { $0.id == id }
    }

    /// No suspension occurs between validating the catalog, retiring history,
    /// and committing the replacement. A late write cannot resurrect an
    /// evicted attempt, even after a process restart. Capacity is still an
    /// error when all retained histories contain unacknowledged mutations.
    public func upsertAssociationState(
        _ state: PlaceAssociationStateRecord,
        retention: PlaceAssociationHistoryRetention = .preserveAll
    ) async throws {
        try Task.checkCancellation()
        var catalog = try loadCatalogRecoveringInvalidData()
        try Task.checkCancellation()
        try validateConfiguredCapacity(catalog)

        if let index = catalog.associationStates.firstIndex(where: { $0.id == state.id }) {
            let existing = catalog.associationStates[index]
            guard existing.context == state.context,
                existing.policyVersion == state.policyVersion,
                existing.createdAt == state.createdAt
            else {
                throw PlaceMemoryRepositoryError.associationContextConflict(id: state.id)
            }
            if existing == state {
                return
            }
            guard state.revision > existing.revision,
                state.updatedAt > existing.updatedAt
            else {
                throw PlaceMemoryRepositoryError.staleAssociationStateUpdate(id: state.id)
            }
            guard state.observations.starts(with: existing.observations) else {
                throw PlaceMemoryRepositoryError.associationHistoryDiverged(id: state.id)
            }
            catalog.associationStates[index] = state
        } else {
            if let retiredThrough = catalog.retiredAssociationCreatedAtThrough,
                state.createdAt <= retiredThrough
            {
                throw PlaceMemoryRepositoryError.retiredAssociationState(id: state.id)
            }
            if catalog.associationStates.count >= maximumAssociationStates,
                case .retireOlderDeferredAttempts = retention,
                let retired = catalog.associationStates
                    .filter({ $0.createdAt < state.createdAt && $0.containsOnlyDeferredDecisions })
                    .min(by: {
                        if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                        return $0.id < $1.id
                    })
            {
                catalog.associationStates.removeAll { $0.id == retired.id }
                catalog.retiredAssociationCreatedAtThrough = max(
                    catalog.retiredAssociationCreatedAtThrough ?? 0, retired.createdAt
                )
            }
            guard catalog.associationStates.count < maximumAssociationStates else {
                throw PlaceMemoryRepositoryError.associationStateCapacityReached(
                    maximum: maximumAssociationStates
                )
            }
            catalog.associationStates.append(state)
        }
        catalog.associationStates.sort(by: PlaceMemoryCatalogSnapshot.associationOrder)
        try Task.checkCancellation()
        try commit(catalog)
    }

    private func loadCatalogRecoveringInvalidData() throws -> PlaceMemoryCatalogSnapshot {
        try SpatialStorageDirectory.prepare(
            at: directoryURL,
            fileManager: fileManager,
            createIfMissing: false
        )
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            return try PlaceMemoryCatalogSnapshot()
        }

        let data: Data
        do {
            data = try readBoundedCatalog()
        } catch let error as PlaceMemoryRepositoryError {
            guard case .catalogTooLarge = error else {
                throw error
            }
            try quarantineCatalog(reason: String(describing: error))
            return try PlaceMemoryCatalogSnapshot()
        } catch {
            // File protection and transient filesystem errors are not evidence
            // that the durable catalog is corrupt.
            throw error
        }

        do {
            return try JSONDecoder().decode(PlaceMemoryCatalogSnapshot.self, from: data)
        } catch {
            try quarantineCatalog(reason: String(describing: error))
            return try PlaceMemoryCatalogSnapshot()
        }
    }

    private func readBoundedCatalog() throws -> Data {
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
            throw PlaceMemoryRepositoryError.catalogTooLarge(
                actual: data.count,
                maximum: Self.maximumCatalogBytes
            )
        }
        return data
    }

    private func validateConfiguredCapacity(_ catalog: PlaceMemoryCatalogSnapshot) throws {
        guard catalog.fingerprints.count <= maximumFingerprints else {
            throw PlaceMemoryRepositoryError.fingerprintCapacityReached(
                maximum: maximumFingerprints
            )
        }
        guard catalog.associationStates.count <= maximumAssociationStates else {
            throw PlaceMemoryRepositoryError.associationStateCapacityReached(
                maximum: maximumAssociationStates
            )
        }
    }

    private func commit(_ catalog: PlaceMemoryCatalogSnapshot) throws {
        try validateConfiguredCapacity(catalog)
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog)
        guard data.count <= Self.maximumCatalogBytes else {
            throw PlaceMemoryRepositoryError.catalogTooLarge(
                actual: data.count,
                maximum: Self.maximumCatalogBytes
            )
        }
        try data.write(
            to: catalogURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
    }

    private func quarantineCatalog(reason: String) throws {
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
            "place-memory-v1.\(nonce).json.quarantined",
            isDirectory: false
        )
        let reasonURL = quarantineDirectory.appendingPathComponent(
            "place-memory-v1.\(nonce).reason.txt",
            isDirectory: false
        )
        try Data(String(reason.prefix(2_048)).utf8).write(
            to: reasonURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        do {
            try fileManager.moveItem(at: catalogURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: reasonURL)
            throw error
        }
    }

    private func prepareDirectory() throws {
        try SpatialStorageDirectory.prepare(at: directoryURL, fileManager: fileManager)
    }
}
