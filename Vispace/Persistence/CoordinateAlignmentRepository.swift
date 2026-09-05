import Foundation
import VispaceCore

public enum CoordinateAlignmentRepositoryError: Error, Equatable, Sendable {
    case catalogTooLarge(actual: Int, maximum: Int)
    case unsupportedCatalogSchema(actual: UInt16)
    case unsupportedRecordSchema(actual: UInt16)
    case alignmentCapacityReached(maximum: Int)
    case identicalMaps(MapID)
    case invalidTimestamp
    case invalidDateOrder
    case resultFrameMismatch(
        expectedSource: CoordinateFrameID,
        actualSource: CoordinateFrameID,
        expectedTarget: CoordinateFrameID,
        actualTarget: CoordinateFrameID
    )
    case duplicateMapPair(first: MapID, second: MapID)
    case inverseAlignmentConflict(sourceMapID: MapID, targetMapID: MapID)
    case alignmentContextConflict(sourceMapID: MapID, targetMapID: MapID)
    case mapCoordinateFrameConflict(mapID: MapID)
    case staleAlignmentUpdate(sourceMapID: MapID, targetMapID: MapID)
    case immutableAlignmentConflict(sourceMapID: MapID, targetMapID: MapID)
    case inconsistentAlignmentCycle(sourceMapID: MapID, targetMapID: MapID)
}

/// An unordered, deterministic map-pair key. Alignment direction remains on
/// the record because a source-to-target transform cannot be used backwards.
public struct CoordinateAlignmentMapPair: Codable, Hashable, Comparable, Sendable {
    public let first: MapID
    public let second: MapID

    public init(_ first: MapID, _ second: MapID) throws {
        guard first != second else {
            throw CoordinateAlignmentRepositoryError.identicalMaps(first)
        }
        if first < second {
            self.first = first
            self.second = second
        } else {
            self.first = second
            self.second = first
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.first != rhs.first {
            return lhs.first < rhs.first
        }
        return lhs.second < rhs.second
    }

    private enum CodingKeys: String, CodingKey {
        case first
        case second
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedFirst = try container.decode(MapID.self, forKey: .first)
        let encodedSecond = try container.decode(MapID.self, forKey: .second)
        do {
            try self.init(encodedFirst, encodedSecond)
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .first,
                in: container,
                debugDescription: "Coordinate alignment map pair is invalid."
            )
        }
        guard first == encodedFirst, second == encodedSecond else {
            throw DecodingError.dataCorruptedError(
                forKey: .first,
                in: container,
                debugDescription: "Coordinate alignment map pair is not canonical."
            )
        }
    }
}

