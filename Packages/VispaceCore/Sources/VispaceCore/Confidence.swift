import Foundation

public enum ConfidenceError: Error, Equatable, Sendable {
    case nonFiniteValue
    case valueOutOfRange
    case invalidThresholdOrder
}

public struct ConfidenceScore: Codable, Hashable, Comparable, Sendable {
    public let value: Double

    public init(validating value: Double) throws {
        guard value.isFinite else {
            throw ConfidenceError.nonFiniteValue
        }
        guard (0...1).contains(value) else {
            throw ConfidenceError.valueOutOfRange
        }
        self.value = value
    }

    public init(clamping value: Double) {
        let finiteValue = value.isFinite ? value : 0
        self.value = Swift.min(1, Swift.max(0, finiteValue))
    }

    public static let zero = ConfidenceScore(clamping: 0)
    public static let one = ConfidenceScore(clamping: 1)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }

    private enum CodingKeys: String, CodingKey {
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedValue = try container.decode(Double.self, forKey: .value)
        do {
            try self.init(validating: decodedValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "Confidence must be finite and between zero and one."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }
}

public enum ConfidenceGrade: Int, Codable, Comparable, Sendable {
    case low
    case medium
    case high

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ConfidencePolicy: Codable, Hashable, Sendable {
    public let mediumThreshold: ConfidenceScore
    public let highThreshold: ConfidenceScore

    public init(
        mediumThreshold: ConfidenceScore = ConfidenceScore(clamping: 0.50),
        highThreshold: ConfidenceScore = ConfidenceScore(clamping: 0.80)
    ) throws {
        guard mediumThreshold < highThreshold else {
            throw ConfidenceError.invalidThresholdOrder
        }
        self.mediumThreshold = mediumThreshold
        self.highThreshold = highThreshold
    }

    public static let `default` = try! ConfidencePolicy()

    public func grade(for score: ConfidenceScore) -> ConfidenceGrade {
        if score >= highThreshold {
            return .high
        }
        if score >= mediumThreshold {
            return .medium
        }
        return .low
    }

    private enum CodingKeys: String, CodingKey {
        case mediumThreshold
        case highThreshold
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                mediumThreshold: container.decode(
                    ConfidenceScore.self,
                    forKey: .mediumThreshold
                ),
                highThreshold: container.decode(ConfidenceScore.self, forKey: .highThreshold)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .mediumThreshold,
                in: container,
                debugDescription: "Medium confidence threshold must be below high threshold."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mediumThreshold, forKey: .mediumThreshold)
        try container.encode(highThreshold, forKey: .highThreshold)
    }
}

/// Confidence dimensions stay separate so strength in one subsystem cannot
/// silently promote an unrelated spatial fact.
public struct ConfidenceVector: Codable, Hashable, Sendable {
    public var semantic: ConfidenceScore
    public var geometry: ConfidenceScore
    public var tracking: ConfidenceScore
    public var place: ConfidenceScore
    public var identity: ConfidenceScore
    public var objectState: ConfidenceScore
    public var relation: ConfidenceScore

    public init(
        semantic: ConfidenceScore = .zero,
        geometry: ConfidenceScore = .zero,
        tracking: ConfidenceScore = .zero,
        place: ConfidenceScore = .zero,
        identity: ConfidenceScore = .zero,
        objectState: ConfidenceScore = .zero,
        relation: ConfidenceScore = .zero
    ) {
        self.semantic = semantic
        self.geometry = geometry
        self.tracking = tracking
        self.place = place
        self.identity = identity
        self.objectState = objectState
        self.relation = relation
    }
}
