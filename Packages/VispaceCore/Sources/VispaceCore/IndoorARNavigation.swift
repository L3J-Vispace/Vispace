import Foundation

public enum IndoorNavigationInputError: Error, Equatable, Sendable {
    case emptyIdentifier
    case nonFiniteValue
    case nonPositiveValue
    case invalidPortal
    case invalidTimestamp
    case invalidCapacity
    case invalidPath
    case invalidResult
}

/// A deterministic cell address in an observed, map-local navigation grid.
/// `level` separates floors; this engine never invents a vertical connection.
public struct IndoorNavigationCell: Codable, Hashable, Comparable, Sendable {
    public let level: Int
    public let column: Int
    public let row: Int

    public init(level: Int = 0, column: Int, row: Int) {
        self.level = level
        self.column = column
        self.row = row
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.level != rhs.level { return lhs.level < rhs.level }
        if lhs.row != rhs.row { return lhs.row < rhs.row }
        return lhs.column < rhs.column
    }

    fileprivate func isHorizontalNeighbor(of other: Self) -> Bool {
        guard level == other.level else { return false }
        let horizontal =
            row == other.row
            && ((column > Int.min && other.column == column - 1)
                || (column < Int.max && other.column == column + 1))
        let vertical =
            column == other.column
            && ((row > Int.min && other.row == row - 1)
                || (row < Int.max && other.row == row + 1))
        return horizontal || vertical
    }
}

public struct IndoorNavigationFloorEvidence: Codable, Hashable, Sendable {
    public let cell: IndoorNavigationCell
    public let zoneIdentifier: String
    public let elevation: Double
    public let confidence: ConfidenceScore

    public init(
        cell: IndoorNavigationCell,
        zoneIdentifier: String,
        elevation: Double,
        confidence: ConfidenceScore
    ) throws {
        guard elevation.isFinite else { throw IndoorNavigationInputError.nonFiniteValue }
        self.cell = cell
        self.zoneIdentifier = try indoorNavigationIdentifier(zoneIdentifier)
        self.elevation = elevation
        self.confidence = confidence
    }
}

public enum IndoorNavigationMeshOccupancy: String, Codable, Hashable, Sendable {
    /// The full cell was observed as traversable free space.
    case free
    /// Observed geometry makes the cell impassable.
    case blocked
    /// The mesh observation cannot establish either state.
    case unknown
}

public struct IndoorNavigationMeshEvidence: Codable, Hashable, Sendable {
    public let cell: IndoorNavigationCell
    public let occupancy: IndoorNavigationMeshOccupancy
    public let confidence: ConfidenceScore

    public init(
        cell: IndoorNavigationCell,
        occupancy: IndoorNavigationMeshOccupancy,
        confidence: ConfidenceScore
    ) {
        self.cell = cell
        self.occupancy = occupancy
        self.confidence = confidence
    }
}

public enum IndoorNavigationDoorState: String, Codable, Hashable, Sendable {
    case open
    case closed
    case unknown
}

/// A portal is the only way an edge may cross two different observed zones.
/// Portal endpoints must be horizontally adjacent cells on the same level.
public struct IndoorNavigationDoorEvidence: Codable, Hashable, Sendable {
    public let identifier: String
    public let firstCell: IndoorNavigationCell
    public let secondCell: IndoorNavigationCell
    public let state: IndoorNavigationDoorState
    public let confidence: ConfidenceScore
    public let clearWidth: Double

    public init(
        identifier: String,
        firstCell: IndoorNavigationCell,
        secondCell: IndoorNavigationCell,
        state: IndoorNavigationDoorState,
        confidence: ConfidenceScore,
        clearWidth: Double = 0.90
    ) throws {
        guard firstCell.isHorizontalNeighbor(of: secondCell) else {
            throw IndoorNavigationInputError.invalidPortal
        }
        guard clearWidth.isFinite else { throw IndoorNavigationInputError.nonFiniteValue }
        guard clearWidth > 0 else { throw IndoorNavigationInputError.nonPositiveValue }
        self.identifier = try indoorNavigationIdentifier(identifier)
        self.firstCell = firstCell
        self.secondCell = secondCell
        self.state = state
        self.confidence = confidence
        self.clearWidth = clearWidth
    }

    fileprivate func connects(_ lhs: IndoorNavigationCell, _ rhs: IndoorNavigationCell) -> Bool {
        (firstCell == lhs && secondCell == rhs) || (firstCell == rhs && secondCell == lhs)
    }
}

public struct IndoorNavigationWallEvidence: Codable, Hashable, Sendable {
    public let identifier: String
    public let start: Vec3
    public let end: Vec3
    public let thickness: Double
    public let confidence: ConfidenceScore

    public init(
        identifier: String,
        start: Vec3,
        end: Vec3,
        thickness: Double,
        confidence: ConfidenceScore
    ) throws {
        guard thickness.isFinite else { throw IndoorNavigationInputError.nonFiniteValue }
        guard thickness > 0 else { throw IndoorNavigationInputError.nonPositiveValue }
        guard hypot(end.x - start.x, end.z - start.z) > IndoorNavigationGeometry.epsilon else {
            throw IndoorNavigationInputError.nonPositiveValue
        }
        self.identifier = try indoorNavigationIdentifier(identifier)
        self.start = start
        self.end = end
        self.thickness = thickness
        self.confidence = confidence
    }
}

public struct IndoorNavigationObstacleEvidence: Codable, Hashable, Sendable {
    public let identifier: String
    public let objectID: ObjectID?
    public let bounds: AABB
    public let confidence: ConfidenceScore

    public init(
        identifier: String,
        objectID: ObjectID? = nil,
        bounds: AABB,
        confidence: ConfidenceScore
    ) throws {
        let size = bounds.size
        guard size.x > 0, size.y > 0, size.z > 0 else {
            throw IndoorNavigationInputError.nonPositiveValue
        }
        self.identifier = try indoorNavigationIdentifier(identifier)
        self.objectID = objectID
        self.bounds = bounds
        self.confidence = confidence
    }
}

/// Completeness is explicit: an empty obstacle list is safe only when the
/// producer confirms that obstacle coverage around the observed cells is complete.
public struct IndoorNavigationEvidenceCompleteness: Codable, Hashable, Sendable {
    public let wallsAroundObservedCellsMapped: Bool
    public let doorwayStatesMapped: Bool
    public let obstaclesAroundObservedCellsMapped: Bool

    public init(
        wallsAroundObservedCellsMapped: Bool,
        doorwayStatesMapped: Bool,
        obstaclesAroundObservedCellsMapped: Bool
    ) {
        self.wallsAroundObservedCellsMapped = wallsAroundObservedCellsMapped
        self.doorwayStatesMapped = doorwayStatesMapped
        self.obstaclesAroundObservedCellsMapped = obstaclesAroundObservedCellsMapped
    }

    public static let complete = Self(
        wallsAroundObservedCellsMapped: true,
        doorwayStatesMapped: true,
        obstaclesAroundObservedCellsMapped: true
    )

    public static let unavailable = Self(
        wallsAroundObservedCellsMapped: false,
        doorwayStatesMapped: false,
        obstaclesAroundObservedCellsMapped: false
    )

    fileprivate var isComplete: Bool {
        wallsAroundObservedCellsMapped && doorwayStatesMapped
            && obstaclesAroundObservedCellsMapped
    }
}

/// Navigation evidence is tied to exactly one durable map and coordinate frame.
/// Cell (0, 0) is centered at `gridOrigin`; cell centers are derived, never guessed.
public struct IndoorNavigationEvidence: Codable, Sendable {
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let revision: UInt64
    public let observedAt: TimeInterval
    public let gridOrigin: Vec3
    public let cellSize: Double
    public let floors: [IndoorNavigationFloorEvidence]
    public let mesh: [IndoorNavigationMeshEvidence]
    public let doors: [IndoorNavigationDoorEvidence]
    public let walls: [IndoorNavigationWallEvidence]
    public let obstacles: [IndoorNavigationObstacleEvidence]
    public let completeness: IndoorNavigationEvidenceCompleteness

