import Foundation

public enum SpatialRelationQueryError: Error, Equatable, Sendable {
    case invalidCurrentTime
    case invalidResultLimit
}

public enum SpatialRelationQueryMode: String, Codable, Hashable, Sendable {
    case listRelatedObjects
    case verifyRelation
}

public enum SpatialRelationQueryStatus: String, Codable, Hashable, Sendable {
    case answered
    case noConfirmedRelation
    case ambiguous
    case notGrounded
    case unsupported
}

public enum SpatialRelationQueryIssue: String, Codable, Hashable, Sendable {
    case noSupportedRelation
    case noSemanticTarget
    case multipleTargetInstances
    case multipleSemanticTargets
    case noConfirmedRelation
}

public struct SpatialRelationQueryEntity: Codable, Hashable, Sendable {
    public let objectID: ObjectID
    public let semanticLabel: String

    public init(objectID: ObjectID, semanticLabel: String) {
        self.objectID = objectID
        self.semanticLabel = semanticLabel
    }
}

public struct GroundedSpatialRelationMatch: Codable, Hashable, Sendable {
    public let subject: SpatialRelationQueryEntity
    public let predicate: SpatialRelationPredicate
    public let object: SpatialRelationQueryEntity
    public let confidence: ConfidenceScore
    public let validFrom: TimeInterval

    public init(
        subject: SpatialRelationQueryEntity,
        predicate: SpatialRelationPredicate,
        object: SpatialRelationQueryEntity,
        confidence: ConfidenceScore,
        validFrom: TimeInterval
    ) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.confidence = confidence
        self.validFrom = validFrom
    }
}

public struct SpatialRelationQueryResult: Codable, Hashable, Sendable {
    public let mode: SpatialRelationQueryMode?
    public let status: SpatialRelationQueryStatus
    public let predicate: SpatialRelationPredicate?
    public let referenceObject: SpatialRelationQueryEntity?
    public let matches: [GroundedSpatialRelationMatch]
    /// Non-nil only for an unambiguous two-object verification request.
    public let isAffirmative: Bool?
    public let issues: [SpatialRelationQueryIssue]

    public init(
        mode: SpatialRelationQueryMode?,
        status: SpatialRelationQueryStatus,
        predicate: SpatialRelationPredicate?,
        referenceObject: SpatialRelationQueryEntity?,
        matches: [GroundedSpatialRelationMatch],
        isAffirmative: Bool?,
        issues: [SpatialRelationQueryIssue]
    ) {
        self.mode = mode
        self.status = status
        self.predicate = predicate
        self.referenceObject = referenceObject
        self.matches = matches
        self.isAffirmative = isAffirmative
        self.issues = issues
    }
}

public struct SpatialRelationQueryPolicy: Hashable, Sendable {
    public static let maximumAllowedResultCount = 64
    public let maximumResultCount: Int

    public init(maximumResultCount: Int = 16) throws {
        guard (1...Self.maximumAllowedResultCount).contains(maximumResultCount) else {
            throw SpatialRelationQueryError.invalidResultLimit
        }
        self.maximumResultCount = maximumResultCount
    }

    public static let `default` = try! Self()
}

/// Answers basic relation questions only from confirmed, currently valid scene
/// graph edges. It never derives a relation from language or object positions.
public struct DeterministicSpatialRelationQueryEngine: Sendable {
    public let policy: SpatialRelationQueryPolicy

    public init(policy: SpatialRelationQueryPolicy = .default) {
        self.policy = policy
    }

