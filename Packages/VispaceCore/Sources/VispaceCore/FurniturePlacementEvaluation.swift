import Foundation

/// Errors are reported while constructing placement inputs. The evaluator only
/// accepts finite, physically meaningful candidates; it never repairs or
/// invents coordinates on behalf of a caller.
public enum FurniturePlacementInputError: Error, Equatable, Sendable {
    case nonFiniteValue
    case nonPositiveDimension
    case emptyEvidenceIdentifier
    case degenerateWall
    case invalidRatio
    case passageWidthExceedsRegion
}

public enum FurnitureKind: String, Codable, CaseIterable, Hashable, Sendable {
    case sofa
    case bed
    case desk
}

/// Axis-aligned dimensions in the furniture's local coordinate system.
/// `width` is local X, `depth` is local Z, and `height` extends upward from the
/// candidate's Y coordinate.
public struct FurnitureDimensions: Codable, Hashable, Sendable {
    public let kind: FurnitureKind
    public let width: Double
    public let depth: Double
    public let height: Double

    public init(kind: FurnitureKind, width: Double, depth: Double, height: Double) throws {
        guard width.isFinite, depth.isFinite, height.isFinite else {
            throw FurniturePlacementInputError.nonFiniteValue
        }
        guard width > 0, depth > 0, height > 0 else {
            throw FurniturePlacementInputError.nonPositiveDimension
        }
        self.kind = kind
        self.width = width
        self.depth = depth
        self.height = height
    }
}

/// A caller-provided, already selected placement pose. This type deliberately
/// has no proposal/generation API: the engine can only evaluate this pose.
public struct FurniturePlacementCandidate: Codable, Hashable, Sendable {
    public let position: Vec3
    public let yawRadians: Double
    public let furniture: FurnitureDimensions

    public init(position: Vec3, yawRadians: Double, furniture: FurnitureDimensions) throws {
        guard yawRadians.isFinite else {
            throw FurniturePlacementInputError.nonFiniteValue
        }
        self.position = position
        self.yawRadians = Self.normalizedAngle(yawRadians)
        self.furniture = furniture
    }

    private static func normalizedAngle(_ value: Double) -> Double {
        atan2(sin(value), cos(value))
    }
}

/// A verified horizontal rectangle in world coordinates. Its center's Y value
/// is metadata only; floor elevation is carried separately by floor evidence.
public struct PlacementHorizontalRegion: Codable, Hashable, Sendable {
    public let center: Vec3
    public let width: Double
    public let depth: Double
    public let yawRadians: Double

    public init(center: Vec3, width: Double, depth: Double, yawRadians: Double = 0) throws {
        guard width.isFinite, depth.isFinite, yawRadians.isFinite else {
            throw FurniturePlacementInputError.nonFiniteValue
        }
        guard width > 0, depth > 0 else {
            throw FurniturePlacementInputError.nonPositiveDimension
        }
        self.center = center
        self.width = width
        self.depth = depth
        self.yawRadians = atan2(sin(yawRadians), cos(yawRadians))
    }
}

public struct PlacementFloorEvidence: Codable, Hashable, Sendable {
    public let identifier: String
    public let region: PlacementHorizontalRegion
    public let elevation: Double
    public let confidence: ConfidenceScore

    public init(
        identifier: String,
        region: PlacementHorizontalRegion,
        elevation: Double,
        confidence: ConfidenceScore
    ) throws {
        let identifier = try validatedEvidenceIdentifier(identifier)
        guard elevation.isFinite else {
            throw FurniturePlacementInputError.nonFiniteValue
        }
        self.identifier = identifier
        self.region = region
        self.elevation = elevation
        self.confidence = confidence
    }
}

/// A region whose geometry and free-space state were actually observed. A
/// placement may be feasible only when its required footprint is covered by one
/// such region; absence of evidence is never treated as free space.
public struct PlacementObservationEvidence: Codable, Hashable, Sendable {
    public let identifier: String
    public let region: PlacementHorizontalRegion
    public let confidence: ConfidenceScore

    public init(
        identifier: String,
        region: PlacementHorizontalRegion,
        confidence: ConfidenceScore
    ) throws {
        self.identifier = try validatedEvidenceIdentifier(identifier)
        self.region = region
        self.confidence = confidence
    }
}

public struct PlacementWallEvidence: Codable, Hashable, Sendable {
    public let identifier: String
    public let start: Vec3
    public let end: Vec3
    public let confidence: ConfidenceScore

