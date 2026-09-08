import Foundation

public enum CoordinateFrameAlignmentSide: String, Codable, Hashable, Sendable {
    case source
    case target
}

public enum CoordinateFrameAlignmentError: Error, Equatable, Sendable {
    case invalidPolicy
    case emptySemanticLabel(objectID: ObjectID)
    case semanticLabelMismatch(sourceObjectID: ObjectID, targetObjectID: ObjectID)
    case sameCoordinateFrame(CoordinateFrameID)
    case tooFewCorrespondences(minimum: Int)
    case tooManyCorrespondences(maximum: Int)
    case duplicateSourceObjectID(ObjectID)
    case duplicateTargetObjectID(ObjectID)
    case inconsistentSourceCoordinateFrame(
        expected: CoordinateFrameID,
        actual: CoordinateFrameID
    )
    case inconsistentTargetCoordinateFrame(
        expected: CoordinateFrameID,
        actual: CoordinateFrameID
    )
    case coordinateOutOfRange(side: CoordinateFrameAlignmentSide, objectID: ObjectID)
    case degenerateHorizontalLayout(side: CoordinateFrameAlignmentSide)
    case nearCollinearHorizontalLayout(side: CoordinateFrameAlignmentSide)
    case unstableRotationEstimate
    case nonFiniteComputation
    case excessiveHorizontalResidual(rootMeanSquare: Double, maximum: Double)
    case excessiveVerticalResidual(rootMeanSquare: Double, maximum: Double)
    case insufficientConfidence(ConfidenceScore)
    case invalidPersistedResult
}

/// A semantic object position expressed in the coordinate frame that is to be
/// transformed. Separate source and target types make the transform direction
/// explicit at the API boundary.
public struct CoordinateFrameAlignmentSourcePoint: Codable, Hashable, Sendable {
    public let objectID: ObjectID
    public let coordinateFrameID: CoordinateFrameID
    public let semanticLabel: String
    public let position: Vec3

    public init(
        objectID: ObjectID,
        coordinateFrameID: CoordinateFrameID,
        semanticLabel: String,
        position: Vec3
    ) throws {
        let normalizedLabel = semanticLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else {
            throw CoordinateFrameAlignmentError.emptySemanticLabel(objectID: objectID)
        }
        self.objectID = objectID
        self.coordinateFrameID = coordinateFrameID
        self.semanticLabel = normalizedLabel
        self.position = position
    }

    private enum CodingKeys: String, CodingKey {
        case objectID
        case coordinateFrameID
        case semanticLabel
        case position
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                objectID: container.decode(ObjectID.self, forKey: .objectID),
                coordinateFrameID: container.decode(
                    CoordinateFrameID.self,
                    forKey: .coordinateFrameID
                ),
                semanticLabel: container.decode(String.self, forKey: .semanticLabel),
                position: container.decode(Vec3.self, forKey: .position)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .semanticLabel,
                in: container,
                debugDescription: "Alignment source point has an invalid semantic label."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(objectID, forKey: .objectID)
        try container.encode(coordinateFrameID, forKey: .coordinateFrameID)
        try container.encode(semanticLabel, forKey: .semanticLabel)
        try container.encode(position, forKey: .position)
    }
}

/// A semantic object position expressed in the destination coordinate frame.
public struct CoordinateFrameAlignmentTargetPoint: Codable, Hashable, Sendable {
    public let objectID: ObjectID
    public let coordinateFrameID: CoordinateFrameID
    public let semanticLabel: String
    public let position: Vec3

    public init(
        objectID: ObjectID,
        coordinateFrameID: CoordinateFrameID,
        semanticLabel: String,
        position: Vec3
    ) throws {
        let normalizedLabel = semanticLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else {
            throw CoordinateFrameAlignmentError.emptySemanticLabel(objectID: objectID)
        }
        self.objectID = objectID
        self.coordinateFrameID = coordinateFrameID
        self.semanticLabel = normalizedLabel
        self.position = position
    }