    public init(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        revision: UInt64,
        observedAt: TimeInterval,
        gridOrigin: Vec3,
        cellSize: Double,
        floors: [IndoorNavigationFloorEvidence],
        mesh: [IndoorNavigationMeshEvidence],
        doors: [IndoorNavigationDoorEvidence] = [],
        walls: [IndoorNavigationWallEvidence] = [],
        obstacles: [IndoorNavigationObstacleEvidence] = [],
        completeness: IndoorNavigationEvidenceCompleteness = .unavailable
    ) throws {
        guard observedAt.isFinite, observedAt >= 0 else {
            throw IndoorNavigationInputError.invalidTimestamp
        }
        guard cellSize.isFinite else { throw IndoorNavigationInputError.nonFiniteValue }
        guard cellSize > 0 else { throw IndoorNavigationInputError.nonPositiveValue }
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        self.revision = revision
        self.observedAt = observedAt
        self.gridOrigin = gridOrigin
        self.cellSize = cellSize
        self.floors = floors
        self.mesh = mesh
        self.doors = doors
        self.walls = walls
        self.obstacles = obstacles
        self.completeness = completeness
    }
}

public struct IndoorNavigationPolicy: Codable, Hashable, Sendable {
    public let agentRadius: Double
    public let obstacleClearance: Double
    public let maximumStepHeight: Double
    public let maximumStartAge: TimeInterval
    public let maximumEvidenceAge: TimeInterval
    public let maximumFutureTimestampSkew: TimeInterval
    public let maximumStartSnapDistance: Double
    public let maximumDestinationSnapDistance: Double
    public let minimumEvidenceConfidence: ConfidenceScore
    public let minimumDestinationConfidence: ConfidenceScore
    public let maximumFloorCells: Int
    public let maximumMeshCells: Int
    public let maximumDoors: Int
    public let maximumWalls: Int
    public let maximumObstacles: Int
    public let maximumExploredNodes: Int
    public let maximumWaypoints: Int
    public let confidencePolicy: ConfidencePolicy

    public init(
        agentRadius: Double = 0.20,
        obstacleClearance: Double = 0.05,
        maximumStepHeight: Double = 0.18,
        maximumStartAge: TimeInterval = 5,
        maximumEvidenceAge: TimeInterval = 5,
        maximumFutureTimestampSkew: TimeInterval = 0.25,
        maximumStartSnapDistance: Double = 1,
        maximumDestinationSnapDistance: Double = 1.5,
        minimumEvidenceConfidence: ConfidenceScore = ConfidenceScore(clamping: 0.50),
        minimumDestinationConfidence: ConfidenceScore = ConfidenceScore(clamping: 0.50),
        maximumFloorCells: Int = 20_000,
        maximumMeshCells: Int = 20_000,
        maximumDoors: Int = 1_000,
        maximumWalls: Int = 10_000,
        maximumObstacles: Int = 10_000,
        maximumExploredNodes: Int = 20_000,
        maximumWaypoints: Int = 20_000,
        confidencePolicy: ConfidencePolicy = .default
    ) throws {
        let finiteValues = [
            agentRadius, obstacleClearance, maximumStepHeight, maximumStartAge, maximumEvidenceAge,
            maximumFutureTimestampSkew, maximumStartSnapDistance,
            maximumDestinationSnapDistance,
        ]
        guard finiteValues.allSatisfy(\.isFinite) else {
            throw IndoorNavigationInputError.nonFiniteValue
        }
        guard finiteValues.allSatisfy({ $0 >= 0 }), agentRadius > 0,
            maximumStartSnapDistance > 0, maximumDestinationSnapDistance > 0
        else {
            throw IndoorNavigationInputError.nonPositiveValue
        }
        let capacities = [
            maximumFloorCells, maximumMeshCells, maximumDoors, maximumWalls,
            maximumObstacles, maximumExploredNodes, maximumWaypoints,
        ]
        guard capacities.allSatisfy({ $0 > 0 }) else {
            throw IndoorNavigationInputError.invalidCapacity
        }
        self.agentRadius = agentRadius
        self.obstacleClearance = obstacleClearance
        self.maximumStepHeight = maximumStepHeight
        self.maximumStartAge = maximumStartAge
        self.maximumEvidenceAge = maximumEvidenceAge
        self.maximumFutureTimestampSkew = maximumFutureTimestampSkew
        self.maximumStartSnapDistance = maximumStartSnapDistance
        self.maximumDestinationSnapDistance = maximumDestinationSnapDistance
        self.minimumEvidenceConfidence = minimumEvidenceConfidence
        self.minimumDestinationConfidence = minimumDestinationConfidence
        self.maximumFloorCells = maximumFloorCells
        self.maximumMeshCells = maximumMeshCells
        self.maximumDoors = maximumDoors
        self.maximumWalls = maximumWalls
        self.maximumObstacles = maximumObstacles
        self.maximumExploredNodes = maximumExploredNodes
        self.maximumWaypoints = maximumWaypoints
        self.confidencePolicy = confidencePolicy
    }

    public static let `default` = try! Self()
}

public enum IndoorNavigationStatus: String, Codable, Hashable, Sendable {
    case success
    case unreachable
    case insufficientEvidence
    case invalidStart
    case invalidDestination
    case invalidEvidence
    case capacityExceeded
}

public enum IndoorNavigationReason: String, Codable, Hashable, Sendable {
    case routeFound
    case alreadyAtDestination
    case evidenceCoverageIncomplete
    case startFrameMismatch
    case startTrackingUnavailable
    case startPoseStale
    case evidenceStale
    case destinationMapMismatch
    case destinationFrameMismatch
    case destinationNotConfirmed
    case destinationRemoved
    case destinationTrackingUnavailable
    case destinationConfidenceTooLow
    case duplicateEvidence
    case inconsistentDoorEvidence
    case nonFiniteDerivedCoordinate
    case endpointOutsideObservedFreeSpace
    case gridResolutionCannotProveClearance
    case uncertainRouteEvidence
    case noTraversableObservedRoute
    case inputCapacityExceeded
    case explorationCapacityExceeded
    case waypointCapacityExceeded
}

public enum IndoorNavigationPathQuality: String, Codable, Hashable, Sendable {
    case direct
    case efficientDetour
    case extendedDetour
}

public struct IndoorNavigationWaypoint: Codable, Hashable, Sendable {
    public let cell: IndoorNavigationCell
    public let position: Vec3
    public let evidenceConfidence: ConfidenceScore

    public init(
        cell: IndoorNavigationCell,
        position: Vec3,
        evidenceConfidence: ConfidenceScore
    ) {
        self.cell = cell
        self.position = position
        self.evidenceConfidence = evidenceConfidence
    }
}

public struct IndoorNavigationPath: Codable, Hashable, Sendable {
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let destinationObjectID: ObjectID
    public let evidenceRevision: UInt64
    public let waypoints: [IndoorNavigationWaypoint]
    public let totalDistance: Double
    public let straightLineDistance: Double
    public let quality: IndoorNavigationPathQuality
    public let confidenceScore: ConfidenceScore
    public let confidence: ConfidenceGrade
    public let exploredNodeCount: Int

    public init(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        destinationObjectID: ObjectID,
        evidenceRevision: UInt64,
        waypoints: [IndoorNavigationWaypoint],
        totalDistance: Double,
        straightLineDistance: Double,
        quality: IndoorNavigationPathQuality,
        confidenceScore: ConfidenceScore,
        confidence: ConfidenceGrade,
        exploredNodeCount: Int
    ) throws {
        guard !waypoints.isEmpty, totalDistance.isFinite, straightLineDistance.isFinite,
            totalDistance >= 0, straightLineDistance >= 0, exploredNodeCount > 0
        else {
            throw IndoorNavigationInputError.invalidPath
        }
        let computedDistance = zip(waypoints, waypoints.dropFirst()).reduce(0.0) {
            $0 + $1.0.position.distance(to: $1.1.position)
        }
        let tolerance = max(1e-8, computedDistance * 1e-8)
        let computedStraight = waypoints.first!.position.distance(to: waypoints.last!.position)
        guard abs(computedDistance - totalDistance) <= tolerance,
            abs(computedStraight - straightLineDistance) <= tolerance,
            totalDistance + tolerance >= straightLineDistance,
            quality
                == indoorNavigationPathQuality(
                    distance: totalDistance,
                    straight: straightLineDistance
                )
        else {
            throw IndoorNavigationInputError.invalidPath
        }
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        self.destinationObjectID = destinationObjectID
        self.evidenceRevision = evidenceRevision
        self.waypoints = waypoints
        self.totalDistance = totalDistance
        self.straightLineDistance = straightLineDistance
        self.quality = quality
        self.confidenceScore = confidenceScore
        self.confidence = confidence
        self.exploredNodeCount = exploredNodeCount
    }
}