    public init(
        identifier: String,
        start: Vec3,
        end: Vec3,
        confidence: ConfidenceScore
    ) throws {
        self.identifier = try validatedEvidenceIdentifier(identifier)
        guard hypot(end.x - start.x, end.z - start.z) > .ulpOfOne else {
            throw FurniturePlacementInputError.degenerateWall
        }
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// The whole region is reserved for the doorway and its approach/swing space.
public struct PlacementDoorwayEvidence: Codable, Hashable, Sendable {
    public let identifier: String
    public let keepClearRegion: PlacementHorizontalRegion
    public let confidence: ConfidenceScore

    public init(
        identifier: String,
        keepClearRegion: PlacementHorizontalRegion,
        confidence: ConfidenceScore
    ) throws {
        self.identifier = try validatedEvidenceIdentifier(identifier)
        self.keepClearRegion = keepClearRegion
        self.confidence = confidence
    }
}

public struct PlacementObstacleEvidence: Codable, Hashable, Sendable {
    public let objectID: ObjectID
    public let bounds: AABB
    public let confidence: ConfidenceScore

    public init(objectID: ObjectID, bounds: AABB, confidence: ConfidenceScore) throws {
        let size = bounds.size
        guard size.x > 0, size.y > 0, size.z > 0 else {
            throw FurniturePlacementInputError.nonPositiveDimension
        }
        self.objectID = objectID
        self.bounds = bounds
        self.confidence = confidence
    }
}

public enum PlacementPassageTravelAxis: String, Codable, Hashable, Sendable {
    case alongWidth
    case alongDepth
}

/// A known navigable corridor. When a candidate overlaps it, the evaluator
/// projects both the candidate and known obstacles onto its cross-axis and
/// verifies that at least one contiguous lane remains wide enough.
public struct PlacementPassageEvidence: Codable, Hashable, Sendable {
    public let identifier: String
    public let region: PlacementHorizontalRegion
    public let travelAxis: PlacementPassageTravelAxis
    public let requiredClearWidth: Double
    public let confidence: ConfidenceScore

    public init(
        identifier: String,
        region: PlacementHorizontalRegion,
        travelAxis: PlacementPassageTravelAxis,
        requiredClearWidth: Double,
        confidence: ConfidenceScore
    ) throws {
        let identifier = try validatedEvidenceIdentifier(identifier)
        guard requiredClearWidth.isFinite else {
            throw FurniturePlacementInputError.nonFiniteValue
        }
        guard requiredClearWidth > 0 else {
            throw FurniturePlacementInputError.nonPositiveDimension
        }
        let availableWidth = travelAxis == .alongWidth ? region.depth : region.width
        guard requiredClearWidth <= availableWidth else {
            throw FurniturePlacementInputError.passageWidthExceedsRegion
        }
        self.identifier = identifier
        self.region = region
        self.travelAxis = travelAxis
        self.requiredClearWidth = requiredClearWidth
        self.confidence = confidence
    }
}

/// Completeness is explicit because an empty array can mean either "none
/// exist" or "not mapped". Only the former is safe evidence for feasibility.
public struct PlacementEvidenceCompleteness: Codable, Hashable, Sendable {
    public let wallsMapped: Bool
    public let doorwaysMapped: Bool
    public let obstaclesMapped: Bool
    public let passagesMapped: Bool

    public init(
        wallsMapped: Bool,
        doorwaysMapped: Bool,
        obstaclesMapped: Bool,
        passagesMapped: Bool
    ) {
        self.wallsMapped = wallsMapped
        self.doorwaysMapped = doorwaysMapped
        self.obstaclesMapped = obstaclesMapped
        self.passagesMapped = passagesMapped
    }

    public static let complete = PlacementEvidenceCompleteness(
        wallsMapped: true,
        doorwaysMapped: true,
        obstaclesMapped: true,
        passagesMapped: true
    )

    public static let unavailable = PlacementEvidenceCompleteness(
        wallsMapped: false,
        doorwaysMapped: false,
        obstaclesMapped: false,
        passagesMapped: false
    )
}

public struct FurniturePlacementEvidence: Codable, Sendable {
    public let floors: [PlacementFloorEvidence]
    public let observations: [PlacementObservationEvidence]
    public let walls: [PlacementWallEvidence]
    public let doorways: [PlacementDoorwayEvidence]
    public let obstacles: [PlacementObstacleEvidence]
    public let passages: [PlacementPassageEvidence]
    public let completeness: PlacementEvidenceCompleteness

    public init(
        floors: [PlacementFloorEvidence],
        observations: [PlacementObservationEvidence],
        walls: [PlacementWallEvidence] = [],
        doorways: [PlacementDoorwayEvidence] = [],
        obstacles: [PlacementObstacleEvidence] = [],
        passages: [PlacementPassageEvidence] = [],
        completeness: PlacementEvidenceCompleteness = .unavailable
    ) {
        self.floors = floors
        self.observations = observations
        self.walls = walls
        self.doorways = doorways
        self.obstacles = obstacles
        self.passages = passages
        self.completeness = completeness
    }
}

public struct FurniturePlacementPolicy: Codable, Hashable, Sendable {
    public let minimumFloorSupportRatio: Double
    public let minimumObservationCoverageRatio: Double
    public let requiredObservationMargin: Double
    public let floorElevationTolerance: Double
    public let minimumWallClearance: Double
    public let minimumObjectClearance: Double
    public let minimumEvidenceConfidence: ConfidenceScore
    public let confidencePolicy: ConfidencePolicy

    public init(
        minimumFloorSupportRatio: Double = 0.98,
        minimumObservationCoverageRatio: Double = 0.95,
        requiredObservationMargin: Double = 0.10,
        floorElevationTolerance: Double = 0.05,
        minimumWallClearance: Double = 0.05,
        minimumObjectClearance: Double = 0.02,
        minimumEvidenceConfidence: ConfidenceScore = ConfidenceScore(clamping: 0.50),
        confidencePolicy: ConfidencePolicy = .default
    ) throws {
        let ratios = [minimumFloorSupportRatio, minimumObservationCoverageRatio]
        let distances = [
            requiredObservationMargin,
            floorElevationTolerance,
            minimumWallClearance,
            minimumObjectClearance,
        ]
        guard ratios.allSatisfy(\.isFinite), distances.allSatisfy(\.isFinite) else {
            throw FurniturePlacementInputError.nonFiniteValue
        }
        guard ratios.allSatisfy({ (0...1).contains($0) }) else {
            throw FurniturePlacementInputError.invalidRatio
        }
        guard distances.allSatisfy({ $0 >= 0 }) else {
            throw FurniturePlacementInputError.nonPositiveDimension
        }
        self.minimumFloorSupportRatio = minimumFloorSupportRatio
        self.minimumObservationCoverageRatio = minimumObservationCoverageRatio
        self.requiredObservationMargin = requiredObservationMargin
        self.floorElevationTolerance = floorElevationTolerance
        self.minimumWallClearance = minimumWallClearance
        self.minimumObjectClearance = minimumObjectClearance
        self.minimumEvidenceConfidence = minimumEvidenceConfidence
        self.confidencePolicy = confidencePolicy
    }

    public static let `default` = try! FurniturePlacementPolicy()
}

public enum FurniturePlacementDisposition: String, Codable, Hashable, Sendable {
    case feasible
    case rejected
    case insufficientEvidence
}

public enum FurniturePlacementReasonCode: String, Codable, CaseIterable, Hashable, Sendable {
    case placementFeasible = "placement_feasible"
    case floorEvidenceMissing = "floor_evidence_missing"
    case floorSupportInsufficient = "floor_support_insufficient"
    case floorConfidenceTooLow = "floor_confidence_too_low"
    case observationEvidenceMissing = "observation_evidence_missing"
    case observationCoverageInsufficient = "observation_coverage_insufficient"
    case observationConfidenceTooLow = "observation_confidence_too_low"
    case wallEvidenceIncomplete = "wall_evidence_incomplete"
    case doorwayEvidenceIncomplete = "doorway_evidence_incomplete"
    case obstacleEvidenceIncomplete = "obstacle_evidence_incomplete"
    case passageEvidenceIncomplete = "passage_evidence_incomplete"
    case collidesWithExistingObject = "collides_with_existing_object"
    case objectClearanceTooSmall = "object_clearance_too_small"
    case possibleObjectConflict = "possible_object_conflict"
    case wallClearanceTooSmall = "wall_clearance_too_small"
    case possibleWallConflict = "possible_wall_conflict"
    case blocksDoorway = "blocks_doorway"
    case possibleDoorwayConflict = "possible_doorway_conflict"
    case passageWidthTooNarrow = "passage_width_too_narrow"
    case possiblePassageConflict = "possible_passage_conflict"

    public var message: String {
        switch self {
        case .placementFeasible:
            return "The candidate satisfies all verified placement constraints."
        case .floorEvidenceMissing:
            return "No floor evidence covers the candidate."
        case .floorSupportInsufficient:
            return "The verified floor does not support enough of the furniture footprint."
        case .floorConfidenceTooLow:
            return "Floor evidence is too uncertain for a placement decision."
        case .observationEvidenceMissing:
            return "The candidate area has not been observed."
        case .observationCoverageInsufficient:
            return "Too little of the candidate area and safety margin has been observed."
        case .observationConfidenceTooLow:
            return "Observed free-space evidence is too uncertain."
        case .wallEvidenceIncomplete:
            return "Wall mapping is incomplete near the candidate."
        case .doorwayEvidenceIncomplete:
            return "Doorway mapping is incomplete near the candidate."
        case .obstacleEvidenceIncomplete:
            return "Existing-object mapping is incomplete near the candidate."
        case .passageEvidenceIncomplete:
            return "Passage mapping is incomplete near the candidate."
        case .collidesWithExistingObject:
            return "The furniture footprint collides with an existing object."
        case .objectClearanceTooSmall:
            return "Clearance from an existing object is below the required distance."
        case .possibleObjectConflict:
            return "Low-confidence object evidence may conflict with the candidate."
        case .wallClearanceTooSmall:
            return "Clearance from a wall is below the required distance."
        case .possibleWallConflict:
            return "Low-confidence wall evidence may conflict with the candidate."
        case .blocksDoorway:
            return "The furniture footprint blocks a verified doorway keep-clear area."
        case .possibleDoorwayConflict:
            return "Low-confidence doorway evidence may conflict with the candidate."
        case .passageWidthTooNarrow:
            return "The candidate leaves less than the required contiguous passage width."
        case .possiblePassageConflict:
            return "Low-confidence passage evidence may conflict with the candidate."
        }
    }
}

public struct FurniturePlacementReason: Codable, Hashable, Sendable {
    public let code: FurniturePlacementReasonCode
    public let evidenceIdentifier: String?
    public let measuredValue: Double?
    public let requiredValue: Double?

    public init(
        code: FurniturePlacementReasonCode,
        evidenceIdentifier: String? = nil,
        measuredValue: Double? = nil,
        requiredValue: Double? = nil
    ) {
        self.code = code
        self.evidenceIdentifier = evidenceIdentifier
        self.measuredValue = measuredValue
        self.requiredValue = requiredValue
    }

    public var message: String {
        code.message
    }
}

public struct FurniturePlacementMeasurements: Codable, Equatable, Sendable {
    public let floorSupportRatio: Double
    public let observationCoverageRatio: Double
    public let nearestWallClearance: Double?
    public let nearestObjectClearance: Double?
    public let narrowestAffectedPassageWidth: Double?
}

public struct FurniturePlacementEvaluation: Codable, Equatable, Sendable {
    public let disposition: FurniturePlacementDisposition
    public let confidence: ConfidenceGrade
    public let confidenceScore: ConfidenceScore
    public let reasons: [FurniturePlacementReason]
    public let measurements: FurniturePlacementMeasurements
}

public struct FurniturePlacementEvaluator: Sendable {
    public let policy: FurniturePlacementPolicy

    public init(policy: FurniturePlacementPolicy = .default) {
        self.policy = policy
    }

    public func evaluate(
        candidate: FurniturePlacementCandidate,
        evidence: FurniturePlacementEvidence
    ) -> FurniturePlacementEvaluation {
        let footprint = Polygon2.rectangle(
            centerX: candidate.position.x,
            centerZ: candidate.position.z,
            width: candidate.furniture.width,
            depth: candidate.furniture.depth,
            yaw: candidate.yawRadians
        )
        let footprintArea = footprint.area
        let observationFootprint = Polygon2.rectangle(
            centerX: candidate.position.x,
            centerZ: candidate.position.z,
            width: candidate.furniture.width + 2 * policy.requiredObservationMargin,
            depth: candidate.furniture.depth + 2 * policy.requiredObservationMargin,
            yaw: candidate.yawRadians
        )

        let floorMatch = bestFloorMatch(
            for: footprint,
            area: footprintArea,
            candidateElevation: candidate.position.y,
            evidence: evidence.floors
        )
        let observationMatch = bestRegionMatch(
            for: observationFootprint,
            area: observationFootprint.area,
            evidence: evidence.observations
        )

        var rejected: [ScoredReason] = []
        var insufficient: [ScoredReason] = []
        var verifiedScores: [Double] = []

        assessObservation(
            match: observationMatch,
            hasEvidence: !evidence.observations.isEmpty,
            insufficient: &insufficient,
            verifiedScores: &verifiedScores
        )
        assessFloor(
            match: floorMatch,
            hasEvidence: !evidence.floors.isEmpty,
            observationIsVerified: observationMatch.isVerified(
                minimumRatio: policy.minimumObservationCoverageRatio,
                minimumConfidence: policy.minimumEvidenceConfidence.value
            ),
            rejected: &rejected,
            insufficient: &insufficient,
            verifiedScores: &verifiedScores
        )
        assessCompleteness(evidence.completeness, insufficient: &insufficient)

        let candidateMinY = candidate.position.y
        let candidateMaxY = candidate.position.y + candidate.furniture.height
        var nearestObjectClearance: Double?
        assessObstacles(
            footprint: footprint,
            minY: candidateMinY,
            maxY: candidateMaxY,
            obstacles: evidence.obstacles,
            rejected: &rejected,
            insufficient: &insufficient,
            nearestClearance: &nearestObjectClearance
        )

        var nearestWallClearance: Double?
        assessWalls(
            footprint: footprint,
            walls: evidence.walls,
            rejected: &rejected,
            insufficient: &insufficient,
            nearestClearance: &nearestWallClearance
        )
        assessDoorways(
            footprint: footprint,
            doorways: evidence.doorways,
            rejected: &rejected,
            insufficient: &insufficient
        )

        var narrowestPassageWidth: Double?
        assessPassages(
            footprint: footprint,
            obstacles: evidence.obstacles,
            passages: evidence.passages,
            rejected: &rejected,
            insufficient: &insufficient,
            narrowestWidth: &narrowestPassageWidth
        )

        let measurements = FurniturePlacementMeasurements(
            floorSupportRatio: floorMatch.ratio,
            observationCoverageRatio: observationMatch.ratio,
            nearestWallClearance: nearestWallClearance,
            nearestObjectClearance: nearestObjectClearance,
            narrowestAffectedPassageWidth: narrowestPassageWidth
        )

        if !rejected.isEmpty {
            let score = rejected.map(\.score).max() ?? 0
            return makeEvaluation(
                disposition: .rejected,
                score: score,
                reasons: rejected.map(\.reason),
                measurements: measurements
            )
        }
        if !insufficient.isEmpty {
            let scores = insufficient.map(\.score)
            let score = scores.min() ?? 0
            return makeEvaluation(
                disposition: .insufficientEvidence,
                score: score,
                reasons: insufficient.map(\.reason),
                measurements: measurements
            )
        }

        let score = verifiedScores.min() ?? 0
        return makeEvaluation(
            disposition: .feasible,
            score: score,
            reasons: [FurniturePlacementReason(code: .placementFeasible)],
            measurements: measurements
        )
    }

    private func assessObservation(
        match: RegionMatch,
        hasEvidence: Bool,
        insufficient: inout [ScoredReason],
        verifiedScores: inout [Double]
    ) {
        guard hasEvidence else {
            insufficient.append(.init(reason: .init(code: .observationEvidenceMissing), score: 0))
            return
        }
        if match.ratio + Geometry2.epsilon < policy.minimumObservationCoverageRatio {
            insufficient.append(
                .init(
                    reason: .init(
                        code: .observationCoverageInsufficient,
                        evidenceIdentifier: match.identifier,
                        measuredValue: match.ratio,
                        requiredValue: policy.minimumObservationCoverageRatio
                    ),
                    score: min(match.ratio, match.confidence)
                )
            )
        } else if match.confidence + Geometry2.epsilon < policy.minimumEvidenceConfidence.value {
            insufficient.append(
                .init(
                    reason: .init(
                        code: .observationConfidenceTooLow,
                        evidenceIdentifier: match.identifier,
                        measuredValue: match.confidence,
                        requiredValue: policy.minimumEvidenceConfidence.value
                    ),
                    score: match.confidence
                )
            )
        } else {
            verifiedScores.append(min(match.ratio, match.confidence))
        }
    }

    private func assessFloor(
        match: RegionMatch,
        hasEvidence: Bool,
        observationIsVerified: Bool,
        rejected: inout [ScoredReason],
        insufficient: inout [ScoredReason],
        verifiedScores: inout [Double]
    ) {
        guard hasEvidence else {
            insufficient.append(.init(reason: .init(code: .floorEvidenceMissing), score: 0))
            return
        }
        if match.ratio + Geometry2.epsilon < policy.minimumFloorSupportRatio {
            let reason = FurniturePlacementReason(
                code: .floorSupportInsufficient,
                evidenceIdentifier: match.identifier,
                measuredValue: match.ratio,
                requiredValue: policy.minimumFloorSupportRatio
            )
            let score = min(match.confidence, match.ratio)
            if observationIsVerified,
                match.confidence + Geometry2.epsilon >= policy.minimumEvidenceConfidence.value
            {
                rejected.append(.init(reason: reason, score: match.confidence))
            } else {
                insufficient.append(.init(reason: reason, score: score))
            }
        } else if match.confidence + Geometry2.epsilon < policy.minimumEvidenceConfidence.value {
            insufficient.append(
                .init(
                    reason: .init(
                        code: .floorConfidenceTooLow,
                        evidenceIdentifier: match.identifier,
                        measuredValue: match.confidence,
                        requiredValue: policy.minimumEvidenceConfidence.value
                    ),
                    score: match.confidence
                )
            )
        } else {
            verifiedScores.append(min(match.ratio, match.confidence))
        }
    }

    private func assessCompleteness(
        _ completeness: PlacementEvidenceCompleteness,
        insufficient: inout [ScoredReason]
    ) {
        if !completeness.wallsMapped {
            insufficient.append(.init(reason: .init(code: .wallEvidenceIncomplete), score: 0))
        }
        if !completeness.doorwaysMapped {
            insufficient.append(.init(reason: .init(code: .doorwayEvidenceIncomplete), score: 0))
        }
        if !completeness.obstaclesMapped {
            insufficient.append(.init(reason: .init(code: .obstacleEvidenceIncomplete), score: 0))
        }
        if !completeness.passagesMapped {
            insufficient.append(.init(reason: .init(code: .passageEvidenceIncomplete), score: 0))
        }
    }

    private func assessObstacles(
        footprint: Polygon2,
        minY: Double,
        maxY: Double,
        obstacles: [PlacementObstacleEvidence],
        rejected: inout [ScoredReason],
        insufficient: inout [ScoredReason],
        nearestClearance: inout Double?
    ) {
        for obstacle in obstacles.sorted(by: { $0.objectID < $1.objectID }) {
            let verticalOverlap =
                min(maxY, obstacle.bounds.max.y)
                - max(minY, obstacle.bounds.min.y)
            guard verticalOverlap > Geometry2.epsilon else { continue }
            let polygon = Polygon2.axisAligned(bounds: obstacle.bounds)
            let overlap = Geometry2.intersectionArea(footprint, polygon)
            let clearance = Geometry2.distance(footprint, polygon)
            nearestClearance = nearestValue(nearestClearance, clearance)
            let isCollision = overlap > Geometry2.epsilon
            let isTooClose =
                !isCollision
                && clearance + Geometry2.epsilon < policy.minimumObjectClearance
            guard isCollision || isTooClose else { continue }

            let strongEvidence =
                obstacle.confidence.value + Geometry2.epsilon
                >= policy.minimumEvidenceConfidence.value
            let code: FurniturePlacementReasonCode
            if strongEvidence {
                code = isCollision ? .collidesWithExistingObject : .objectClearanceTooSmall
            } else {
                code = .possibleObjectConflict
            }
            let reason = FurniturePlacementReason(
                code: code,
                evidenceIdentifier: obstacle.objectID.description,
                measuredValue: isCollision ? 0 : clearance,
                requiredValue: isCollision ? nil : policy.minimumObjectClearance
            )
            let scored = ScoredReason(reason: reason, score: obstacle.confidence.value)
            if strongEvidence {
                rejected.append(scored)
            } else {
                insufficient.append(scored)
            }
        }
    }

    private func assessWalls(
        footprint: Polygon2,
        walls: [PlacementWallEvidence],
        rejected: inout [ScoredReason],
        insufficient: inout [ScoredReason],
        nearestClearance: inout Double?
    ) {
        for wall in walls.sorted(by: { $0.identifier < $1.identifier }) {
            let segment = Segment2(
                start: Point2(x: wall.start.x, z: wall.start.z),
                end: Point2(x: wall.end.x, z: wall.end.z)
            )
            let distance = Geometry2.distance(footprint, segment)
            nearestClearance = nearestValue(nearestClearance, distance)
            guard
                Geometry2.intersectsInterior(footprint, segment)
                    || distance + Geometry2.epsilon < policy.minimumWallClearance
            else { continue }
            let strongEvidence =
                wall.confidence.value + Geometry2.epsilon
                >= policy.minimumEvidenceConfidence.value
            let code: FurniturePlacementReasonCode =
                strongEvidence
                ? .wallClearanceTooSmall : .possibleWallConflict
            let reason = FurniturePlacementReason(
                code: code,
                evidenceIdentifier: wall.identifier,
                measuredValue: distance,
                requiredValue: policy.minimumWallClearance
            )
            let scored = ScoredReason(reason: reason, score: wall.confidence.value)
            if strongEvidence {
                rejected.append(scored)
            } else {
                insufficient.append(scored)
            }
        }
    }

    private func assessDoorways(
        footprint: Polygon2,
        doorways: [PlacementDoorwayEvidence],
        rejected: inout [ScoredReason],
        insufficient: inout [ScoredReason]
    ) {
        for doorway in doorways.sorted(by: { $0.identifier < $1.identifier }) {
            let keepClear = Polygon2.rectangle(doorway.keepClearRegion)
            let overlap = Geometry2.intersectionArea(footprint, keepClear)
            guard overlap > Geometry2.epsilon else { continue }
            let strongEvidence =
                doorway.confidence.value + Geometry2.epsilon
                >= policy.minimumEvidenceConfidence.value
            let code: FurniturePlacementReasonCode =
                strongEvidence
                ? .blocksDoorway : .possibleDoorwayConflict
            let reason = FurniturePlacementReason(
                code: code,
                evidenceIdentifier: doorway.identifier,
                measuredValue: overlap,
                requiredValue: 0
            )
            let scored = ScoredReason(reason: reason, score: doorway.confidence.value)
            if strongEvidence {
                rejected.append(scored)
            } else {
                insufficient.append(scored)
            }
        }
    }

    private func assessPassages(
        footprint: Polygon2,
        obstacles: [PlacementObstacleEvidence],
        passages: [PlacementPassageEvidence],
        rejected: inout [ScoredReason],
        insufficient: inout [ScoredReason],
        narrowestWidth: inout Double?
    ) {
        for passage in passages.sorted(by: { $0.identifier < $1.identifier }) {
            let passagePolygon = Polygon2.rectangle(passage.region)
            guard Geometry2.intersectionArea(footprint, passagePolygon) > Geometry2.epsilon else {
                continue
            }
            var blocked = [crossAxisInterval(of: footprint, in: passage)]
            for obstacle in obstacles.sorted(by: { $0.objectID < $1.objectID }) {
                // Passage regions are floor-level footprints. Only geometry
                // within the same two-metre walking envelope used by indoor
                // navigation reduces their usable width; a high ceiling does not.
                guard obstacle.bounds.max.y > passage.region.center.y + Geometry2.epsilon,
                    obstacle.bounds.min.y < passage.region.center.y + 2.0
                else { continue }
                let polygon = Polygon2.axisAligned(bounds: obstacle.bounds)
                guard Geometry2.intersectionArea(polygon, passagePolygon) > Geometry2.epsilon else {
                    continue
                }
                blocked.append(crossAxisInterval(of: polygon, in: passage))
            }
            let clearWidth = widestClearLane(blocked: blocked, passage: passage)
            narrowestWidth = nearestValue(narrowestWidth, clearWidth)
            guard clearWidth + Geometry2.epsilon < passage.requiredClearWidth else { continue }

            let strongEvidence =
                passage.confidence.value + Geometry2.epsilon
                >= policy.minimumEvidenceConfidence.value
            let code: FurniturePlacementReasonCode =
                strongEvidence
                ? .passageWidthTooNarrow : .possiblePassageConflict
            let reason = FurniturePlacementReason(
                code: code,
                evidenceIdentifier: passage.identifier,
                measuredValue: clearWidth,
                requiredValue: passage.requiredClearWidth
            )
            let scored = ScoredReason(reason: reason, score: passage.confidence.value)
            if strongEvidence {
                rejected.append(scored)
            } else {
                insufficient.append(scored)
            }
        }
    }

    private func bestFloorMatch(
        for footprint: Polygon2,
        area: Double,
        candidateElevation: Double,
        evidence: [PlacementFloorEvidence]
    ) -> RegionMatch {
        evidence.reduce(.none) { current, floor in
            let elevationMatches =
                abs(floor.elevation - candidateElevation)
                <= policy.floorElevationTolerance + Geometry2.epsilon
            let ratio =
                elevationMatches
                ? Geometry2.intersectionArea(footprint, Polygon2.rectangle(floor.region)) / area
                : 0
            return current.preferred(
                over: RegionMatch(
                    identifier: floor.identifier,
                    ratio: clampedRatio(ratio),
                    confidence: floor.confidence.value
                )
            )
        }
    }

    private func bestRegionMatch(
        for footprint: Polygon2,
        area: Double,
        evidence: [PlacementObservationEvidence]
    ) -> RegionMatch {
        evidence.reduce(.none) { current, observation in
            let ratio =
                Geometry2.intersectionArea(
                    footprint,
                    Polygon2.rectangle(observation.region)
                ) / area
            return current.preferred(
                over: RegionMatch(
                    identifier: observation.identifier,
                    ratio: clampedRatio(ratio),
                    confidence: observation.confidence.value
                )
            )
        }
    }

    private func crossAxisInterval(
        of polygon: Polygon2,
        in passage: PlacementPassageEvidence
    ) -> ClosedRange<Double> {
        let cosine = cos(passage.region.yawRadians)
        let sine = sin(passage.region.yawRadians)
        let values = polygon.vertices.map { point -> Double in
            let dx = point.x - passage.region.center.x
            let dz = point.z - passage.region.center.z
            let localX = dx * cosine + dz * sine
            let localZ = -dx * sine + dz * cosine
            return passage.travelAxis == .alongWidth ? localZ : localX
        }
        let halfWidth =
            (passage.travelAxis == .alongWidth
                ? passage.region.depth : passage.region.width) / 2
        let lower = max(-halfWidth, values.min() ?? -halfWidth)
        let upper = min(halfWidth, values.max() ?? halfWidth)
        return min(lower, upper)...max(lower, upper)
    }

    private func widestClearLane(
        blocked: [ClosedRange<Double>],
        passage: PlacementPassageEvidence
    ) -> Double {
        let halfWidth =
            (passage.travelAxis == .alongWidth
                ? passage.region.depth : passage.region.width) / 2
        let intervals =
            blocked
            .map { max(-halfWidth, $0.lowerBound)...min(halfWidth, $0.upperBound) }
            .filter { $0.lowerBound <= $0.upperBound }
            .sorted {
                if abs($0.lowerBound - $1.lowerBound) > Geometry2.epsilon {
                    return $0.lowerBound < $1.lowerBound
                }
                return $0.upperBound < $1.upperBound
            }
        var cursor = -halfWidth
        var widest = 0.0
        for interval in intervals {
            widest = max(widest, max(0, interval.lowerBound - cursor))
            cursor = max(cursor, interval.upperBound)
        }
        return max(widest, max(0, halfWidth - cursor))
    }

    private func makeEvaluation(
        disposition: FurniturePlacementDisposition,
        score: Double,
        reasons: [FurniturePlacementReason],
        measurements: FurniturePlacementMeasurements
    ) -> FurniturePlacementEvaluation {
        let score = ConfidenceScore(clamping: score)
        let reasons = reasons.sorted {
            if $0.code.rawValue != $1.code.rawValue {
                return $0.code.rawValue < $1.code.rawValue
            }
            return ($0.evidenceIdentifier ?? "") < ($1.evidenceIdentifier ?? "")
        }
        return FurniturePlacementEvaluation(
            disposition: disposition,
            confidence: policy.confidencePolicy.grade(for: score),
            confidenceScore: score,
            reasons: reasons,
            measurements: measurements
        )
    }

    private func nearestValue(_ current: Double?, _ candidate: Double) -> Double {
        current.map { min($0, candidate) } ?? candidate
    }

    private func clampedRatio(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }
}

extension FurnitureDimensions {
    private enum CodingKeys: String, CodingKey {
        case kind
        case width
        case depth
        case height
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                kind: container.decode(FurnitureKind.self, forKey: .kind),
                width: container.decode(Double.self, forKey: .width),
                depth: container.decode(Double.self, forKey: .depth),
                height: container.decode(Double.self, forKey: .height)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw invalidPlacementDecoding(.width, in: container)
        }
    }
}

extension FurniturePlacementCandidate {
    private enum CodingKeys: String, CodingKey {
        case position
        case yawRadians
        case furniture
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                position: container.decode(Vec3.self, forKey: .position),
                yawRadians: container.decode(Double.self, forKey: .yawRadians),
                furniture: container.decode(FurnitureDimensions.self, forKey: .furniture)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw invalidPlacementDecoding(.yawRadians, in: container)
        }
    }
}