/// A validated, directional alignment between two logical maps. Coordinate
/// frame IDs are intentionally duplicated beside `result` so catalog decoding
/// can detect a record/result substitution instead of silently trusting it.
public struct CoordinateAlignmentRecord: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let sourceMapID: MapID
    public let sourceCoordinateFrameID: CoordinateFrameID
    public let targetMapID: MapID
    public let targetCoordinateFrameID: CoordinateFrameID
    public let result: CoordinateFrameAlignmentResult
    public let createdAt: TimeInterval
    public let updatedAt: TimeInterval

    public var mapPair: CoordinateAlignmentMapPair {
        // Validation in every initializer makes this construction infallible.
        try! CoordinateAlignmentMapPair(sourceMapID, targetMapID)
    }

    public var isCanonical: Bool {
        sourceMapID < targetMapID
    }

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        sourceMapID: MapID,
        sourceCoordinateFrameID: CoordinateFrameID,
        targetMapID: MapID,
        targetCoordinateFrameID: CoordinateFrameID,
        result: CoordinateFrameAlignmentResult,
        createdAt: TimeInterval,
        updatedAt: TimeInterval
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CoordinateAlignmentRepositoryError.unsupportedRecordSchema(
                actual: schemaVersion
            )
        }
        _ = try CoordinateAlignmentMapPair(sourceMapID, targetMapID)
        try Self.validateTimestamp(createdAt)
        try Self.validateTimestamp(updatedAt)
        guard createdAt <= updatedAt else {
            throw CoordinateAlignmentRepositoryError.invalidDateOrder
        }
        guard result.sourceCoordinateFrameID == sourceCoordinateFrameID,
            result.targetCoordinateFrameID == targetCoordinateFrameID
        else {
            throw CoordinateAlignmentRepositoryError.resultFrameMismatch(
                expectedSource: sourceCoordinateFrameID,
                actualSource: result.sourceCoordinateFrameID,
                expectedTarget: targetCoordinateFrameID,
                actualTarget: result.targetCoordinateFrameID
            )
        }

        self.schemaVersion = schemaVersion
        self.sourceMapID = sourceMapID
        self.sourceCoordinateFrameID = sourceCoordinateFrameID
        self.targetMapID = targetMapID
        self.targetCoordinateFrameID = targetCoordinateFrameID
        self.result = result
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Returns this record in the one durable direction used for an unordered
    /// map pair. Reversing an input also reverses its validated transform; map
    /// identifiers and frame identifiers are never swapped independently.
    public func canonicalized() throws -> Self {
        guard !isCanonical else {
            return self
        }
        return try Self(
            schemaVersion: schemaVersion,
            sourceMapID: targetMapID,
            sourceCoordinateFrameID: targetCoordinateFrameID,
            targetMapID: sourceMapID,
            targetCoordinateFrameID: sourceCoordinateFrameID,
            result: result.inverted(),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sourceMapID
        case sourceCoordinateFrameID
        case targetMapID
        case targetCoordinateFrameID
        case result
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
                sourceMapID: container.decode(MapID.self, forKey: .sourceMapID),
                sourceCoordinateFrameID: container.decode(
                    CoordinateFrameID.self,
                    forKey: .sourceCoordinateFrameID
                ),
                targetMapID: container.decode(MapID.self, forKey: .targetMapID),
                targetCoordinateFrameID: container.decode(
                    CoordinateFrameID.self,
                    forKey: .targetCoordinateFrameID
                ),
                result: container.decode(
                    CoordinateFrameAlignmentResult.self,
                    forKey: .result
                ),
                createdAt: container.decode(TimeInterval.self, forKey: .createdAt),
                updatedAt: container.decode(TimeInterval.self, forKey: .updatedAt)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .result,
                in: container,
                debugDescription: "Coordinate alignment record failed validation."
            )
        }
    }

    private static func validateTimestamp(_ value: TimeInterval) throws {
        guard value.isFinite, value >= 0 else {
            throw CoordinateAlignmentRepositoryError.invalidTimestamp
        }
    }
}

public enum CoordinateAlignmentCommitResult: Equatable, Sendable {
    case committed(CoordinateAlignmentRecord)
    case alreadyCommitted(CoordinateAlignmentRecord)
}

public struct CoordinateAlignmentCatalogSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let absoluteMaximumAlignments = 128

    public let schemaVersion: UInt16
    public fileprivate(set) var alignments: [CoordinateAlignmentRecord]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        alignments: [CoordinateAlignmentRecord] = []
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CoordinateAlignmentRepositoryError.unsupportedCatalogSchema(
                actual: schemaVersion
            )
        }
        guard alignments.count <= Self.absoluteMaximumAlignments else {
            throw CoordinateAlignmentRepositoryError.alignmentCapacityReached(
                maximum: Self.absoluteMaximumAlignments
            )
        }

        let ordered = try alignments.map { try $0.canonicalized() }
            .sorted(by: Self.alignmentOrder)
        var seenPairs = Set<CoordinateAlignmentMapPair>()
        var framesByMap = [MapID: CoordinateFrameID]()
        for record in ordered {
            guard seenPairs.insert(record.mapPair).inserted else {
                throw CoordinateAlignmentRepositoryError.duplicateMapPair(
                    first: record.mapPair.first,
                    second: record.mapPair.second
                )
            }
            try Self.bind(
                mapID: record.sourceMapID,
                to: record.sourceCoordinateFrameID,
                framesByMap: &framesByMap
            )
            try Self.bind(
                mapID: record.targetMapID,
                to: record.targetCoordinateFrameID,
                framesByMap: &framesByMap
            )
        }

        self.schemaVersion = schemaVersion
        self.alignments = ordered
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case alignments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
                alignments: container.decode(
                    [CoordinateAlignmentRecord].self,
                    forKey: .alignments
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .alignments,
                in: container,
                debugDescription: "Coordinate alignment catalog failed validation."
            )
        }
    }

    fileprivate static func alignmentOrder(
        _ lhs: CoordinateAlignmentRecord,
        _ rhs: CoordinateAlignmentRecord
    ) -> Bool {
        if lhs.mapPair != rhs.mapPair {
            return lhs.mapPair < rhs.mapPair
        }
        if lhs.sourceMapID != rhs.sourceMapID {
            return lhs.sourceMapID < rhs.sourceMapID
        }
        return lhs.targetMapID < rhs.targetMapID
    }

    fileprivate static func validateMapFrameBindings(
        _ records: [CoordinateAlignmentRecord]
    ) throws {
        var framesByMap = [MapID: CoordinateFrameID]()
        for record in records {
            try bind(
                mapID: record.sourceMapID,
                to: record.sourceCoordinateFrameID,
                framesByMap: &framesByMap
            )
            try bind(
                mapID: record.targetMapID,
                to: record.targetCoordinateFrameID,
                framesByMap: &framesByMap
            )
        }
    }

    private static func bind(
        mapID: MapID,
        to frameID: CoordinateFrameID,
        framesByMap: inout [MapID: CoordinateFrameID]
    ) throws {
        if let existing = framesByMap[mapID], existing != frameID {
            throw CoordinateAlignmentRepositoryError.mapCoordinateFrameConflict(
                mapID: mapID
            )
        }
        framesByMap[mapID] = frameID
    }
}

