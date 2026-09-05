import Foundation

public enum PlaceRecognitionError: Error, Equatable, Sendable {
    case invalidWeights
    case invalidThresholds
}

public enum PlaceClassification: String, Codable, Hashable, Sendable {
    case known
    case overlapping
    case new
}

public enum PlaceMutationPlan: String, Codable, Hashable, Sendable {
    case updateExisting
    case validateMerge
    case createNewNode
}

public struct PlaceEvidence: Codable, Hashable, Sendable {
    public let visual: ConfidenceScore
    public let geometry: ConfidenceScore
    public let structure: ConfidenceScore
    public let poseConsistency: ConfidenceScore
    public let objectLayout: ConfidenceScore
    public let spatialOverlap: ConfidenceScore

    public init(
        visual: ConfidenceScore,
        geometry: ConfidenceScore,
        structure: ConfidenceScore,
        poseConsistency: ConfidenceScore,
        objectLayout: ConfidenceScore,
        spatialOverlap: ConfidenceScore
    ) {
        self.visual = visual
        self.geometry = geometry
        self.structure = structure
        self.poseConsistency = poseConsistency
        self.objectLayout = objectLayout
        self.spatialOverlap = spatialOverlap
    }
}

public struct PlaceEvidenceWeights: Codable, Hashable, Sendable {
    public let visual: Double
    public let geometry: Double
    public let structure: Double
    public let poseConsistency: Double
    public let objectLayout: Double

    public init(
        visual: Double,
        geometry: Double,
        structure: Double,
        poseConsistency: Double,
        objectLayout: Double
    ) throws {
        let values = [visual, geometry, structure, poseConsistency, objectLayout]
        let total = values.reduce(0, +)
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }), total.isFinite, total > 0 else {
            throw PlaceRecognitionError.invalidWeights
        }
        self.visual = visual
        self.geometry = geometry
        self.structure = structure
        self.poseConsistency = poseConsistency
        self.objectLayout = objectLayout
    }

    public static let balanced = try! Self(
        visual: 0.20,
        geometry: 0.25,
        structure: 0.25,
        poseConsistency: 0.15,
        objectLayout: 0.15
    )

    fileprivate var total: Double {
        visual + geometry + structure + poseConsistency + objectLayout
    }

    private enum CodingKeys: String, CodingKey {
        case visual
        case geometry
        case structure
        case poseConsistency
        case objectLayout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                visual: container.decode(Double.self, forKey: .visual),
                geometry: container.decode(Double.self, forKey: .geometry),
                structure: container.decode(Double.self, forKey: .structure),
                poseConsistency: container.decode(Double.self, forKey: .poseConsistency),
                objectLayout: container.decode(Double.self, forKey: .objectLayout)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .visual,
                in: container,
                debugDescription: "Place evidence weights must be finite, nonnegative, and nonzero."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(visual, forKey: .visual)
        try container.encode(geometry, forKey: .geometry)
        try container.encode(structure, forKey: .structure)
        try container.encode(poseConsistency, forKey: .poseConsistency)
        try container.encode(objectLayout, forKey: .objectLayout)
    }
}

public struct PlaceRecognitionPolicy: Codable, Hashable, Sendable {
    public let overlappingScoreThreshold: ConfidenceScore
    public let knownScoreThreshold: ConfidenceScore
    public let minimumOverlap: ConfidenceScore
    public let knownOverlapThreshold: ConfidenceScore
    public let minimumKnownGeometry: ConfidenceScore
    public let weights: PlaceEvidenceWeights

    public init(
        overlappingScoreThreshold: ConfidenceScore = ConfidenceScore(clamping: 0.55),
        knownScoreThreshold: ConfidenceScore = ConfidenceScore(clamping: 0.80),
        minimumOverlap: ConfidenceScore = ConfidenceScore(clamping: 0.10),
        knownOverlapThreshold: ConfidenceScore = ConfidenceScore(clamping: 0.65),
        minimumKnownGeometry: ConfidenceScore = ConfidenceScore(clamping: 0.60),
        weights: PlaceEvidenceWeights = .balanced
    ) throws {
        guard overlappingScoreThreshold < knownScoreThreshold,
            minimumOverlap < knownOverlapThreshold
        else {
            throw PlaceRecognitionError.invalidThresholds
        }
        self.overlappingScoreThreshold = overlappingScoreThreshold
        self.knownScoreThreshold = knownScoreThreshold
        self.minimumOverlap = minimumOverlap
        self.knownOverlapThreshold = knownOverlapThreshold
        self.minimumKnownGeometry = minimumKnownGeometry
        self.weights = weights
    }

