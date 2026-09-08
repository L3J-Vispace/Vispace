import Foundation

/// Answers only about the presently observed, single-level walking space.
/// Counterfactual obstacle removal is used solely to attribute a blockage; it
/// can never produce a traversable route or an accessibility relation.
public struct ObservedNavigationRelationDeriver: Sendable {
    public init() {}

    public func derive(
        scope: SpatialRelationQueryGeometryScope,
        objects: [SpatialObjectMetadata],
        evidence: IndoorNavigationEvidence,
        cameraStart: FramedPosition,
        segmentID: CaptureSegmentID,
        evaluatedAt: TimeInterval,
        wallTime: TimeInterval,
        objectRevisionEpoch: UInt64? = nil
    ) throws -> SceneGraph {
        var graph = SceneGraph()
        guard !scope.predicate.isGeometryDerived, evidence.completeness.isComplete,
            evaluatedAt.isFinite, wallTime.isFinite, wallTime >= 0,
            evaluatedAt >= evidence.observedAt, evaluatedAt - evidence.observedAt <= 0.75,
            evidence.floors.count <= 12_000, evidence.mesh.count <= 12_000
        else { return graph }
        let eligible = objects.filter {
            $0.mapID == evidence.mapID && $0.position.coordinateFrameID == evidence.coordinateFrameID
                && $0.object.certainty == .confirmed && $0.object.presence == .visible
                && wallTime >= $0.object.lastSeenAt && wallTime - $0.object.lastSeenAt <= 3
                && $0.object.confidence.identity.value >= 0.8
                && $0.object.confidence.geometry.value >= 0.8
        }.sorted { $0.object.id < $1.object.id }
        // Do not silently truncate an ambiguous, dense environment into a
        // positive answer. Query-scoped generation is bounded independently.
        guard eligible.count <= 32, Set(eligible.map { $0.object.id }).count == eligible.count,
            scope.objectIDs.isSubset(of: Set(eligible.map { $0.object.id }))
        else { return graph }
        let engine = IndoorARNavigationEngine()
        let source = SpatialRelationObservationSource(
            mapID: evidence.mapID,
            coordinateFrameID: evidence.coordinateFrameID, segmentID: segmentID,
            surfaceRevision: evidence.revision, observedAt: evidence.observedAt,
            objectRevisionEpoch: objectRevisionEpoch)
        let doorExpiry = evidence.doors.compactMap(\.validUntil).min() ?? (evaluatedAt + 0.75)
        let lifetime = min(0.75 - (evaluatedAt - evidence.observedAt), doorExpiry - evaluatedAt)
        guard lifetime > 0 else { return graph }
        var routeChecks = 0
        for subject in eligible {
            for object in eligible where object.object.id != subject.object.id {
                guard
                    scope.objectIDs.contains(subject.object.id) || scope.objectIDs.contains(object.object.id)
                else { continue }
                if scope.objectIDs.count == 2,
                    !(scope.objectIDs.contains(subject.object.id)
                        && scope.objectIDs.contains(object.object.id))
                {
                    continue
                }
                try Task.checkCancellation()
                routeChecks += 1
                guard routeChecks <= 64 else { return SceneGraph() }
                var confirmed = false
                var confidence = 0.8
                switch scope.predicate {
                case .accessibleFrom, .connectedTo:
                    guard let start = approach(to: object, evidence: evidence, at: evaluatedAt) else {
                        continue
                    }
                    let result = engine.route(
                        from: start, to: subject, using: evidence, evaluatedAt: evaluatedAt)
                    if let path = result.path, path.waypoints.count > 1 {
                        confirmed = true
                        confidence = path.confidenceScore.value
                    }
                case .blocking:
                    // An identified current object must coincide with depth-
                    // blocked cells. Unknown cells remain unknown throughout.
                    let actual = engine.route(
                        from: cameraStart, to: object, using: evidence, evaluatedAt: evaluatedAt)
                    guard actual.status == .unreachable, actual.reason == .noTraversableObservedRoute,
                        let counterfactual = removingObservedBlocker(subject, from: evidence)
                    else { continue }
                    confirmed =
                        engine.route(
                            from: cameraStart, to: object,
                            using: counterfactual, evaluatedAt: evaluatedAt
                        ).path != nil
                default: continue
                }
                guard confirmed, confidence >= 0.8 else { continue }
                let relation = try SpatialRelation(
                    key: RelationKey(
                        subject: .object(subject.object.id), predicate: scope.predicate,
                        object: .object(object.object.id)),
                    confidence: ConfidenceScore(clamping: confidence), certainty: .confirmed,
                    validFrom: wallTime, validUntil: wallTime + lifetime,
                    subjectTemporalRevision: subject.object.temporalRevision,
                    objectTemporalRevision: object.object.temporalRevision,
                    observationSource: source
                )
                try graph.upsert(relation)
            }
        }
        return graph
    }