/// A bounded, data-protected repository for validated cross-map coordinate
/// transforms. Actor isolation makes each read-modify-write transaction serial.
public actor CoordinateAlignmentRepository {
    public static let catalogFileName = "coordinate-alignments-v1.json"
    public static let maximumCatalogBytes = 1 * 1_024 * 1_024
    public static let defaultMaximumAlignments = 128

    /// A logical map edge is accepted only when it agrees with an already
    /// connected path within these conservative pose tolerances.
    public static let maximumCycleTranslationErrorMeters = 0.05
    public static let maximumCycleYawErrorRadians = Double.pi / 180

    /// Reverse canonicalization can introduce a few ulps in `-Rᵀt`. This
    /// tolerance is intentionally much tighter than the graph consistency
    /// policy and is used only to recognize an otherwise identical retry.
    private static let retryTransformElementTolerance = 1e-9

    private let directoryURL: URL
    private let catalogURL: URL
    private let maximumAlignments: Int
    private let fileManager: FileManager

    public init(
        directoryURL: URL,
        maximumAlignments: Int = CoordinateAlignmentRepository.defaultMaximumAlignments,
        fileManager: FileManager = .default
    ) {
        let standardizedDirectory = directoryURL.standardizedFileURL
        self.directoryURL = standardizedDirectory
        catalogURL = standardizedDirectory.appendingPathComponent(
            Self.catalogFileName,
            isDirectory: false
        )
        self.maximumAlignments = min(
            max(1, maximumAlignments),
            CoordinateAlignmentCatalogSnapshot.absoluteMaximumAlignments
        )
        self.fileManager = fileManager
    }

    public func catalogSnapshot() async throws -> CoordinateAlignmentCatalogSnapshot {
        try Task.checkCancellation()
        let catalog = try loadCatalogRecoveringInvalidData()
        try Task.checkCancellation()
        try validateConfiguredCapacity(catalog)
        return catalog
    }

    public func listAlignments() async throws -> [CoordinateAlignmentRecord] {
        try await catalogSnapshot().alignments
    }

    /// Loads only an alignment in the requested direction. A stored inverse is
    /// not silently returned because its transform has the opposite meaning.
    public func loadAlignment(
        sourceMapID: MapID,
        targetMapID: MapID
    ) async throws -> CoordinateAlignmentRecord? {
        try Task.checkCancellation()
        let pair = try CoordinateAlignmentMapPair(sourceMapID, targetMapID)
        let catalog = try loadCatalogRecoveringInvalidData()
        try Task.checkCancellation()
        try validateConfiguredCapacity(catalog)
        return catalog.alignments.first {
            $0.mapPair == pair
                && $0.sourceMapID == sourceMapID
                && $0.targetMapID == targetMapID
        }
    }

    /// Loads the sole stored direction for an unordered pair.
    public func loadAlignment(
        between firstMapID: MapID,
        and secondMapID: MapID
    ) async throws -> CoordinateAlignmentRecord? {
        try Task.checkCancellation()
        let pair = try CoordinateAlignmentMapPair(firstMapID, secondMapID)
        let catalog = try loadCatalogRecoveringInvalidData()
        try Task.checkCancellation()
        try validateConfiguredCapacity(catalog)
        return catalog.alignments.first { $0.mapPair == pair }
    }

    /// Commits an immutable logical map edge. Every record is first normalized
    /// to ascending MapID order, so observing the same pair from the opposite
    /// direction cannot create a second edge. An equivalent retry is a no-op;
    /// changing any accepted alignment evidence fails closed.
    @discardableResult
    public func commitIfAbsent(
        _ inputRecord: CoordinateAlignmentRecord
    ) async throws -> CoordinateAlignmentCommitResult {
        try Task.checkCancellation()
        var catalog = try loadCatalogRecoveringInvalidData()
        try Task.checkCancellation()
        try validateConfiguredCapacity(catalog)
        let record = try inputRecord.canonicalized()

        if let index = catalog.alignments.firstIndex(where: {
            $0.mapPair == record.mapPair
        }) {
            let existing = catalog.alignments[index]
            guard Self.hasEquivalentImmutableAlignment(existing, record) else {
                throw CoordinateAlignmentRepositoryError.immutableAlignmentConflict(
                    sourceMapID: existing.sourceMapID,
                    targetMapID: existing.targetMapID
                )
            }
            return .alreadyCommitted(existing)
        } else {
            guard catalog.alignments.count < maximumAlignments else {
                throw CoordinateAlignmentRepositoryError.alignmentCapacityReached(
                    maximum: maximumAlignments
                )
            }
            try CoordinateAlignmentCatalogSnapshot.validateMapFrameBindings(
                catalog.alignments + [record]
            )
            try validateCycleConsistency(
                of: record,
                against: catalog.alignments
            )
            catalog.alignments.append(record)
        }

        catalog.alignments.sort(by: CoordinateAlignmentCatalogSnapshot.alignmentOrder)
        try Task.checkCancellation()
        try commit(catalog)
        return .committed(record)
    }

    /// Kept for source compatibility. Alignments are intentionally no longer
    /// updatable after their first validated commit.
    public func upsertAlignment(_ record: CoordinateAlignmentRecord) async throws {
        _ = try await commitIfAbsent(record)
    }

    private static func hasEquivalentImmutableAlignment(
        _ lhs: CoordinateAlignmentRecord,
        _ rhs: CoordinateAlignmentRecord
    ) -> Bool {
        guard lhs.schemaVersion == rhs.schemaVersion,
            lhs.sourceMapID == rhs.sourceMapID,
            lhs.sourceCoordinateFrameID == rhs.sourceCoordinateFrameID,
            lhs.targetMapID == rhs.targetMapID,
            lhs.targetCoordinateFrameID == rhs.targetCoordinateFrameID,
            lhs.result.sourceCoordinateFrameID == rhs.result.sourceCoordinateFrameID,
            lhs.result.targetCoordinateFrameID == rhs.result.targetCoordinateFrameID,
            lhs.result.confidence == rhs.result.confidence,
            lhs.result.residuals == rhs.result.residuals,
            lhs.result.evidenceCount == rhs.result.evidenceCount,
            lhs.result.policy == rhs.result.policy
        else {
            return false
        }
        return zip(
            lhs.result.sourceToTarget.rowMajorElements,
            rhs.result.sourceToTarget.rowMajorElements
        ).allSatisfy { left, right in
            abs(left - right) <= Self.retryTransformElementTolerance
        }
    }

    private func validateCycleConsistency(
        of record: CoordinateAlignmentRecord,
        against existing: [CoordinateAlignmentRecord]
    ) throws {
        guard
            let pathTransform = try composedTransform(
                from: record.sourceMapID,
                to: record.targetMapID,
                through: existing
            )
        else {
            return
        }

        let proposed = record.result.sourceToTarget
        let translationError = proposed.translation.distance(to: pathTransform.translation)
        let proposedYaw = atan2(proposed[0, 2], proposed[0, 0])
        let pathYaw = atan2(pathTransform[0, 2], pathTransform[0, 0])
        let yawError = abs(atan2(sin(proposedYaw - pathYaw), cos(proposedYaw - pathYaw)))
        guard
            translationError <= Self.maximumCycleTranslationErrorMeters,
            yawError <= Self.maximumCycleYawErrorRadians
        else {
            throw CoordinateAlignmentRepositoryError.inconsistentAlignmentCycle(
                sourceMapID: record.sourceMapID,
                targetMapID: record.targetMapID
            )
        }
    }

    /// With column-vector transforms, traversing source->node and then
    /// node->neighbor composes as `nodeToNeighbor * sourceToNode`.
    private func composedTransform(
        from sourceMapID: MapID,
        to targetMapID: MapID,
        through records: [CoordinateAlignmentRecord]
    ) throws -> Transform3D? {
        var adjacency: [MapID: [CoordinateAlignmentGraphEdge]] = [:]
        for inputRecord in records {
            let record = try inputRecord.canonicalized()
            adjacency[record.sourceMapID, default: []].append(
                CoordinateAlignmentGraphEdge(
                    destinationMapID: record.targetMapID,
                    sourceToDestination: record.result.sourceToTarget
                )
            )
            adjacency[record.targetMapID, default: []].append(
                CoordinateAlignmentGraphEdge(
                    destinationMapID: record.sourceMapID,
                    sourceToDestination: try record.result.inverted().sourceToTarget
                )
            )
        }
        for mapID in Array(adjacency.keys) {
            adjacency[mapID] = adjacency[mapID, default: []].sorted {
                $0.destinationMapID < $1.destinationMapID
            }
        }

        var visited: Set<MapID> = [sourceMapID]
        var queue = [
            CoordinateAlignmentGraphTraversal(
                mapID: sourceMapID,
                sourceToMap: .identity
            )
        ]
        var nextIndex = 0
        while nextIndex < queue.count {
            let current = queue[nextIndex]
            nextIndex += 1
            for edge in adjacency[current.mapID, default: []] {
                guard visited.insert(edge.destinationMapID).inserted else {
                    continue
                }
                let sourceToDestination =
                    try edge.sourceToDestination * current.sourceToMap
                if edge.destinationMapID == targetMapID {
                    return sourceToDestination
                }
                queue.append(
                    CoordinateAlignmentGraphTraversal(
                        mapID: edge.destinationMapID,
                        sourceToMap: sourceToDestination
                    )
                )
            }
        }
        return nil
    }

    private func validateGraphConsistency(
        _ records: [CoordinateAlignmentRecord]
    ) throws {
        var accepted: [CoordinateAlignmentRecord] = []
        for record in records.sorted(by: CoordinateAlignmentCatalogSnapshot.alignmentOrder) {
            try validateCycleConsistency(of: record, against: accepted)
            accepted.append(record)
        }
    }

    private func loadCatalogRecoveringInvalidData() throws
        -> CoordinateAlignmentCatalogSnapshot
    {
        try SpatialStorageDirectory.prepare(
            at: directoryURL,
            fileManager: fileManager,
            createIfMissing: false
        )
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            return try CoordinateAlignmentCatalogSnapshot()
        }

        let data: Data
        do {
            data = try readBoundedCatalog()
        } catch let error as CoordinateAlignmentRepositoryError {
            guard case .catalogTooLarge = error else {
                throw error
            }
            try quarantineCatalog(reason: String(describing: error))
            return try CoordinateAlignmentCatalogSnapshot()
        } catch {
            // Protection or transient filesystem failures are not proof of
            // corruption and must not move a potentially valid catalog.
            throw error
        }

        do {
            let catalog = try JSONDecoder().decode(
                CoordinateAlignmentCatalogSnapshot.self,
                from: data
            )
            try validateGraphConsistency(catalog.alignments)
            return catalog
        } catch {
            try quarantineCatalog(reason: String(describing: error))
            return try CoordinateAlignmentCatalogSnapshot()
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
            throw CoordinateAlignmentRepositoryError.catalogTooLarge(
                actual: data.count,
                maximum: Self.maximumCatalogBytes
            )
        }
        return data
    }

    private func validateConfiguredCapacity(
        _ catalog: CoordinateAlignmentCatalogSnapshot
    ) throws {
        guard catalog.alignments.count <= maximumAlignments else {
            throw CoordinateAlignmentRepositoryError.alignmentCapacityReached(
                maximum: maximumAlignments
            )
        }
    }

    private func commit(_ catalog: CoordinateAlignmentCatalogSnapshot) throws {
        try validateConfiguredCapacity(catalog)
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog)
        guard data.count <= Self.maximumCatalogBytes else {
            throw CoordinateAlignmentRepositoryError.catalogTooLarge(
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
            "coordinate-alignments-v1.\(nonce).json.quarantined",
            isDirectory: false
        )
        let reasonURL = quarantineDirectory.appendingPathComponent(
            "coordinate-alignments-v1.\(nonce).reason.txt",
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

private struct CoordinateAlignmentGraphEdge {
    let destinationMapID: MapID
    let sourceToDestination: Transform3D
}

private struct CoordinateAlignmentGraphTraversal {
    let mapID: MapID
    let sourceToMap: Transform3D
}