extension PlacementHorizontalRegion {
    private enum CodingKeys: String, CodingKey {
        case center
        case width
        case depth
        case yawRadians
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                center: container.decode(Vec3.self, forKey: .center),
                width: container.decode(Double.self, forKey: .width),
                depth: container.decode(Double.self, forKey: .depth),
                yawRadians: container.decode(Double.self, forKey: .yawRadians)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw invalidPlacementDecoding(.width, in: container)
        }
    }
}

extension PlacementFloorEvidence {
    private enum CodingKeys: String, CodingKey {
        case identifier
        case region
        case elevation
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                identifier: container.decode(String.self, forKey: .identifier),
                region: container.decode(PlacementHorizontalRegion.self, forKey: .region),
                elevation: container.decode(Double.self, forKey: .elevation),
                confidence: container.decode(ConfidenceScore.self, forKey: .confidence)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw invalidPlacementDecoding(.identifier, in: container)
        }
    }
}

extension PlacementObservationEvidence {
    private enum CodingKeys: String, CodingKey {
        case identifier
        case region
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                identifier: container.decode(String.self, forKey: .identifier),
                region: container.decode(PlacementHorizontalRegion.self, forKey: .region),
                confidence: container.decode(ConfidenceScore.self, forKey: .confidence)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw invalidPlacementDecoding(.identifier, in: container)
        }
    }
}