    private enum CodingKeys: String, CodingKey {
        case objectID
        case coordinateFrameID
        case semanticLabel
        case position
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                objectID: container.decode(ObjectID.self, forKey: .objectID),
                coordinateFrameID: container.decode(
                    CoordinateFrameID.self,
                    forKey: .coordinateFrameID
                ),
                semanticLabel: container.decode(String.self, forKey: .semanticLabel),
                position: container.decode(Vec3.self, forKey: .position)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .semanticLabel,
                in: container,
                debugDescription: "Alignment target point has an invalid semantic label."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(objectID, forKey: .objectID)
        try container.encode(coordinateFrameID, forKey: .coordinateFrameID)
        try container.encode(semanticLabel, forKey: .semanticLabel)
        try container.encode(position, forKey: .position)
    }
}

/// One explicitly established cross-frame object identity. The estimator does
/// not discover correspondences and therefore cannot silently invent them.
public struct CoordinateFrameAlignmentCorrespondence: Codable, Hashable, Sendable {
    public let source: CoordinateFrameAlignmentSourcePoint
    public let target: CoordinateFrameAlignmentTargetPoint
    public let identityConfidence: ConfidenceScore

    public init(
        source: CoordinateFrameAlignmentSourcePoint,
        target: CoordinateFrameAlignmentTargetPoint,
        identityConfidence: ConfidenceScore
    ) throws {
        guard source.coordinateFrameID != target.coordinateFrameID else {
            throw CoordinateFrameAlignmentError.sameCoordinateFrame(source.coordinateFrameID)
        }
        guard Self.semanticKey(source.semanticLabel) == Self.semanticKey(target.semanticLabel) else {
            throw CoordinateFrameAlignmentError.semanticLabelMismatch(
                sourceObjectID: source.objectID,
                targetObjectID: target.objectID
            )
        }
        self.source = source
        self.target = target
        self.identityConfidence = identityConfidence
    }

    private static func semanticKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case target
        case identityConfidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                source: container.decode(
                    CoordinateFrameAlignmentSourcePoint.self,
                    forKey: .source
                ),
                target: container.decode(
                    CoordinateFrameAlignmentTargetPoint.self,
                    forKey: .target
                ),
                identityConfidence: container.decode(
                    ConfidenceScore.self,
                    forKey: .identityConfidence
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .source,
                in: container,
                debugDescription: "Alignment correspondence violates frame or semantic identity rules."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(target, forKey: .target)
        try container.encode(identityConfidence, forKey: .identityConfidence)
    }
}

public struct CoordinateFrameAlignmentPolicy: Codable, Hashable, Sendable {
    public static let maximumAllowedCorrespondenceCount = 64

    public let maximumCorrespondenceCount: Int
    public let maximumCoordinateMagnitude: Double
    public let minimumHorizontalSpread: Double
    public let minimumMinorToMajorEigenvalueRatio: Double
    public let maximumHorizontalRootMeanSquareResidual: Double
    public let maximumHorizontalResidual: Double
    public let maximumVerticalRootMeanSquareResidual: Double
    public let maximumVerticalResidual: Double

    public init(
        maximumCorrespondenceCount: Int = Self.maximumAllowedCorrespondenceCount,
        maximumCoordinateMagnitude: Double = 10_000,
        minimumHorizontalSpread: Double = 0.15,
        minimumMinorToMajorEigenvalueRatio: Double = 0.015,
        maximumHorizontalRootMeanSquareResidual: Double = 0.08,
        maximumHorizontalResidual: Double = 0.15,
        maximumVerticalRootMeanSquareResidual: Double = 0.06,
        maximumVerticalResidual: Double = 0.10
    ) throws {
        let scalarValues = [
            maximumCoordinateMagnitude,
            minimumHorizontalSpread,
            minimumMinorToMajorEigenvalueRatio,
            maximumHorizontalRootMeanSquareResidual,
            maximumHorizontalResidual,
            maximumVerticalRootMeanSquareResidual,
            maximumVerticalResidual,
        ]
        guard maximumCorrespondenceCount >= 3,
            maximumCorrespondenceCount <= Self.maximumAllowedCorrespondenceCount,
            scalarValues.allSatisfy({ $0.isFinite && $0 > 0 }),
            minimumMinorToMajorEigenvalueRatio < 1,
            maximumHorizontalRootMeanSquareResidual <= maximumHorizontalResidual,
            maximumVerticalRootMeanSquareResidual <= maximumVerticalResidual
        else {
            throw CoordinateFrameAlignmentError.invalidPolicy
        }

        self.maximumCorrespondenceCount = maximumCorrespondenceCount
        self.maximumCoordinateMagnitude = maximumCoordinateMagnitude
        self.minimumHorizontalSpread = minimumHorizontalSpread
        self.minimumMinorToMajorEigenvalueRatio = minimumMinorToMajorEigenvalueRatio
        self.maximumHorizontalRootMeanSquareResidual =
            maximumHorizontalRootMeanSquareResidual
        self.maximumHorizontalResidual = maximumHorizontalResidual
        self.maximumVerticalRootMeanSquareResidual = maximumVerticalRootMeanSquareResidual
        self.maximumVerticalResidual = maximumVerticalResidual
    }