public struct IndoorNavigationResult: Codable, Hashable, Sendable {
    public let status: IndoorNavigationStatus
    public let reason: IndoorNavigationReason
    public let path: IndoorNavigationPath?

    public init(
        status: IndoorNavigationStatus,
        reason: IndoorNavigationReason,
        path: IndoorNavigationPath? = nil
    ) throws {
        guard (status == .success) == (path != nil) else {
            throw IndoorNavigationInputError.invalidResult
        }
        let successReason = reason == .routeFound || reason == .alreadyAtDestination
        guard (status == .success) == successReason else {
            throw IndoorNavigationInputError.invalidResult
        }
        guard Self.accepts(reason: reason, for: status) else {
            throw IndoorNavigationInputError.invalidResult
        }
        self.status = status
        self.reason = reason
        self.path = path
    }

    private static func accepts(
        reason: IndoorNavigationReason,
        for status: IndoorNavigationStatus
    ) -> Bool {
        switch status {
        case .success:
            return reason == .routeFound || reason == .alreadyAtDestination
        case .unreachable:
            return reason == .noTraversableObservedRoute
        case .insufficientEvidence:
            return reason == .evidenceCoverageIncomplete
                || reason == .endpointOutsideObservedFreeSpace
                || reason == .gridResolutionCannotProveClearance
                || reason == .uncertainRouteEvidence
        case .invalidStart:
            return reason == .startFrameMismatch || reason == .startTrackingUnavailable
                || reason == .startPoseStale
        case .invalidDestination:
            return reason == .destinationMapMismatch || reason == .destinationFrameMismatch
                || reason == .destinationNotConfirmed || reason == .destinationRemoved
                || reason == .destinationTrackingUnavailable
                || reason == .destinationConfidenceTooLow
        case .invalidEvidence:
            return reason == .duplicateEvidence || reason == .inconsistentDoorEvidence
                || reason == .nonFiniteDerivedCoordinate || reason == .evidenceStale
        case .capacityExceeded:
            return reason == .inputCapacityExceeded
                || reason == .explorationCapacityExceeded
                || reason == .waypointCapacityExceeded
        }
    }
}

/// Conservative, deterministic indoor routing over observed evidence only.
/// The destination parameter is durable metadata by design, so callers cannot
/// pass an unproven coordinate from an LLM or a natural-language parser.
public struct IndoorARNavigationEngine: Sendable {
    public let policy: IndoorNavigationPolicy

    public init(policy: IndoorNavigationPolicy = .default) {
        self.policy = policy
    }

    public func route(
        from start: FramedPosition,
        to destination: SpatialObjectMetadata,
        using evidence: IndoorNavigationEvidence
    ) -> IndoorNavigationResult {
        route(from: start, to: destination, using: evidence, evaluatedAt: evidence.observedAt)
    }

    /// All timestamps must use the capture session's monotonic clock. Live callers
    /// supply the current evaluation time; the compatibility overload evaluates
    /// at the evidence snapshot's time without changing any observation timestamp.
    public func route(
        from start: FramedPosition,
        to destination: SpatialObjectMetadata,
        using evidence: IndoorNavigationEvidence,
        evaluatedAt: TimeInterval
    ) -> IndoorNavigationResult {
        if Task.isCancelled {
            return result(.insufficientEvidence, .evidenceCoverageIncomplete)
        }
        if let capacityReason = capacityFailure(evidence) {
            return result(.capacityExceeded, capacityReason)
        }
        if !evidence.completeness.isComplete {
            return result(.insufficientEvidence, .evidenceCoverageIncomplete)
        }
        let requiredCellWidth = 2 * (policy.agentRadius + policy.obstacleClearance)
        if evidence.cellSize + IndoorNavigationGeometry.epsilon < requiredCellWidth {
            return result(.insufficientEvidence, .gridResolutionCannotProveClearance)
        }
        if start.coordinateFrameID != evidence.coordinateFrameID {
            return result(.invalidStart, .startFrameMismatch)
        }
        if start.trackingQuality != .normal || !isUsableUncertainty(start.uncertainty) {
            return result(.invalidStart, .startTrackingUnavailable)
        }
        guard evaluatedAt.isFinite, evaluatedAt >= 0 else {
            return result(.invalidEvidence, .evidenceStale)
        }
        if !isFresh(start.observedAt, at: evaluatedAt, maximumAge: policy.maximumStartAge) {
            return result(.invalidStart, .startPoseStale)
        }
        if !isFresh(evidence.observedAt, at: evaluatedAt, maximumAge: policy.maximumEvidenceAge) {
            return result(.invalidEvidence, .evidenceStale)
        }
        if destination.mapID != evidence.mapID {
            return result(.invalidDestination, .destinationMapMismatch)
        }
        if destination.position.coordinateFrameID != evidence.coordinateFrameID {
            return result(.invalidDestination, .destinationFrameMismatch)
        }
        if destination.object.certainty != .confirmed {
            return result(.invalidDestination, .destinationNotConfirmed)
        }
        if destination.object.presence == .removed {
            return result(.invalidDestination, .destinationRemoved)
        }
        if destination.position.trackingQuality != .normal
            || !isUsableUncertainty(destination.position.uncertainty)
        {
            return result(.invalidDestination, .destinationTrackingUnavailable)
        }
        let destinationConfidence = minimum([
            destination.object.confidence.geometry,
            destination.object.confidence.identity,
            destination.object.confidence.place,
        ])
        if destinationConfidence < policy.minimumDestinationConfidence {
            return result(.invalidDestination, .destinationConfidenceTooLow)
        }

        let validation = validateEvidence(evidence)
        guard validation.reason == nil else {
            return result(.invalidEvidence, validation.reason!)
        }
        let trusted = buildGraph(
            evidence: evidence,
            floors: validation.floors,
            mesh: validation.mesh,
            allowUncertain: false
        )
        guard trusted.reason == nil else {
            return result(.invalidEvidence, trusted.reason!)
        }
        let possible = buildGraph(
            evidence: evidence,
            floors: validation.floors,
            mesh: validation.mesh,
            allowUncertain: true
        )
        guard possible.reason == nil else {
            return result(.invalidEvidence, possible.reason!)
        }
        if Task.isCancelled {
            return result(.insufficientEvidence, .evidenceCoverageIncomplete)
        }

        let trustedStart = connectedStartCell(for: start.value, graph: trusted, evidence: evidence)
        let trustedGoal = connectedDestinationCell(
            for: destination, graph: trusted, evidence: evidence,
            validation: validation, allowUncertain: false, reachableFrom: trustedStart
        )
        guard let trustedStart, let trustedGoal else {
            let possibleStart = connectedStartCell(for: start.value, graph: possible, evidence: evidence)
            let possibleGoal = connectedDestinationCell(
                for: destination, graph: possible, evidence: evidence,
                validation: validation, allowUncertain: true, reachableFrom: possibleStart
            )
            let reason: IndoorNavigationReason =
                possibleStart != nil && possibleGoal != nil
                ? .uncertainRouteEvidence : .endpointOutsideObservedFreeSpace
            return result(.insufficientEvidence, reason)
        }

        let search = shortestPath(from: trustedStart, to: trustedGoal.cell, graph: trusted)
        if Task.isCancelled {
            return result(.insufficientEvidence, .evidenceCoverageIncomplete)
        }
        if search.capacityExceeded {
            return result(.capacityExceeded, .explorationCapacityExceeded)
        }
        guard let cells = search.cells else {
            let possibleStart = connectedStartCell(for: start.value, graph: possible, evidence: evidence)
            let diagnostic = shortestPath(
                from: possibleStart,
                to: connectedDestinationCell(
                    for: destination, graph: possible, evidence: evidence,
                    validation: validation, allowUncertain: true, reachableFrom: possibleStart
                )?.cell,
                graph: possible
            )
            if diagnostic.cells != nil || diagnostic.capacityExceeded {
                return result(.insufficientEvidence, .uncertainRouteEvidence)
            }
            return result(.unreachable, .noTraversableObservedRoute)
        }
        guard cells.count <= policy.maximumWaypoints else {
            return result(.capacityExceeded, .waypointCapacityExceeded)
        }

        var waypoints = cells.compactMap { cell -> IndoorNavigationWaypoint? in
            guard let node = trusted.nodes[cell] else { return nil }
            return IndoorNavigationWaypoint(
                cell: cell,
                position: node.position,
                evidenceConfidence: node.confidence
            )
        }
        guard waypoints.count == cells.count else {
            return result(.invalidEvidence, .nonFiniteDerivedCoordinate)
        }
        // Preserve the verified connector in the output rather than presenting
        // a route that silently starts at a different position.
        if let first = waypoints.first,
            first.position.distance(to: start.value) > IndoorNavigationGeometry.epsilon
        {
            guard waypoints.count < policy.maximumWaypoints else {
                return result(.capacityExceeded, .waypointCapacityExceeded)
            }
            waypoints.insert(
                IndoorNavigationWaypoint(
                    cell: trustedStart,
                    position: start.value,
                    evidenceConfidence: first.evidenceConfidence
                ),
                at: 0
            )
        }
        let distance = zip(waypoints, waypoints.dropFirst()).reduce(0.0) {
            $0 + $1.0.position.distance(to: $1.1.position)
        }
        let straight = waypoints.first!.position.distance(to: waypoints.last!.position)
        let routeConfidence = minimum(
            waypoints.map(\.evidenceConfidence)
                + cells.adjacentPairs().compactMap { trusted.edgeConfidence[$0] }
                + [destinationConfidence, trustedGoal.confidence]
        )
        let quality = indoorNavigationPathQuality(distance: distance, straight: straight)
        let path = try! IndoorNavigationPath(
            mapID: evidence.mapID,
            coordinateFrameID: evidence.coordinateFrameID,
            destinationObjectID: destination.object.id,
            evidenceRevision: evidence.revision,
            waypoints: waypoints,
            totalDistance: distance,
            straightLineDistance: straight,
            quality: quality,
            confidenceScore: routeConfidence,
            confidence: policy.confidencePolicy.grade(for: routeConfidence),
            exploredNodeCount: search.explored
        )
        return try! IndoorNavigationResult(
            status: .success,
            reason: waypoints.count == 1 ? .alreadyAtDestination : .routeFound,
            path: path
        )
    }