extension PlacementWallEvidence {
    private enum CodingKeys: String, CodingKey {
        case identifier
        case start
        case end
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                identifier: container.decode(String.self, forKey: .identifier),
                start: container.decode(Vec3.self, forKey: .start),
                end: container.decode(Vec3.self, forKey: .end),
                confidence: container.decode(ConfidenceScore.self, forKey: .confidence)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw invalidPlacementDecoding(.identifier, in: container)
        }
    }
}

extension PlacementDoorwayEvidence {
    private enum CodingKeys: String, CodingKey {
        case identifier
        case keepClearRegion
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                identifier: container.decode(String.self, forKey: .identifier),
                keepClearRegion: container.decode(
                    PlacementHorizontalRegion.self,
                    forKey: .keepClearRegion
                ),
                confidence: container.decode(ConfidenceScore.self, forKey: .confidence)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw invalidPlacementDecoding(.identifier, in: container)
        }
    }
}

extension PlacementObstacleEvidence {
    private enum CodingKeys: String, CodingKey {
        case objectID
        case bounds
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                objectID: container.decode(ObjectID.self, forKey: .objectID),
                bounds: container.decode(AABB.self, forKey: .bounds),
                confidence: container.decode(ConfidenceScore.self, forKey: .confidence)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw invalidPlacementDecoding(.bounds, in: container)
        }
    }
}

