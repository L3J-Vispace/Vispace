import Foundation
import VispaceCore

public enum SceneGraphRepositoryError: Error, Equatable, Sendable {
    case catalogTooLarge(actual: Int, maximum: Int)
    case unsupportedCatalogSchema(UInt16)
    case unsupportedRecordSchema(UInt16)
    case invalidTimestamp
    case invalidRevision
    case historyContainsActiveRelation
    case duplicateMap(MapID)
    case mapCapacityReached(maximum: Int)
    case mapCoordinateFrameConflict(MapID)
    case revisionConflict(expected: UInt64, actual: UInt64)
    case historyCapacityExceeded(maximum: Int)
    case updateIDCapacityExceeded(maximum: Int)
    case invalidUpdateHistory
    case invalidProjectionMode
}

public enum SceneGraphGeometryProjection: String, Codable, Sendable {
    case materialized
    /// Geometry edges are derived for the grounded query from durable object
    /// metadata. An absent cached edge in this mode is never negative evidence.
    case onDemand
}

public struct SceneGraphMapRecord: Codable, Sendable {
    public static let currentSchemaVersion: UInt16 = 2
    public static let absoluteMaximumHistoryCount = 2_048
    public static let absoluteMaximumAppliedUpdateIDs = 512

    public let schemaVersion: UInt16
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let revision: UInt64
    public let graph: SceneGraph
    public let geometryProjection: SceneGraphGeometryProjection
    public let expiredRelationHistory: [SpatialRelation]
    public let appliedUpdateIDs: Set<UUID>
    /// Oldest to newest. Revision checks reject replays outside this window.
    public let appliedUpdateOrder: [UUID]
    public let createdAt: TimeInterval
    public let updatedAt: TimeInterval

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        revision: UInt64,
        graph: SceneGraph,
        geometryProjection: SceneGraphGeometryProjection = .materialized,
        expiredRelationHistory: [SpatialRelation] = [],
        appliedUpdateIDs: Set<UUID> = [],
        appliedUpdateOrder: [UUID]? = nil,
        createdAt: TimeInterval,
        updatedAt: TimeInterval
    ) throws {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw SceneGraphRepositoryError.unsupportedRecordSchema(schemaVersion)
        }
        guard createdAt.isFinite, createdAt >= 0,
            updatedAt.isFinite, updatedAt >= createdAt
        else {
            throw SceneGraphRepositoryError.invalidTimestamp
        }
        guard revision > 0 else {
            throw SceneGraphRepositoryError.invalidRevision
        }
        guard expiredRelationHistory.count <= Self.absoluteMaximumHistoryCount else {
            throw SceneGraphRepositoryError.historyCapacityExceeded(
                maximum: Self.absoluteMaximumHistoryCount
            )
        }
        guard expiredRelationHistory.allSatisfy({ $0.validUntil != nil }) else {
            throw SceneGraphRepositoryError.historyContainsActiveRelation
        }
        guard geometryProjection != .onDemand || (
            graph.relations(includeProvisional: true).allSatisfy { !$0.key.predicate.isGeometryDerived }
                && expiredRelationHistory.allSatisfy { !$0.key.predicate.isGeometryDerived }
        ) else { throw SceneGraphRepositoryError.invalidProjectionMode }
        guard appliedUpdateIDs.count <= Self.absoluteMaximumAppliedUpdateIDs else {
            throw SceneGraphRepositoryError.updateIDCapacityExceeded(
                maximum: Self.absoluteMaximumAppliedUpdateIDs
            )
        }
        // Schema v1 catalogs did not record ordering. Migrate deterministically;
        // all newly applied updates retain their real insertion order.
        let updateOrder = appliedUpdateOrder ?? appliedUpdateIDs.sorted { $0.uuidString < $1.uuidString }
        guard updateOrder.count == appliedUpdateIDs.count,
            Set(updateOrder) == appliedUpdateIDs
        else {
            throw SceneGraphRepositoryError.invalidUpdateHistory
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        self.revision = revision
        self.graph = graph
        self.geometryProjection = geometryProjection
        self.expiredRelationHistory = expiredRelationHistory
        self.appliedUpdateIDs = appliedUpdateIDs
        self.appliedUpdateOrder = updateOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mapID
        case coordinateFrameID
        case revision
        case graph
        case geometryProjection
        case expiredRelationHistory
        case appliedUpdateIDs
        case appliedUpdateOrder
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(UInt16.self, forKey: .schemaVersion)
        do {
            try self.init(
                schemaVersion: version,
                mapID: container.decode(MapID.self, forKey: .mapID),
                coordinateFrameID: container.decode(
                    CoordinateFrameID.self,
                    forKey: .coordinateFrameID
                ),
                revision: container.decode(UInt64.self, forKey: .revision),
                graph: container.decode(SceneGraph.self, forKey: .graph),
                geometryProjection: version == 1 ? .materialized : container.decode(
                    SceneGraphGeometryProjection.self, forKey: .geometryProjection
                ),
                expiredRelationHistory: container.decode(
                    [SpatialRelation].self,
                    forKey: .expiredRelationHistory
                ),
                appliedUpdateIDs: container.decode(
                    Set<UUID>.self,
                    forKey: .appliedUpdateIDs
                ),
                appliedUpdateOrder: container.decodeIfPresent(
                    [UUID].self, forKey: .appliedUpdateOrder
                ),
                createdAt: container.decode(TimeInterval.self, forKey: .createdAt),
                updatedAt: container.decode(TimeInterval.self, forKey: .updatedAt)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .graph,
                in: container,
                debugDescription: "Scene graph record failed validation."
            )
        }
    }

    fileprivate var cachedGeometryCount: Int {
        graph.relations(includeProvisional: true).filter { $0.key.predicate.isGeometryDerived }.count
            + expiredRelationHistory.filter { $0.key.predicate.isGeometryDerived }.count
    }

    fileprivate func withoutGeometryCache() throws -> SceneGraphMapRecord {
        var retained = SceneGraph(confidencePolicy: graph.confidencePolicy)
        for relation in graph.relations(includeProvisional: true) where !relation.key.predicate.isGeometryDerived {
            try retained.upsert(relation)
        }
        return try SceneGraphMapRecord(
            mapID: mapID, coordinateFrameID: coordinateFrameID, revision: revision,
            graph: retained, geometryProjection: .onDemand,
            expiredRelationHistory: expiredRelationHistory.filter { !$0.key.predicate.isGeometryDerived },
            appliedUpdateIDs: appliedUpdateIDs, appliedUpdateOrder: appliedUpdateOrder,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }
}