    public static let `default` = try! Self()

    private enum CodingKeys: String, CodingKey {
        case maximumCorrespondenceCount
        case maximumCoordinateMagnitude
        case minimumHorizontalSpread
        case minimumMinorToMajorEigenvalueRatio
        case maximumHorizontalRootMeanSquareResidual
        case maximumHorizontalResidual
        case maximumVerticalRootMeanSquareResidual
        case maximumVerticalResidual
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                maximumCorrespondenceCount: container.decode(
                    Int.self,
                    forKey: .maximumCorrespondenceCount
                ),
                maximumCoordinateMagnitude: container.decode(
                    Double.self,
                    forKey: .maximumCoordinateMagnitude
                ),
                minimumHorizontalSpread: container.decode(
                    Double.self,
                    forKey: .minimumHorizontalSpread
                ),
                minimumMinorToMajorEigenvalueRatio: container.decode(
                    Double.self,
                    forKey: .minimumMinorToMajorEigenvalueRatio
                ),
                maximumHorizontalRootMeanSquareResidual: container.decode(
                    Double.self,
                    forKey: .maximumHorizontalRootMeanSquareResidual
                ),
                maximumHorizontalResidual: container.decode(
                    Double.self,
                    forKey: .maximumHorizontalResidual
                ),
                maximumVerticalRootMeanSquareResidual: container.decode(
                    Double.self,
                    forKey: .maximumVerticalRootMeanSquareResidual
                ),
                maximumVerticalResidual: container.decode(
                    Double.self,
                    forKey: .maximumVerticalResidual
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .maximumCorrespondenceCount,
                in: container,
                debugDescription: "Coordinate-frame alignment policy is invalid."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maximumCorrespondenceCount, forKey: .maximumCorrespondenceCount)
        try container.encode(maximumCoordinateMagnitude, forKey: .maximumCoordinateMagnitude)
        try container.encode(minimumHorizontalSpread, forKey: .minimumHorizontalSpread)
        try container.encode(
            minimumMinorToMajorEigenvalueRatio,
            forKey: .minimumMinorToMajorEigenvalueRatio
        )
        try container.encode(
            maximumHorizontalRootMeanSquareResidual,
            forKey: .maximumHorizontalRootMeanSquareResidual
        )
        try container.encode(maximumHorizontalResidual, forKey: .maximumHorizontalResidual)
        try container.encode(
            maximumVerticalRootMeanSquareResidual,
            forKey: .maximumVerticalRootMeanSquareResidual
        )
        try container.encode(maximumVerticalResidual, forKey: .maximumVerticalResidual)
    }
}

public struct CoordinateFrameAlignmentResiduals: Codable, Hashable, Sendable {
    public let rootMeanSquare: Double
    public let maximum: Double
    public let horizontalRootMeanSquare: Double
    public let horizontalMaximum: Double
    public let verticalRootMeanSquare: Double
    public let verticalMaximum: Double