extension PlacementPassageEvidence {
    private enum CodingKeys: String, CodingKey {
        case identifier
        case region
        case travelAxis
        case requiredClearWidth
        case confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                identifier: container.decode(String.self, forKey: .identifier),
                region: container.decode(PlacementHorizontalRegion.self, forKey: .region),
                travelAxis: container.decode(PlacementPassageTravelAxis.self, forKey: .travelAxis),
                requiredClearWidth: container.decode(Double.self, forKey: .requiredClearWidth),
                confidence: container.decode(ConfidenceScore.self, forKey: .confidence)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw invalidPlacementDecoding(.requiredClearWidth, in: container)
        }
    }
}

extension FurniturePlacementPolicy {
    private enum CodingKeys: String, CodingKey {
        case minimumFloorSupportRatio
        case minimumObservationCoverageRatio
        case requiredObservationMargin
        case floorElevationTolerance
        case minimumWallClearance
        case minimumObjectClearance
        case minimumEvidenceConfidence
        case confidencePolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                minimumFloorSupportRatio: container.decode(
                    Double.self,
                    forKey: .minimumFloorSupportRatio
                ),
                minimumObservationCoverageRatio: container.decode(
                    Double.self,
                    forKey: .minimumObservationCoverageRatio
                ),
                requiredObservationMargin: container.decode(
                    Double.self,
                    forKey: .requiredObservationMargin
                ),
                floorElevationTolerance: container.decode(
                    Double.self,
                    forKey: .floorElevationTolerance
                ),
                minimumWallClearance: container.decode(
                    Double.self,
                    forKey: .minimumWallClearance
                ),
                minimumObjectClearance: container.decode(
                    Double.self,
                    forKey: .minimumObjectClearance
                ),
                minimumEvidenceConfidence: container.decode(
                    ConfidenceScore.self,
                    forKey: .minimumEvidenceConfidence
                ),
                confidencePolicy: container.decode(
                    ConfidencePolicy.self,
                    forKey: .confidencePolicy
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw invalidPlacementDecoding(.minimumFloorSupportRatio, in: container)
        }
    }
}

