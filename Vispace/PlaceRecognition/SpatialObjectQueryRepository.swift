import Foundation
import VispaceCore

/// A deterministic, bounded alias table used only to match persisted semantic
/// labels. It never supplies an object identity or a coordinate.
public struct SpatialObjectAliasCatalog: Hashable, Sendable {
    public static let maximumCanonicalLabelCount = 128
    public static let maximumAliasesPerLabel = 12
    public static let maximumTermLength = 64

    private let aliasesByCanonicalLabel: [String: [String]]

    public init(entries: [String: [String]]) {
        var sanitized: [String: [String]] = [:]
        let canonicalLabels = Set(entries.keys.compactMap(Self.normalizedTerm))
            .sorted()
            .prefix(Self.maximumCanonicalLabelCount)

        for canonicalLabel in canonicalLabels {
            let matchingValues =
                entries
                .filter { Self.normalizedTerm($0.key) == canonicalLabel }
                .flatMap { $0.value }
            let aliases = Set(matchingValues.compactMap(Self.normalizedTerm))
                .subtracting([canonicalLabel])
                .sorted()
                .prefix(Self.maximumAliasesPerLabel)
            sanitized[canonicalLabel] = Array(aliases)
        }
        aliasesByCanonicalLabel = sanitized
    }

    /// Creates a symmetric alias table. Every term in a group can be the
    /// canonical detector label, and all remaining terms become its aliases.
    public init(semanticGroups: [[String]]) {
        var entries: [String: [String]] = [:]
        for group in semanticGroups {
            let terms = Array(Set(group.compactMap(Self.normalizedTerm))).sorted()
            for term in terms {
                entries[term, default: []].append(contentsOf: terms.filter { $0 != term })
            }
        }
        self.init(entries: entries)
    }

    public func aliases(for semanticLabel: String) -> [String] {
        guard let key = Self.normalizedTerm(semanticLabel) else {
            return []
        }
        return aliasesByCanonicalLabel[key] ?? []
    }

    public var canonicalLabelCount: Int {
        aliasesByCanonicalLabel.count
    }

    public static let koreanEnglishDefaults = Self(semanticGroups: [
        ["chair", "의자"],
        ["table", "dining table", "테이블", "탁자"],
        ["sofa", "couch", "소파"],
        ["bed", "침대"],
        ["desk", "책상"],
        ["laptop", "notebook computer", "노트북"],
        ["phone", "cell phone", "smartphone", "휴대폰", "핸드폰", "스마트폰"],
        ["key", "keys", "열쇠", "키"],
        ["wallet", "지갑"],
        ["bag", "handbag", "가방"],
        ["backpack", "백팩", "배낭"],
        ["remote", "remote control", "리모컨"],
        ["bottle", "water bottle", "병", "물병"],
        ["printer", "프린터"],
        ["television", "tv", "텔레비전", "티비"],
        ["refrigerator", "fridge", "냉장고"],
        ["microwave", "전자레인지"],
        ["book", "책"],
        ["cup", "mug", "컵", "잔"],
        ["camera", "카메라"],
        ["speaker", "스피커"],
        ["monitor", "모니터"],
        ["mouse", "마우스"],
        ["keyboard", "키보드"],
        ["plant", "potted plant", "화분", "식물"],
    ])

    private static func normalizedTerm(_ value: String) -> String? {
        let normalized =
            value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty, normalized.count <= maximumTermLength else {
            return nil
        }
        return normalized
    }
}

public struct SpatialObjectQueryRepositorySnapshot: Hashable, Sendable {
    public let records: [StoredSpatialObjectRecord]
    public let alignmentCatalog: CoordinateAlignmentCatalogSnapshot

    public init(
        records: [StoredSpatialObjectRecord],
        alignmentCatalog: CoordinateAlignmentCatalogSnapshot
    ) {
        self.records = records
        self.alignmentCatalog = alignmentCatalog
    }
}

