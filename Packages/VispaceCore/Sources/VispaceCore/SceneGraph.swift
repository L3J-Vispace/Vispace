import Foundation

public enum SceneEntityID: Codable, Hashable, Comparable, Sendable {
    case object(ObjectID)
    case spatialNode(SpatialNodeID)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    private var sortKey: String {
        switch self {
        case .object(let id):
            return "object:\(id)"
        case .spatialNode(let id):
            return "node:\(id)"
        }
    }
}

public enum SpatialRelationPredicate: String, Codable, CaseIterable, Hashable, Sendable {
    case leftOf
    case rightOf
    case on
    case under
    case inside
    case near
    case blocking
    case intersects
    case connectedTo
    case accessibleFrom
}

public enum RelationCertainty: String, Codable, Hashable, Sendable {
    case provisional
    case confirmed
}

public struct RelationKey: Codable, Hashable, Comparable, Sendable {
    public let subject: SceneEntityID
    public let predicate: SpatialRelationPredicate
    public let object: SceneEntityID

    public init(
        subject: SceneEntityID,
        predicate: SpatialRelationPredicate,
        object: SceneEntityID
    ) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.subject != rhs.subject {
            return lhs.subject < rhs.subject
        }
        if lhs.predicate.rawValue != rhs.predicate.rawValue {
            return lhs.predicate.rawValue < rhs.predicate.rawValue
        }
        return lhs.object < rhs.object
    }
}

public enum SceneGraphError: Error, Equatable, Sendable {
    case invalidValidityRange
    case insufficientConfidence(RelationKey)
    case cannotDowngradeConfirmedRelation(RelationKey)
    case outOfOrderRelation(RelationKey)
    case relationKeyMismatch(RelationKey)
    case relationCertaintyMismatch(RelationKey)
    case duplicateRelation(RelationKey)
}

public struct SpatialRelation: Codable, Hashable, Sendable {
    public let key: RelationKey
    public let confidence: ConfidenceScore
    public let certainty: RelationCertainty
    public let validFrom: TimeInterval
    public let validUntil: TimeInterval?
    public let subjectTemporalRevision: UInt64?
    public let objectTemporalRevision: UInt64?

    public init(
        key: RelationKey,
        confidence: ConfidenceScore,
        certainty: RelationCertainty,
        validFrom: TimeInterval,
        validUntil: TimeInterval? = nil,
        subjectTemporalRevision: UInt64? = nil,
        objectTemporalRevision: UInt64? = nil
    ) throws {
        guard validFrom.isFinite, validFrom >= 0,
            validUntil.map({ $0.isFinite && $0 >= validFrom }) ?? true,
            subjectTemporalRevision.map({ $0 > 0 }) ?? true,
            objectTemporalRevision.map({ $0 > 0 }) ?? true
        else {
            throw SceneGraphError.invalidValidityRange
        }
        self.key = key
        self.confidence = confidence
        self.certainty = certainty
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.subjectTemporalRevision = subjectTemporalRevision
        self.objectTemporalRevision = objectTemporalRevision
    }

    public func isValid(at time: TimeInterval) -> Bool {
        time >= validFrom && (validUntil.map { time <= $0 } ?? true)
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case confidence
        case certainty
        case validFrom
        case validUntil
        case subjectTemporalRevision
        case objectTemporalRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                key: container.decode(RelationKey.self, forKey: .key),
                confidence: container.decode(ConfidenceScore.self, forKey: .confidence),
                certainty: container.decode(RelationCertainty.self, forKey: .certainty),
                validFrom: container.decode(TimeInterval.self, forKey: .validFrom),
                validUntil: container.decodeIfPresent(TimeInterval.self, forKey: .validUntil),
                subjectTemporalRevision: container.decodeIfPresent(UInt64.self, forKey: .subjectTemporalRevision),
                objectTemporalRevision: container.decodeIfPresent(UInt64.self, forKey: .objectTemporalRevision)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .validFrom,
                in: container,
                debugDescription: "Relation validity timestamps are invalid."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(certainty, forKey: .certainty)
        try container.encode(validFrom, forKey: .validFrom)
        try container.encodeIfPresent(validUntil, forKey: .validUntil)
        try container.encodeIfPresent(subjectTemporalRevision, forKey: .subjectTemporalRevision)
        try container.encodeIfPresent(objectTemporalRevision, forKey: .objectTemporalRevision)
    }
}

public struct SceneGraph: Codable, Sendable {
    public private(set) var confirmedRelations: [RelationKey: SpatialRelation]
    public private(set) var provisionalRelations: [RelationKey: SpatialRelation]
    public let confidencePolicy: ConfidencePolicy

    public init(confidencePolicy: ConfidencePolicy = .default) {
        confirmedRelations = [:]
        provisionalRelations = [:]
        self.confidencePolicy = confidencePolicy
    }