private func validatedEvidenceIdentifier(_ value: String) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
        throw FurniturePlacementInputError.emptyEvidenceIdentifier
    }
    return normalized
}

private func invalidPlacementDecoding<Key: CodingKey>(
    _ key: Key,
    in container: KeyedDecodingContainer<Key>
) -> DecodingError {
    DecodingError.dataCorruptedError(
        forKey: key,
        in: container,
        debugDescription: "Placement input contains an invalid value."
    )
}

private struct RegionMatch: Sendable {
    let identifier: String?
    let ratio: Double
    let confidence: Double

    static let none = RegionMatch(identifier: nil, ratio: 0, confidence: 0)

    func preferred(over candidate: Self) -> Self {
        if candidate.ratio > ratio + Geometry2.epsilon {
            return candidate
        }
        if abs(candidate.ratio - ratio) <= Geometry2.epsilon {
            if candidate.confidence > confidence + Geometry2.epsilon {
                return candidate
            }
            if abs(candidate.confidence - confidence) <= Geometry2.epsilon,
                (candidate.identifier ?? "") < (identifier ?? "")
            {
                return candidate
            }
        }
        return self
    }

    func isVerified(minimumRatio: Double, minimumConfidence: Double) -> Bool {
        ratio + Geometry2.epsilon >= minimumRatio
            && confidence + Geometry2.epsilon >= minimumConfidence
    }
}