    private func approach(
        to object: SpatialObjectMetadata, evidence: IndoorNavigationEvidence,
        at timestamp: TimeInterval
    ) -> FramedPosition? {
        let free = Set(evidence.mesh.filter { $0.occupancy == .free }.map(\.cell))
        let candidates = evidence.floors.compactMap { floor -> Vec3? in
            guard free.contains(floor.cell), floor.confidence.value >= 0.8 else { return nil }
            return try? Vec3(
                x: evidence.gridOrigin.x + Double(floor.cell.column) * evidence.cellSize,
                y: floor.elevation, z: evidence.gridOrigin.z + Double(floor.cell.row) * evidence.cellSize)
        }.filter { position in
            let horizontal = hypot(position.x - object.position.value.x, position.z - object.position.value.z)
            return horizontal <= 1
                && abs(position.y - (object.object.bounds?.min.y ?? object.position.value.y)) <= 0.3
                && !evidence.obstacles.contains { obstacle in
                    position.x >= obstacle.bounds.min.x - 0.25 && position.x <= obstacle.bounds.max.x + 0.25
                        && position.z >= obstacle.bounds.min.z - 0.25
                        && position.z <= obstacle.bounds.max.z + 0.25
                }
        }.sorted { $0.distance(to: object.position.value) < $1.distance(to: object.position.value) }
        for position in candidates {
            guard !Task.isCancelled else { return nil }
            guard
                let start = try? FramedPosition(
                    coordinateFrameID: evidence.coordinateFrameID, value: position,
                    observedAt: timestamp, trackingQuality: .normal, uncertainty: .highConfidenceDepth)
            else { continue }
            // Nearby is not connected: the closest free cell may be across a
            // wall or a closed door from the source object. Reuse the engine's
            // endpoint connector proof before treating this as its approach.
            if IndoorARNavigationEngine().route(
                from: start, to: object,
                using: evidence, evaluatedAt: timestamp
            ).path != nil {
                return start
            }
        }
        return nil
    }

    private func removingObservedBlocker(
        _ object: SpatialObjectMetadata,
        from evidence: IndoorNavigationEvidence
    ) -> IndoorNavigationEvidence? {
        guard let bounds = object.object.bounds,
            let obstacle = evidence.obstacles.first(where: { $0.objectID == object.object.id }),
            obstacle.bounds == bounds, obstacle.confidence.value >= 0.8
        else { return nil }
        // Overlapping depth cannot identify which object owns the blocked
        // cells. Do not attribute those cells to one object by AABB alone.
        guard
            !evidence.obstacles.contains(where: { other in
                other.identifier != obstacle.identifier
                    && other.bounds.min.x <= bounds.max.x && other.bounds.max.x >= bounds.min.x
                    && other.bounds.min.y <= bounds.max.y && other.bounds.max.y >= bounds.min.y
                    && other.bounds.min.z <= bounds.max.z && other.bounds.max.z >= bounds.min.z
            })
        else { return nil }
        var replaced = 0
        let half = evidence.cellSize / 2
        let mesh = evidence.mesh.map { cell -> IndoorNavigationMeshEvidence in
            let x = evidence.gridOrigin.x + Double(cell.cell.column) * evidence.cellSize
            let z = evidence.gridOrigin.z + Double(cell.cell.row) * evidence.cellSize
            guard cell.occupancy == .blocked, cell.confidence.value >= 0.8,
                x - half >= bounds.min.x, x + half <= bounds.max.x,
                z - half >= bounds.min.z, z + half <= bounds.max.z
            else { return cell }
            replaced += 1
            return IndoorNavigationMeshEvidence(
                cell: cell.cell, occupancy: .free, confidence: cell.confidence)
        }
        guard replaced > 0 else { return nil }
        return try? IndoorNavigationEvidence(
            mapID: evidence.mapID, coordinateFrameID: evidence.coordinateFrameID,
            revision: evidence.revision, observedAt: evidence.observedAt, gridOrigin: evidence.gridOrigin,
            cellSize: evidence.cellSize, floors: evidence.floors, mesh: mesh, doors: evidence.doors,
            walls: evidence.walls, obstacles: evidence.obstacles.filter { $0.objectID != object.object.id },
            completeness: evidence.completeness)
    }
}