    public func query(
        _ utterance: String,
        records: [StoredSpatialObjectRecord],
        graph: SceneGraph,
        at currentTime: TimeInterval
    ) throws -> SpatialRelationQueryResult {
        guard currentTime.isFinite, currentTime >= 0 else {
            throw SpatialRelationQueryError.invalidCurrentTime
        }
        guard let predicate = detectedPredicate(in: utterance) else {
            return emptyResult(
                status: .unsupported,
                issue: .noSupportedRelation
            )
        }

        let eligible = eligibleRecords(records)
        let mentions = semanticMentions(in: utterance, records: eligible)
        let orderedLabels = orderedDistinctLabels(mentions)
        guard !orderedLabels.isEmpty else {
            return SpatialRelationQueryResult(
                mode: nil,
                status: .notGrounded,
                predicate: predicate,
                referenceObject: nil,
                matches: [],
                isAffirmative: nil,
                issues: [.noSemanticTarget]
            )
        }

        let entitiesByLabel = Dictionary(grouping: eligible) {
            normalize($0.metadata.object.semanticLabel)
        }
        guard orderedLabels.count <= 2 else {
            // Do not answer a different two-object question by silently
            // discarding additional grounded entities in a compound request.
            return emptyResult(
                predicate: predicate,
                status: .ambiguous,
                issue: .multipleSemanticTargets
            )
        }
        if orderedLabels.count == 2 {
            return verifyRelation(
                predicate: predicate,
                subjectLabel: orderedLabels[0],
                objectLabel: orderedLabels[1],
                entitiesByLabel: entitiesByLabel,
                graph: graph,
                at: currentTime
            )
        }
        return listRelated(
            predicate: predicate,
            referenceLabel: orderedLabels[0],
            entitiesByLabel: entitiesByLabel,
            records: eligible,
            graph: graph,
            at: currentTime
        )
    }

    private func verifyRelation(
        predicate: SpatialRelationPredicate,
        subjectLabel: String,
        objectLabel: String,
        entitiesByLabel: [String: [StoredSpatialObjectRecord]],
        graph: SceneGraph,
        at currentTime: TimeInterval
    ) -> SpatialRelationQueryResult {
        guard subjectLabel != objectLabel else {
            return emptyResult(
                mode: .verifyRelation,
                predicate: predicate,
                status: .ambiguous,
                issue: .multipleSemanticTargets
            )
        }
        let subjects = entitiesByLabel[subjectLabel] ?? []
        let objects = entitiesByLabel[objectLabel] ?? []
        guard subjects.count == 1, objects.count == 1 else {
            return emptyResult(
                mode: .verifyRelation,
                predicate: predicate,
                status: .ambiguous,
                issue: .multipleTargetInstances
            )
        }
        let subject = subjects[0].metadata.object
        let object = objects[0].metadata.object
        let relations = matchingRelations(
            predicate: predicate,
            subjectID: subject.id,
            objectID: object.id,
            graph: graph,
            at: currentTime
        )
        let matches = relations.prefix(policy.maximumResultCount).map {
            groundedMatch($0, objectLookup: [subject.id: subject, object.id: object])
        }
        return SpatialRelationQueryResult(
            mode: .verifyRelation,
            status: matches.isEmpty ? .noConfirmedRelation : .answered,
            predicate: predicate,
            referenceObject: entity(object),
            matches: Array(matches),
            isAffirmative: !matches.isEmpty,
            issues: matches.isEmpty ? [.noConfirmedRelation] : []
        )
    }

    private func listRelated(
        predicate: SpatialRelationPredicate,
        referenceLabel: String,
        entitiesByLabel: [String: [StoredSpatialObjectRecord]],
        records: [StoredSpatialObjectRecord],
        graph: SceneGraph,
        at currentTime: TimeInterval
    ) -> SpatialRelationQueryResult {
        let references = entitiesByLabel[referenceLabel] ?? []
        guard references.count == 1 else {
            return emptyResult(
                mode: .listRelatedObjects,
                predicate: predicate,
                status: .ambiguous,
                issue: .multipleTargetInstances
            )
        }
        let reference = references[0].metadata.object
        let objectLookup = Dictionary(
            uniqueKeysWithValues: records.map { ($0.metadata.object.id, $0.metadata.object) }
        )
        let relations = graph.relations(
            predicate: predicate,
            validAt: currentTime,
            includeProvisional: false
        ).filter { relation in
            guard case .object(let subjectID) = relation.key.subject,
                case .object(let objectID) = relation.key.object
            else {
                return false
            }
            if isSymmetric(predicate) {
                return subjectID == reference.id || objectID == reference.id
            }
            // "What is on/under/inside/near X?" treats X as the reference
            // object of the stored subject-predicate-object relation.
            return objectID == reference.id
        }.filter { relation in
            guard case .object(let subjectID) = relation.key.subject,
                case .object(let objectID) = relation.key.object
            else {
                return false
            }
            return objectLookup[subjectID] != nil && objectLookup[objectID] != nil
        }.sorted(by: relationRank)

        let matches = relations.prefix(policy.maximumResultCount).map {
            groundedMatch($0, objectLookup: objectLookup)
        }
        return SpatialRelationQueryResult(
            mode: .listRelatedObjects,
            status: matches.isEmpty ? .noConfirmedRelation : .answered,
            predicate: predicate,
            referenceObject: entity(reference),
            matches: Array(matches),
            isAffirmative: nil,
            issues: matches.isEmpty ? [.noConfirmedRelation] : []
        )
    }