private struct ScoredReason: Sendable {
    let reason: FurniturePlacementReason
    let score: Double
}

private struct Point2: Equatable, Sendable {
    let x: Double
    let z: Double

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(x: lhs.x + rhs.x, z: lhs.z + rhs.z)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(x: lhs.x - rhs.x, z: lhs.z - rhs.z)
    }

    static func * (lhs: Self, rhs: Double) -> Self {
        Self(x: lhs.x * rhs, z: lhs.z * rhs)
    }
}

private struct Segment2: Sendable {
    let start: Point2
    let end: Point2
}

private struct Polygon2: Sendable {
    let vertices: [Point2]

    var area: Double {
        Geometry2.area(vertices)
    }

    var edges: [Segment2] {
        guard vertices.count > 1 else { return [] }
        return vertices.indices.map { index in
            Segment2(start: vertices[index], end: vertices[(index + 1) % vertices.count])
        }
    }

    static func rectangle(_ region: PlacementHorizontalRegion) -> Self {
        rectangle(
            centerX: region.center.x,
            centerZ: region.center.z,
            width: region.width,
            depth: region.depth,
            yaw: region.yawRadians
        )
    }

    static func rectangle(
        centerX: Double,
        centerZ: Double,
        width: Double,
        depth: Double,
        yaw: Double
    ) -> Self {
        let halfWidth = width / 2
        let halfDepth = depth / 2
        let cosine = cos(yaw)
        let sine = sin(yaw)
        let center = Point2(x: centerX, z: centerZ)
        let xAxis = Point2(x: cosine, z: sine)
        let zAxis = Point2(x: -sine, z: cosine)
        let vertices = [
            center + xAxis * -halfWidth + zAxis * -halfDepth,
            center + xAxis * halfWidth + zAxis * -halfDepth,
            center + xAxis * halfWidth + zAxis * halfDepth,
            center + xAxis * -halfWidth + zAxis * halfDepth,
        ]
        return Self(vertices: vertices)
    }

    static func axisAligned(bounds: AABB) -> Self {
        Self(vertices: [
            Point2(x: bounds.min.x, z: bounds.min.z),
            Point2(x: bounds.max.x, z: bounds.min.z),
            Point2(x: bounds.max.x, z: bounds.max.z),
            Point2(x: bounds.min.x, z: bounds.max.z),
        ])
    }
}