/// App-layer read model joining durable object metadata with validated map
/// alignments. Every persisted record participates in search; result limits
/// belong after semantic matching, never before it.
public actor SpatialObjectQueryRepository {
    public typealias MetadataProvider = @Sendable () async throws -> SpatialMetadataDocument
    public typealias AlignmentCatalogProvider =
        @Sendable () async throws ->
        CoordinateAlignmentCatalogSnapshot

    private let metadataProvider: MetadataProvider
    private let alignmentCatalogProvider: AlignmentCatalogProvider
    private let aliasCatalog: SpatialObjectAliasCatalog

    public init(
        metadataProvider: @escaping MetadataProvider,
        alignmentCatalogProvider: @escaping AlignmentCatalogProvider,
        aliasCatalog: SpatialObjectAliasCatalog = .koreanEnglishDefaults
    ) {
        self.metadataProvider = metadataProvider
        self.alignmentCatalogProvider = alignmentCatalogProvider
        self.aliasCatalog = aliasCatalog
    }

    public init(
        worldMapRepository: WorldMapCheckpointRepository,
        coordinateAlignmentRepository: CoordinateAlignmentRepository,
        aliasCatalog: SpatialObjectAliasCatalog = .koreanEnglishDefaults
    ) {
        metadataProvider = {
            try await worldMapRepository.metadataSnapshot()
        }
        alignmentCatalogProvider = {
            try await coordinateAlignmentRepository.catalogSnapshot()
        }
        self.aliasCatalog = aliasCatalog
    }

    public func loadSnapshot(
        currentMapID: MapID?
    ) async throws -> SpatialObjectQueryRepositorySnapshot {
        async let metadata = metadataProvider()
        async let alignmentCatalog = alignmentCatalogProvider()
        let (document, catalog) = try await (metadata, alignmentCatalog)
        try Task.checkCancellation()

        let records = document.objects
            .sorted { Self.ranksBefore($0, $1, currentMapID: currentMapID) }
            .map { metadata in
                StoredSpatialObjectRecord(
                    metadata: metadata,
                    memoryTier: Self.memoryTier(for: metadata, currentMapID: currentMapID),
                    semanticAliases: aliasCatalog.aliases(
                        for: metadata.object.semanticLabel
                    ) + [metadata.object.displayName].compactMap { $0 }
                )
            }
        return SpatialObjectQueryRepositorySnapshot(
            records: Array(records),
            alignmentCatalog: catalog
        )
    }

    private static func memoryTier(
        for metadata: SpatialObjectMetadata,
        currentMapID: MapID?
    ) -> MemoryTier {
        guard metadata.mapID == currentMapID else {
            return .longTerm
        }
        return metadata.object.presence == .visible ? .realtime : .localMap
    }

    private static func ranksBefore(
        _ lhs: SpatialObjectMetadata,
        _ rhs: SpatialObjectMetadata,
        currentMapID: MapID?
    ) -> Bool {
        let lhsCurrent = lhs.mapID == currentMapID
        let rhsCurrent = rhs.mapID == currentMapID
        if lhsCurrent != rhsCurrent {
            return lhsCurrent
        }
        if lhs.object.certainty != rhs.object.certainty {
            return lhs.object.certainty == .confirmed
        }
        let lhsPresence = presenceRank(lhs.object.presence)
        let rhsPresence = presenceRank(rhs.object.presence)
        if lhsPresence != rhsPresence {
            return lhsPresence < rhsPresence
        }
        if lhs.object.lastSeenAt != rhs.object.lastSeenAt {
            return lhs.object.lastSeenAt > rhs.object.lastSeenAt
        }
        if lhs.mapID != rhs.mapID {
            return lhs.mapID < rhs.mapID
        }
        return lhs.object.id < rhs.object.id
    }

    private static func presenceRank(_ presence: ObjectPresence) -> Int {
        switch presence {
        case .visible:
            return 0
        case .notVisible:
            return 1
        case .lastSeen:
            return 2
        case .removed:
            return 3
        }
    }
}

public struct ResolvedCurrentFramePosition: Hashable, Sendable {
    public let source: FramedPosition
    public let currentFramePosition: FramedPosition
    public let mapPath: [MapID]
    public let alignmentConfidence: ConfidenceScore?

    public var position: Vec3 {
        currentFramePosition.value
    }

    public init(
        source: FramedPosition,
        currentFramePosition: FramedPosition,
        mapPath: [MapID],
        alignmentConfidence: ConfidenceScore?
    ) {
        self.source = source
        self.currentFramePosition = currentFramePosition
        self.mapPath = mapPath
        self.alignmentConfidence = alignmentConfidence
    }
}

/// Resolves only exact-frame positions or paths composed entirely of validated
/// alignment records. Missing, stale, or frame-inconsistent evidence fails
/// closed and produces no AR coordinate.
public struct ValidatedCurrentFramePositionResolver: Sendable {
    public static let defaultMaximumAlignmentHops = 8
    public static let absoluteMaximumAlignmentHops = 16

    public let maximumAlignmentHops: Int

    public init(
        maximumAlignmentHops: Int = Self.defaultMaximumAlignmentHops
    ) {
        self.maximumAlignmentHops = min(
            max(1, maximumAlignmentHops),
            Self.absoluteMaximumAlignmentHops
        )
    }