    private func matchingRelations(
        predicate: SpatialRelationPredicate,
        subjectID: ObjectID,
        objectID: ObjectID,
        graph: SceneGraph,
        at currentTime: TimeInterval
    ) -> [SpatialRelation] {
        let direct = graph.relations(
            subject: .object(subjectID),
            predicate: predicate,
            object: .object(objectID),
            validAt: currentTime
        )
        guard direct.isEmpty, isSymmetric(predicate) else {
            return direct
        }
        return graph.relations(
            subject: .object(objectID),
            predicate: predicate,
            object: .object(subjectID),
            validAt: currentTime
        )
    }

    private func eligibleRecords(
        _ records: [StoredSpatialObjectRecord]
    ) -> [StoredSpatialObjectRecord] {
        var seen: Set<ObjectID> = []
        return records.filter { record in
            let object = record.metadata.object
            return object.certainty == .confirmed
                && object.presence != .removed
                && seen.insert(object.id).inserted
        }
    }

    private func semanticMentions(
        in utterance: String,
        records: [StoredSpatialObjectRecord]
    ) -> [RelationSemanticMention] {
        let queryTokens = lexicalTokens(utterance)
        guard !queryTokens.isEmpty else {
            return []
        }
        var mentions: [RelationSemanticMention] = []
        for record in records {
            let canonical = normalize(record.metadata.object.semanticLabel)
            let terms = Set(
                ([record.metadata.object.semanticLabel] + record.semanticAliases)
                    .map(normalize)
                    .filter { !$0.isEmpty }
            )
            for term in terms {
                let termTokens = lexicalTokens(term)
                guard !termTokens.isEmpty, termTokens.count <= queryTokens.count else {
                    continue
                }
                for start in 0...(queryTokens.count - termTokens.count) {
                    let range = start..<(start + termTokens.count)
                    guard
                        tokensMatch(
                            query: Array(queryTokens[range]),
                            term: termTokens
                        )
                    else {
                        continue
                    }
                    mentions.append(
                        RelationSemanticMention(
                            canonicalLabel: canonical,
                            range: range,
                            specificity: termTokens.count
                        )
                    )
                }
            }
        }
        return Array(Set(mentions)).sorted { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            if lhs.specificity != rhs.specificity {
                return lhs.specificity > rhs.specificity
            }
            return lhs.canonicalLabel < rhs.canonicalLabel
        }
    }

    private func orderedDistinctLabels(
        _ mentions: [RelationSemanticMention]
    ) -> [String] {
        var labels: [String] = []
        for mention in mentions where !labels.contains(mention.canonicalLabel) {
            let isShadowed = mentions.contains { other in
                other.canonicalLabel != mention.canonicalLabel
                    && other.specificity > mention.specificity
                    && other.range.lowerBound <= mention.range.lowerBound
                    && other.range.upperBound >= mention.range.upperBound
            }
            if !isShadowed {
                labels.append(mention.canonicalLabel)
            }
        }
        return labels
    }