    private func capacityFailure(_ evidence: IndoorNavigationEvidence) -> IndoorNavigationReason? {
        guard evidence.floors.count <= policy.maximumFloorCells,
            evidence.mesh.count <= policy.maximumMeshCells,
            evidence.doors.count <= policy.maximumDoors,
            evidence.walls.count <= policy.maximumWalls,
            evidence.obstacles.count <= policy.maximumObstacles
        else { return .inputCapacityExceeded }
        return nil
    }

    private func validateEvidence(_ evidence: IndoorNavigationEvidence) -> EvidenceValidation {
        let floors = Dictionary(grouping: evidence.floors, by: \.cell)
        let mesh = Dictionary(grouping: evidence.mesh, by: \.cell)
        guard floors.values.allSatisfy({ $0.count == 1 }),
            mesh.values.allSatisfy({ $0.count == 1 }),
            Set(evidence.doors.map(\.identifier)).count == evidence.doors.count,
            Set(evidence.doors.map { CellPair($0.firstCell, $0.secondCell) }).count
                == evidence.doors.count,
            Set(evidence.walls.map(\.identifier)).count == evidence.walls.count,
            Set(evidence.obstacles.map(\.identifier)).count == evidence.obstacles.count
        else {
            return EvidenceValidation(floors: [:], mesh: [:], reason: .duplicateEvidence)
        }
        let flatFloors = floors.mapValues { $0[0] }
        let flatMesh = mesh.mapValues { $0[0] }
        for door in evidence.doors {
            if Task.isCancelled {
                return EvidenceValidation(
                    floors: flatFloors,
                    mesh: flatMesh,
                    reason: .nonFiniteDerivedCoordinate
                )
            }
            guard let first = flatFloors[door.firstCell],
                let second = flatFloors[door.secondCell],
                first.zoneIdentifier != second.zoneIdentifier
            else {
                return EvidenceValidation(
                    floors: flatFloors,
                    mesh: flatMesh,
                    reason: .inconsistentDoorEvidence
                )
            }
        }
        return EvidenceValidation(floors: flatFloors, mesh: flatMesh, reason: nil)
    }

    private func buildGraph(
        evidence: IndoorNavigationEvidence,
        floors: [IndoorNavigationCell: IndoorNavigationFloorEvidence],
        mesh: [IndoorNavigationCell: IndoorNavigationMeshEvidence],
        allowUncertain: Bool
    ) -> BuiltGraph {
        var nodes: [IndoorNavigationCell: GraphNode] = [:]
        for cell in floors.keys.sorted() {
            if Task.isCancelled {
                return BuiltGraph(reason: .nonFiniteDerivedCoordinate)
            }
            guard let floor = floors[cell], let meshCell = mesh[cell] else { continue }
            let meshCanPass =
                allowUncertain
                ? meshCell.occupancy != .blocked
                : meshCell.occupancy == .free
            let confidenceCanPass =
                allowUncertain
                || (floor.confidence >= policy.minimumEvidenceConfidence
                    && meshCell.confidence >= policy.minimumEvidenceConfidence)
            guard meshCanPass, confidenceCanPass else { continue }
            guard
                let position = derivedPosition(
                    cell: cell,
                    elevation: floor.elevation,
                    evidence: evidence
                )
            else {
                return BuiltGraph(reason: .nonFiniteDerivedCoordinate)
            }
            let confidence = minimum([floor.confidence, meshCell.confidence])
            guard !isPointBlocked(position, evidence: evidence) else { continue }
            nodes[cell] = GraphNode(
                position: position,
                zoneIdentifier: floor.zoneIdentifier,
                confidence: confidence
            )
        }

        var adjacency: [IndoorNavigationCell: [GraphEdge]] = [:]
        var edgeConfidence: [CellPair: ConfidenceScore] = [:]
        for cell in nodes.keys.sorted() {
            if Task.isCancelled {
                return BuiltGraph(reason: .nonFiniteDerivedCoordinate)
            }
            for neighbor in horizontalNeighbors(of: cell).filter({ $0 > cell }) {
                if Task.isCancelled {
                    return BuiltGraph(reason: .nonFiniteDerivedCoordinate)
                }
                guard let source = nodes[cell], let target = nodes[neighbor] else { continue }
                guard abs(source.position.y - target.position.y) <= policy.maximumStepHeight else {
                    continue
                }
                let portal = evidence.doors
                    .filter { $0.connects(cell, neighbor) }
                    .sorted { $0.identifier < $1.identifier }
                    .first
                let crossesZone = source.zoneIdentifier != target.zoneIdentifier
                if crossesZone {
                    guard let portal else { continue }
                    let requiredDoorWidth = 2 * (policy.agentRadius + policy.obstacleClearance)
                    if allowUncertain {
                        guard portal.state != .closed,
                            portal.clearWidth + IndoorNavigationGeometry.epsilon
                                >= requiredDoorWidth
                                || portal.confidence < policy.minimumEvidenceConfidence
                        else { continue }
                    } else {
                        guard portal.state == .open,
                            portal.confidence >= policy.minimumEvidenceConfidence,
                            portal.clearWidth + IndoorNavigationGeometry.epsilon
                                >= requiredDoorWidth
                        else { continue }
                    }
                }
                let trustedPortal = crossesZone ? portal : nil
                guard
                    isEdgeClear(
                        from: source.position,
                        to: target.position,
                        portal: trustedPortal,
                        allowUncertainPortal: allowUncertain,
                        evidence: evidence
                    )
                else { continue }
                let distance = source.position.distance(to: target.position)
                var confidence = minimum([source.confidence, target.confidence])
                if let trustedPortal {
                    confidence = min(confidence, trustedPortal.confidence)
                }
                adjacency[cell, default: []].append(
                    GraphEdge(destination: neighbor, distance: distance, confidence: confidence)
                )
                adjacency[neighbor, default: []].append(
                    GraphEdge(destination: cell, distance: distance, confidence: confidence)
                )
                edgeConfidence[CellPair(cell, neighbor)] = confidence
            }
        }
        for key in adjacency.keys {
            adjacency[key]?.sort { $0.destination < $1.destination }
        }
        // Label reachability once in O(nodes + edges), bounded by the validated
        // input graph. Endpoint selection can then prefer an accessible side
        // without running a separate path search for every candidate.
        var components: [IndoorNavigationCell: IndoorNavigationCell] = [:]
        for seed in nodes.keys.sorted() where components[seed] == nil {
            var queue = [seed]
            var index = 0
            components[seed] = seed
            while index < queue.count {
                guard !Task.isCancelled else {
                    return BuiltGraph(reason: .nonFiniteDerivedCoordinate)
                }
                let current = queue[index]
                index += 1
                for edge in adjacency[current] ?? [] where components[edge.destination] == nil {
                    components[edge.destination] = seed
                    queue.append(edge.destination)
                }
            }
        }
        return BuiltGraph(
            nodes: nodes, adjacency: adjacency, edgeConfidence: edgeConfidence, components: components
        )
    }