    fileprivate init(
        rootMeanSquare: Double,
        maximum: Double,
        horizontalRootMeanSquare: Double,
        horizontalMaximum: Double,
        verticalRootMeanSquare: Double,
        verticalMaximum: Double
    ) throws {
        let values = [
            rootMeanSquare,
            maximum,
            horizontalRootMeanSquare,
            horizontalMaximum,
            verticalRootMeanSquare,
            verticalMaximum,
        ]
        let tolerance = max(1, values.max() ?? 1) * 1e-9
        let expectedRootMeanSquareSquared =
            horizontalRootMeanSquare * horizontalRootMeanSquare
            + verticalRootMeanSquare * verticalRootMeanSquare
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }),
            maximum + tolerance >= rootMeanSquare,
            horizontalMaximum + tolerance >= horizontalRootMeanSquare,
            verticalMaximum + tolerance >= verticalRootMeanSquare,
            rootMeanSquare + tolerance >= horizontalRootMeanSquare,
            rootMeanSquare + tolerance >= verticalRootMeanSquare,
            maximum + tolerance >= horizontalMaximum,
            maximum + tolerance >= verticalMaximum,
            maximum <= hypot(horizontalMaximum, verticalMaximum) + tolerance,
            abs(rootMeanSquare * rootMeanSquare - expectedRootMeanSquareSquared)
                <= tolerance
        else {
            throw CoordinateFrameAlignmentError.invalidPersistedResult
        }
        self.rootMeanSquare = rootMeanSquare
        self.maximum = maximum
        self.horizontalRootMeanSquare = horizontalRootMeanSquare
        self.horizontalMaximum = horizontalMaximum
        self.verticalRootMeanSquare = verticalRootMeanSquare
        self.verticalMaximum = verticalMaximum
    }

    private enum CodingKeys: String, CodingKey {
        case rootMeanSquare
        case maximum
        case horizontalRootMeanSquare
        case horizontalMaximum
        case verticalRootMeanSquare
        case verticalMaximum
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                rootMeanSquare: container.decode(Double.self, forKey: .rootMeanSquare),
                maximum: container.decode(Double.self, forKey: .maximum),
                horizontalRootMeanSquare: container.decode(
                    Double.self,
                    forKey: .horizontalRootMeanSquare
                ),
                horizontalMaximum: container.decode(Double.self, forKey: .horizontalMaximum),
                verticalRootMeanSquare: container.decode(
                    Double.self,
                    forKey: .verticalRootMeanSquare
                ),
                verticalMaximum: container.decode(Double.self, forKey: .verticalMaximum)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .rootMeanSquare,
                in: container,
                debugDescription: "Coordinate-frame alignment residuals are invalid."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rootMeanSquare, forKey: .rootMeanSquare)
        try container.encode(maximum, forKey: .maximum)
        try container.encode(horizontalRootMeanSquare, forKey: .horizontalRootMeanSquare)
        try container.encode(horizontalMaximum, forKey: .horizontalMaximum)
        try container.encode(verticalRootMeanSquare, forKey: .verticalRootMeanSquare)
        try container.encode(verticalMaximum, forKey: .verticalMaximum)
    }
}

/// A high-confidence, gravity-preserving transform from `sourceCoordinateFrameID`
/// into `targetCoordinateFrameID`. Its initializer is intentionally not public;
/// callers can obtain a success value only through the validating estimator or
/// by decoding a previously validated value.
public struct CoordinateFrameAlignmentResult: Codable, Hashable, Sendable {
    public let sourceCoordinateFrameID: CoordinateFrameID
    public let targetCoordinateFrameID: CoordinateFrameID
    public let sourceToTarget: Transform3D
    public let confidence: ConfidenceScore
    public let residuals: CoordinateFrameAlignmentResiduals
    public let evidenceCount: Int
    public let policy: CoordinateFrameAlignmentPolicy