    public static let `default` = try! Self()

    private enum CodingKeys: String, CodingKey {
        case overlappingScoreThreshold
        case knownScoreThreshold
        case minimumOverlap
        case knownOverlapThreshold
        case minimumKnownGeometry
        case weights
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                overlappingScoreThreshold: container.decode(
                    ConfidenceScore.self,
                    forKey: .overlappingScoreThreshold
                ),
                knownScoreThreshold: container.decode(
                    ConfidenceScore.self,
                    forKey: .knownScoreThreshold
                ),
                minimumOverlap: container.decode(ConfidenceScore.self, forKey: .minimumOverlap),
                knownOverlapThreshold: container.decode(
                    ConfidenceScore.self,
                    forKey: .knownOverlapThreshold
                ),
                minimumKnownGeometry: container.decode(
                    ConfidenceScore.self,
                    forKey: .minimumKnownGeometry
                ),
                weights: container.decode(PlaceEvidenceWeights.self, forKey: .weights)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .knownScoreThreshold,
                in: container,
                debugDescription: "Place recognition thresholds are not strictly ordered."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(overlappingScoreThreshold, forKey: .overlappingScoreThreshold)
        try container.encode(knownScoreThreshold, forKey: .knownScoreThreshold)
        try container.encode(minimumOverlap, forKey: .minimumOverlap)
        try container.encode(knownOverlapThreshold, forKey: .knownOverlapThreshold)
        try container.encode(minimumKnownGeometry, forKey: .minimumKnownGeometry)
        try container.encode(weights, forKey: .weights)
    }
}

public struct PlaceRecognitionResult: Codable, Hashable, Sendable {
    public let classification: PlaceClassification
    public let mutationPlan: PlaceMutationPlan
    public let aggregateScore: ConfidenceScore
    public let grade: ConfidenceGrade

    public init(
        classification: PlaceClassification,
        mutationPlan: PlaceMutationPlan,
        aggregateScore: ConfidenceScore,
        grade: ConfidenceGrade
    ) {
        self.classification = classification
        self.mutationPlan = mutationPlan
        self.aggregateScore = aggregateScore
        self.grade = grade
    }
}

public struct PlaceRecognizer: Sendable {
    public let policy: PlaceRecognitionPolicy
    public let confidencePolicy: ConfidencePolicy

    public init(
        policy: PlaceRecognitionPolicy = .default,
        confidencePolicy: ConfidencePolicy = .default
    ) {
        self.policy = policy
        self.confidencePolicy = confidencePolicy
    }

    public func classify(_ evidence: PlaceEvidence) -> PlaceRecognitionResult {
        let weights = policy.weights
        let weightedSum =
            evidence.visual.value * weights.visual
            + evidence.geometry.value * weights.geometry
            + evidence.structure.value * weights.structure
            + evidence.poseConsistency.value * weights.poseConsistency
            + evidence.objectLayout.value * weights.objectLayout
        let rawAggregate = weightedSum / weights.total
        let aggregate = ConfidenceScore(
            clamping: thresholdStableValue(rawAggregate)
        )
        let classification: PlaceClassification
        let mutationPlan: PlaceMutationPlan

        if aggregate >= policy.knownScoreThreshold,
            evidence.spatialOverlap >= policy.knownOverlapThreshold,
            evidence.geometry >= policy.minimumKnownGeometry
        {
            classification = .known
            mutationPlan = .updateExisting
        } else if aggregate >= policy.overlappingScoreThreshold,
            evidence.spatialOverlap >= policy.minimumOverlap
        {
            classification = .overlapping
            mutationPlan = .validateMerge
        } else {
            classification = .new
            mutationPlan = .createNewNode
        }

        return PlaceRecognitionResult(
            classification: classification,
            mutationPlan: mutationPlan,
            aggregateScore: aggregate,
            grade: confidencePolicy.grade(for: aggregate)
        )
    }

    /// Decimal policy weights are not exactly representable in binary. Snap
    /// only machine-close values to declared decision boundaries so an exact
    /// mathematical threshold (for example 0.8) remains inclusive.
    private func thresholdStableValue(_ value: Double) -> Double {
        let tolerance = 1e-12
        let boundaries = [
            policy.overlappingScoreThreshold.value,
            policy.knownScoreThreshold.value,
            confidencePolicy.mediumThreshold.value,
            confidencePolicy.highThreshold.value,
        ]
        return boundaries.first(where: { abs(value - $0) <= tolerance }) ?? value
    }
}