    private func derivedPosition(
        cell: IndoorNavigationCell,
        elevation: Double,
        evidence: IndoorNavigationEvidence
    ) -> Vec3? {
        let x = evidence.gridOrigin.x + Double(cell.column) * evidence.cellSize
        let z = evidence.gridOrigin.z + Double(cell.row) * evidence.cellSize
        return try? Vec3(x: x, y: elevation, z: z)
    }

    private func isPointBlocked(_ point: Vec3, evidence: IndoorNavigationEvidence) -> Bool {
        let clearance = policy.agentRadius + policy.obstacleClearance
        for wall in evidence.walls {
            let barrier = Segment2D(start: wall.start, end: wall.end)
            if IndoorNavigationGeometry.pointSegmentDistance(point, barrier)
                < policy.agentRadius + wall.thickness / 2
                - IndoorNavigationGeometry.epsilon
            {
                return true
            }
        }
        for obstacle in evidence.obstacles {
            guard obstacle.bounds.max.y > point.y + IndoorNavigationGeometry.epsilon,
                obstacle.bounds.min.y < point.y + 2.0
            else { continue }
            if IndoorNavigationGeometry.pointRectangleDistance(point, obstacle.bounds) < clearance {
                return true
            }
        }
        return false
    }

    private func isEdgeClear(
        from start: Vec3,
        to end: Vec3,
        portal: IndoorNavigationDoorEvidence?,
        allowUncertainPortal: Bool,
        evidence: IndoorNavigationEvidence,
        excludingObstacleIdentifiers: Set<String> = []
    ) -> Bool {
        let segment = Segment2D(start: start, end: end)
        for wall in evidence.walls {
            let barrier = Segment2D(start: wall.start, end: wall.end)
            let required = policy.agentRadius + wall.thickness / 2
            let wallDistance = IndoorNavigationGeometry.segmentDistance(segment, barrier)
            if wallDistance
                < required - IndoorNavigationGeometry.epsilon
            {
                // An explicitly open cross-zone portal represents the measured
                // opening in a coarse wall segment and exempts only that exact edge.
                guard let portal,
                    portal.state == .open
                        || (allowUncertainPortal && portal.state == .unknown),
                    wallDistance <= IndoorNavigationGeometry.epsilon
                else { return false }
            }
        }
        let required = policy.agentRadius + policy.obstacleClearance
        for obstacle in evidence.obstacles {
            guard !excludingObstacleIdentifiers.contains(obstacle.identifier) else { continue }
            guard obstacle.bounds.max.y > min(start.y, end.y) + IndoorNavigationGeometry.epsilon,
                obstacle.bounds.min.y < max(start.y, end.y) + 2.0
            else { continue }
            if IndoorNavigationGeometry.segmentRectangleDistance(segment, obstacle.bounds)
                < required - IndoorNavigationGeometry.epsilon
            {
                return false
            }
        }
        return true
    }