    public init(
        validatingConfirmedRelations confirmedRelations: [RelationKey: SpatialRelation],
        provisionalRelations: [RelationKey: SpatialRelation],
        confidencePolicy: ConfidencePolicy = .default
    ) throws {
        if let duplicate = Set(confirmedRelations.keys)
            .intersection(provisionalRelations.keys)
            .sorted()
            .first
        {
            throw SceneGraphError.duplicateRelation(duplicate)
        }
        for (key, relation) in confirmedRelations {
            guard key == relation.key else {
                throw SceneGraphError.relationKeyMismatch(key)
            }
            guard relation.certainty == .confirmed else {
                throw SceneGraphError.relationCertaintyMismatch(key)
            }
            guard confidencePolicy.grade(for: relation.confidence) == .high else {
                throw SceneGraphError.insufficientConfidence(key)
            }
        }
        for (key, relation) in provisionalRelations {
            guard key == relation.key else {
                throw SceneGraphError.relationKeyMismatch(key)
            }
            guard relation.certainty == .provisional else {
                throw SceneGraphError.relationCertaintyMismatch(key)
            }
        }
        self.confirmedRelations = confirmedRelations
        self.provisionalRelations = provisionalRelations
        self.confidencePolicy = confidencePolicy
    }

    public mutating func upsert(_ relation: SpatialRelation) throws {
        switch relation.certainty {
        case .provisional:
            guard confirmedRelations[relation.key] == nil else {
                throw SceneGraphError.cannotDowngradeConfirmedRelation(relation.key)
            }
            try rejectOutOfOrder(relation, comparedWith: provisionalRelations[relation.key])
            provisionalRelations[relation.key] = relation

        case .confirmed:
            guard confidencePolicy.grade(for: relation.confidence) == .high else {
                throw SceneGraphError.insufficientConfidence(relation.key)
            }
            try rejectOutOfOrder(relation, comparedWith: confirmedRelations[relation.key])
            provisionalRelations.removeValue(forKey: relation.key)
            confirmedRelations[relation.key] = relation
        }
    }

    public mutating func remove(_ key: RelationKey) {
        confirmedRelations.removeValue(forKey: key)
        provisionalRelations.removeValue(forKey: key)
    }

    public func relations(
        subject: SceneEntityID? = nil,
        predicate: SpatialRelationPredicate? = nil,
        object: SceneEntityID? = nil,
        validAt time: TimeInterval? = nil,
        includeProvisional: Bool = false
    ) -> [SpatialRelation] {
        let base =
            Array(confirmedRelations.values)
            + (includeProvisional ? Array(provisionalRelations.values) : [])
        return
            base
            .filter { relation in
                (subject.map { relation.key.subject == $0 } ?? true)
                    && (predicate.map { relation.key.predicate == $0 } ?? true)
                    && (object.map { relation.key.object == $0 } ?? true)
                    && (time.map { relation.isValid(at: $0) } ?? true)
            }
            .sorted { $0.key < $1.key }
    }

    private func rejectOutOfOrder(
        _ relation: SpatialRelation,
        comparedWith existing: SpatialRelation?
    ) throws {
        if let existing, relation.validFrom < existing.validFrom {
            throw SceneGraphError.outOfOrderRelation(relation.key)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case confirmedRelations
        case provisionalRelations
        case confidencePolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                validatingConfirmedRelations: container.decode(
                    [RelationKey: SpatialRelation].self,
                    forKey: .confirmedRelations
                ),
                provisionalRelations: container.decode(
                    [RelationKey: SpatialRelation].self,
                    forKey: .provisionalRelations
                ),
                confidencePolicy: container.decode(
                    ConfidencePolicy.self,
                    forKey: .confidencePolicy
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .confirmedRelations,
                in: container,
                debugDescription: "Scene graph relation partitions are invalid."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(confirmedRelations, forKey: .confirmedRelations)
        try container.encode(provisionalRelations, forKey: .provisionalRelations)
        try container.encode(confidencePolicy, forKey: .confidencePolicy)
    }
}

public struct SpatialRelationDeriver: Sendable {
    public let nearDistance: Double
    public let supportTolerance: Double

    public init(nearDistance: Double = 0.75, supportTolerance: Double = 0.05) {
        precondition(nearDistance.isFinite && nearDistance >= 0)
        precondition(supportTolerance.isFinite && supportTolerance >= 0)
        self.nearDistance = nearDistance
        self.supportTolerance = supportTolerance
    }

    public func predicates(subject: AABB, object: AABB) -> Set<SpatialRelationPredicate> {
        var result: Set<SpatialRelationPredicate> = []
        let yOverlap = rangesOverlap(subject.min.y...subject.max.y, object.min.y...object.max.y)
        let zOverlap = rangesOverlap(subject.min.z...subject.max.z, object.min.z...object.max.z)
        let xOverlap = rangesOverlap(subject.min.x...subject.max.x, object.min.x...object.max.x)

        if subject.max.x <= object.min.x, yOverlap, zOverlap {
            result.insert(.leftOf)
        }
        if subject.min.x >= object.max.x, yOverlap, zOverlap {
            result.insert(.rightOf)
        }
        if object.contains(subject) {
            result.insert(.inside)
        }
        if let overlap = subject.intersection(with: object), overlap.volume > 0 {
            result.insert(.intersects)
        }
        if subject.distance(to: object) <= nearDistance {
            result.insert(.near)
        }
        if xOverlap, zOverlap, abs(subject.min.y - object.max.y) <= supportTolerance {
            result.insert(.on)
        }
        if xOverlap, zOverlap, abs(subject.max.y - object.min.y) <= supportTolerance {
            result.insert(.under)
        }
        return result
    }

    private func rangesOverlap(_ lhs: ClosedRange<Double>, _ rhs: ClosedRange<Double>) -> Bool {
        lhs.lowerBound <= rhs.upperBound && rhs.lowerBound <= lhs.upperBound
    }
}
