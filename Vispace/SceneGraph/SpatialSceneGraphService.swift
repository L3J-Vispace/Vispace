import Foundation
import VispaceCore

public enum SpatialSceneGraphServiceError: Error, Equatable, Sendable {
    case invalidTimestamp
    case missingChangedObject
    case mapCoordinateFrameMismatch
    case revisionOverflow
    case outOfOrderObservation
}

public enum SpatialSceneGraphServiceResult: Sendable {
    case unchanged(SceneGraphMapRecord)
    case updated(SceneGraphMapRecord)
    case deferredForCapacity(mapID: MapID)
}

/// Recomputes only relations touching the changed object. Previous relation
/// versions are retained as bounded expired evidence instead of being silently
/// overwritten.
public actor SpatialSceneGraphService {
    public private(set) var capacityDeferralCount: UInt64 = 0
    public private(set) var rebuildObjectProjectionCount: UInt64 = 0
    private let repository: SceneGraphRepository
    private let deriver: SpatialRelationDeriver
    private let confidencePolicy: ConfidencePolicy

    public init(
        repository: SceneGraphRepository,
        deriver: SpatialRelationDeriver = SpatialRelationDeriver(),
        confidencePolicy: ConfidencePolicy = .default
    ) {
        self.repository = repository
        self.deriver = deriver
        self.confidencePolicy = confidencePolicy
    }

    /// Replaces only live navigation observations. Optimistic revision checks
    /// preserve concurrent metadata-derived writes; failure never publishes an
    /// uncommitted positive observation to the caller.
    public func replaceObservedRelations(
        mapID: MapID, coordinateFrameID: CoordinateFrameID,
        graph observed: SceneGraph, at timestamp: TimeInterval
    ) async throws {
        guard timestamp.isFinite, timestamp >= 0 else { throw SpatialSceneGraphServiceError.invalidTimestamp }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let existing = try await repository.load(mapID: mapID)
            guard existing?.coordinateFrameID == nil || existing?.coordinateFrameID == coordinateFrameID
            else {
                throw SpatialSceneGraphServiceError.mapCoordinateFrameMismatch
            }
            var graph = existing?.graph ?? SceneGraph(confidencePolicy: confidencePolicy)
            var history = existing?.expiredRelationHistory ?? []
            for relation in graph.relations(includeProvisional: true) where relation.observationSource != nil
            {
                try archive(relation, at: timestamp, into: &history)
                graph.remove(relation.key)
            }
            for relation in observed.relations(includeProvisional: true) {
                guard let source = relation.observationSource,
                    source.mapID == mapID, source.coordinateFrameID == coordinateFrameID,
                    relation.isValid(at: timestamp)
                else { throw SpatialSceneGraphServiceError.outOfOrderObservation }
                if let old = graph.relations(includeProvisional: true).first(where: { $0.key == relation.key }
                ) {
                    try archive(old, at: timestamp, into: &history)
                    graph.remove(old.key)
                }
                try graph.upsert(relation)
            }
            compactHistory(&history)
            let update = SceneGraphMapUpdate(
                mapID: mapID, coordinateFrameID: coordinateFrameID,
                baseRevision: existing?.revision ?? 0, graph: graph, expiredRelationHistory: history,
                timestamp: max(timestamp, existing?.updatedAt ?? timestamp))
            do {
                _ = try await repository.apply(update)
                return
            } catch let error as SceneGraphRepositoryError {
                if case .revisionConflict = error, attempt < 2 { continue }
                throw error
            }
        }
    }

    /// The caller commits the complete metadata batch before rebuilding this
    /// optional cache. Once the map uses on-demand geometry (or records a
    /// capacity deferral), all queryable source objects are already durable;
    /// visiting the remaining objects would only repeat the same catalog I/O.
    public func rebuild(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        allObjects: [SpatialObjectMetadata],
        at timestamp: TimeInterval
    ) async throws {
        guard timestamp.isFinite, timestamp >= 0 else { throw SpatialSceneGraphServiceError.invalidTimestamp }
        let sameMap = allObjects.filter { $0.mapID == mapID }
        guard sameMap.allSatisfy({ $0.position.coordinateFrameID == coordinateFrameID }) else {
            throw SpatialSceneGraphServiceError.mapCoordinateFrameMismatch
        }
        for metadata in sameMap.sorted(by: { $0.object.id < $1.object.id }) {
            try Task.checkCancellation()
            rebuildObjectProjectionCount &+= 1
            let result = try await ingest(changed: metadata, allObjects: sameMap, at: timestamp)
            switch result {
            case .deferredForCapacity:
                return
            case .unchanged(let record), .updated(let record):
                if record.geometryProjection == .onDemand { return }
            }
        }
    }

    @discardableResult
    public func ingest(
        changed: SpatialObjectMetadata,
        allObjects: [SpatialObjectMetadata],
        at timestamp: TimeInterval
    ) async throws -> SpatialSceneGraphServiceResult {
        guard timestamp.isFinite, timestamp >= 0 else {
            throw SpatialSceneGraphServiceError.invalidTimestamp
        }
        let sameMap = allObjects.filter { metadata in
            metadata.mapID == changed.mapID
                && metadata.position.coordinateFrameID
                    == changed.position.coordinateFrameID
        }
        guard let authoritative = sameMap.first(where: { $0.object.id == changed.object.id }) else {
            throw SpatialSceneGraphServiceError.missingChangedObject
        }
        guard
            !allObjects.contains(where: { metadata in
                metadata.mapID == changed.mapID
                    && metadata.object.id == changed.object.id
                    && metadata.position.coordinateFrameID
                        != changed.position.coordinateFrameID
            })
        else {
            throw SpatialSceneGraphServiceError.mapCoordinateFrameMismatch
        }

        // The writer may have received a retried/stale projection argument.
        // Always derive from the metadata that actually committed to storage.
        let changed = authoritative

        let existing = try await repository.load(mapID: changed.mapID)
        if let existing,
            existing.coordinateFrameID != changed.position.coordinateFrameID
        {
            throw SpatialSceneGraphServiceError.mapCoordinateFrameMismatch
        }
        guard existing?.revision != UInt64.max else {
            throw SpatialSceneGraphServiceError.revisionOverflow
        }
        // Wall time describes evidence validity, never the storage ordering.
        // Repository revision fences updates even after the calendar moves back.
        let effectiveTimestamp = timestamp
        var stateUpdatedAtByObjectID: [ObjectID: TimeInterval] = [:]
        for metadata in sameMap {
            stateUpdatedAtByObjectID[metadata.object.id] = max(
                stateUpdatedAtByObjectID[metadata.object.id] ?? 0,
                metadata.object.stateUpdatedAt
            )
        }

        var graph = existing?.graph ?? SceneGraph(confidencePolicy: confidencePolicy)
        var history = existing?.expiredRelationHistory ?? []
        if let existing, existing.geometryProjection == .onDemand {
            // The durable objects are the projection source. Dense maps stay in
            // this mode; observation processing does not rewrite an all-pairs cache.
            try await repository.acknowledgeCurrentProjection(mapID: changed.mapID)
            return .unchanged(existing)
        }
        let desired = try Self.desiredRelations(
            changed: changed,
            sameMapObjects: sameMap,
            timestamp: effectiveTimestamp,
            deriver: deriver, confidencePolicy: confidencePolicy
        )
        let currentRelations = graph.relations(includeProvisional: true)
        var currentByKey = Dictionary(uniqueKeysWithValues: currentRelations.map { ($0.key, $0) })
        var didMutate = existing == nil

        for relation in currentRelations
        where relationTouches(
            relation,
            objectID: changed.object.id
        ) && relation.key.predicate.isGeometryDerived {
            guard let replacement = desired[relation.key] else {
                try archive(relation, at: effectiveTimestamp, into: &history)
                graph.remove(relation.key)
                currentByKey.removeValue(forKey: relation.key)
                didMutate = true
                continue
            }
            guard relation.confidence == replacement.confidence,
                relation.certainty == replacement.certainty,
                relation.subjectTemporalRevision == replacement.subjectTemporalRevision,
                relation.objectTemporalRevision == replacement.objectTemporalRevision,
                relation.validUntil == nil,
                relationIsFresh(
                    relation,
                    stateUpdatedAtByObjectID: stateUpdatedAtByObjectID
                )
            else {
                try archive(relation, at: effectiveTimestamp, into: &history)
                graph.remove(relation.key)
                currentByKey.removeValue(forKey: relation.key)
                didMutate = true
                continue
            }
        }

        for (key, relation) in desired.sorted(by: { $0.key < $1.key }) {
            guard currentByKey[key] == nil else {
                continue
            }
            try graph.upsert(relation)
            didMutate = true
        }

        if let existing, !didMutate {
            return .unchanged(existing)
        }
        compactHistory(&history)
        let update = SceneGraphMapUpdate(
            mapID: changed.mapID,
            coordinateFrameID: changed.position.coordinateFrameID,
            baseRevision: existing?.revision ?? 0,
            graph: graph,
            expiredRelationHistory: history,
            timestamp: effectiveTimestamp
        )
        let applied: SceneGraphUpdateResult
        do {
            applied = try await repository.apply(update)
        } catch let error as SceneGraphRepositoryError {
            guard case .catalogTooLarge = error else { throw error }
            // Source metadata has already committed. Keep opaque graph evidence
            // intact and durably mark incomplete coverage instead of blocking
            // every later object observation on this optional projection.
            try await repository.recordCapacityDeferral(mapID: changed.mapID, baseRevision: update.baseRevision)
            capacityDeferralCount &+= 1
            return .deferredForCapacity(mapID: changed.mapID)
        }
        switch applied {
        case .applied(let record), .alreadyApplied(let record):
            return .updated(record)
        }
    }

    /// Rebuilds only the requested predicate touching its one or two grounded
    /// objects. It uses the same geometry/confidence rules as ingestion and
    /// preserves source observation times rather than dating old evidence now.
    public nonisolated static func geometryGraphForQuery(
        scope: SpatialRelationQueryGeometryScope,
        objects: [SpatialObjectMetadata],
        at timestamp: TimeInterval,
        confidencePolicy: ConfidencePolicy = .default
    ) throws -> SceneGraph {
        guard timestamp.isFinite, timestamp >= 0 else { throw SpatialSceneGraphServiceError.invalidTimestamp }
        var graph = SceneGraph(confidencePolicy: confidencePolicy)
        for objectID in scope.objectIDs.sorted() {
            try Task.checkCancellation()
            guard let target = objects.first(where: { $0.object.id == objectID }) else { continue }
            let sameMap = objects.filter {
                $0.mapID == target.mapID && $0.position.coordinateFrameID == target.position.coordinateFrameID
            }
            let relations = try desiredRelations(
                changed: target, sameMapObjects: sameMap, timestamp: timestamp,
                deriver: SpatialRelationDeriver(), confidencePolicy: confidencePolicy,
                predicate: scope.predicate, useObservationTime: true
            )
            for relation in relations.values { try graph.upsert(relation) }
        }
        return graph
    }

    private nonisolated static func desiredRelations(
        changed: SpatialObjectMetadata,
        sameMapObjects: [SpatialObjectMetadata],
        timestamp: TimeInterval,
        deriver: SpatialRelationDeriver,
        confidencePolicy: ConfidencePolicy,
        predicate requestedPredicate: SpatialRelationPredicate? = nil,
        useObservationTime: Bool = false
    ) throws -> [RelationKey: SpatialRelation] {
        guard isEligible(changed), changed.object.lastSeenAt <= timestamp,
            changed.object.stateUpdatedAt <= timestamp,
            let changedBounds = changed.object.bounds else {
            return [:]
        }
        var desired: [RelationKey: SpatialRelation] = [:]
        for other in sameMapObjects.sorted(by: { $0.object.id < $1.object.id }) {
            try Task.checkCancellation()
            guard other.object.id != changed.object.id,
                isEligible(other),
                other.object.lastSeenAt <= timestamp,
                other.object.stateUpdatedAt <= timestamp,
                let otherBounds = other.object.bounds
            else {
                continue
            }
            let confidence = relationConfidence(changed.object, other.object)
            let grade = confidencePolicy.grade(for: confidence)
            guard grade != .low else {
                continue
            }
            let certainty: RelationCertainty = grade == .high ? .confirmed : .provisional
            let validFrom = useObservationTime ? max(
                max(changed.object.stateUpdatedAt, other.object.stateUpdatedAt),
                max(changed.object.lastSeenAt, other.object.lastSeenAt)
            ) : timestamp
            for predicate in deriver.predicates(subject: changedBounds, object: otherBounds)
            where requestedPredicate == nil || requestedPredicate == predicate {
                let key = RelationKey(
                    subject: .object(changed.object.id),
                    predicate: predicate,
                    object: .object(other.object.id)
                )
                desired[key] = try SpatialRelation(
                    key: key,
                    confidence: confidence,
                    certainty: certainty,
                    validFrom: validFrom,
                    subjectTemporalRevision: changed.object.temporalRevision,
                    objectTemporalRevision: other.object.temporalRevision
                )
            }
            for predicate in deriver.predicates(subject: otherBounds, object: changedBounds)
            where requestedPredicate == nil || requestedPredicate == predicate {
                let key = RelationKey(
                    subject: .object(other.object.id),
                    predicate: predicate,
                    object: .object(changed.object.id)
                )
                desired[key] = try SpatialRelation(
                    key: key,
                    confidence: confidence,
                    certainty: certainty,
                    validFrom: validFrom,
                    subjectTemporalRevision: other.object.temporalRevision,
                    objectTemporalRevision: changed.object.temporalRevision
                )
            }
        }
        return desired
    }

    private nonisolated static func isEligible(_ metadata: SpatialObjectMetadata) -> Bool {
        metadata.object.certainty == .confirmed
            && metadata.object.presence != .removed
            && metadata.object.bounds != nil
    }

    private nonisolated static func relationConfidence(
        _ first: SpatialObject,
        _ second: SpatialObject
    ) -> ConfidenceScore {
        let values = [
            first.confidence.geometry,
            first.confidence.tracking,
            first.confidence.identity,
            first.confidence.objectState,
            second.confidence.geometry,
            second.confidence.tracking,
            second.confidence.identity,
            second.confidence.objectState,
        ]
        return values.min() ?? .zero
    }

    private func relationTouches(
        _ relation: SpatialRelation,
        objectID: ObjectID
    ) -> Bool {
        relation.key.subject == .object(objectID)
            || relation.key.object == .object(objectID)
    }

    private func relationIsFresh(
        _ relation: SpatialRelation,
        stateUpdatedAtByObjectID: [ObjectID: TimeInterval]
    ) -> Bool {
        guard case .object(let subjectID) = relation.key.subject,
            case .object(let objectID) = relation.key.object,
            let subjectStateUpdatedAt = stateUpdatedAtByObjectID[subjectID],
            let objectStateUpdatedAt = stateUpdatedAtByObjectID[objectID]
        else {
            return false
        }
        return relation.validFrom >= subjectStateUpdatedAt
            && relation.validFrom >= objectStateUpdatedAt
    }

    private func archive(
        _ relation: SpatialRelation,
        at timestamp: TimeInterval,
        into history: inout [SpatialRelation]
    ) throws {
        let end = max(relation.validFrom, min(timestamp, relation.validUntil ?? timestamp))
        history.append(
            try SpatialRelation(
                key: relation.key,
                confidence: relation.confidence,
                certainty: relation.certainty,
                validFrom: relation.validFrom,
                validUntil: end,
                subjectTemporalRevision: relation.subjectTemporalRevision,
                objectTemporalRevision: relation.objectTemporalRevision,
                observationSource: relation.observationSource
            )
        )
    }

    private func compactHistory(_ history: inout [SpatialRelation]) {
        history.sort { lhs, rhs in
            let leftEnd = lhs.validUntil ?? .infinity
            let rightEnd = rhs.validUntil ?? .infinity
            if leftEnd != rightEnd {
                return leftEnd < rightEnd
            }
            if lhs.validFrom != rhs.validFrom {
                return lhs.validFrom < rhs.validFrom
            }
            return lhs.key < rhs.key
        }
        if history.count > SceneGraphMapRecord.absoluteMaximumHistoryCount {
            history.removeFirst(
                history.count - SceneGraphMapRecord.absoluteMaximumHistoryCount
            )
        }
    }
}