    fileprivate init(
        sourceCoordinateFrameID: CoordinateFrameID,
        targetCoordinateFrameID: CoordinateFrameID,
        sourceToTarget: Transform3D,
        confidence: ConfidenceScore,
        residuals: CoordinateFrameAlignmentResiduals,
        evidenceCount: Int,
        policy: CoordinateFrameAlignmentPolicy
    ) throws {
        let worstNormalizedResidual = max(
            residuals.horizontalRootMeanSquare
                / policy.maximumHorizontalRootMeanSquareResidual,
            residuals.horizontalMaximum / policy.maximumHorizontalResidual,
            residuals.verticalRootMeanSquare
                / policy.maximumVerticalRootMeanSquareResidual,
            residuals.verticalMaximum / policy.maximumVerticalResidual
        )
        let residualConfidence = ConfidenceScore(clamping: 1 - worstNormalizedResidual)
        guard sourceCoordinateFrameID != targetCoordinateFrameID,
            (3...policy.maximumCorrespondenceCount)
                .contains(evidenceCount),
            ConfidencePolicy.default.grade(for: confidence) == .high,
            residuals.horizontalRootMeanSquare
                <= policy.maximumHorizontalRootMeanSquareResidual,
            residuals.horizontalMaximum <= policy.maximumHorizontalResidual,
            residuals.verticalRootMeanSquare <= policy.maximumVerticalRootMeanSquareResidual,
            residuals.verticalMaximum <= policy.maximumVerticalResidual,
            confidence.value <= residualConfidence.value + 1e-12,
            Self.isGravityPreservingRigidTransform(sourceToTarget)
        else {
            throw CoordinateFrameAlignmentError.invalidPersistedResult
        }
        self.sourceCoordinateFrameID = sourceCoordinateFrameID
        self.targetCoordinateFrameID = targetCoordinateFrameID
        self.sourceToTarget = sourceToTarget
        self.confidence = confidence
        self.residuals = residuals
        self.evidenceCount = evidenceCount
        self.policy = policy
    }

    /// Returns the same validated alignment expressed in the opposite
    /// direction. For a rigid transform `[R t; 0 1]`, the inverse is
    /// `[Rᵀ -Rᵀt; 0 1]`; simply negating `t` would be incorrect whenever
    /// the alignment also contains yaw.
    public func inverted() throws -> Self {
        let transform = sourceToTarget
        let translation = transform.translation
        let inverse = try Transform3D(rowMajorElements: [
            transform[0, 0], transform[1, 0], transform[2, 0],
            -(transform[0, 0] * translation.x
                + transform[1, 0] * translation.y
                + transform[2, 0] * translation.z),
            transform[0, 1], transform[1, 1], transform[2, 1],
            -(transform[0, 1] * translation.x
                + transform[1, 1] * translation.y
                + transform[2, 1] * translation.z),
            transform[0, 2], transform[1, 2], transform[2, 2],
            -(transform[0, 2] * translation.x
                + transform[1, 2] * translation.y
                + transform[2, 2] * translation.z),
            0, 0, 0, 1,
        ])
        return try Self(
            sourceCoordinateFrameID: targetCoordinateFrameID,
            targetCoordinateFrameID: sourceCoordinateFrameID,
            sourceToTarget: inverse,
            confidence: confidence,
            residuals: residuals,
            evidenceCount: evidenceCount,
            policy: policy
        )
    }

    private static func isGravityPreservingRigidTransform(_ transform: Transform3D) -> Bool {
        let tolerance = 1e-9
        let c = transform[0, 0]
        let s = transform[0, 2]
        let expectedZeroes = [
            transform[0, 1], transform[1, 0], transform[1, 2], transform[2, 1],
            transform[3, 0], transform[3, 1], transform[3, 2],
        ]
        guard expectedZeroes.allSatisfy({ abs($0) <= tolerance }),
            abs(transform[1, 1] - 1) <= tolerance,
            abs(transform[2, 0] + s) <= tolerance,
            abs(transform[2, 2] - c) <= tolerance,
            abs(transform[3, 3] - 1) <= tolerance,
            abs((c * c + s * s) - 1) <= tolerance
        else {
            return false
        }
        return true
    }

