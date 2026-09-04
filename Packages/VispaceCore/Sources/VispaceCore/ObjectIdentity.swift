import Foundation

public enum ObjectIdentityError: Error, Equatable, Sendable {
    case invalidWeights
    case invalidPolicy
}

public struct IdentityEvidence: Codable, Hashable, Sendable {
    public let objectID: ObjectID
    public let semanticClassMatches: Bool
    public let visual: ConfidenceScore
    public let geometry: ConfidenceScore
    public let spatialContext: ConfidenceScore
    public let temporalContinuity: ConfidenceScore
    public let validObservationCount: UInt

    public init(
        objectID: ObjectID,
        semanticClassMatches: Bool,
        visual: ConfidenceScore,
        geometry: ConfidenceScore,
        spatialContext: ConfidenceScore,
        temporalContinuity: ConfidenceScore,
        validObservationCount: UInt
    ) {
        self.objectID = objectID
        self.semanticClassMatches = semanticClassMatches
        self.visual = visual
        self.geometry = geometry
        self.spatialContext = spatialContext
        self.temporalContinuity = temporalContinuity
        self.validObservationCount = validObservationCount
    }
}

public struct IdentityWeights: Codable, Hashable, Sendable {
    public let visual: Double
    public let geometry: Double
    public let spatialContext: Double
    public let temporalContinuity: Double

    public init(
        visual: Double,
        geometry: Double,
        spatialContext: Double,
        temporalContinuity: Double
    ) throws {
        let values = [visual, geometry, spatialContext, temporalContinuity]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }), values.reduce(0, +) > 0 else {
            throw ObjectIdentityError.invalidWeights
        }
        self.visual = visual
        self.geometry = geometry
        self.spatialContext = spatialContext
        self.temporalContinuity = temporalContinuity
    }

    public static let balanced = try! Self(
        visual: 0.35,
        geometry: 0.25,
        spatialContext: 0.20,
        temporalContinuity: 0.20
    )

    fileprivate var total: Double {
        visual + geometry + spatialContext + temporalContinuity
    }

    private enum CodingKeys: String, CodingKey {
        case visual
        case geometry
        case spatialContext
        case temporalContinuity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                visual: container.decode(Double.self, forKey: .visual),
                geometry: container.decode(Double.self, forKey: .geometry),
                spatialContext: container.decode(Double.self, forKey: .spatialContext),
                temporalContinuity: container.decode(Double.self, forKey: .temporalContinuity)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .visual,
                in: container,
                debugDescription: "Identity weights must be finite, nonnegative, and nonzero."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(visual, forKey: .visual)
        try container.encode(geometry, forKey: .geometry)
        try container.encode(spatialContext, forKey: .spatialContext)
        try container.encode(temporalContinuity, forKey: .temporalContinuity)
    }
}

public struct ObjectIdentityPolicy: Codable, Hashable, Sendable {
    public let candidateThreshold: ConfidenceScore
    public let confirmationThreshold: ConfidenceScore
    public let ambiguityMargin: ConfidenceScore
    public let minimumObservationCount: UInt
    public let weights: IdentityWeights

    public init(
        candidateThreshold: ConfidenceScore = ConfidenceScore(clamping: 0.50),
        confirmationThreshold: ConfidenceScore = ConfidenceScore(clamping: 0.80),
        ambiguityMargin: ConfidenceScore = ConfidenceScore(clamping: 0.10),
        minimumObservationCount: UInt = 2,
        weights: IdentityWeights = .balanced
    ) throws {
        guard candidateThreshold < confirmationThreshold, minimumObservationCount > 0 else {
            throw ObjectIdentityError.invalidPolicy
        }
        self.candidateThreshold = candidateThreshold
        self.confirmationThreshold = confirmationThreshold
        self.ambiguityMargin = ambiguityMargin
        self.minimumObservationCount = minimumObservationCount
        self.weights = weights
    }

    public static let `default` = try! Self()

    private enum CodingKeys: String, CodingKey {
        case candidateThreshold
        case confirmationThreshold
        case ambiguityMargin
        case minimumObservationCount
        case weights
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                candidateThreshold: container.decode(
                    ConfidenceScore.self,
                    forKey: .candidateThreshold
                ),
                confirmationThreshold: container.decode(
                    ConfidenceScore.self,
                    forKey: .confirmationThreshold
                ),
                ambiguityMargin: container.decode(
                    ConfidenceScore.self,
                    forKey: .ambiguityMargin
                ),
                minimumObservationCount: container.decode(
                    UInt.self,
                    forKey: .minimumObservationCount
                ),
                weights: container.decode(IdentityWeights.self, forKey: .weights)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .candidateThreshold,
                in: container,
                debugDescription: "Identity policy thresholds or observation count are invalid."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(candidateThreshold, forKey: .candidateThreshold)
        try container.encode(confirmationThreshold, forKey: .confirmationThreshold)
        try container.encode(ambiguityMargin, forKey: .ambiguityMargin)
        try container.encode(minimumObservationCount, forKey: .minimumObservationCount)
        try container.encode(weights, forKey: .weights)
    }
}

public struct RankedIdentityCandidate: Codable, Hashable, Sendable {
    public let objectID: ObjectID
    public let score: ConfidenceScore
    public let validObservationCount: UInt

    public init(objectID: ObjectID, score: ConfidenceScore, validObservationCount: UInt) {
        self.objectID = objectID
        self.score = score
        self.validObservationCount = validObservationCount
    }
}

public enum ObjectIdentityDecision: Codable, Hashable, Sendable {
    case confirmed(RankedIdentityCandidate)
    case provisional([RankedIdentityCandidate])
    case newObject
}

public struct ObjectIdentityEngine: Sendable {
    public let policy: ObjectIdentityPolicy

    public init(policy: ObjectIdentityPolicy = .default) {
        self.policy = policy
    }

    public func rankedCandidates(from evidence: [IdentityEvidence]) -> [RankedIdentityCandidate] {
        var bestByObject: [ObjectID: RankedIdentityCandidate] = [:]
        for item in evidence where item.semanticClassMatches {
            let weights = policy.weights
            let sum =
                item.visual.value * weights.visual
                + item.geometry.value * weights.geometry
                + item.spatialContext.value * weights.spatialContext
                + item.temporalContinuity.value * weights.temporalContinuity
            let candidate = RankedIdentityCandidate(
                objectID: item.objectID,
                score: ConfidenceScore(clamping: sum / weights.total),
                validObservationCount: item.validObservationCount
            )
            if let existing = bestByObject[item.objectID] {
                if candidate.score > existing.score
                    || (candidate.score == existing.score
                        && candidate.validObservationCount > existing.validObservationCount)
                {
                    bestByObject[item.objectID] = candidate
                }
            } else {
                bestByObject[item.objectID] = candidate
            }
        }

        return bestByObject.values.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.objectID < rhs.objectID
        }
    }

    public func decide(from evidence: [IdentityEvidence]) -> ObjectIdentityDecision {
        let ranked = rankedCandidates(from: evidence)
        guard let best = ranked.first else {
            return .newObject
        }
        guard best.score >= policy.candidateThreshold else {
            return .newObject
        }

        let ambiguityIsAcceptable: Bool
        if ranked.count > 1 {
            ambiguityIsAcceptable =
                best.score.value - ranked[1].score.value
                >= policy.ambiguityMargin.value
        } else {
            ambiguityIsAcceptable = true
        }

        if best.score >= policy.confirmationThreshold,
            best.validObservationCount >= policy.minimumObservationCount,
            ambiguityIsAcceptable
        {
            return .confirmed(best)
        }
        return .provisional(ranked)
    }
}