public struct SceneGraphCatalogSnapshot: Codable, Sendable {
    public static let currentSchemaVersion: UInt16 = 2
    public static let absoluteMaximumMapCount = 64

    public let schemaVersion: UInt16
    public fileprivate(set) var records: [SceneGraphMapRecord]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        records: [SceneGraphMapRecord] = []
    ) throws {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw SceneGraphRepositoryError.unsupportedCatalogSchema(schemaVersion)
        }
        guard records.count <= Self.absoluteMaximumMapCount else {
            throw SceneGraphRepositoryError.mapCapacityReached(
                maximum: Self.absoluteMaximumMapCount
            )
        }
        var mapIDs: Set<MapID> = []
        for record in records where !mapIDs.insert(record.mapID).inserted {
            throw SceneGraphRepositoryError.duplicateMap(record.mapID)
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.records = records.sorted { $0.mapID < $1.mapID }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case records
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
                records: container.decode([SceneGraphMapRecord].self, forKey: .records)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .records,
                in: container,
                debugDescription: "Scene graph catalog failed validation."
            )
        }
    }
}

public struct SceneGraphMapUpdate: Sendable {
    public let id: UUID
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let baseRevision: UInt64
    public let graph: SceneGraph
    public let geometryProjection: SceneGraphGeometryProjection
    public let expiredRelationHistory: [SpatialRelation]
    public let timestamp: TimeInterval

    public init(
        id: UUID = UUID(),
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        baseRevision: UInt64,
        graph: SceneGraph,
        geometryProjection: SceneGraphGeometryProjection = .materialized,
        expiredRelationHistory: [SpatialRelation],
        timestamp: TimeInterval
    ) {
        self.id = id
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        self.baseRevision = baseRevision
        self.graph = graph
        self.geometryProjection = geometryProjection
        self.expiredRelationHistory = expiredRelationHistory
        self.timestamp = timestamp
    }
}

public enum SceneGraphUpdateResult: Sendable {
    case applied(SceneGraphMapRecord)
    case alreadyApplied(SceneGraphMapRecord)
}