    private static let schemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sourceCoordinateFrameID
        case targetCoordinateFrameID
        case sourceToTarget
        case confidence
        case residuals
        case evidenceCount
        case policy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported coordinate-frame alignment result schema."
            )
        }
        do {
            try self.init(
                sourceCoordinateFrameID: container.decode(
                    CoordinateFrameID.self,
                    forKey: .sourceCoordinateFrameID
                ),
                targetCoordinateFrameID: container.decode(
                    CoordinateFrameID.self,
                    forKey: .targetCoordinateFrameID
                ),
                sourceToTarget: container.decode(Transform3D.self, forKey: .sourceToTarget),
                confidence: container.decode(ConfidenceScore.self, forKey: .confidence),
                residuals: container.decode(
                    CoordinateFrameAlignmentResiduals.self,
                    forKey: .residuals
                ),
                evidenceCount: container.decode(Int.self, forKey: .evidenceCount),
                policy: container.decode(
                    CoordinateFrameAlignmentPolicy.self,
                    forKey: .policy
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceToTarget,
                in: container,
                debugDescription:
                    "Persisted coordinate-frame alignment is not a validated high-confidence yaw transform."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(sourceCoordinateFrameID, forKey: .sourceCoordinateFrameID)
        try container.encode(targetCoordinateFrameID, forKey: .targetCoordinateFrameID)
        try container.encode(sourceToTarget, forKey: .sourceToTarget)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(residuals, forKey: .residuals)
        try container.encode(evidenceCount, forKey: .evidenceCount)
        try container.encode(policy, forKey: .policy)
    }
}

public struct CoordinateFrameAlignmentEstimator: Sendable {
    public let policy: CoordinateFrameAlignmentPolicy

    public init(policy: CoordinateFrameAlignmentPolicy = .default) {
        self.policy = policy
    }

    /// Estimates a rigid source-to-target transform restricted to yaw and
    /// translation. Scale, reflection, roll, and pitch are never estimated.
    public func estimate(
        correspondences: [CoordinateFrameAlignmentCorrespondence]
    ) throws -> CoordinateFrameAlignmentResult {
        guard correspondences.count >= 3 else {
            throw CoordinateFrameAlignmentError.tooFewCorrespondences(minimum: 3)
        }
        guard correspondences.count <= policy.maximumCorrespondenceCount else {
            throw CoordinateFrameAlignmentError.tooManyCorrespondences(
                maximum: policy.maximumCorrespondenceCount
            )
        }

        let ordered = correspondences.sorted(by: Self.correspondenceOrder)
        let sourceFrameID = ordered[0].source.coordinateFrameID
        let targetFrameID = ordered[0].target.coordinateFrameID

        var sourceIDs = Set<ObjectID>()
        var targetIDs = Set<ObjectID>()
        for correspondence in ordered {
            guard correspondence.source.coordinateFrameID == sourceFrameID else {
                throw CoordinateFrameAlignmentError.inconsistentSourceCoordinateFrame(
                    expected: sourceFrameID,
                    actual: correspondence.source.coordinateFrameID
                )
            }
            guard correspondence.target.coordinateFrameID == targetFrameID else {
                throw CoordinateFrameAlignmentError.inconsistentTargetCoordinateFrame(
                    expected: targetFrameID,
                    actual: correspondence.target.coordinateFrameID
                )
            }
            guard sourceIDs.insert(correspondence.source.objectID).inserted else {
                throw CoordinateFrameAlignmentError.duplicateSourceObjectID(
                    correspondence.source.objectID
                )
            }
            guard targetIDs.insert(correspondence.target.objectID).inserted else {
                throw CoordinateFrameAlignmentError.duplicateTargetObjectID(
                    correspondence.target.objectID
                )
            }
            try validateCoordinate(
                correspondence.source.position,
                side: .source,
                objectID: correspondence.source.objectID
            )
            try validateCoordinate(
                correspondence.target.position,
                side: .target,
                objectID: correspondence.target.objectID
            )
        }

        let sourceCentroid = try centroid(of: ordered.map(\.source.position))
        let targetCentroid = try centroid(of: ordered.map(\.target.position))
        let sourceCentered = ordered.map { horizontalOffset($0.source.position, sourceCentroid) }
        let targetCentered = ordered.map { horizontalOffset($0.target.position, targetCentroid) }

        try validateHorizontalLayout(sourceCentered, side: .source)
        try validateHorizontalLayout(targetCentered, side: .target)

        var cosineAccumulator = StableDoubleSum()
        var sineAccumulator = StableDoubleSum()
        for index in ordered.indices {
            let source = sourceCentered[index]
            let target = targetCentered[index]
            cosineAccumulator.add(source.x * target.x + source.z * target.z)
            sineAccumulator.add(source.z * target.x - source.x * target.z)
        }
        let cosineTerm = cosineAccumulator.value
        let sineTerm = sineAccumulator.value
        let rotationStrength = hypot(cosineTerm, sineTerm)
        guard rotationStrength.isFinite else {
            throw CoordinateFrameAlignmentError.nonFiniteComputation
        }
        guard rotationStrength > 1e-12 else {
            throw CoordinateFrameAlignmentError.unstableRotationEstimate
        }

        let yaw = atan2(sineTerm, cosineTerm)
        let cosine = cos(yaw)
        let sine = sin(yaw)
        let rotatedSourceCentroidX = cosine * sourceCentroid.x + sine * sourceCentroid.z
        let rotatedSourceCentroidZ = -sine * sourceCentroid.x + cosine * sourceCentroid.z
        let translation = try Vec3(
            x: targetCentroid.x - rotatedSourceCentroidX,
            y: targetCentroid.y - sourceCentroid.y,
            z: targetCentroid.z - rotatedSourceCentroidZ
        )
        let transform = try Transform3D(rowMajorElements: [
            cosine, 0, sine, translation.x,
            0, 1, 0, translation.y,
            -sine, 0, cosine, translation.z,
            0, 0, 0, 1,
        ])

        let residuals = try calculateResiduals(ordered, transform: transform)
        guard
            residuals.horizontalRootMeanSquare
                <= policy.maximumHorizontalRootMeanSquareResidual,
            residuals.horizontalMaximum <= policy.maximumHorizontalResidual
        else {
            throw CoordinateFrameAlignmentError.excessiveHorizontalResidual(
                rootMeanSquare: residuals.horizontalRootMeanSquare,
                maximum: residuals.horizontalMaximum
            )
        }
        guard
            residuals.verticalRootMeanSquare
                <= policy.maximumVerticalRootMeanSquareResidual,
            residuals.verticalMaximum <= policy.maximumVerticalResidual
        else {
            throw CoordinateFrameAlignmentError.excessiveVerticalResidual(
                rootMeanSquare: residuals.verticalRootMeanSquare,
                maximum: residuals.verticalMaximum
            )
        }

        let worstNormalizedResidual = max(
            residuals.horizontalRootMeanSquare
                / policy.maximumHorizontalRootMeanSquareResidual,
            residuals.horizontalMaximum / policy.maximumHorizontalResidual,
            residuals.verticalRootMeanSquare
                / policy.maximumVerticalRootMeanSquareResidual,
            residuals.verticalMaximum / policy.maximumVerticalResidual
        )
        let residualConfidence = ConfidenceScore(clamping: 1 - worstNormalizedResidual)
        let identityConfidence = ordered.map(\.identityConfidence).min() ?? .zero
        let confidence = min(residualConfidence, identityConfidence)
        guard ConfidencePolicy.default.grade(for: confidence) == .high else {
            throw CoordinateFrameAlignmentError.insufficientConfidence(confidence)
        }

        return try CoordinateFrameAlignmentResult(
            sourceCoordinateFrameID: sourceFrameID,
            targetCoordinateFrameID: targetFrameID,
            sourceToTarget: transform,
            confidence: confidence,
            residuals: residuals,
            evidenceCount: ordered.count,
            policy: policy
        )
    }

    private func validateCoordinate(
        _ point: Vec3,
        side: CoordinateFrameAlignmentSide,
        objectID: ObjectID
    ) throws {
        let values = [point.x, point.y, point.z]
        guard values.allSatisfy({ $0.isFinite && abs($0) <= policy.maximumCoordinateMagnitude })
        else {
            throw CoordinateFrameAlignmentError.coordinateOutOfRange(
                side: side,
                objectID: objectID
            )
        }
    }

    private func centroid(of points: [Vec3]) throws -> Vec3 {
        var x = StableDoubleSum()
        var y = StableDoubleSum()
        var z = StableDoubleSum()
        for point in points {
            x.add(point.x)
            y.add(point.y)
            z.add(point.z)
        }
        let count = Double(points.count)
        guard x.value.isFinite, y.value.isFinite, z.value.isFinite else {
            throw CoordinateFrameAlignmentError.nonFiniteComputation
        }
        return try Vec3(x: x.value / count, y: y.value / count, z: z.value / count)
    }

    private func horizontalOffset(_ point: Vec3, _ centroid: Vec3) -> HorizontalPoint {
        HorizontalPoint(x: point.x - centroid.x, z: point.z - centroid.z)
    }

    private func validateHorizontalLayout(
        _ points: [HorizontalPoint],
        side: CoordinateFrameAlignmentSide
    ) throws {
        var xx = StableDoubleSum()
        var xz = StableDoubleSum()
        var zz = StableDoubleSum()
        for point in points {
            xx.add(point.x * point.x)
            xz.add(point.x * point.z)
            zz.add(point.z * point.z)
        }
        let divisor = Double(points.count)
        let covarianceXX = xx.value / divisor
        let covarianceXZ = xz.value / divisor
        let covarianceZZ = zz.value / divisor
        let trace = covarianceXX + covarianceZZ
        let discriminant = hypot(covarianceXX - covarianceZZ, 2 * covarianceXZ)
        let majorEigenvalue = max(0, (trace + discriminant) * 0.5)
        let minorEigenvalue = max(0, (trace - discriminant) * 0.5)
        guard majorEigenvalue.isFinite, minorEigenvalue.isFinite else {
            throw CoordinateFrameAlignmentError.nonFiniteComputation
        }
        guard majorEigenvalue.squareRoot() >= policy.minimumHorizontalSpread else {
            throw CoordinateFrameAlignmentError.degenerateHorizontalLayout(side: side)
        }
        guard
            minorEigenvalue / majorEigenvalue
                >= policy.minimumMinorToMajorEigenvalueRatio
        else {
            throw CoordinateFrameAlignmentError.nearCollinearHorizontalLayout(side: side)
        }
    }

    private func calculateResiduals(
        _ correspondences: [CoordinateFrameAlignmentCorrespondence],
        transform: Transform3D
    ) throws -> CoordinateFrameAlignmentResiduals {
        var totalSquared = StableDoubleSum()
        var horizontalSquared = StableDoubleSum()
        var verticalSquared = StableDoubleSum()
        var maximum = 0.0
        var horizontalMaximum = 0.0
        var verticalMaximum = 0.0

        for correspondence in correspondences {
            let transformed = try transform.transformed(correspondence.source.position)
            let dx = transformed.x - correspondence.target.position.x
            let dy = transformed.y - correspondence.target.position.y
            let dz = transformed.z - correspondence.target.position.z
            let horizontal = hypot(dx, dz)
            let vertical = abs(dy)
            let total = hypot(horizontal, vertical)
            guard horizontal.isFinite, vertical.isFinite, total.isFinite else {
                throw CoordinateFrameAlignmentError.nonFiniteComputation
            }
            horizontalSquared.add(horizontal * horizontal)
            verticalSquared.add(vertical * vertical)
            totalSquared.add(total * total)
            horizontalMaximum = max(horizontalMaximum, horizontal)
            verticalMaximum = max(verticalMaximum, vertical)
            maximum = max(maximum, total)
        }

        let divisor = Double(correspondences.count)
        return try CoordinateFrameAlignmentResiduals(
            rootMeanSquare: (totalSquared.value / divisor).squareRoot(),
            maximum: maximum,
            horizontalRootMeanSquare: (horizontalSquared.value / divisor).squareRoot(),
            horizontalMaximum: horizontalMaximum,
            verticalRootMeanSquare: (verticalSquared.value / divisor).squareRoot(),
            verticalMaximum: verticalMaximum
        )
    }

    private static func correspondenceOrder(
        _ lhs: CoordinateFrameAlignmentCorrespondence,
        _ rhs: CoordinateFrameAlignmentCorrespondence
    ) -> Bool {
        if lhs.source.objectID != rhs.source.objectID {
            return lhs.source.objectID < rhs.source.objectID
        }
        return lhs.target.objectID < rhs.target.objectID
    }
}

private struct HorizontalPoint {
    let x: Double
    let z: Double
}

/// Kahan-style compensated summation keeps centroid and covariance calculations
/// stable while the canonical correspondence ordering makes them deterministic.
private struct StableDoubleSum {
    private var sum = 0.0
    private var compensation = 0.0

    mutating func add(_ value: Double) {
        let adjusted = value - compensation
        let next = sum + adjusted
        compensation = (next - sum) - adjusted
        sum = next
    }

    var value: Double {
        sum
    }
}
