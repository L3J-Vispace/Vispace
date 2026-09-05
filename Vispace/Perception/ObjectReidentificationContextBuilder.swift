import Foundation
import VispaceCore

struct ObjectReidentificationContextBundle: Sendable {
    let incoming: ObjectReidentificationSpatialContext
    let candidates: [ObjectReidentificationSpatialContext]
    let eligibleExistingObjects: [SpatialObjectMetadata]
}

/// Derives conservative, ID-addressed scene context from already confirmed
/// objects in one persisted map. Same-class re-identification candidates are
/// excluded as reference landmarks so a hypothesis can never corroborate
/// itself.
struct ObjectReidentificationContextBuilder: Sendable {
    let maximumCandidateDistance: Double
    let nearDistance: Double
    let horizontalRelationDeadZone: Double

    init(
        maximumCandidateDistance: Double = PersistentObjectReidentificationPolicy
            .default.maximumPositionDistance,
        nearDistance: Double = 2,
        horizontalRelationDeadZone: Double = 0.20
    ) {
        self.maximumCandidateDistance = maximumCandidateDistance
        self.nearDistance = nearDistance
        self.horizontalRelationDeadZone = horizontalRelationDeadZone
    }

    func makeContexts(
        for promoted: SpatialObjectMetadata,
        existingObjects: [SpatialObjectMetadata]
    ) throws -> ObjectReidentificationContextBundle {
        let confidencePolicy = ConfidencePolicy.default
        let eligible = existingObjects.filter { metadata in
            metadata.mapID == promoted.mapID
                && metadata.position.coordinateFrameID
                    == promoted.position.coordinateFrameID
                && metadata.object.id != promoted.object.id
                && metadata.object.certainty == .confirmed
                && metadata.object.presence != .removed
                && confidencePolicy.grade(for: metadata.object.confidence.semantic) == .high
                && confidencePolicy.grade(for: metadata.object.confidence.geometry) == .high
                && confidencePolicy.grade(for: metadata.object.confidence.identity) == .high
                && confidencePolicy.grade(for: metadata.object.confidence.objectState) == .high
        }.sorted { $0.object.id < $1.object.id }

        let semanticKey = normalizedLabel(promoted.object.semanticLabel)
        let candidates = eligible.filter { metadata in
            normalizedLabel(metadata.object.semanticLabel) == semanticKey
                && metadata.object.position.distance(to: promoted.object.position)
                    <= maximumCandidateDistance
        }
        let candidateIDs = Set(candidates.map(\.object.id))
        let references = eligible.filter { !candidateIDs.contains($0.object.id) }

        let incoming = try ObjectReidentificationSpatialContext(
            objectID: promoted.object.id,
            mapID: promoted.mapID,
            coordinateFrameID: promoted.position.coordinateFrameID,
            features: features(for: promoted.object, references: references)
        )
        let candidateContexts = try candidates.map { candidate in
            try ObjectReidentificationSpatialContext(
                objectID: candidate.object.id,
                mapID: candidate.mapID,
                coordinateFrameID: candidate.position.coordinateFrameID,
                features: features(for: candidate.object, references: references)
            )
        }
        return ObjectReidentificationContextBundle(
            incoming: incoming,
            candidates: candidateContexts,
            eligibleExistingObjects: eligible
        )
    }

    private func features(
        for subject: SpatialObject,
        references: [SpatialObjectMetadata]
    ) -> [ObjectReidentificationSpatialFeature] {
        var values = Set<ObjectReidentificationSpatialFeature>()
        for referenceMetadata in references {
            let reference = referenceMetadata.object
            let referenceID = SceneEntityID.object(reference.id)
            let deltaX = subject.position.x - reference.position.x
            let distance = subject.position.distance(to: reference.position)

            if distance <= nearDistance {
                values.insert(
                    ObjectReidentificationSpatialFeature(
                        predicate: .near,
                        reference: referenceID
                    )
                )
            }
            if deltaX <= -horizontalRelationDeadZone {
                values.insert(
                    ObjectReidentificationSpatialFeature(
                        predicate: .leftOf,
                        reference: referenceID
                    )
                )
            } else if deltaX >= horizontalRelationDeadZone {
                values.insert(
                    ObjectReidentificationSpatialFeature(
                        predicate: .rightOf,
                        reference: referenceID
                    )
                )
            }
            if let referenceBounds = reference.bounds,
                referenceBounds.contains(subject.position)
            {
                values.insert(
                    ObjectReidentificationSpatialFeature(
                        predicate: .inside,
                        reference: referenceID
                    )
                )
            }
            if let subjectBounds = subject.bounds,
                let referenceBounds = reference.bounds
            {
                if subjectBounds.intersects(referenceBounds) {
                    values.insert(
                        ObjectReidentificationSpatialFeature(
                            predicate: .intersects,
                            reference: referenceID
                        )
                    )
                }
                if isSupported(subjectBounds, by: referenceBounds) {
                    values.insert(
                        ObjectReidentificationSpatialFeature(
                            predicate: .on,
                            reference: referenceID
                        )
                    )
                } else if isSupported(referenceBounds, by: subjectBounds) {
                    values.insert(
                        ObjectReidentificationSpatialFeature(
                            predicate: .under,
                            reference: referenceID
                        )
                    )
                }
            }
        }
        return Array(values.sorted().prefix(ObjectReidentificationSpatialContext.maximumFeatureCount))
    }

    private func isSupported(_ upper: AABB, by lower: AABB) -> Bool {
        let verticalGap = upper.min.y - lower.max.y
        guard (-0.03...0.15).contains(verticalGap) else {
            return false
        }
        let overlapsX = upper.min.x <= lower.max.x && upper.max.x >= lower.min.x
        let overlapsZ = upper.min.z <= lower.max.z && upper.max.z >= lower.min.z
        return overlapsX && overlapsZ
    }

    private func normalizedLabel(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