    public func resolve(
        _ metadata: SpatialObjectMetadata,
        into currentIdentity: ARCaptureIdentity,
        using catalog: CoordinateAlignmentCatalogSnapshot
    ) -> ResolvedCurrentFramePosition? {
        guard currentIdentity.status == .confirmed else {
            return nil
        }

        let sourcePosition = metadata.position
        if sourcePosition.coordinateFrameID == currentIdentity.coordinateFrameID {
            let path: [MapID]
            if let currentMapID = currentIdentity.mapID, currentMapID != metadata.mapID {
                path = [metadata.mapID, currentMapID]
            } else {
                path = [metadata.mapID]
            }
            return ResolvedCurrentFramePosition(
                source: sourcePosition,
                currentFramePosition: sourcePosition,
                mapPath: path,
                alignmentConfidence: nil
            )
        }

        guard let currentMapID = currentIdentity.mapID,
            currentMapID != metadata.mapID
        else {
            return nil
        }

        let graph = directedGraph(from: catalog)
        var queue = [
            PathState(
                mapID: metadata.mapID,
                coordinateFrameID: sourcePosition.coordinateFrameID,
                sourceToCurrentNode: .identity,
                mapPath: [metadata.mapID],
                minimumConfidence: .one
            )
        ]
        var nextIndex = 0
        var visited: Set<MapID> = [metadata.mapID]

        while nextIndex < queue.count {
            let state = queue[nextIndex]
            nextIndex += 1
            let hopCount = state.mapPath.count - 1
            guard hopCount < maximumAlignmentHops else {
                continue
            }

            for edge in graph[state.mapID] ?? [] {
                guard edge.sourceCoordinateFrameID == state.coordinateFrameID,
                    visited.insert(edge.targetMapID).inserted
                else {
                    continue
                }
                guard
                    let transform = try? edge.sourceToTarget * state.sourceToCurrentNode
                else {
                    // A malformed or extreme persisted alignment must make the
                    // location unavailable rather than trap during composition.
                    return nil
                }
                let path = state.mapPath + [edge.targetMapID]
                let minimumConfidence = min(state.minimumConfidence, edge.confidence)

                if edge.targetMapID == currentMapID {
                    guard
                        edge.targetCoordinateFrameID
                            == currentIdentity.coordinateFrameID,
                        let transformedValue = try? transform.transformed(
                            sourcePosition.value
                        ),
                        let transformedPosition = try? FramedPosition(
                            coordinateFrameID: currentIdentity.coordinateFrameID,
                            value: transformedValue,
                            observedAt: sourcePosition.observedAt,
                            trackingQuality: sourcePosition.trackingQuality,
                            uncertainty: sourcePosition.uncertainty
                        )
                    else {
                        return nil
                    }
                    return ResolvedCurrentFramePosition(
                        source: sourcePosition,
                        currentFramePosition: transformedPosition,
                        mapPath: path,
                        alignmentConfidence: minimumConfidence
                    )
                }

                queue.append(
                    PathState(
                        mapID: edge.targetMapID,
                        coordinateFrameID: edge.targetCoordinateFrameID,
                        sourceToCurrentNode: transform,
                        mapPath: path,
                        minimumConfidence: minimumConfidence
                    )
                )
            }
        }
        return nil
    }

    private func directedGraph(
        from catalog: CoordinateAlignmentCatalogSnapshot
    ) -> [MapID: [DirectedAlignmentEdge]] {
        var graph: [MapID: [DirectedAlignmentEdge]] = [:]
        for record in catalog.alignments {
            graph[record.sourceMapID, default: []].append(
                DirectedAlignmentEdge(
                    sourceMapID: record.sourceMapID,
                    sourceCoordinateFrameID: record.sourceCoordinateFrameID,
                    targetMapID: record.targetMapID,
                    targetCoordinateFrameID: record.targetCoordinateFrameID,
                    sourceToTarget: record.result.sourceToTarget,
                    confidence: record.result.confidence
                )
            )
            guard let inverse = try? record.result.inverted() else {
                continue
            }
            graph[record.targetMapID, default: []].append(
                DirectedAlignmentEdge(
                    sourceMapID: record.targetMapID,
                    sourceCoordinateFrameID: record.targetCoordinateFrameID,
                    targetMapID: record.sourceMapID,
                    targetCoordinateFrameID: record.sourceCoordinateFrameID,
                    sourceToTarget: inverse.sourceToTarget,
                    confidence: inverse.confidence
                )
            )
        }
        for mapID in Array(graph.keys) {
            graph[mapID]?.sort { lhs, rhs in
                if lhs.targetMapID != rhs.targetMapID {
                    return lhs.targetMapID < rhs.targetMapID
                }
                return lhs.targetCoordinateFrameID < rhs.targetCoordinateFrameID
            }
        }
        return graph
    }
}

private struct DirectedAlignmentEdge: Sendable {
    let sourceMapID: MapID
    let sourceCoordinateFrameID: CoordinateFrameID
    let targetMapID: MapID
    let targetCoordinateFrameID: CoordinateFrameID
    let sourceToTarget: Transform3D
    let confidence: ConfidenceScore
}

private struct PathState: Sendable {
    let mapID: MapID
    let coordinateFrameID: CoordinateFrameID
    let sourceToCurrentNode: Transform3D
    let mapPath: [MapID]
    let minimumConfidence: ConfidenceScore
}