    /// Stop beside an occupied target, but prove the approach without granting
    /// passage through unrelated obstacles, walls, or unobserved grid cells.
    /// The route graph itself never exempts the target obstacle.
    private func connectedDestinationCell(
        for destination: SpatialObjectMetadata,
        graph: BuiltGraph,
        evidence: IndoorNavigationEvidence,
        validation: EvidenceValidation,
        allowUncertain: Bool,
        reachableFrom start: IndoorNavigationCell?
    ) -> (cell: IndoorNavigationCell, confidence: ConfidenceScore)? {
        let point = destination.position.value
        let targetObstacles = Set(
            evidence.obstacles.filter {
                $0.objectID == destination.object.id && $0.bounds.contains(point)
            }.map(\.identifier))
        let startComponent = start.flatMap { graph.components[$0] }
        let candidates = graph.nodes
            .map {
                (
                    cell: $0.key, distance: $0.value.position.distance(to: point),
                    reachable: startComponent != nil && graph.components[$0.key] == startComponent
                )
            }
            .filter {
                $0.distance <= policy.maximumDestinationSnapDistance + IndoorNavigationGeometry.epsilon
            }
            .sorted {
                if $0.reachable != $1.reachable { return $0.reachable }
                if abs($0.distance - $1.distance) > IndoorNavigationGeometry.epsilon {
                    return $0.distance < $1.distance
                }
                return $0.cell < $1.cell
            }
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            guard let node = graph.nodes[candidate.cell],
                let endpoint = try? Vec3(x: point.x, y: node.position.y, z: point.z),
                isEdgeClear(
                    from: node.position, to: endpoint, portal: nil,
                    allowUncertainPortal: false, evidence: evidence,
                    excludingObstacleIdentifiers: targetObstacles
                ),
                let confidence = destinationConnectorConfidence(
                    from: node, to: endpoint, cell: candidate.cell,
                    evidence: evidence, validation: validation, allowUncertain: allowUncertain
                )
            else { continue }
            // If no reachable connector exists, keep the nearest locally valid
            // disconnected candidate so the caller can still diagnose an
            // unreachable route separately from missing endpoint evidence.
            return (candidate.cell, confidence)
        }
        return nil
    }

    private func destinationConnectorConfidence(
        from node: GraphNode,
        to endpoint: Vec3,
        cell: IndoorNavigationCell,
        evidence: IndoorNavigationEvidence,
        validation: EvidenceValidation,
        allowUncertain: Bool
    ) -> ConfidenceScore? {
        let clearance = policy.agentRadius + policy.obstacleClearance
        let halfCell = evidence.cellSize / 2
        let start = node.position
        // Bound the swept capsule, not just its endpoints. Checked conversion
        // and a cell budget keep even extreme injected coordinates bounded.
        guard
            let minColumn = Int(
                exactly: floor(
                    (min(start.x, endpoint.x) - clearance - evidence.gridOrigin.x) / evidence.cellSize + 0.5
                )),
            let maxColumn = Int(
                exactly: floor(
                    (max(start.x, endpoint.x) + clearance - evidence.gridOrigin.x) / evidence.cellSize + 0.5
                )),
            let minRow = Int(
                exactly: floor(
                    (min(start.z, endpoint.z) - clearance - evidence.gridOrigin.z) / evidence.cellSize + 0.5
                )),
            let maxRow = Int(
                exactly: floor(
                    (max(start.z, endpoint.z) + clearance - evidence.gridOrigin.z) / evidence.cellSize + 0.5
                ))
        else { return nil }
        let (columnSpan, columnOverflow) = maxColumn.subtractingReportingOverflow(minColumn)
        let (rowSpan, rowOverflow) = maxRow.subtractingReportingOverflow(minRow)
        guard !columnOverflow, !rowOverflow, columnSpan >= 0, rowSpan >= 0,
            columnSpan < policy.maximumFloorCells, rowSpan < policy.maximumFloorCells,
            columnSpan + 1 <= policy.maximumFloorCells / (rowSpan + 1)
        else { return nil }
        let segment = Segment2D(start: start, end: endpoint)
        var confidence = node.confidence
        for column in minColumn...maxColumn {
            for row in minRow...maxRow {
                guard !Task.isCancelled else { return nil }
                let neighbor = IndoorNavigationCell(level: cell.level, column: column, row: row)
                guard
                    let center = derivedPosition(
                        cell: neighbor, elevation: start.y, evidence: evidence
                    ),
                    let bounds = try? AABB(
                        min: Vec3(x: center.x - halfCell, y: 0, z: center.z - halfCell),
                        max: Vec3(x: center.x + halfCell, y: 1, z: center.z + halfCell)
                    )
                else { return nil }
                guard
                    IndoorNavigationGeometry.segmentRectangleDistance(segment, bounds)
                        < clearance - IndoorNavigationGeometry.epsilon
                else { continue }
                // Target identity may exempt its explicit bounds, never an
                // unowned blocked mesh cell or an unverified zone transition.
                guard let floor = validation.floors[neighbor],
                    let mesh = validation.mesh[neighbor],
                    floor.zoneIdentifier == node.zoneIdentifier,
                    abs(floor.elevation - start.y) <= policy.maximumStepHeight,
                    mesh.occupancy == .free || (allowUncertain && mesh.occupancy == .unknown),
                    allowUncertain
                        || (floor.confidence >= policy.minimumEvidenceConfidence
                            && mesh.confidence >= policy.minimumEvidenceConfidence)
                else { return nil }
                confidence = min(confidence, min(floor.confidence, mesh.confidence))
            }
        }
        return confidence
    }

    /// A start may join only the free cell that actually contains it. Nearby
    /// cells cannot grant passage through a blocked or unobserved start region.
    private func connectedStartCell(
        for point: Vec3,
        graph: BuiltGraph,
        evidence: IndoorNavigationEvidence
    ) -> IndoorNavigationCell? {
        let columnValue = floor((point.x - evidence.gridOrigin.x) / evidence.cellSize + 0.5)
        let rowValue = floor((point.z - evidence.gridOrigin.z) / evidence.cellSize + 0.5)
        guard let column = Int(exactly: columnValue), let row = Int(exactly: rowValue) else {
            return nil
        }
        let candidates = graph.nodes.filter {
            $0.key.column == column && $0.key.row == row
                && abs($0.value.position.y - point.y) <= policy.maximumStepHeight
                && $0.value.position.distance(to: point)
                    <= policy.maximumStartSnapDistance + IndoorNavigationGeometry.epsilon
        }.sorted {
            let lhs = $0.value.position.distance(to: point)
            let rhs = $1.value.position.distance(to: point)
            if abs(lhs - rhs) > IndoorNavigationGeometry.epsilon { return lhs < rhs }
            return $0.key < $1.key
        }
        for (cell, node) in candidates {
            guard !isPointBlocked(point, evidence: evidence),
                isEdgeClear(
                    from: point,
                    to: node.position,
                    portal: nil,
                    allowUncertainPortal: false,
                    evidence: evidence
                ),
                connectorHasObservedClearance(
                    from: point, to: node, cell: cell, graph: graph, evidence: evidence
                )
            else { continue }
            return cell
        }
        return nil
    }

    /// The swept clearance around an off-center connector can overlap adjacent
    /// cells. Every overlapped cell must be represented in the selected graph;
    /// unknown coverage and unverified zone transitions cannot be skipped.
    private func connectorHasObservedClearance(
        from start: Vec3,
        to target: GraphNode,
        cell: IndoorNavigationCell,
        graph: BuiltGraph,
        evidence: IndoorNavigationEvidence
    ) -> Bool {
        let clearance = policy.agentRadius + policy.obstacleClearance
        let halfCell = evidence.cellSize / 2
        let segment = Segment2D(start: start, end: target.position)
        // Routing already requires cellSize >= 2 * clearance. Since the start
        // is in this cell, its connector's footprint touches at most 3 x 3 cells.
        for columnOffset in -1...1 {
            for rowOffset in -1...1 {
                let (column, columnOverflow) = cell.column.addingReportingOverflow(columnOffset)
                let (row, rowOverflow) = cell.row.addingReportingOverflow(rowOffset)
                guard !columnOverflow, !rowOverflow else { return false }
                let neighbor = IndoorNavigationCell(level: cell.level, column: column, row: row)
                guard
                    let center = derivedPosition(
                        cell: neighbor, elevation: target.position.y, evidence: evidence
                    ),
                    let bounds = try? AABB(
                        min: Vec3(x: center.x - halfCell, y: 0, z: center.z - halfCell),
                        max: Vec3(x: center.x + halfCell, y: 1, z: center.z + halfCell)
                    )
                else { return false }
                guard
                    IndoorNavigationGeometry.segmentRectangleDistance(segment, bounds)
                        < clearance - IndoorNavigationGeometry.epsilon
                else { continue }
                guard let observed = graph.nodes[neighbor],
                    observed.zoneIdentifier == target.zoneIdentifier,
                    abs(observed.position.y - target.position.y) <= policy.maximumStepHeight
                else { return false }
            }
        }
        return true
    }

    private func isFresh(
        _ observedAt: TimeInterval,
        at evaluatedAt: TimeInterval,
        maximumAge: TimeInterval
    ) -> Bool {
        let age = evaluatedAt - observedAt
        return age <= maximumAge && age >= -policy.maximumFutureTimestampSkew
    }

    private func shortestPath(
        from start: IndoorNavigationCell?,
        to goal: IndoorNavigationCell?,
        graph: BuiltGraph
    ) -> SearchResult {
        guard let start, let goal else { return SearchResult() }
        if start == goal { return SearchResult(cells: [start], explored: 1) }
        var open: Set<IndoorNavigationCell> = [start]
        var closed: Set<IndoorNavigationCell> = []
        var predecessor: [IndoorNavigationCell: IndoorNavigationCell] = [:]
        var cost: [IndoorNavigationCell: Double] = [start: 0]
        var estimate: [IndoorNavigationCell: Double] = [
            start: graph.nodes[start]!.position.distance(to: graph.nodes[goal]!.position)
        ]
        var explored = 0

        while let current = open.min(by: { lhs, rhs in
            let left = estimate[lhs] ?? .infinity
            let right = estimate[rhs] ?? .infinity
            if abs(left - right) > IndoorNavigationGeometry.epsilon { return left < right }
            let leftCost = cost[lhs] ?? .infinity
            let rightCost = cost[rhs] ?? .infinity
            if abs(leftCost - rightCost) > IndoorNavigationGeometry.epsilon {
                return leftCost < rightCost
            }
            return lhs < rhs
        }) {
            if Task.isCancelled {
                return SearchResult(explored: explored, capacityExceeded: true)
            }
            open.remove(current)
            explored += 1
            if explored > policy.maximumExploredNodes {
                return SearchResult(explored: explored, capacityExceeded: true)
            }
            if current == goal {
                var path = [current]
                var cursor = current
                while let previous = predecessor[cursor] {
                    path.append(previous)
                    cursor = previous
                }
                return SearchResult(cells: path.reversed(), explored: explored)
            }
            closed.insert(current)
            for edge in graph.adjacency[current] ?? [] where !closed.contains(edge.destination) {
                if Task.isCancelled {
                    return SearchResult(explored: explored, capacityExceeded: true)
                }
                let candidate = (cost[current] ?? .infinity) + edge.distance
                let existing = cost[edge.destination] ?? .infinity
                let preferredEqualPredecessor =
                    abs(candidate - existing) <= IndoorNavigationGeometry.epsilon
                    && current < (predecessor[edge.destination] ?? current)
                if candidate < existing - IndoorNavigationGeometry.epsilon
                    || preferredEqualPredecessor
                {
                    predecessor[edge.destination] = current
                    cost[edge.destination] = candidate
                    estimate[edge.destination] =
                        candidate
                        + graph.nodes[edge.destination]!.position.distance(
                            to: graph.nodes[goal]!.position
                        )
                    open.insert(edge.destination)
                }
            }
        }
        return SearchResult(explored: explored)
    }

    private func isUsableUncertainty(_ value: SpatialPositionUncertainty) -> Bool {
        switch value {
        case .mediumConfidenceDepth, .highConfidenceDepth, .raycastEstimate:
            return true
        case .unavailable, .lowConfidenceDepth, .unknown:
            return false
        }
    }

    private func result(
        _ status: IndoorNavigationStatus,
        _ reason: IndoorNavigationReason
    ) -> IndoorNavigationResult {
        try! IndoorNavigationResult(status: status, reason: reason)
    }
}

