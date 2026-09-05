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
}

/// Recomputes only relations touching the changed object. Previous relation
/// versions are retained as bounded expired evidence instead of being silently
/// overwritten.
public actor SpatialSceneGraphService {
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
        let desired = try desiredRelations(
            changed: changed,
            sameMapObjects: sameMap,
            timestamp: effectiveTimestamp
        )
        let currentRelations = graph.relations(includeProvisional: true)
        var currentByKey = Dictionary(uniqueKeysWithValues: currentRelations.map { ($0.key, $0) })
        var didMutate = existing == nil

        for relation in currentRelations
        where relationTouches(
            relation,
            objectID: changed.object.id
        ) {
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
        let applied = try await repository.apply(update)
        switch applied {
        case .applied(let record), .alreadyApplied(let record):
            return .updated(record)
        }
    }

    private func desiredRelations(
        changed: SpatialObjectMetadata,
        sameMapObjects: [SpatialObjectMetadata],
        timestamp: TimeInterval
    ) throws -> [RelationKey: SpatialRelation] {
        guard isEligible(changed), changed.object.lastSeenAt <= timestamp,
            changed.object.stateUpdatedAt <= timestamp,
            let changedBounds = changed.object.bounds else {
            return [:]
        }
        var desired: [RelationKey: SpatialRelation] = [:]
        for other in sameMapObjects.sorted(by: { $0.object.id < $1.object.id }) {
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
            for predicate in deriver.predicates(subject: changedBounds, object: otherBounds) {
                let key = RelationKey(
                    subject: .object(changed.object.id),
                    predicate: predicate,
                    object: .object(other.object.id)
                )
                desired[key] = try SpatialRelation(
                    key: key,
                    confidence: confidence,
                    certainty: certainty,
                    validFrom: timestamp,
                    subjectTemporalRevision: changed.object.temporalRevision,
                    objectTemporalRevision: other.object.temporalRevision
                )
            }
            for predicate in deriver.predicates(subject: otherBounds, object: changedBounds) {
                let key = RelationKey(
                    subject: .object(other.object.id),
                    predicate: predicate,
                    object: .object(changed.object.id)
                )
                desired[key] = try SpatialRelation(
                    key: key,
                    confidence: confidence,
                    certainty: certainty,
                    validFrom: timestamp,
                    subjectTemporalRevision: other.object.temporalRevision,
                    objectTemporalRevision: changed.object.temporalRevision
                )
            }
        }
        return desired
    }

    private func isEligible(_ metadata: SpatialObjectMetadata) -> Bool {
        metadata.object.certainty == .confirmed
            && metadata.object.presence != .removed
            && metadata.object.bounds != nil
    }

    private func relationConfidence(
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
        let end = max(relation.validFrom, timestamp)
        history.append(
            try SpatialRelation(
                key: relation.key,
                confidence: relation.confidence,
                certainty: relation.certainty,
                validFrom: relation.validFrom,
                validUntil: end,
                subjectTemporalRevision: relation.subjectTemporalRevision,
                objectTemporalRevision: relation.objectTemporalRevision
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