private enum Geometry2 {
    static let epsilon = 1e-9

    static func area(_ vertices: [Point2]) -> Double {
        guard vertices.count >= 3 else { return 0 }
        let doubledArea = vertices.indices.reduce(0.0) { partial, index in
            let next = vertices[(index + 1) % vertices.count]
            return partial + cross(vertices[index], next)
        }
        return abs(doubledArea) / 2
    }

    static func intersectionArea(_ subject: Polygon2, _ clip: Polygon2) -> Double {
        var output = subject.vertices
        for edge in clip.edges {
            guard !output.isEmpty else { return 0 }
            let input = output
            output.removeAll(keepingCapacity: true)
            var previous = input[input.count - 1]
            for current in input {
                let currentInside = isInside(current, edge: edge)
                let previousInside = isInside(previous, edge: edge)
                if currentInside {
                    if !previousInside,
                        let intersection = lineIntersection(previous, current, edge.start, edge.end)
                    {
                        output.append(intersection)
                    }
                    output.append(current)
                } else if previousInside,
                    let intersection = lineIntersection(previous, current, edge.start, edge.end)
                {
                    output.append(intersection)
                }
                previous = current
            }
        }
        return area(output)
    }

    static func distance(_ lhs: Polygon2, _ rhs: Polygon2) -> Double {
        if intersectionArea(lhs, rhs) > epsilon {
            return 0
        }
        return lhs.edges.flatMap { left in
            rhs.edges.map { right in segmentDistance(left, right) }
        }.min() ?? .infinity
    }

    static func distance(_ polygon: Polygon2, _ segment: Segment2) -> Double {
        // Edge intersections alone miss a short wall wholly enclosed by the
        // footprint. Rectangle vertices are counter-clockwise, including yaw.
        if polygon.edges.allSatisfy({ isInside(segment.start, edge: $0) })
            || polygon.edges.allSatisfy({ isInside(segment.end, edge: $0) })
        {
            return 0
        }
        return polygon.edges.map { segmentDistance($0, segment) }.min() ?? .infinity
    }

    /// Clip the wall's parameter interval against the convex footprint's open
    /// interior. Unlike distance == 0, this distinguishes crossing/containment
    /// from boundary-only contact when the requested clearance is zero.
    static func intersectsInterior(_ polygon: Polygon2, _ segment: Segment2) -> Bool {
        var lower = 0.0
        var upper = 1.0
        let direction = segment.end - segment.start
        for edge in polygon.edges {
            let edgeDirection = edge.end - edge.start
            let offset = cross(edgeDirection, segment.start - edge.start)
            let slope = cross(edgeDirection, direction)
            if abs(slope) <= epsilon {
                guard offset > epsilon else { return false }
                continue
            }
            let boundary = (epsilon - offset) / slope
            if slope > 0 {
                lower = max(lower, boundary)
            } else {
                upper = min(upper, boundary)
            }
            guard lower < upper else { return false }
        }
        return lower < upper
    }

    private static func isInside(_ point: Point2, edge: Segment2) -> Bool {
        cross(edge.end - edge.start, point - edge.start) >= -epsilon
    }

    private static func lineIntersection(
        _ subjectStart: Point2,
        _ subjectEnd: Point2,
        _ clipStart: Point2,
        _ clipEnd: Point2
    ) -> Point2? {
        let subjectDirection = subjectEnd - subjectStart
        let clipDirection = clipEnd - clipStart
        let denominator = cross(clipDirection, subjectDirection)
        guard abs(denominator) > epsilon else { return nil }
        let t = cross(clipDirection, clipStart - subjectStart) / denominator
        return subjectStart + subjectDirection * t
    }

    private static func segmentDistance(_ lhs: Segment2, _ rhs: Segment2) -> Double {
        if segmentsIntersect(lhs, rhs) {
            return 0
        }
        return [
            pointSegmentDistance(lhs.start, rhs),
            pointSegmentDistance(lhs.end, rhs),
            pointSegmentDistance(rhs.start, lhs),
            pointSegmentDistance(rhs.end, lhs),
        ].min() ?? .infinity
    }

    private static func segmentsIntersect(_ lhs: Segment2, _ rhs: Segment2) -> Bool {
        let d1 = cross(lhs.end - lhs.start, rhs.start - lhs.start)
        let d2 = cross(lhs.end - lhs.start, rhs.end - lhs.start)
        let d3 = cross(rhs.end - rhs.start, lhs.start - rhs.start)
        let d4 = cross(rhs.end - rhs.start, lhs.end - rhs.start)
        if (d1 > epsilon && d2 < -epsilon) || (d1 < -epsilon && d2 > epsilon),
            (d3 > epsilon && d4 < -epsilon) || (d3 < -epsilon && d4 > epsilon)
        {
            return true
        }
        return (abs(d1) <= epsilon && pointOnSegment(rhs.start, lhs))
            || (abs(d2) <= epsilon && pointOnSegment(rhs.end, lhs))
            || (abs(d3) <= epsilon && pointOnSegment(lhs.start, rhs))
            || (abs(d4) <= epsilon && pointOnSegment(lhs.end, rhs))
    }

    private static func pointOnSegment(_ point: Point2, _ segment: Segment2) -> Bool {
        point.x >= min(segment.start.x, segment.end.x) - epsilon
            && point.x <= max(segment.start.x, segment.end.x) + epsilon
            && point.z >= min(segment.start.z, segment.end.z) - epsilon
            && point.z <= max(segment.start.z, segment.end.z) + epsilon
    }

    private static func pointSegmentDistance(_ point: Point2, _ segment: Segment2) -> Double {
        let direction = segment.end - segment.start
        let lengthSquared = dot(direction, direction)
        guard lengthSquared > epsilon else {
            return hypot(point.x - segment.start.x, point.z - segment.start.z)
        }
        let projection = dot(point - segment.start, direction) / lengthSquared
        let t = min(1, max(0, projection))
        let closest = segment.start + direction * t
        return hypot(point.x - closest.x, point.z - closest.z)
    }

    private static func cross(_ lhs: Point2, _ rhs: Point2) -> Double {
        lhs.x * rhs.z - lhs.z * rhs.x
    }

    private static func dot(_ lhs: Point2, _ rhs: Point2) -> Double {
        lhs.x * rhs.x + lhs.z * rhs.z
    }
}