// MARK: - Validating Codable

extension IndoorNavigationFloorEvidence {
    private enum CodingKeys: String, CodingKey { case cell, zoneIdentifier, elevation, confidence }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                cell: container.decode(IndoorNavigationCell.self, forKey: .cell),
                zoneIdentifier: container.decode(String.self, forKey: .zoneIdentifier),
                elevation: container.decode(Double.self, forKey: .elevation),
                confidence: container.decode(ConfidenceScore.self, forKey: .confidence)
            )
        } catch let error as DecodingError { throw error } catch {
            throw invalidIndoorNavigationDecoding(.elevation, in: container)
        }
    }
}

extension IndoorNavigationDoorEvidence {
    private enum CodingKeys: String, CodingKey {
        case identifier, firstCell, secondCell, state, confidence, clearWidth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                identifier: container.decode(String.self, forKey: .identifier),
                firstCell: container.decode(IndoorNavigationCell.self, forKey: .firstCell),
                secondCell: container.decode(IndoorNavigationCell.self, forKey: .secondCell),
                state: container.decode(IndoorNavigationDoorState.self, forKey: .state),
                confidence: container.decode(ConfidenceScore.self, forKey: .confidence),
                clearWidth: container.decode(Double.self, forKey: .clearWidth)
            )
        } catch let error as DecodingError { throw error } catch {
            throw invalidIndoorNavigationDecoding(.identifier, in: container)
        }
    }
}

extension IndoorNavigationWallEvidence {
    private enum CodingKeys: String, CodingKey {
        case identifier, start, end, thickness, confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                identifier: container.decode(String.self, forKey: .identifier),
                start: container.decode(Vec3.self, forKey: .start),
                end: container.decode(Vec3.self, forKey: .end),
                thickness: container.decode(Double.self, forKey: .thickness),
                confidence: container.decode(ConfidenceScore.self, forKey: .confidence)
            )
        } catch let error as DecodingError { throw error } catch {
            throw invalidIndoorNavigationDecoding(.thickness, in: container)
        }
    }
}

extension IndoorNavigationObstacleEvidence {
    private enum CodingKeys: String, CodingKey {
        case identifier, objectID, bounds, confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                identifier: container.decode(String.self, forKey: .identifier),
                objectID: container.decodeIfPresent(ObjectID.self, forKey: .objectID),
                bounds: container.decode(AABB.self, forKey: .bounds),
                confidence: container.decode(ConfidenceScore.self, forKey: .confidence)
            )
        } catch let error as DecodingError { throw error } catch {
            throw invalidIndoorNavigationDecoding(.bounds, in: container)
        }
    }
}

extension IndoorNavigationEvidence {
    private enum CodingKeys: String, CodingKey {
        case mapID, coordinateFrameID, revision, observedAt, gridOrigin, cellSize
        case floors, mesh, doors, walls, obstacles, completeness
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                mapID: container.decode(MapID.self, forKey: .mapID),
                coordinateFrameID: container.decode(CoordinateFrameID.self, forKey: .coordinateFrameID),
                revision: container.decode(UInt64.self, forKey: .revision),
                observedAt: container.decode(TimeInterval.self, forKey: .observedAt),
                gridOrigin: container.decode(Vec3.self, forKey: .gridOrigin),
                cellSize: container.decode(Double.self, forKey: .cellSize),
                floors: container.decode([IndoorNavigationFloorEvidence].self, forKey: .floors),
                mesh: container.decode([IndoorNavigationMeshEvidence].self, forKey: .mesh),
                doors: container.decode([IndoorNavigationDoorEvidence].self, forKey: .doors),
                walls: container.decode([IndoorNavigationWallEvidence].self, forKey: .walls),
                obstacles: container.decode([IndoorNavigationObstacleEvidence].self, forKey: .obstacles),
                completeness: container.decode(
                    IndoorNavigationEvidenceCompleteness.self, forKey: .completeness)
            )
        } catch let error as DecodingError { throw error } catch {
            throw invalidIndoorNavigationDecoding(.cellSize, in: container)
        }
    }
}

extension IndoorNavigationPolicy {
    private enum CodingKeys: String, CodingKey {
        case agentRadius, obstacleClearance, maximumStepHeight, maximumStartAge, maximumEvidenceAge
        case maximumFutureTimestampSkew, maximumStartSnapDistance
        case maximumDestinationSnapDistance, minimumEvidenceConfidence
        case minimumDestinationConfidence, maximumFloorCells, maximumMeshCells
        case maximumDoors, maximumWalls, maximumObstacles, maximumExploredNodes
        case maximumWaypoints, confidencePolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                agentRadius: container.decode(Double.self, forKey: .agentRadius),
                obstacleClearance: container.decode(Double.self, forKey: .obstacleClearance),
                maximumStepHeight: container.decode(Double.self, forKey: .maximumStepHeight),
                maximumStartAge: container.decode(TimeInterval.self, forKey: .maximumStartAge),
                maximumEvidenceAge: container.decodeIfPresent(TimeInterval.self, forKey: .maximumEvidenceAge)
                    ?? 5,
                maximumFutureTimestampSkew: container.decode(
                    TimeInterval.self, forKey: .maximumFutureTimestampSkew),
                maximumStartSnapDistance: container.decode(Double.self, forKey: .maximumStartSnapDistance),
                maximumDestinationSnapDistance: container.decode(
                    Double.self, forKey: .maximumDestinationSnapDistance),
                minimumEvidenceConfidence: container.decode(
                    ConfidenceScore.self, forKey: .minimumEvidenceConfidence),
                minimumDestinationConfidence: container.decode(
                    ConfidenceScore.self, forKey: .minimumDestinationConfidence),
                maximumFloorCells: container.decode(Int.self, forKey: .maximumFloorCells),
                maximumMeshCells: container.decode(Int.self, forKey: .maximumMeshCells),
                maximumDoors: container.decode(Int.self, forKey: .maximumDoors),
                maximumWalls: container.decode(Int.self, forKey: .maximumWalls),
                maximumObstacles: container.decode(Int.self, forKey: .maximumObstacles),
                maximumExploredNodes: container.decode(Int.self, forKey: .maximumExploredNodes),
                maximumWaypoints: container.decode(Int.self, forKey: .maximumWaypoints),
                confidencePolicy: container.decode(ConfidencePolicy.self, forKey: .confidencePolicy)
            )
        } catch let error as DecodingError { throw error } catch {
            throw invalidIndoorNavigationDecoding(.agentRadius, in: container)
        }
    }
}

extension IndoorNavigationPath {
    private enum CodingKeys: String, CodingKey {
        case mapID, coordinateFrameID, destinationObjectID, evidenceRevision, waypoints
        case totalDistance, straightLineDistance, quality, confidenceScore, confidence
        case exploredNodeCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                mapID: container.decode(MapID.self, forKey: .mapID),
                coordinateFrameID: container.decode(CoordinateFrameID.self, forKey: .coordinateFrameID),
                destinationObjectID: container.decode(ObjectID.self, forKey: .destinationObjectID),
                evidenceRevision: container.decode(UInt64.self, forKey: .evidenceRevision),
                waypoints: container.decode([IndoorNavigationWaypoint].self, forKey: .waypoints),
                totalDistance: container.decode(Double.self, forKey: .totalDistance),
                straightLineDistance: container.decode(Double.self, forKey: .straightLineDistance),
                quality: container.decode(IndoorNavigationPathQuality.self, forKey: .quality),
                confidenceScore: container.decode(ConfidenceScore.self, forKey: .confidenceScore),
                confidence: container.decode(ConfidenceGrade.self, forKey: .confidence),
                exploredNodeCount: container.decode(Int.self, forKey: .exploredNodeCount)
            )
        } catch let error as DecodingError { throw error } catch {
            throw invalidIndoorNavigationDecoding(.waypoints, in: container)
        }
    }
}

