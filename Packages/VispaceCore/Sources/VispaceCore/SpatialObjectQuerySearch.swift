import Foundation

public enum SpatialObjectSearchError: Error, Equatable, Sendable {
    case invalidCurrentTime
    case invalidResultLimit
    case invalidAmbiguityThreshold
}

/// A persisted object plus non-coordinate search context supplied by the
/// persistence layer. The only position carried by this type is the validated
/// `SpatialObjectMetadata.position` value.
public struct StoredSpatialObjectRecord: Hashable, Sendable {
    public let metadata: SpatialObjectMetadata
    public let memoryTier: MemoryTier
    public let floorNodeID: SpatialNodeID?
    public let semanticAliases: [String]

    public init(
        metadata: SpatialObjectMetadata,
        memoryTier: MemoryTier,
        floorNodeID: SpatialNodeID? = nil,
        semanticAliases: [String] = []
    ) {
        self.metadata = metadata
        self.memoryTier = memoryTier
        self.floorNodeID = floorNodeID
        self.semanticAliases = Array(
            Set(
                semanticAliases
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
    }
}

public struct SpatialObjectSearchContext: Hashable, Sendable {
    public let currentMapID: MapID?
    public let currentFloorNodeID: SpatialNodeID?
    public let now: TimeInterval
    public let includeRemoved: Bool

    public init(
        currentMapID: MapID? = nil,
        currentFloorNodeID: SpatialNodeID? = nil,
        now: TimeInterval,
        includeRemoved: Bool = false
    ) throws {
        guard now.isFinite, now >= 0 else {
            throw SpatialObjectSearchError.invalidCurrentTime
        }
        self.currentMapID = currentMapID
        self.currentFloorNodeID = currentFloorNodeID
        self.now = now
        self.includeRemoved = includeRemoved
    }
}

public struct SpatialObjectSearchPolicy: Hashable, Sendable {
    public static let maximumAllowedResultCount = 64

    public let confidencePolicy: ConfidencePolicy
    public let maximumResultCount: Int
    /// Candidates in the same context remain ambiguous when their effective
    /// confidence differs by no more than this amount. Recency orders the list
    /// but never silently turns two otherwise equivalent objects into one ID.
    public let ambiguityConfidenceDelta: Double

    public init(
        confidencePolicy: ConfidencePolicy = .default,
        maximumResultCount: Int = 8,
        ambiguityConfidenceDelta: Double = 0.05
    ) throws {
        guard (1...Self.maximumAllowedResultCount).contains(maximumResultCount) else {
            throw SpatialObjectSearchError.invalidResultLimit
        }
        guard ambiguityConfidenceDelta.isFinite,
            (0...1).contains(ambiguityConfidenceDelta)
        else {
            throw SpatialObjectSearchError.invalidAmbiguityThreshold
        }
        self.confidencePolicy = confidencePolicy
        self.maximumResultCount = maximumResultCount
        self.ambiguityConfidenceDelta = ambiguityConfidenceDelta
    }

    public static let `default` = try! Self()
}

public enum SpatialObjectSearchStatus: String, Codable, Hashable, Sendable {
    /// One medium- or high-confidence persisted location was selected.
    case found
    /// More than one semantic target or object remains plausible.
    case ambiguous
    /// The deterministic request could not be grounded in eligible metadata.
    case notFound
    /// A candidate exists, but its grounded position is below the confidence floor.
    case lowConfidence
    /// This engine does not handle the routed intent. No location is selected.
    case unsupportedIntent
}

public enum SpatialObjectSearchIssue: String, Codable, Hashable, Sendable {
    case noSemanticTarget
    case noEligibleStoredObject
    case multipleSemanticTargets
    case multiplePlausibleObjects
    case groundedPositionLowConfidence
    case unsupportedIntent
}

/// A ranked candidate. `groundedPosition` is computed directly from persisted
/// metadata; the search engine has no API that accepts or generates a Vec3.
public struct GroundedSpatialObjectCandidate: Hashable, Sendable {
    public let record: StoredSpatialObjectRecord
    public let effectiveConfidence: ConfidenceScore
    public let confidenceGrade: ConfidenceGrade
    public let matchesCurrentMap: Bool?
    public let matchesCurrentFloor: Bool?
    public let secondsSinceLastSeen: TimeInterval

    public var groundedPosition: FramedPosition {
        record.metadata.position
    }

    public init(
        record: StoredSpatialObjectRecord,
        effectiveConfidence: ConfidenceScore,
        confidenceGrade: ConfidenceGrade,
        matchesCurrentMap: Bool?,
        matchesCurrentFloor: Bool?,
        secondsSinceLastSeen: TimeInterval
    ) {
        self.record = record
        self.effectiveConfidence = effectiveConfidence
        self.confidenceGrade = confidenceGrade
        self.matchesCurrentMap = matchesCurrentMap
        self.matchesCurrentFloor = matchesCurrentFloor
        self.secondsSinceLastSeen = secondsSinceLastSeen
    }
}

public struct SpatialObjectSearchResult: Hashable, Sendable {
    public let route: IntentRoute
    public let status: SpatialObjectSearchStatus
    public let matchedSemanticLabels: [String]
    public let candidates: [GroundedSpatialObjectCandidate]
    public let issues: [SpatialObjectSearchIssue]

    /// Only a resolved identity above the confidence floor exposes a candidate.
    /// The controller may also resolve ambiguity through an explicit user choice.
    public var selectedCandidate: GroundedSpatialObjectCandidate? {
        guard status == .found else {
            return nil
        }
        return candidates.first
    }

    /// This is always the framed coordinate stored in `SpatialObjectMetadata`.
    /// Unsupported, missing, ambiguous, and low-confidence results expose none.
    public var groundedPosition: FramedPosition? {
        selectedCandidate?.groundedPosition
    }

    public var requiresLLM: Bool {
        route.requiresLLM
    }

    public init(
        route: IntentRoute,
        status: SpatialObjectSearchStatus,
        matchedSemanticLabels: [String],
        candidates: [GroundedSpatialObjectCandidate],
        issues: [SpatialObjectSearchIssue]
    ) {
        self.route = route
        self.status = status
        self.matchedSemanticLabels = matchedSemanticLabels
        self.candidates = candidates
        self.issues = issues
    }
}

/// Deterministically routes a find/last-seen/navigation utterance, grounds its
/// semantic target against known labels or aliases, and ranks persisted object
/// metadata by map, floor, confidence, then recency.
///
/// Complex or relation intents are never passed through as fabricated search
/// coordinates. A caller may use an LLM for language generation, but AR
/// guidance can only consume this engine's `groundedPosition`.
public struct DeterministicSpatialObjectSearchEngine: Sendable {
    public let policy: SpatialObjectSearchPolicy
    private let intentRouter: DeterministicIntentRouter

    public init(
        policy: SpatialObjectSearchPolicy = .default,
        intentRouter: DeterministicIntentRouter = DeterministicIntentRouter()
    ) {
        self.policy = policy
        self.intentRouter = intentRouter
    }

    public func search(
        utterance: String,
        records: [StoredSpatialObjectRecord],
        context: SpatialObjectSearchContext
    ) -> SpatialObjectSearchResult {
        let termMatches = semanticMatches(in: utterance, records: records)
        let canonicalLabels = canonicalLabels(from: termMatches)
        let initialRoute = intentRouter.route(utterance)
        let route = routeForBareSemanticLabelIfNeeded(
            initialRoute,
            utterance: utterance,
            matches: termMatches
        )

        guard supportsObjectLookup(route.kind) else {
            return SpatialObjectSearchResult(
                route: route,
                status: .unsupportedIntent,
                matchedSemanticLabels: canonicalLabels,
                candidates: [],
                issues: [.unsupportedIntent]
            )
        }

        guard !canonicalLabels.isEmpty else {
            return SpatialObjectSearchResult(
                route: route,
                status: .notFound,
                matchedSemanticLabels: [],
                candidates: [],
                issues: [.noSemanticTarget]
            )
        }

        let matchingIDs = Set(termMatches.map(\.objectID))
        let matchingRecords = records.filter { record in
            matchingIDs.contains(record.metadata.object.id)
                && record.metadata.object.certainty == .confirmed
                && (context.includeRemoved || record.metadata.object.presence != .removed)
        }
        var ranked = matchingRecords.map { rankedCandidate(for: $0, context: context) }
        ranked.sort(by: ranksBefore)
        ranked = deduplicatingObjectIDs(ranked)
        let candidates = Array(ranked.prefix(policy.maximumResultCount).map(\.candidate))

        guard !candidates.isEmpty else {
            return SpatialObjectSearchResult(
                route: route,
                status: .notFound,
                matchedSemanticLabels: canonicalLabels,
                candidates: [],
                issues: [.noEligibleStoredObject]
            )
        }

        if canonicalLabels.count > 1 {
            return SpatialObjectSearchResult(
                route: route,
                status: .ambiguous,
                matchedSemanticLabels: canonicalLabels,
                candidates: candidates,
                issues: [.multipleSemanticTargets]
            )
        }

        if ranked.count > 1, candidatesAreAmbiguous(ranked[0], ranked[1]) {
            var issues: [SpatialObjectSearchIssue] = [.multiplePlausibleObjects]
            if ranked[0].candidate.confidenceGrade == .low {
                issues.append(.groundedPositionLowConfidence)
            }
            return SpatialObjectSearchResult(
                route: route,
                status: .ambiguous,
                matchedSemanticLabels: canonicalLabels,
                candidates: candidates,
                issues: issues
            )
        }

        guard ranked[0].candidate.confidenceGrade != .low else {
            return SpatialObjectSearchResult(
                route: route,
                status: .lowConfidence,
                matchedSemanticLabels: canonicalLabels,
                candidates: candidates,
                issues: [.groundedPositionLowConfidence]
            )
        }

        return SpatialObjectSearchResult(
            route: route,
            status: .found,
            matchedSemanticLabels: canonicalLabels,
            candidates: candidates,
            issues: []
        )
    }

    private func supportsObjectLookup(_ kind: SpatialIntentKind) -> Bool {
        switch kind {
        case .searchObject, .lastSeen, .navigate:
            return true
        case .relationQuery, .complexAsk:
            return false
        }
    }

    /// Explicit user choice resolves identity ambiguity only. Fresh metadata
    /// still has to satisfy eligibility and the normal confidence floor.
    public func select(record: StoredSpatialObjectRecord, route: IntentRoute,
                       context: SpatialObjectSearchContext) -> SpatialObjectSearchResult {
        guard supportsObjectLookup(route.kind) else {
            return SpatialObjectSearchResult(route: route, status: .unsupportedIntent,
                matchedSemanticLabels: [], candidates: [], issues: [.unsupportedIntent])
        }
        guard record.metadata.object.certainty == .confirmed,
            record.metadata.object.presence != .removed
                || (route.kind == .lastSeen && context.includeRemoved) else {
            return SpatialObjectSearchResult(route: route, status: .notFound,
                matchedSemanticLabels: [record.metadata.object.semanticLabel],
                candidates: [], issues: [.noEligibleStoredObject])
        }
        let candidate = rankedCandidate(for: record, context: context).candidate
        let isLow = candidate.confidenceGrade == .low
        return SpatialObjectSearchResult(route: route, status: isLow ? .lowConfidence : .found,
            matchedSemanticLabels: [record.metadata.object.semanticLabel], candidates: [candidate],
            issues: isLow ? [.groundedPositionLowConfidence] : [])
    }

    private func routeForBareSemanticLabelIfNeeded(
        _ route: IntentRoute,
        utterance: String,
        matches: [SemanticTermMatch]
    ) -> IntentRoute {
        guard route.kind == .complexAsk,
            matches.contains(where: { match in
                match.range.lowerBound == 0
                    && match.range.upperBound == lexicalTokens(utterance).count
            })
        else {
            return route
        }
        return IntentRoute(
            kind: .searchObject,
            normalizedUtterance: normalizeText(utterance),
            matchedSignals: ["exact-semantic-label"],
            requiresLLM: false
        )
    }

    private func rankedCandidate(
        for record: StoredSpatialObjectRecord,
        context: SpatialObjectSearchContext
    ) -> RankedCandidate {
        let object = record.metadata.object
        let effectiveConfidence = effectiveLocationConfidence(for: record.metadata)
        let mapRank: Int
        let mapMatch: Bool?
        if let currentMapID = context.currentMapID {
            let matches = record.metadata.mapID == currentMapID
            mapRank = matches ? 0 : 1
            mapMatch = matches
        } else {
            mapRank = 0
            mapMatch = nil
        }

        let floorRank: Int
        let floorMatch: Bool?
        if let currentFloorNodeID = context.currentFloorNodeID {
            if let floorNodeID = record.floorNodeID {
                let matches = floorNodeID == currentFloorNodeID
                floorRank = matches ? 0 : 2
                floorMatch = matches
            } else {
                floorRank = 1
                floorMatch = nil
            }
        } else {
            floorRank = 0
            floorMatch = nil
        }

        let candidate = GroundedSpatialObjectCandidate(
            record: record,
            effectiveConfidence: effectiveConfidence,
            confidenceGrade: policy.confidencePolicy.grade(for: effectiveConfidence),
            matchesCurrentMap: mapMatch,
            matchesCurrentFloor: floorMatch,
            secondsSinceLastSeen: max(0, context.now - object.lastSeenAt)
        )
        return RankedCandidate(
            candidate: candidate,
            mapRank: mapRank,
            floorRank: floorRank,
            presenceRank: presenceRank(object.presence)
        )
    }

    private func effectiveLocationConfidence(
        for metadata: SpatialObjectMetadata
    ) -> ConfidenceScore {
        let confidence = metadata.object.confidence
        var value =
            [
                confidence.semantic.value,
                confidence.geometry.value,
                confidence.tracking.value,
                confidence.identity.value,
                confidence.objectState.value,
            ].min() ?? 0

        switch metadata.position.trackingQuality {
        case .normal:
            break
        case .limited:
            value = min(value, policy.confidencePolicy.highThreshold.value.nextDown)
        case .unavailable:
            value = min(value, policy.confidencePolicy.mediumThreshold.value.nextDown)
        }

        switch metadata.position.uncertainty {
        case .highConfidenceDepth:
            break
        case .mediumConfidenceDepth, .raycastEstimate, .unknown:
            value = min(value, policy.confidencePolicy.highThreshold.value.nextDown)
        case .lowConfidenceDepth, .unavailable:
            value = min(value, policy.confidencePolicy.mediumThreshold.value.nextDown)
        }
        return ConfidenceScore(clamping: value)
    }

    private func ranksBefore(_ lhs: RankedCandidate, _ rhs: RankedCandidate) -> Bool {
        if lhs.mapRank != rhs.mapRank {
            return lhs.mapRank < rhs.mapRank
        }
        if lhs.floorRank != rhs.floorRank {
            return lhs.floorRank < rhs.floorRank
        }
        if lhs.candidate.confidenceGrade != rhs.candidate.confidenceGrade {
            return lhs.candidate.confidenceGrade > rhs.candidate.confidenceGrade
        }
        if lhs.candidate.effectiveConfidence != rhs.candidate.effectiveConfidence {
            return lhs.candidate.effectiveConfidence > rhs.candidate.effectiveConfidence
        }
        let lhsObject = lhs.candidate.record.metadata.object
        let rhsObject = rhs.candidate.record.metadata.object
        if lhs.candidate.secondsSinceLastSeen != rhs.candidate.secondsSinceLastSeen {
            return lhs.candidate.secondsSinceLastSeen < rhs.candidate.secondsSinceLastSeen
        }
        if lhs.presenceRank != rhs.presenceRank {
            return lhs.presenceRank < rhs.presenceRank
        }
        if lhs.candidate.record.memoryTier != rhs.candidate.record.memoryTier {
            return lhs.candidate.record.memoryTier < rhs.candidate.record.memoryTier
        }
        if lhs.candidate.record.metadata.mapID != rhs.candidate.record.metadata.mapID {
            return lhs.candidate.record.metadata.mapID < rhs.candidate.record.metadata.mapID
        }
        return lhsObject.id < rhsObject.id
    }

    private func candidatesAreAmbiguous(
        _ first: RankedCandidate,
        _ second: RankedCandidate
    ) -> Bool {
        first.mapRank == second.mapRank
            && first.floorRank == second.floorRank
            && first.presenceRank == second.presenceRank
            && first.candidate.confidenceGrade == second.candidate.confidenceGrade
            && abs(
                first.candidate.effectiveConfidence.value
                    - second.candidate.effectiveConfidence.value
            ) <= policy.ambiguityConfidenceDelta
    }

    private func deduplicatingObjectIDs(
        _ ranked: [RankedCandidate]
    ) -> [RankedCandidate] {
        var seen: Set<ObjectID> = []
        return ranked.filter { candidate in
            seen.insert(candidate.candidate.record.metadata.object.id).inserted
        }
    }

    private func presenceRank(_ presence: ObjectPresence) -> Int {
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

    private func semanticMatches(
        in utterance: String,
        records: [StoredSpatialObjectRecord]
    ) -> [SemanticTermMatch] {
        let queryTokens = lexicalTokens(utterance)
        guard !queryTokens.isEmpty else {
            return []
        }

        var matches: [SemanticTermMatch] = []
        for record in records {
            let canonicalLabel = normalizeLabel(record.metadata.object.semanticLabel)
            let terms = [record.metadata.object.semanticLabel] + record.semanticAliases
                + [record.metadata.object.displayName].compactMap { $0 }
            for term in Set(terms.map(normalizeLabel)).sorted() {
                let termTokens = lexicalTokens(term)
                guard !termTokens.isEmpty, termTokens.count <= queryTokens.count else {
                    continue
                }
                for start in 0...(queryTokens.count - termTokens.count) {
                    let range = start..<(start + termTokens.count)
                    guard tokensMatch(query: Array(queryTokens[range]), term: termTokens) else {
                        continue
                    }
                    matches.append(
                        SemanticTermMatch(
                            canonicalLabel: canonicalLabel,
                            objectID: record.metadata.object.id,
                            range: range,
                            specificity: termTokens.count
                        )
                    )
                }
            }
        }

        let unshadowed = matches.filter { match in
            !matches.contains { other in
                other.specificity > match.specificity
                    && other.range.lowerBound <= match.range.lowerBound
                    && other.range.upperBound >= match.range.upperBound
            }
        }
        return Array(Set(unshadowed)).sorted { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            if lhs.specificity != rhs.specificity {
                return lhs.specificity > rhs.specificity
            }
            return lhs.canonicalLabel < rhs.canonicalLabel
        }
    }

    private func canonicalLabels(from matches: [SemanticTermMatch]) -> [String] {
        Array(Set(matches.map(\.canonicalLabel))).sorted()
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
                strippedKoreanParticle(from: query[index]) == term[index]
            else {
                return false
            }
        }
        return true
    }

    private func strippedKoreanParticle(from token: String) -> String {
        guard token.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains(Int($0.value)) })
        else {
            return token
        }
        let suffixes = [
            "으로부터", "에게서", "한테서", "에서는", "으로", "에서", "에게", "한테", "께서",
            "이랑", "까지", "부터", "처럼", "보다", "하고", "이나", "라도", "은", "는", "이",
            "가", "을", "를", "의", "에", "도", "만", "와", "과", "로", "랑",
        ]
        for suffix in suffixes where token.count > suffix.count && token.hasSuffix(suffix) {
            return String(token.dropLast(suffix.count))
        }
        return token
    }

    private func lexicalTokens(_ value: String) -> [String] {
        normalizeText(value).split(separator: " ").map(String.init)
    }

    private func normalizeLabel(_ value: String) -> String {
        lexicalTokens(value).joined(separator: " ")
    }

    private func normalizeText(_ value: String) -> String {
        let folded = value.precomposedStringWithCanonicalMapping.lowercased()
        var normalized = String.UnicodeScalarView()
        var previousWasSeparator = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                normalized.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                normalized.append(" ")
                previousWasSeparator = true
            }
        }
        return String(normalized).trimmingCharacters(in: .whitespaces)
    }
}

private struct RankedCandidate: Sendable {
    let candidate: GroundedSpatialObjectCandidate
    let mapRank: Int
    let floorRank: Int
    let presenceRank: Int
}

private struct SemanticTermMatch: Hashable, Sendable {
    let canonicalLabel: String
    let objectID: ObjectID
    let range: Range<Int>
    let specificity: Int
}