    private func detectedPredicate(
        in utterance: String
    ) -> SpatialRelationPredicate? {
        let normalized = " \(normalize(utterance)) "
        let lexemes: [(SpatialRelationPredicate, [String])] = [
            (.accessibleFrom, ["갈 수", "접근 가능", "accessible from", "reachable from"]),
            (.connectedTo, ["연결", "연결돼", "연결되어", "connected to"]),
            (.blocking, ["가로막고", "가로막아", "막고", "막아", "blocking", "blocks"]),
            (.intersects, ["겹쳐", "겹치고", "intersects", "overlaps"]),
            (.inside, ["안에", "내부", "inside"]),
            (.under, ["아래", "밑에", "under", "below"]),
            (.on, ["위에", "위의", "on top of", " on "]),
            (.near, ["근처", "가까이", "주변", "near", "next to"]),
        ]
        for (predicate, signals) in lexemes {
            if signals.contains(where: { signal in
                let normalizedSignal = normalize(signal)
                return normalized.contains(" \(normalizedSignal) ")
            }) {
                return predicate
            }
        }
        return nil
    }

    private func groundedMatch(
        _ relation: SpatialRelation,
        objectLookup: [ObjectID: SpatialObject]
    ) -> GroundedSpatialRelationMatch {
        guard case .object(let subjectID) = relation.key.subject,
            case .object(let objectID) = relation.key.object,
            let subject = objectLookup[subjectID],
            let object = objectLookup[objectID]
        else {
            preconditionFailure("Relations are filtered to eligible object endpoints.")
        }
        return GroundedSpatialRelationMatch(
            subject: entity(subject),
            predicate: relation.key.predicate,
            object: entity(object),
            confidence: relation.confidence,
            validFrom: relation.validFrom
        )
    }

    private func entity(_ object: SpatialObject) -> SpatialRelationQueryEntity {
        SpatialRelationQueryEntity(
            objectID: object.id,
            semanticLabel: object.semanticLabel
        )
    }

    private func relationRank(_ lhs: SpatialRelation, _ rhs: SpatialRelation) -> Bool {
        if lhs.confidence != rhs.confidence {
            return lhs.confidence > rhs.confidence
        }
        if lhs.validFrom != rhs.validFrom {
            return lhs.validFrom > rhs.validFrom
        }
        return lhs.key < rhs.key
    }

    private func isSymmetric(_ predicate: SpatialRelationPredicate) -> Bool {
        switch predicate {
        case .near, .intersects, .connectedTo:
            return true
        default:
            return false
        }
    }

    private func tokensMatch(query: [String], term: [String]) -> Bool {
        guard query.count == term.count else {
            return false
        }
        for index in term.indices {
            if query[index] == term[index] {
                continue
            }
            guard index == term.indices.last,
                stripKoreanParticle(query[index]) == term[index]
            else {
                return false
            }
        }
        return true
    }

    private func stripKoreanParticle(_ token: String) -> String {
        let suffixes = [
            "에서는", "으로", "에서", "에게", "한테", "이랑", "까지", "처럼", "보다",
            "하고", "이나", "은", "는", "이", "가", "을", "를", "의", "에", "도", "만",
            "와", "과", "로", "랑",
        ]
        for suffix in suffixes where token.count > suffix.count && token.hasSuffix(suffix) {
            return String(token.dropLast(suffix.count))
        }
        return token
    }

    private func lexicalTokens(_ value: String) -> [String] {
        normalize(value).split(separator: " ").map(String.init)
    }

    private func normalize(_ value: String) -> String {
        let folded = value.precomposedStringWithCanonicalMapping.lowercased()
        var scalars = String.UnicodeScalarView()
        var previousWasSeparator = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                scalars.append(" ")
                previousWasSeparator = true
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    private func emptyResult(
        mode: SpatialRelationQueryMode? = nil,
        predicate: SpatialRelationPredicate? = nil,
        status: SpatialRelationQueryStatus,
        issue: SpatialRelationQueryIssue
    ) -> SpatialRelationQueryResult {
        SpatialRelationQueryResult(
            mode: mode,
            status: status,
            predicate: predicate,
            referenceObject: nil,
            matches: [],
            isAffirmative: nil,
            issues: [issue]
        )
    }
}

private struct RelationSemanticMention: Hashable, Sendable {
    let canonicalLabel: String
    let range: Range<Int>
    let specificity: Int
}