extension IndoorNavigationResult {
    private enum CodingKeys: String, CodingKey { case status, reason, path }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                status: container.decode(IndoorNavigationStatus.self, forKey: .status),
                reason: container.decode(IndoorNavigationReason.self, forKey: .reason),
                path: container.decodeIfPresent(IndoorNavigationPath.self, forKey: .path)
            )
        } catch let error as DecodingError { throw error } catch {
            throw invalidIndoorNavigationDecoding(.status, in: container)
        }
    }
}

private struct EvidenceValidation {
    let floors: [IndoorNavigationCell: IndoorNavigationFloorEvidence]
    let mesh: [IndoorNavigationCell: IndoorNavigationMeshEvidence]
    let reason: IndoorNavigationReason?
}

private struct GraphNode {
    let position: Vec3
    let zoneIdentifier: String
    let confidence: ConfidenceScore
}

private struct GraphEdge {
    let destination: IndoorNavigationCell
    let distance: Double
    let confidence: ConfidenceScore
}

private struct CellPair: Hashable {
    let first: IndoorNavigationCell
    let second: IndoorNavigationCell

    init(_ lhs: IndoorNavigationCell, _ rhs: IndoorNavigationCell) {
        first = min(lhs, rhs)
        second = max(lhs, rhs)
    }
}

private struct BuiltGraph {
    var nodes: [IndoorNavigationCell: GraphNode] = [:]
    var adjacency: [IndoorNavigationCell: [GraphEdge]] = [:]
    var edgeConfidence: [CellPair: ConfidenceScore] = [:]
    var components: [IndoorNavigationCell: IndoorNavigationCell] = [:]
    var reason: IndoorNavigationReason?

    init(
        nodes: [IndoorNavigationCell: GraphNode] = [:],
        adjacency: [IndoorNavigationCell: [GraphEdge]] = [:],
        edgeConfidence: [CellPair: ConfidenceScore] = [:],
        components: [IndoorNavigationCell: IndoorNavigationCell] = [:],
        reason: IndoorNavigationReason? = nil
    ) {
        self.nodes = nodes
        self.adjacency = adjacency
        self.edgeConfidence = edgeConfidence
        self.components = components
        self.reason = reason
    }
}

private struct SearchResult {
    var cells: [IndoorNavigationCell]?
    var explored = 0
    var capacityExceeded = false
}

private struct Segment2D {
    let start: Vec3
    let end: Vec3
}

private enum IndoorNavigationGeometry {
    static let epsilon = 1e-9

    static func segmentDistance(_ lhs: Segment2D, _ rhs: Segment2D) -> Double {
        if segmentsIntersect(lhs, rhs) { return 0 }
        return [
            pointSegmentDistance(lhs.start, rhs), pointSegmentDistance(lhs.end, rhs),
            pointSegmentDistance(rhs.start, lhs), pointSegmentDistance(rhs.end, lhs),
        ].min() ?? .infinity
    }

    static func pointRectangleDistance(_ point: Vec3, _ bounds: AABB) -> Double {
        let dx = max(0, max(bounds.min.x - point.x, point.x - bounds.max.x))
        let dz = max(0, max(bounds.min.z - point.z, point.z - bounds.max.z))
        return hypot(dx, dz)
    }

    static func segmentRectangleDistance(_ segment: Segment2D, _ bounds: AABB) -> Double {
        if pointInsideRectangle(segment.start, bounds)
            || pointInsideRectangle(segment.end, bounds)
        {
            return 0
        }
        let corners = [
            try! Vec3(x: bounds.min.x, y: 0, z: bounds.min.z),
            try! Vec3(x: bounds.max.x, y: 0, z: bounds.min.z),
            try! Vec3(x: bounds.max.x, y: 0, z: bounds.max.z),
            try! Vec3(x: bounds.min.x, y: 0, z: bounds.max.z),
        ]
        let edges = corners.indices.map {
            Segment2D(start: corners[$0], end: corners[($0 + 1) % corners.count])
        }
        return edges.map { segmentDistance(segment, $0) }.min() ?? .infinity
    }

    private static func pointInsideRectangle(_ point: Vec3, _ bounds: AABB) -> Bool {
        point.x >= bounds.min.x && point.x <= bounds.max.x
            && point.z >= bounds.min.z && point.z <= bounds.max.z
    }

    static func pointSegmentDistance(_ point: Vec3, _ segment: Segment2D) -> Double {
        let dx = segment.end.x - segment.start.x
        let dz = segment.end.z - segment.start.z
        let lengthSquared = dx * dx + dz * dz
        guard lengthSquared > epsilon else {
            return hypot(point.x - segment.start.x, point.z - segment.start.z)
        }
        let projection =
            ((point.x - segment.start.x) * dx
                + (point.z - segment.start.z) * dz) / lengthSquared
        let t = min(1, max(0, projection))
        return hypot(
            point.x - (segment.start.x + dx * t),
            point.z - (segment.start.z + dz * t)
        )
    }

    private static func segmentsIntersect(_ lhs: Segment2D, _ rhs: Segment2D) -> Bool {
        let o1 = orientation(lhs.start, lhs.end, rhs.start)
        let o2 = orientation(lhs.start, lhs.end, rhs.end)
        let o3 = orientation(rhs.start, rhs.end, lhs.start)
        let o4 = orientation(rhs.start, rhs.end, lhs.end)
        if o1 * o2 < -epsilon && o3 * o4 < -epsilon { return true }
        return (abs(o1) <= epsilon && onSegment(rhs.start, lhs))
            || (abs(o2) <= epsilon && onSegment(rhs.end, lhs))
            || (abs(o3) <= epsilon && onSegment(lhs.start, rhs))
            || (abs(o4) <= epsilon && onSegment(lhs.end, rhs))
    }

    private static func orientation(_ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double {
        (b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x)
    }

    private static func onSegment(_ point: Vec3, _ segment: Segment2D) -> Bool {
        point.x >= min(segment.start.x, segment.end.x) - epsilon
            && point.x <= max(segment.start.x, segment.end.x) + epsilon
            && point.z >= min(segment.start.z, segment.end.z) - epsilon
            && point.z <= max(segment.start.z, segment.end.z) + epsilon
    }
}

extension Array where Element == IndoorNavigationCell {
    fileprivate func adjacentPairs() -> [CellPair] {
        zip(self, dropFirst()).map(CellPair.init)
    }
}

private func horizontalNeighbors(of cell: IndoorNavigationCell) -> [IndoorNavigationCell] {
    var neighbors: [IndoorNavigationCell] = []
    if cell.column > Int.min {
        neighbors.append(.init(level: cell.level, column: cell.column - 1, row: cell.row))
    }
    if cell.column < Int.max {
        neighbors.append(.init(level: cell.level, column: cell.column + 1, row: cell.row))
    }
    if cell.row > Int.min {
        neighbors.append(.init(level: cell.level, column: cell.column, row: cell.row - 1))
    }
    if cell.row < Int.max {
        neighbors.append(.init(level: cell.level, column: cell.column, row: cell.row + 1))
    }
    return neighbors.sorted()
}

private func minimum(_ values: [ConfidenceScore]) -> ConfidenceScore {
    values.min() ?? .zero
}

private func indoorNavigationPathQuality(
    distance: Double,
    straight: Double
) -> IndoorNavigationPathQuality {
    guard straight > IndoorNavigationGeometry.epsilon else { return .direct }
    let ratio = distance / straight
    if ratio <= 1.05 { return .direct }
    if ratio <= 1.50 { return .efficientDetour }
    return .extendedDetour
}

private func indoorNavigationIdentifier(_ value: String) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw IndoorNavigationInputError.emptyIdentifier }
    return normalized
}

private func invalidIndoorNavigationDecoding<Key: CodingKey>(
    _ key: Key,
    in container: KeyedDecodingContainer<Key>
) -> DecodingError {
    DecodingError.dataCorruptedError(
        forKey: key,
        in: container,
        debugDescription: "Indoor navigation value violates a structural invariant."
    )
}