/// Bounded, atomically replaced, data-protected scene graph storage. Raw image
/// or mesh buffers are not representable by this schema.
public actor SceneGraphRepository {
    public static let catalogFileName = "scene-graphs-v1.json"
    public static let maximumCatalogBytes = 4 * 1_024 * 1_024
    public static let maximumCachedGeometryRelationsPerMap = 1_024

    private let directoryURL: URL
    private let catalogURL: URL
    private let maximumMapCount: Int
    private let catalogByteLimit: Int
    private let fileManager: FileManager

    public init(
        directoryURL: URL,
        maximumMapCount: Int = 32,
        catalogByteLimit: Int = SceneGraphRepository.maximumCatalogBytes,
        fileManager: FileManager = .default
    ) {
        let directory = directoryURL.standardizedFileURL
        self.directoryURL = directory
        catalogURL = directory.appendingPathComponent(Self.catalogFileName)
        self.maximumMapCount = min(
            max(1, maximumMapCount),
            SceneGraphCatalogSnapshot.absoluteMaximumMapCount
        )
        self.fileManager = fileManager
        self.catalogByteLimit = min(Self.maximumCatalogBytes, max(1_024, catalogByteLimit))
    }

    public func catalogSnapshot() async throws -> SceneGraphCatalogSnapshot {
        try Task.checkCancellation()
        let catalog = try loadRecoveringInvalidData()
        try validateConfiguredCapacity(catalog)
        return catalog
    }

    public func load(mapID: MapID) async throws -> SceneGraphMapRecord? {
        try await catalogSnapshot().records.first { $0.mapID == mapID }
    }

    /// Tiny independent receipt: non-reproducible evidence can fill the graph
    /// catalog, but that must not prevent object commits or masquerade as a
    /// complete relation snapshot after process restart.
    public func isProjectionDeferred(mapID: MapID) throws -> Bool {
        try projectionDeferrals()[mapID] != nil
    }

    public func recordCapacityDeferral(mapID: MapID, baseRevision: UInt64) throws {
        try Task.checkCancellation()
        var deferred = try projectionDeferrals()
        deferred[mapID] = max(deferred[mapID] ?? 0, baseRevision)
        try writeProjectionDeferrals(deferred)
    }

    public func acknowledgeCurrentProjection(mapID: MapID) async throws {
        guard let record = try await load(mapID: mapID) else { return }
        try clearProjectionDeferral(mapID: mapID, committedRevision: record.revision)
    }

    @discardableResult
    public func apply(_ update: SceneGraphMapUpdate) async throws -> SceneGraphUpdateResult {
        try Task.checkCancellation()
        guard update.timestamp.isFinite, update.timestamp >= 0 else {
            throw SceneGraphRepositoryError.invalidTimestamp
        }
        var catalog = try loadRecoveringInvalidData()
        try validateConfiguredCapacity(catalog)

        if let index = catalog.records.firstIndex(where: { $0.mapID == update.mapID }) {
            let existing = catalog.records[index]
            guard existing.coordinateFrameID == update.coordinateFrameID else {
                throw SceneGraphRepositoryError.mapCoordinateFrameConflict(update.mapID)
            }
            if existing.appliedUpdateIDs.contains(update.id) {
                try clearProjectionDeferral(mapID: update.mapID, committedRevision: existing.revision)
                return .alreadyApplied(existing)
            }
            guard existing.revision == update.baseRevision else {
                throw SceneGraphRepositoryError.revisionConflict(
                    expected: existing.revision,
                    actual: update.baseRevision
                )
            }
            guard existing.revision < UInt64.max else {
                throw SceneGraphRepositoryError.invalidRevision
            }
            let updateOrder = Array(
                (existing.appliedUpdateOrder + [update.id])
                    .suffix(SceneGraphMapRecord.absoluteMaximumAppliedUpdateIDs)
            )
            let record = try SceneGraphMapRecord(
                mapID: update.mapID,
                coordinateFrameID: update.coordinateFrameID,
                revision: existing.revision + 1,
                graph: update.graph,
                geometryProjection: update.geometryProjection,
                expiredRelationHistory: update.expiredRelationHistory,
                appliedUpdateIDs: Set(updateOrder),
                appliedUpdateOrder: updateOrder,
                createdAt: existing.createdAt,
                updatedAt: max(update.timestamp, existing.updatedAt.nextUp)
            )
            catalog.records[index] = record
            try Task.checkCancellation()
            let committed = try commit(catalog)
            try clearProjectionDeferral(mapID: update.mapID, committedRevision: committed.records[index].revision)
            return .applied(committed.records[index])
        }

        guard update.baseRevision == 0 else {
            throw SceneGraphRepositoryError.revisionConflict(
                expected: 0,
                actual: update.baseRevision
            )
        }
        guard catalog.records.count < maximumMapCount else {
            throw SceneGraphRepositoryError.mapCapacityReached(maximum: maximumMapCount)
        }
        let record = try SceneGraphMapRecord(
            mapID: update.mapID,
            coordinateFrameID: update.coordinateFrameID,
            revision: 1,
            graph: update.graph,
            geometryProjection: update.geometryProjection,
            expiredRelationHistory: update.expiredRelationHistory,
            appliedUpdateIDs: [update.id],
            createdAt: update.timestamp,
            updatedAt: update.timestamp
        )
        catalog.records.append(record)
        catalog.records.sort { $0.mapID < $1.mapID }
        try Task.checkCancellation()
        let committed = try commit(catalog)
        try clearProjectionDeferral(mapID: update.mapID, committedRevision: record.revision)
        return .applied(committed.records.first { $0.mapID == update.mapID } ?? record)
    }

    public func deleteMap(mapID: MapID) async throws {
        try Task.checkCancellation()
        var catalog = try loadRecoveringInvalidData()
        catalog.records.removeAll { $0.mapID == mapID }
        try Task.checkCancellation()
        try commit(catalog, reclaiming: true)
        try clearProjectionDeferral(mapID: mapID)
    }

    private func loadRecoveringInvalidData() throws -> SceneGraphCatalogSnapshot {
        try SpatialStorageDirectory.prepare(
            at: directoryURL,
            fileManager: fileManager,
            createIfMissing: false
        )
        try SpatialStorageDirectory.validatePath(at: catalogURL, fileManager: fileManager)
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            return try SceneGraphCatalogSnapshot()
        }
        do {
            let data = try readBounded()
            try SpatialStorageDirectory.validateJSONSchemas(data, maximumSchemaVersion: 2)
            return try JSONDecoder().decode(SceneGraphCatalogSnapshot.self, from: data)
        } catch let error as SceneGraphRepositoryError {
            guard case .catalogTooLarge = error else {
                throw error
            }
            try quarantine(reason: String(describing: error))
            return try SceneGraphCatalogSnapshot()
        } catch is DecodingError {
            try quarantine(reason: "Scene graph catalog failed secure structural validation.")
            return try SceneGraphCatalogSnapshot()
        }
    }

    private func readBounded() throws -> Data {
        try SpatialStorageDirectory.validateRegularFile(at: catalogURL, fileManager: fileManager)
        let handle = try FileHandle(forReadingFrom: catalogURL)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= Self.maximumCatalogBytes {
            guard let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        guard data.count <= Self.maximumCatalogBytes else {
            throw SceneGraphRepositoryError.catalogTooLarge(
                actual: data.count,
                maximum: Self.maximumCatalogBytes
            )
        }
        return data
    }

    private func validateConfiguredCapacity(_ catalog: SceneGraphCatalogSnapshot) throws {
        guard catalog.records.count <= maximumMapCount else {
            throw SceneGraphRepositoryError.mapCapacityReached(maximum: maximumMapCount)
        }
    }

    @discardableResult
    private func commit(_ input: SceneGraphCatalogSnapshot, reclaiming: Bool = false) throws -> SceneGraphCatalogSnapshot {
        var catalog = input
        try validateConfiguredCapacity(catalog)
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for index in catalog.records.indices
        where catalog.records[index].cachedGeometryCount > Self.maximumCachedGeometryRelationsPerMap {
            catalog.records[index] = try catalog.records[index].withoutGeometryCache()
        }
        var data = try encoder.encode(catalog)
        // Only reproducible geometry is evictable. Explicit graph evidence and
        // its history are preserved even when that means reporting real storage
        // exhaustion. Largest caches go first; MapID order breaks equal ties.
        let evictionOrder = catalog.records.indices.sorted {
            let left = catalog.records[$0].cachedGeometryCount
            let right = catalog.records[$1].cachedGeometryCount
            return left == right ? catalog.records[$0].mapID < catalog.records[$1].mapID : left > right
        }
        for index in evictionOrder where data.count > catalogByteLimit {
            guard catalog.records[index].cachedGeometryCount > 0 else { continue }
            catalog.records[index] = try catalog.records[index].withoutGeometryCache()
            data = try encoder.encode(catalog)
        }
        guard data.count <= catalogByteLimit else {
            throw SceneGraphRepositoryError.catalogTooLarge(
                actual: data.count,
                maximum: catalogByteLimit
            )
        }
        try SpatialStorageDirectory.atomicWrite(
            data, to: catalogURL, directory: directoryURL, fileManager: fileManager, reclaiming: reclaiming
        )
        return catalog
    }

    private struct ProjectionDeferrals: Codable {
        let schemaVersion: UInt16
        let entries: [Entry]

        struct Entry: Codable {
            let mapID: MapID
            let baseRevision: UInt64
        }
    }

    private var projectionDeferralsURL: URL {
        directoryURL.appendingPathComponent("scene-graph-projection-deferrals-v1.json")
    }

    private func projectionDeferrals() throws -> [MapID: UInt64] {
        let url = projectionDeferralsURL
        try SpatialStorageDirectory.validatePath(at: url, fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        try SpatialStorageDirectory.validateRegularFile(at: url, fileManager: fileManager)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16_385) ?? Data()
        guard data.count <= 16_384 else {
            throw SceneGraphRepositoryError.invalidProjectionMode
        }
        try SpatialStorageDirectory.validateJSONSchemas(data)
        let receipt = try JSONDecoder().decode(ProjectionDeferrals.self, from: data)
        guard receipt.schemaVersion == 1 else {
            throw SceneGraphRepositoryError.unsupportedCatalogSchema(receipt.schemaVersion)
        }
        let ids = Set(receipt.entries.map(\.mapID))
        guard ids.count == receipt.entries.count, ids.count <= SceneGraphCatalogSnapshot.absoluteMaximumMapCount else {
            throw SceneGraphRepositoryError.invalidProjectionMode
        }
        return Dictionary(uniqueKeysWithValues: receipt.entries.map { ($0.mapID, $0.baseRevision) })
    }

    private func writeProjectionDeferrals(_ ids: [MapID: UInt64], reclaiming: Bool = false) throws {
        guard ids.count <= SceneGraphCatalogSnapshot.absoluteMaximumMapCount else {
            throw SceneGraphRepositoryError.mapCapacityReached(maximum: SceneGraphCatalogSnapshot.absoluteMaximumMapCount)
        }
        try prepareDirectory()
        let entries = ids.sorted { $0.key < $1.key }.map {
            ProjectionDeferrals.Entry(mapID: $0.key, baseRevision: $0.value)
        }
        let data = try JSONEncoder().encode(ProjectionDeferrals(schemaVersion: 1, entries: entries))
        try SpatialStorageDirectory.atomicWrite(
            data, to: projectionDeferralsURL, directory: directoryURL, fileManager: fileManager,
            reclaiming: reclaiming
        )
    }

    private func clearProjectionDeferral(mapID: MapID, committedRevision: UInt64? = nil) throws {
        var deferred = try projectionDeferrals()
        guard let failedBase = deferred[mapID], committedRevision.map({ $0 > failedBase }) ?? true else { return }
        deferred.removeValue(forKey: mapID)
        try writeProjectionDeferrals(deferred, reclaiming: true)
    }

    private func quarantine(reason: String) throws {
        try SpatialStorageDirectory.validatePath(at: catalogURL, fileManager: fileManager)
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            return
        }
        try prepareDirectory()
        let quarantine = directoryURL.appendingPathComponent("Quarantine", isDirectory: true)
        try SpatialStorageDirectory.prepare(
            at: quarantine,
            fileManager: fileManager
        )
        let nonce = UUID().uuidString.lowercased()
        let destination = quarantine.appendingPathComponent(
            "scene-graphs-v1.\(nonce).json.quarantined"
        )
        try fileManager.moveItem(at: catalogURL, to: destination)
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        try Data(String(reason.prefix(2_048)).utf8).write(
            to: quarantine.appendingPathComponent(
                "scene-graphs-v1.\(nonce).reason.txt"
            ),
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        try? SpatialStorageDirectory.maintainArtifacts(at: directoryURL, fileManager: fileManager)
    }

    private func prepareDirectory() throws {
        try SpatialStorageDirectory.prepare(at: directoryURL, fileManager: fileManager)
    }
}
