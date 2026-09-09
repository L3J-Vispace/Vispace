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
    case unresolvedRelationRoles
}

public struct SpatialRelationQueryEntity: Codable, Hashable, Sendable {
    public let objectID: ObjectID
    public let semanticLabel: String
    public let displayName: String?
    public let lastSeenAt: TimeInterval?
    public let position: Vec3?
    public var name: String { displayName ?? semanticLabel }

    public init(
        objectID: ObjectID, semanticLabel: String, displayName: String? = nil,
        lastSeenAt: TimeInterval? = nil, position: Vec3? = nil
    ) {
        self.objectID = objectID
        self.semanticLabel = semanticLabel
        self.displayName = displayName
        self.lastSeenAt = lastSeenAt
        self.position = position
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

public struct SpatialRelationQueryTarget: Codable, Hashable, Sendable {
    public let mention: String
    public let candidates: [SpatialRelationQueryEntity]

    public init(mention: String, candidates: [SpatialRelationQueryEntity]) {
        self.mention = mention
        self.candidates = candidates
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
    public let ambiguousTargets: [SpatialRelationQueryTarget]

    public init(
        mode: SpatialRelationQueryMode?,
        status: SpatialRelationQueryStatus,
        predicate: SpatialRelationPredicate?,
        referenceObject: SpatialRelationQueryEntity?,
        matches: [GroundedSpatialRelationMatch],
        isAffirmative: Bool?,
        issues: [SpatialRelationQueryIssue],
        ambiguousTargets: [SpatialRelationQueryTarget] = []
    ) {
        self.mode = mode
        self.status = status
        self.predicate = predicate
        self.referenceObject = referenceObject
        self.matches = matches
        self.isAffirmative = isAffirmative
        self.issues = issues
        self.ambiguousTargets = ambiguousTargets
    }

    private enum CodingKeys: String, CodingKey {
        case mode, status, predicate, referenceObject, matches, isAffirmative, issues, ambiguousTargets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try container.decodeIfPresent(SpatialRelationQueryMode.self, forKey: .mode),
            status: try container.decode(SpatialRelationQueryStatus.self, forKey: .status),
            predicate: try container.decodeIfPresent(SpatialRelationPredicate.self, forKey: .predicate),
            referenceObject: try container.decodeIfPresent(
                SpatialRelationQueryEntity.self, forKey: .referenceObject),
            matches: try container.decode([GroundedSpatialRelationMatch].self, forKey: .matches),
            isAffirmative: try container.decodeIfPresent(Bool.self, forKey: .isAffirmative),
            issues: try container.decode([SpatialRelationQueryIssue].self, forKey: .issues),
            ambiguousTargets: try container.decodeIfPresent(
                [SpatialRelationQueryTarget].self, forKey: .ambiguousTargets) ?? [])
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

/// A bounded geometry lookup selected with exactly the query engine's semantic
/// grounding rules. Unresolved or ambiguous language never starts pair expansion.
public struct SpatialRelationQueryGeometryScope: Sendable {
    public let predicate: SpatialRelationPredicate
    public let objectIDs: Set<ObjectID>

    fileprivate init(predicate: SpatialRelationPredicate, objectIDs: Set<ObjectID>) {
        self.predicate = predicate
        self.objectIDs = objectIDs
    }
}

/// Answers basic relation questions only from confirmed, currently valid scene
/// graph edges. It never derives a relation from language or object positions.
public struct DeterministicSpatialRelationQueryEngine: Sendable {
    public let policy: SpatialRelationQueryPolicy

    public init(policy: SpatialRelationQueryPolicy = .default) {
        self.policy = policy
    }

    public func geometryScope(
        for utterance: String,
        records: [StoredSpatialObjectRecord],
        selections: [String: ObjectID] = [:]
    ) -> SpatialRelationQueryGeometryScope? {
        guard let scope = targetScope(for: utterance, records: records, selections: selections),
            scope.predicate.isGeometryDerived
        else { return nil }
        return scope
    }

    public func targetScope(
        for utterance: String, records: [StoredSpatialObjectRecord], selections: [String: ObjectID] = [:]
    ) -> SpatialRelationQueryGeometryScope? {
        let eligible = eligibleRecords(records)
        let targets = groundedTargets(in: utterance, records: eligible, selections: selections)
        guard let predicate = detectedPredicate(in: utterance, excluding: targets) else { return nil }
        let labels = targets.map(\.mention)
        guard (1...2).contains(labels.count) else { return nil }
        if labels.count == 1, !isListReference(in: utterance, predicate: predicate, targets: targets) {
            return nil
        }
        if labels.count == 2,
            resolvedRoles(in: utterance, predicate: predicate, targets: targets) == nil
        {
            return nil
        }
        let byLabel = Dictionary(uniqueKeysWithValues: targets.map { ($0.mention, $0.records) })
        var objectIDs: Set<ObjectID> = []
        for label in labels {
            guard let matches = byLabel[label], matches.count == 1 else { return nil }
            objectIDs.insert(matches[0].metadata.object.id)
        }
        return SpatialRelationQueryGeometryScope(predicate: predicate, objectIDs: objectIDs)
    }

    public func query(
        _ utterance: String,
        records: [StoredSpatialObjectRecord],
        graph: SceneGraph,
        at currentTime: TimeInterval,
        selections: [String: ObjectID] = [:]
    ) throws -> SpatialRelationQueryResult {
        guard currentTime.isFinite, currentTime >= 0 else {
            throw SpatialRelationQueryError.invalidCurrentTime
        }
        let eligible = eligibleRecords(records)
        let targets = groundedTargets(in: utterance, records: eligible, selections: selections)
        guard let predicate = detectedPredicate(in: utterance, excluding: targets) else {
            return emptyResult(
                status: .unsupported,
                issue: .noSupportedRelation
            )
        }

        let orderedLabels = targets.map(\.mention)
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

        let entitiesByLabel = Dictionary(uniqueKeysWithValues: targets.map { ($0.mention, $0.records) })
        let ambiguous = targets.filter { $0.records.count != 1 }.map {
            SpatialRelationQueryTarget(
                mention: $0.mention, candidates: $0.records.map { entity($0.metadata.object) })
        }
        if !ambiguous.isEmpty {
            return SpatialRelationQueryResult(
                mode: targets.count == 1 ? .listRelatedObjects : .verifyRelation,
                status: .ambiguous, predicate: predicate, referenceObject: nil,
                matches: [], isAffirmative: nil, issues: [.multipleTargetInstances],
                ambiguousTargets: ambiguous
            )
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
            guard let roles = resolvedRoles(in: utterance, predicate: predicate, targets: targets) else {
                return emptyResult(
                    mode: .verifyRelation, predicate: predicate, status: .unsupported,
                    issue: .unresolvedRelationRoles)
            }
            return verifyRelation(
                predicate: predicate,
                subjectLabel: roles.subject,
                objectLabel: roles.object,
                entitiesByLabel: entitiesByLabel,
                graph: graph,
                at: currentTime
            )
        }
        guard isListReference(in: utterance, predicate: predicate, targets: targets) else {
            return emptyResult(
                mode: .listRelatedObjects, predicate: predicate, status: .unsupported,
                issue: .unresolvedRelationRoles)
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
        guard subject.id != object.id else {
            return emptyResult(
                mode: .verifyRelation, predicate: predicate, status: .ambiguous,
                issue: .multipleSemanticTargets)
        }
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
            isAffirmative: matches.isEmpty ? nil : true,
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
            let terms = Set(
                ([record.metadata.object.semanticLabel, record.metadata.object.displayName ?? ""]
                    + record.semanticAliases)
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
                            canonicalLabel: term,
                            objectID: record.metadata.object.id,
                            range: range,
                            specificity: termTokens.joined().count
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

    /// Keep IDs attached to the actual name span instead of widening a user
    /// name back into all instances of its detector class.
    private func groundedTargets(
        in utterance: String,
        records: [StoredSpatialObjectRecord],
        selections: [String: ObjectID]
    ) -> [GroundedRelationTarget] {
        let mentions = semanticMentions(in: utterance, records: records)
        let retained = mentions.filter { mention in
            !mentions.contains { other in
                other.specificity > mention.specificity
                    && other.range.lowerBound <= mention.range.lowerBound
                    && other.range.upperBound >= mention.range.upperBound
            }
        }
        var result: [GroundedRelationTarget] = []
        for mention in retained {
            if result.contains(where: { $0.mention == mention.canonicalLabel }) { continue }
            let ids = Set(
                retained.filter {
                    $0.canonicalLabel == mention.canonicalLabel
                }.map(\.objectID))
            var candidates = records.filter { ids.contains($0.metadata.object.id) }
            if let selected = selections[mention.canonicalLabel] {
                // A stale choice must not silently select a replacement.
                candidates = candidates.filter { $0.metadata.object.id == selected }
            }
            result.append(
                GroundedRelationTarget(
                    mention: mention.canonicalLabel, records: candidates,
                    ranges: Set(retained.filter { $0.canonicalLabel == mention.canonicalLabel }.map(\.range)))
            )
        }
        return result
    }

    private func detectedPredicate(
        in utterance: String, excluding targets: [GroundedRelationTarget]
    ) -> SpatialRelationPredicate? {
        let signals = relationSignals(in: utterance, excluding: targets)
        // A one-reference list request has no later role-resolution step.
        // Reject compound relations here too, instead of picking a predicate
        // by vocabulary order and answering only part of the user's question.
        guard targets.count != 1 || signals.count == 1 else { return nil }
        return signals.first?.predicate
    }

    private func relationSignals(
        in utterance: String, excluding targets: [GroundedRelationTarget]
    ) -> [RelationLanguageSignal] {
        let tokens = lexicalTokens(utterance)
        let lexemes = SpatialRelationLanguage.lexemes
        var found: [RelationLanguageSignal] = []
        for (predicate, signals) in lexemes {
            for signal in signals {
                let phrase = lexicalTokens(signal)
                guard !phrase.isEmpty, phrase.count <= tokens.count else { continue }
                for start in 0...(tokens.count - phrase.count) {
                    let range = start..<(start + phrase.count)
                    if Array(tokens[range]) == phrase {
                        found.append(
                            RelationLanguageSignal(
                                predicate: predicate, range: range,
                                isEnglish: signal.unicodeScalars.allSatisfy { $0.isASCII }))
                    }
                }
            }
        }
        // Prefer the complete phrase "on top of" over its embedded "on".
        return found.filter { signal in
            !targets.contains { target in target.ranges.contains { $0.overlaps(signal.range) } }
                && !found.contains { other in
                    other.predicate == signal.predicate && other.range.count > signal.range.count
                        && other.range.lowerBound <= signal.range.lowerBound
                        && other.range.upperBound >= signal.range.upperBound
                }
        }
    }

    /// Resolve a bounded set of grammar forms from grounded name spans. Missing
    /// grammar never falls back to the order in which object names appeared.
    private func resolvedRoles(
        in utterance: String, predicate: SpatialRelationPredicate, targets: [GroundedRelationTarget]
    ) -> (subject: String, object: String)? {
        guard targets.count == 2, targets.allSatisfy({ $0.ranges.count == 1 }) else { return nil }
        let signals = relationSignals(in: utterance, excluding: targets)
        guard signals.count == 1, let signal = signals.first, signal.predicate == predicate else {
            return nil
        }
        if isSymmetric(predicate) { return (targets[0].mention, targets[1].mention) }
        let references = referenceTargets(in: utterance, signal: signal, targets: targets)
        guard references.count == 1, let reference = references.first,
            let subject = targets.first(where: { $0.mention != reference.mention })
        else { return nil }
        return (subject.mention, reference.mention)
    }

    /// Listing incoming directional edges is valid only when the grounded
    /// name is the reference. "What is the cup on?" cannot become "what is
    /// on the cup?", including when the actual reference has no saved record.
    private func isListReference(
        in utterance: String, predicate: SpatialRelationPredicate, targets: [GroundedRelationTarget]
    ) -> Bool {
        guard targets.count == 1, targets[0].ranges.count == 1 else { return false }
        let signals = relationSignals(in: utterance, excluding: targets)
        guard signals.count == 1, let signal = signals.first, signal.predicate == predicate else {
            return false
        }
        return isSymmetric(predicate)
            || referenceTargets(in: utterance, signal: signal, targets: targets).count == 1
    }

    private func referenceTargets(
        in utterance: String, signal: RelationLanguageSignal, targets: [GroundedRelationTarget]
    ) -> [GroundedRelationTarget] {
        let tokens = lexicalTokens(utterance)
        func particle(_ target: GroundedRelationTarget) -> String? {
            guard let range = target.ranges.first, let last = lexicalTokens(target.mention).last else {
                return nil
            }
            let token = tokens[range.upperBound - 1]
            guard token.hasPrefix(last) else { return nil }
            return String(token.dropFirst(last.count))
        }
        let allNamesBeforeRelation = targets.allSatisfy {
            guard let range = $0.ranges.first else { return false }
            return range.upperBound <= signal.range.lowerBound
        }
        let references: [GroundedRelationTarget]
        if signal.isEnglish {
            // English prepositions identify the following reference, including
            // fronted forms such as "on the table is the cup?".
            references = targets.filter { target in
                guard let range = target.ranges.first, range.lowerBound >= signal.range.upperBound else {
                    return false
                }
                return tokens[signal.range.upperBound..<range.lowerBound].allSatisfy {
                    ["the", "a", "an"].contains($0)
                }
            }
        } else {
            switch signal.predicate {
            case .on, .under, .inside:
                references = targets.filter { target in
                    target.ranges.first?.upperBound == signal.range.lowerBound
                        && ["", "의"].contains(particle(target) ?? "?")
                }
            case .blocking:
                references = targets.filter { ["을", "를"].contains(particle($0) ?? "") }
                guard allNamesBeforeRelation,
                    targets.count == 1
                        || targets.contains(where: { ["이", "가", "은", "는"].contains(particle($0) ?? "") })
                else { return [] }
            case .accessibleFrom:
                references = targets.filter { ["에서", "에서는"].contains(particle($0) ?? "") }
                guard allNamesBeforeRelation else { return [] }
            default:
                return []
            }
        }
        return references
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
            semanticLabel: object.semanticLabel,
            displayName: object.displayName,
            lastSeenAt: object.lastSeenAt,
            position: object.position
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
    let objectID: ObjectID
    let range: Range<Int>
    let specificity: Int
}

private struct GroundedRelationTarget {
    let mention: String
    let records: [StoredSpatialObjectRecord]
    let ranges: Set<Range<Int>>
}

private struct RelationLanguageSignal {
    let predicate: SpatialRelationPredicate
    let range: Range<Int>
    let isEnglish: Bool
}
