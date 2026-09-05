import Foundation
import VispaceCore
import simd

/// Converts only densely observed, fully classified LiDAR geometry into a
/// bounded navigation grid. Unknown mesh faces and partially covered cells are
/// excluded rather than interpreted as free space.
public struct ARVerifiedNavigationEvidenceBuilder: Sendable {
    public let cellSize: Double
    public let maximumTriangleCount: Int
    public let maximumCellCount: Int
    public let maximumWallCount: Int
    public let floorHeightTolerance: Double
    public let obstacleClearance: Double
    public let evidenceConfidence: ConfidenceScore

    public init(
        cellSize: Double = 0.50,
        maximumTriangleCount: Int = 60_000,
        maximumCellCount: Int = 12_000,
        maximumWallCount: Int = 8_000,
        floorHeightTolerance: Double = 0.08,
        obstacleClearance: Double = 0.25,
        evidenceConfidence: ConfidenceScore = ConfidenceScore(clamping: 0.85)
    ) {
        self.cellSize = Self.clampedFinite(
            cellSize,
            minimum: 0.50,
            maximum: 2.0,
            fallback: 0.50
        )
        self.maximumTriangleCount = min(max(1, maximumTriangleCount), 100_000)
        self.maximumCellCount = min(max(1, maximumCellCount), 20_000)
        self.maximumWallCount = min(max(1, maximumWallCount), 10_000)
        self.floorHeightTolerance = Self.clampedFinite(
            floorHeightTolerance,
            minimum: 0.01,
            maximum: 0.30,
            fallback: 0.08
        )
        self.obstacleClearance = Self.clampedFinite(
            obstacleClearance,
            minimum: 0.05,
            maximum: 1.0,
            fallback: 0.25
        )
        self.evidenceConfidence = evidenceConfidence
    }

    public func adapt(
        _ snapshot: ARSurfaceStateSnapshot,
        currentIdentity: ARCaptureIdentity,
        currentDepthFrame: ARFrameSnapshot? = nil,
        recentDepthFrames: [ARNavigationDepthFrame] = [],
        dynamicObjects: [SpatialObjectMetadata] = []
    ) -> ARIndoorNavigationEvidenceAdaptation {
        let staticResult = adaptStaticGeometry(snapshot, currentIdentity: currentIdentity)
        guard case .ready(let candidate) = staticResult else { return staticResult }
        guard let frame = currentDepthFrame,
            frame.pose.coordinateFrameStatus == .confirmed,
            frame.pose.trackingState == .normal,
            frame.pose.mapID == snapshot.mapID,
            frame.pose.coordinateFrameID == snapshot.coordinateFrameID,
            frame.pose.segmentID == snapshot.segmentID,
            frame.pose.timestamp.isFinite,
            frame.pose.timestamp - snapshot.timestamp >= -0.25,
            snapshot.hasFreshSurfaces(at: frame.pose.timestamp, maximumAge: 5),
            let currentDepth = ARNavigationDepthFrame(frame)
        else { return .insufficientEvidence(.dynamicOccupancyUnavailable) }

        var seenFrames: Set<ARFrameID> = []
        let frames = ([currentDepth] + recentDepthFrames)
            .filter {
                $0.pose.sessionToken == frame.pose.sessionToken
                    && $0.pose.mapID == frame.pose.mapID
                    && $0.pose.coordinateFrameID == frame.pose.coordinateFrameID
                    && $0.pose.segmentID == frame.pose.segmentID
                    && $0.pose.coordinateFrameStatus == .confirmed
                    && $0.pose.trackingState == .normal
                    && frame.pose.timestamp - $0.pose.timestamp >= 0
                    && frame.pose.timestamp - $0.pose.timestamp <= 3
            }
            .sorted { $0.pose.timestamp > $1.pose.timestamp }
            .filter { seenFrames.insert($0.pose.id).inserted }
            .prefix(16)
        let occupancies = frames.compactMap {
            ARDepthNavigationOccupancy(pose: $0.pose, intrinsics: $0.intrinsics,
                imageDimensions: $0.imageDimensions, depth: $0.depth)
        }
        guard !occupancies.isEmpty, occupancies.count == frames.count else {
            return .insufficientEvidence(.dynamicOccupancyUnavailable)
        }

        var checks = 0
        let elevations = Dictionary(uniqueKeysWithValues: candidate.floors.map { ($0.cell, $0.elevation) })
        let mesh = candidate.mesh.map { cell -> IndoorNavigationMeshEvidence in
            guard cell.occupancy == .free, let elevation = elevations[cell.cell] else { return cell }
            var state: IndoorNavigationMeshOccupancy = .unknown
            for occupancy in occupancies {
                let observation = occupancy.observation(
                    centerX: candidate.gridOrigin.x + Double(cell.cell.column) * cellSize,
                    centerZ: candidate.gridOrigin.z + Double(cell.cell.row) * cellSize,
                    floorElevation: elevation, halfWidth: cellSize / 2,
                    remainingChecks: &checks
                )
                switch observation {
                case .free: state = .free
                case .blocked: state = .blocked
                case .uncertain: state = .unknown
                case .unobserved: continue
                }
                break
            }
            return IndoorNavigationMeshEvidence(cell: cell.cell, occupancy: state, confidence: cell.confidence)
        }
        guard mesh.contains(where: { $0.occupancy == .free }) else {
            return .insufficientEvidence(.dynamicOccupancyUnavailable)
        }
        let currentObjects = dynamicObjects.filter {
            $0.mapID == snapshot.mapID
                && $0.position.coordinateFrameID == snapshot.coordinateFrameID
                && $0.object.presence != .removed
        }
        guard currentObjects.count <= 2_048 else {
            return .insufficientEvidence(.coverageAttestationUnavailable)
        }
        var obstacles: [IndoorNavigationObstacleEvidence] = []
        for record in currentObjects {
            // Keep known objects conservative even when they are temporarily
            // not visible. Fresh depth additionally catches unrecognized motion.
            let position = record.position.value
            guard let bounds = record.object.bounds ?? (try? AABB(
                min: Vec3(x: position.x - 0.35, y: position.y - 0.35, z: position.z - 0.35),
                max: Vec3(x: position.x + 0.35, y: position.y + 0.35, z: position.z + 0.35)
            )), let obstacle = try? IndoorNavigationObstacleEvidence(
                identifier: "object-\(record.object.id.rawValue)", objectID: record.object.id,
                bounds: bounds, confidence: evidenceConfidence
            ) else { return .insufficientEvidence(.coverageAttestationUnavailable) }
            obstacles.append(obstacle)
        }
        guard let verified = try? IndoorNavigationEvidence(
            mapID: candidate.mapID, coordinateFrameID: candidate.coordinateFrameID,
            revision: candidate.revision, observedAt: candidate.observedAt,
            gridOrigin: candidate.gridOrigin, cellSize: candidate.cellSize,
            floors: candidate.floors, mesh: mesh, doors: candidate.doors,
            walls: candidate.walls, obstacles: obstacles, completeness: .complete
        ) else { return .insufficientEvidence(.coverageAttestationUnavailable) }
        return ARSurfaceIndoorNavigationEvidenceAdapter().adapt(
            snapshot, currentIdentity: currentIdentity, verifiedEvidence: verified
        )
    }

    /// Geometry candidate only. Public routing also requires current raw depth
    /// coverage and current object obstacles; static floors do not prove this.
    func adaptStaticGeometry(
        _ snapshot: ARSurfaceStateSnapshot,
        currentIdentity: ARCaptureIdentity
    ) -> ARIndoorNavigationEvidenceAdaptation {
        guard !Task.isCancelled else {
            return .insufficientEvidence(.coverageAttestationUnavailable)
        }
        guard currentIdentity.status == .confirmed,
            snapshot.coordinateFrameStatus == .confirmed
        else {
            return .insufficientEvidence(.captureNotConfirmed)
        }
        guard snapshot.isComplete else {
            return .insufficientEvidence(.surfaceSnapshotIncomplete)
        }
        guard snapshot.hasFreshSurfaces(at: snapshot.timestamp, maximumAge: 5) else {
            return .insufficientEvidence(.surfaceObservationStale)
        }
        guard let mapID = currentIdentity.mapID,
            snapshot.mapID == mapID
        else {
            return .insufficientEvidence(.currentMapUnavailable)
        }
        guard snapshot.coordinateFrameID == currentIdentity.coordinateFrameID,
            snapshot.segmentID == currentIdentity.segmentID
        else {
            return .insufficientEvidence(.coordinateContextMismatch)
        }

        guard let geometry = makeGeometry(from: snapshot),
            let selectedFloor = selectDominantFloor(from: geometry.floorTriangles),
            !geometry.floorPlanes.isEmpty,
            let grid = makeGrid(
                floorTriangles: selectedFloor,
                floorPlanes: geometry.floorPlanes,
                blockingTriangles: geometry.blockingTriangles
            ),
            !grid.floors.isEmpty,
            !grid.mesh.isEmpty,
            let walls = makeWalls(
                from: geometry.barrierSegments,
                nearFloorElevation: grid.referenceElevation
            )
        else {
            return .insufficientEvidence(.coverageAttestationUnavailable)
        }

        guard
            let evidence = try? IndoorNavigationEvidence(
                mapID: mapID,
                coordinateFrameID: snapshot.coordinateFrameID,
                revision: snapshot.revision,
                observedAt: snapshot.timestamp,
                gridOrigin: grid.origin,
                cellSize: cellSize,
                floors: grid.floors,
                mesh: grid.mesh,
                doors: [],
                walls: walls,
                obstacles: [],
                completeness: .complete
            )
        else {
            return .insufficientEvidence(.coverageAttestationUnavailable)
        }
        return ARSurfaceIndoorNavigationEvidenceAdapter().adapt(
            snapshot,
            currentIdentity: currentIdentity,
            verifiedEvidence: evidence
        )
    }

    private func makeGeometry(
        from snapshot: ARSurfaceStateSnapshot
    ) -> NavigationGeometry? {
        var floorPlanes: [WorldFloorPlane] = []
        var planeBlockingTriangles: [WorldTriangle] = []
        var barrierSegments: [WorldBarrierSegment] = []
        var triangleCount = 0
        for plane in snapshot.planes.values.sorted(by: {
            $0.anchorID.uuidString < $1.anchorID.uuidString
        }) {
            guard !Task.isCancelled else {
                return nil
            }
            switch plane.classification {
            case .floor:
                guard plane.alignment == .horizontal,
                    let floorPlane = WorldFloorPlane(plane)
                else {
                    return nil
                }
                floorPlanes.append(floorPlane)
            case .wall, .ceiling, .table, .seat, .window:
                guard let polygon = WorldPlanePolygon(plane),
                    let classification = ARMeshClassificationSnapshot(plane.classification),
                    let triangles = polygon.triangles(classification: classification),
                    triangles.count <= maximumTriangleCount - triangleCount
                else {
                    return nil
                }
                triangleCount += triangles.count
                planeBlockingTriangles.append(contentsOf: triangles)
                if plane.classification == .wall
                    || plane.classification == .window
                {
                    guard let segment = polygon.barrierSegment else {
                        return nil
                    }
                    barrierSegments.append(segment)
                }
            case .door:
                // ARKit identifies door geometry, not a verified open/closed
                // traversal state. A route cannot claim complete portal evidence.
                return nil
            case .none, .unknown:
                // An unclassified plane can conceal an obstacle. Do not attest
                // the surrounding cells as free until ARKit classifies it.
                return nil
            }
        }
        guard !floorPlanes.isEmpty else {
            return nil
        }

        var floorTriangles: [WorldTriangle] = []
        var blockingTriangles = planeBlockingTriangles

        for mesh in snapshot.meshes.values.sorted(by: { $0.anchorID.uuidString < $1.anchorID.uuidString }) {
            guard !Task.isCancelled else {
                return nil
            }
            guard mesh.triangleIndices.count.isMultiple(of: 3) else {
                return nil
            }
            let faceCount = mesh.triangleIndices.count / 3
            guard mesh.faceClassifications.count == faceCount,
                faceCount <= maximumTriangleCount - triangleCount
            else {
                return nil
            }
            triangleCount += faceCount

            for faceIndex in 0..<faceCount {
                guard !Task.isCancelled else {
                    return nil
                }
                let classification = mesh.faceClassifications[faceIndex]
                guard classification != .none, classification != .unknown else {
                    return nil
                }
                let index = faceIndex * 3
                let rawIndices = mesh.triangleIndices[index..<(index + 3)]
                let vertexIndices = rawIndices.map(Int.init)
                guard vertexIndices.allSatisfy({ mesh.vertices.indices.contains($0) }),
                    let triangle = WorldTriangle(
                        localVertices: vertexIndices.map { mesh.vertices[$0] },
                        transform: mesh.transform.simdValue,
                        classification: classification
                    )
                else {
                    return nil
                }

                switch classification {
                case .floor:
                    floorTriangles.append(triangle)
                case .wall, .window:
                    blockingTriangles.append(triangle)
                    guard let segment = WorldBarrierSegment(triangle) else {
                        return nil
                    }
                    barrierSegments.append(segment)
                case .door:
                    return nil
                case .table, .seat, .ceiling:
                    blockingTriangles.append(triangle)
                case .none, .unknown:
                    return nil
                }
            }
        }
        guard triangleCount > 0, !floorTriangles.isEmpty else {
            return nil
        }
        return NavigationGeometry(
            floorPlanes: floorPlanes,
            floorTriangles: floorTriangles,
            blockingTriangles: blockingTriangles,
            barrierSegments: barrierSegments
        )
    }

    private func selectDominantFloor(
        from triangles: [WorldTriangle]
    ) -> [WorldTriangle]? {
        let sorted = triangles.sorted { $0.averageY < $1.averageY }
        guard let first = sorted.first else {
            return nil
        }
        var selected = [first]
        var elevationSum = first.averageY
        for triangle in sorted.dropFirst() {
            guard !Task.isCancelled else {
                return nil
            }
            let mean = elevationSum / Double(selected.count)
            guard abs(mean - triangle.averageY) <= 0.18 else {
                // Without the grounded start pose, selecting one of multiple
                // elevations could hide a step or mezzanine classified as floor.
                return nil
            }
            selected.append(triangle)
            elevationSum += triangle.averageY
        }
        return selected
    }

    private func makeGrid(
        floorTriangles: [WorldTriangle],
        floorPlanes: [WorldFloorPlane],
        blockingTriangles: [WorldTriangle]
    ) -> NavigationGrid? {
        guard let minX = floorTriangles.map(\.minX).min(),
            let maxX = floorTriangles.map(\.maxX).max(),
            let minZ = floorTriangles.map(\.minZ).min(),
            let maxZ = floorTriangles.map(\.maxZ).max()
        else {
            return nil
        }
        let normalizedOriginX = floor(minX / cellSize) * cellSize
        let normalizedOriginZ = floor(minZ / cellSize) * cellSize
        let originX = normalizedOriginX + cellSize / 2
        let originZ = normalizedOriginZ + cellSize / 2
        let rawColumnCount = floor((maxX - originX) / cellSize) + 1
        let rawRowCount = floor((maxZ - originZ) / cellSize) + 1
        guard originX.isFinite, originZ.isFinite,
            rawColumnCount.isFinite, rawRowCount.isFinite,
            rawColumnCount >= 1, rawRowCount >= 1,
            rawColumnCount <= Double(maximumCellCount),
            rawRowCount <= Double(maximumCellCount)
        else {
            return nil
        }
        let columns = Int(rawColumnCount)
        let rows = Int(rawRowCount)
        guard columns > 0, rows > 0,
            columns <= maximumCellCount,
            rows <= maximumCellCount,
            columns <= maximumCellCount / rows
        else {
            return nil
        }

        let origin = try? Vec3(x: originX, y: 0, z: originZ)
        guard let origin else {
            return nil
        }
        let cellCount = rows * columns
        var floorBuckets = Array(repeating: [WorldTriangle](), count: cellCount)
        var floorReferenceCount = 0
        let maximumIndexedReferences = min(2_000_000, max(4_096, maximumCellCount * 128))
        for triangle in floorTriangles {
            guard !Task.isCancelled else {
                return nil
            }
            guard
                let columnRange = cellIndexRange(
                    minimum: triangle.minX,
                    maximum: triangle.maxX,
                    origin: originX,
                    count: columns
                ),
                let rowRange = cellIndexRange(
                    minimum: triangle.minZ,
                    maximum: triangle.maxZ,
                    origin: originZ,
                    count: rows
                )
            else {
                continue
            }
            let addedReferences = columnRange.count * rowRange.count
            guard addedReferences <= maximumIndexedReferences - floorReferenceCount else {
                return nil
            }
            floorReferenceCount += addedReferences
            for row in rowRange {
                for column in columnRange {
                    floorBuckets[row * columns + column].append(triangle)
                }
            }
        }

        var overlapComparisonCount = 0
        let maximumOverlapComparisons = 2_000_000
        for bucket in floorBuckets {
            guard !Task.isCancelled else {
                return nil
            }
            guard bucket.count <= 256 else {
                return nil
            }
            let comparisons = bucket.count * max(0, bucket.count - 1) / 2
            guard comparisons <= maximumOverlapComparisons - overlapComparisonCount else {
                return nil
            }
            overlapComparisonCount += comparisons
        }

        var floors: [IndoorNavigationFloorEvidence] = []
        var floorElevations: [IndoorNavigationCell: Double] = [:]
        var allElevations: [Double] = []
        for row in 0..<rows {
            guard !Task.isCancelled else {
                return nil
            }
            for column in 0..<columns {
                let centerX = originX + Double(column) * cellSize
                let centerZ = originZ + Double(row) * cellSize
                guard
                    let elevation = verifiedCellElevation(
                        centerX: centerX,
                        centerZ: centerZ,
                        floorTriangles: floorBuckets[row * columns + column],
                        floorPlanes: floorPlanes
                    )
                else {
                    continue
                }

                let cell = IndoorNavigationCell(column: column, row: row)
                guard
                    let floor = try? IndoorNavigationFloorEvidence(
                        cell: cell,
                        zoneIdentifier: "verified-current-floor",
                        elevation: elevation,
                        confidence: evidenceConfidence
                    )
                else {
                    return nil
                }
                floors.append(floor)
                floorElevations[cell] = elevation
                allElevations.append(elevation)
            }
        }
        guard floors.count <= maximumCellCount,
            let referenceElevation = allElevations.mean
        else {
            return nil
        }

        var blockedCells: Set<IndoorNavigationCell> = []
        var blockingReferenceCount = 0
        for triangle in blockingTriangles {
            guard !Task.isCancelled else {
                return nil
            }
            guard
                let columnRange = cellIndexRange(
                    minimum: triangle.minX,
                    maximum: triangle.maxX,
                    origin: originX,
                    count: columns,
                    margin: obstacleClearance
                ),
                let rowRange = cellIndexRange(
                    minimum: triangle.minZ,
                    maximum: triangle.maxZ,
                    origin: originZ,
                    count: rows,
                    margin: obstacleClearance
                )
            else {
                continue
            }
            let addedReferences = columnRange.count * rowRange.count
            guard addedReferences <= maximumIndexedReferences - blockingReferenceCount else {
                return nil
            }
            blockingReferenceCount += addedReferences
            for row in rowRange {
                for column in columnRange {
                    let cell = IndoorNavigationCell(column: column, row: row)
                    guard let elevation = floorElevations[cell] else {
                        continue
                    }
                    let centerX = originX + Double(column) * cellSize
                    let centerZ = originZ + Double(row) * cellSize
                    if triangle.blocksCell(
                        centerX: centerX,
                        centerZ: centerZ,
                        floorElevation: elevation,
                        halfWidth: cellSize / 2 + obstacleClearance
                    ) {
                        blockedCells.insert(cell)
                    }
                }
            }
        }
        let mesh = floors.map {
            IndoorNavigationMeshEvidence(
                cell: $0.cell,
                occupancy: blockedCells.contains($0.cell) ? .blocked : .free,
                confidence: evidenceConfidence
            )
        }
        return NavigationGrid(
            origin: origin,
            floors: floors,
            mesh: mesh,
            referenceElevation: referenceElevation
        )
    }

    private func makeWalls(
        from segments: [WorldBarrierSegment],
        nearFloorElevation floorElevation: Double
    ) -> [IndoorNavigationWallEvidence]? {
        var walls: [IndoorNavigationWallEvidence] = []
        var seen: Set<String> = []
        for segment in segments {
            guard !Task.isCancelled else {
                return nil
            }
            guard segment.maxY > floorElevation + 0.05,
                segment.minY < floorElevation + 2.0,
                segment.start.distanceXZ(to: segment.end) >= 0.05
            else {
                continue
            }
            guard let key = quantizedEdgeKey(segment.start, segment.end) else {
                return nil
            }
            guard seen.insert(key).inserted else {
                continue
            }
            guard walls.count < maximumWallCount,
                let wall = try? IndoorNavigationWallEvidence(
                    identifier: "mesh-wall-\(walls.count)",
                    start: segment.start,
                    end: segment.end,
                    thickness: 0.05,
                    confidence: evidenceConfidence
                )
            else {
                return nil
            }
            walls.append(wall)
        }
        return walls
    }

    private func cellIndexRange(
        minimum: Double,
        maximum: Double,
        origin: Double,
        count: Int,
        margin: Double = 0
    ) -> ClosedRange<Int>? {
        guard count > 0, minimum.isFinite, maximum.isFinite,
            origin.isFinite, margin.isFinite, margin >= 0,
            minimum <= maximum
        else {
            return nil
        }
        let gridMinimum = origin - cellSize / 2
        let gridMaximum = origin + Double(count) * cellSize - cellSize / 2
        let expandedMinimum = minimum - margin
        let expandedMaximum = maximum + margin
        guard expandedMaximum >= gridMinimum,
            expandedMinimum <= gridMaximum
        else {
            return nil
        }
        let lower = max(
            0,
            min(Double(count - 1), floor((expandedMinimum - gridMinimum) / cellSize))
        )
        let upper = max(
            0,
            min(Double(count - 1), floor((expandedMaximum - gridMinimum) / cellSize))
        )
        guard lower.isFinite, upper.isFinite, lower <= upper else {
            return nil
        }
        return Int(lower)...Int(upper)
    }

    private func verifiedCellElevation(
        centerX: Double,
        centerZ: Double,
        floorTriangles: [WorldTriangle],
        floorPlanes: [WorldFloorPlane]
    ) -> Double? {
        let half = cellSize / 2
        let rectangle = AxisAlignedRectangle2D(
            minX: centerX - half,
            maxX: centerX + half,
            minZ: centerZ - half,
            maxZ: centerZ + half
        )
        var clipped: [ClippedFloorPolygon] = []
        for triangle in floorTriangles {
            guard !Task.isCancelled else {
                return nil
            }
            guard triangle.intersects(rectangle),
                let polygon = triangle.clipped(to: rectangle),
                polygon.area > 1e-10
            else {
                continue
            }
            clipped.append(polygon)
        }
        guard !clipped.isEmpty, clipped.count <= 256 else {
            return nil
        }

        let cellArea = cellSize * cellSize
        let areaTolerance = max(1e-9, cellArea * 0.000_001)
        var coveredArea = 0.0
        var pairwiseOverlapArea = 0.0
        var elevations: [Double] = []
        for index in clipped.indices {
            guard !Task.isCancelled else {
                return nil
            }
            coveredArea += clipped[index].area
            elevations.append(contentsOf: clipped[index].elevations)
            for otherIndex in clipped.indices where otherIndex < index {
                let overlap = clipped[index].intersectionArea(with: clipped[otherIndex])
                guard overlap.isFinite else {
                    return nil
                }
                pairwiseOverlapArea += overlap
            }
        }
        // The first two Bonferroni terms are a lower bound on polygon-union
        // area. This prevents accumulated overlaps from compensating for a hole.
        let guaranteedUnionArea = coveredArea - pairwiseOverlapArea
        guard guaranteedUnionArea >= cellArea - areaTolerance,
            let minimumElevation = elevations.min(),
            let maximumElevation = elevations.max(),
            maximumElevation - minimumElevation <= floorHeightTolerance,
            let elevation = elevations.mean
        else {
            return nil
        }

        let corners = rectangle.corners + [Point2D(x: centerX, z: centerZ)]
        guard
            floorPlanes.contains(where: { plane in
                corners.allSatisfy {
                    plane.contains(x: $0.x, y: elevation, z: $0.z)
                }
            })
        else {
            return nil
        }
        return elevation
    }

    private func quantizedEdgeKey(_ first: Vec3, _ second: Vec3) -> String? {
        func pointKey(_ point: Vec3) -> String? {
            let scale = 50.0
            let x = (point.x * scale).rounded()
            let z = (point.z * scale).rounded()
            guard x.isFinite, z.isFinite,
                abs(x) <= 5_000_000, abs(z) <= 5_000_000
            else {
                return nil
            }
            let normalizedX = x == 0 ? 0.0 : x
            let normalizedZ = z == 0 ? 0.0 : z
            return "\(normalizedX.bitPattern):\(normalizedZ.bitPattern)"
        }
        guard let firstKey = pointKey(first),
            let secondKey = pointKey(second)
        else {
            return nil
        }
        let keys = [firstKey, secondKey].sorted()
        return keys.joined(separator: "-")
    }

    private static func clampedFinite(
        _ value: Double,
        minimum: Double,
        maximum: Double,
        fallback: Double
    ) -> Double {
        guard value.isFinite else {
            return fallback
        }
        return min(maximum, max(minimum, value))
    }
}

private struct NavigationGeometry {
    let floorPlanes: [WorldFloorPlane]
    let floorTriangles: [WorldTriangle]
    let blockingTriangles: [WorldTriangle]
    let barrierSegments: [WorldBarrierSegment]
}

private struct NavigationGrid {
    let origin: Vec3
    let floors: [IndoorNavigationFloorEvidence]
    let mesh: [IndoorNavigationMeshEvidence]
    let referenceElevation: Double
}

private struct Point2D: Equatable {
    let x: Double
    let z: Double
}

private struct AxisAlignedRectangle2D {
    let minX: Double
    let maxX: Double
    let minZ: Double
    let maxZ: Double

    var corners: [Point2D] {
        [
            Point2D(x: minX, z: minZ),
            Point2D(x: maxX, z: minZ),
            Point2D(x: maxX, z: maxZ),
            Point2D(x: minX, z: maxZ),
        ]
    }
}

private struct ClippedFloorPolygon {
    let vertices: [Point2D]
    let elevations: [Double]

    var area: Double {
        abs(signedArea(of: vertices))
    }

    func intersectionArea(with other: ClippedFloorPolygon) -> Double {
        abs(signedArea(of: convexIntersection(vertices, other.vertices)))
    }
}

private struct WorldBarrierSegment {
    let start: Vec3
    let end: Vec3
    let minY: Double
    let maxY: Double

    init(start: Vec3, end: Vec3, minY: Double, maxY: Double) {
        self.start = start
        self.end = end
        self.minY = minY
        self.maxY = maxY
    }

    init?(_ triangle: WorldTriangle) {
        guard let edge = triangle.longestHorizontalEdge else {
            return nil
        }
        start = edge.0
        end = edge.1
        minY = triangle.minY
        maxY = triangle.maxY
    }
}

private struct WorldPlanePolygon {
    let vertices: [Vec3]

    init?(_ plane: ARPlaneObservationSnapshot) {
        guard let localVertices = localPlaneVertices(plane) else {
            return nil
        }
        let transformed = localVertices.compactMap {
            Vec3.transforming($0, by: plane.transform.simdValue)
        }
        guard transformed.count == localVertices.count else {
            return nil
        }
        vertices = transformed
    }

    func triangles(
        classification: ARMeshClassificationSnapshot
    ) -> [WorldTriangle]? {
        guard vertices.count >= 3 else {
            return nil
        }
        var triangles: [WorldTriangle] = []
        triangles.reserveCapacity(vertices.count - 2)
        for index in 1..<(vertices.count - 1) {
            guard
                let triangle = WorldTriangle(
                    worldVertices: [vertices[0], vertices[index], vertices[index + 1]],
                    classification: classification
                )
            else {
                return nil
            }
            triangles.append(triangle)
        }
        return triangles
    }

    var barrierSegment: WorldBarrierSegment? {
        guard vertices.count >= 2,
            let minY = vertices.map(\.y).min(),
            let maxY = vertices.map(\.y).max()
        else {
            return nil
        }
        let edges = vertices.indices.map { index in
            (vertices[index], vertices[(index + 1) % vertices.count])
        }
        guard
            let edge = edges.max(by: {
                $0.0.distanceXZ(to: $0.1) < $1.0.distanceXZ(to: $1.1)
            }),
            edge.0.distanceXZ(to: edge.1) >= 0.05
        else {
            return nil
        }
        return WorldBarrierSegment(
            start: edge.0,
            end: edge.1,
            minY: minY,
            maxY: maxY
        )
    }
}

private func localPlaneVertices(
    _ plane: ARPlaneObservationSnapshot
) -> [SIMD3<Float>]? {
    let vertices: [SIMD3<Float>]
    if plane.boundaryVertices.count >= 3 {
        guard plane.boundaryVertices.count <= 2_048 else {
            return nil
        }
        vertices = plane.boundaryVertices
    } else {
        let halfX = plane.extent.x / 2
        let halfZ = plane.extent.z / 2
        let rotation = plane.extentRotationOnYAxis
        guard halfX.isFinite, halfZ.isFinite, rotation.isFinite,
            halfX > 0, halfZ > 0
        else {
            return nil
        }
        let cosine = cos(rotation)
        let sine = sin(rotation)
        vertices = [
            SIMD2<Float>(-halfX, -halfZ),
            SIMD2<Float>(halfX, -halfZ),
            SIMD2<Float>(halfX, halfZ),
            SIMD2<Float>(-halfX, halfZ),
        ].map { offset in
            SIMD3<Float>(
                plane.center.x + offset.x * cosine - offset.y * sine,
                plane.center.y,
                plane.center.z + offset.x * sine + offset.y * cosine
            )
        }
    }
    guard
        vertices.allSatisfy({
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
        })
    else {
        return nil
    }
    return vertices
}

private func signedArea(of vertices: [Point2D]) -> Double {
    guard vertices.count >= 3 else {
        return 0
    }
    return vertices.indices.reduce(0) { area, index in
        let next = vertices[(index + 1) % vertices.count]
        return area + vertices[index].x * next.z - next.x * vertices[index].z
    } / 2
}

private func convexIntersection(
    _ subjectVertices: [Point2D],
    _ clipVertices: [Point2D]
) -> [Point2D] {
    guard subjectVertices.count >= 3, clipVertices.count >= 3 else {
        return []
    }
    var output = normalizedCounterClockwise(subjectVertices)
    let clip = normalizedCounterClockwise(clipVertices)
    for index in clip.indices {
        let edgeStart = clip[index]
        let edgeEnd = clip[(index + 1) % clip.count]
        let input = output
        output = []
        guard !input.isEmpty else {
            break
        }
        var previous = input[input.count - 1]
        var previousInside = isInsideClipEdge(previous, edgeStart, edgeEnd)
        for current in input {
            let currentInside = isInsideClipEdge(current, edgeStart, edgeEnd)
            if currentInside {
                if !previousInside,
                    let intersection = lineIntersection(
                        from: previous,
                        to: current,
                        edgeStart: edgeStart,
                        edgeEnd: edgeEnd
                    )
                {
                    appendDistinct(intersection, to: &output)
                }
                appendDistinct(current, to: &output)
            } else if previousInside,
                let intersection = lineIntersection(
                    from: previous,
                    to: current,
                    edgeStart: edgeStart,
                    edgeEnd: edgeEnd
                )
            {
                appendDistinct(intersection, to: &output)
            }
            previous = current
            previousInside = currentInside
        }
        if output.count > 1, pointsNearlyEqual(output[0], output[output.count - 1]) {
            output.removeLast()
        }
    }
    return output
}

private func normalizedCounterClockwise(_ vertices: [Point2D]) -> [Point2D] {
    signedArea(of: vertices) < 0 ? Array(vertices.reversed()) : vertices
}

private func isInsideClipEdge(
    _ point: Point2D,
    _ edgeStart: Point2D,
    _ edgeEnd: Point2D
) -> Bool {
    cross(
        x1: edgeEnd.x - edgeStart.x,
        z1: edgeEnd.z - edgeStart.z,
        x2: point.x - edgeStart.x,
        z2: point.z - edgeStart.z
    ) >= -1e-10
}

private func lineIntersection(
    from start: Point2D,
    to end: Point2D,
    edgeStart: Point2D,
    edgeEnd: Point2D
) -> Point2D? {
    let segmentX = end.x - start.x
    let segmentZ = end.z - start.z
    let edgeX = edgeEnd.x - edgeStart.x
    let edgeZ = edgeEnd.z - edgeStart.z
    let denominator = cross(
        x1: segmentX,
        z1: segmentZ,
        x2: edgeX,
        z2: edgeZ
    )
    guard abs(denominator) > 1e-14 else {
        return nil
    }
    let t =
        cross(
            x1: edgeStart.x - start.x,
            z1: edgeStart.z - start.z,
            x2: edgeX,
            z2: edgeZ
        ) / denominator
    return Point2D(
        x: start.x + t * segmentX,
        z: start.z + t * segmentZ
    )
}

private func cross(x1: Double, z1: Double, x2: Double, z2: Double) -> Double {
    x1 * z2 - z1 * x2
}

private func appendDistinct(_ point: Point2D, to vertices: inout [Point2D]) {
    guard vertices.last.map({ !pointsNearlyEqual($0, point) }) ?? true else {
        return
    }
    vertices.append(point)
}

private func pointsNearlyEqual(_ lhs: Point2D, _ rhs: Point2D) -> Bool {
    abs(lhs.x - rhs.x) <= 1e-10 && abs(lhs.z - rhs.z) <= 1e-10
}

private struct WorldFloorPlane {
    let vertices: [Vec3]
    let elevation: Double

    init?(_ plane: ARPlaneObservationSnapshot) {
        guard let localVertices = localPlaneVertices(plane) else {
            return nil
        }
        let transformed = localVertices.compactMap {
            Vec3.transforming($0, by: plane.transform.simdValue)
        }
        guard transformed.count == localVertices.count,
            let elevation = transformed.map(\.y).mean
        else {
            return nil
        }
        vertices = transformed
        self.elevation = elevation
    }

    func contains(x: Double, y: Double, z: Double) -> Bool {
        guard abs(y - elevation) <= 0.12 else {
            return false
        }
        let point = Point2D(x: x, z: z)
        for index in vertices.indices {
            let start = Point2D(x: vertices[index].x, z: vertices[index].z)
            let endVertex = vertices[(index + 1) % vertices.count]
            let end = Point2D(x: endVertex.x, z: endVertex.z)
            if pointLiesOnSegment(point, start: start, end: end) {
                return true
            }
        }
        var isInside = false
        var previous = vertices[vertices.count - 1]
        for current in vertices {
            let crosses = (current.z > z) != (previous.z > z)
            if crosses {
                let denominator = previous.z - current.z
                if abs(denominator) > 1e-9 {
                    let boundaryX =
                        (previous.x - current.x) * (z - current.z) / denominator
                        + current.x
                    if x < boundaryX {
                        isInside.toggle()
                    }
                }
            }
            previous = current
        }
        return isInside
    }
}

private func pointLiesOnSegment(
    _ point: Point2D,
    start: Point2D,
    end: Point2D
) -> Bool {
    let segmentX = end.x - start.x
    let segmentZ = end.z - start.z
    let length = hypot(segmentX, segmentZ)
    guard length > 1e-12 else {
        return pointsNearlyEqual(point, start)
    }
    let distanceNumerator = abs(
        cross(
            x1: segmentX,
            z1: segmentZ,
            x2: point.x - start.x,
            z2: point.z - start.z
        )
    )
    guard distanceNumerator / length <= 1e-7 else {
        return false
    }
    let dot = (point.x - start.x) * segmentX + (point.z - start.z) * segmentZ
    return dot >= -1e-7 && dot <= length * length + 1e-7
}

private struct WorldTriangle {
    let first: Vec3
    let second: Vec3
    let third: Vec3
    let classification: ARMeshClassificationSnapshot

    init?(
        localVertices: [SIMD3<Float>],
        transform: simd_float4x4,
        classification: ARMeshClassificationSnapshot
    ) {
        guard localVertices.count == 3,
            let first = Vec3.transforming(localVertices[0], by: transform),
            let second = Vec3.transforming(localVertices[1], by: transform),
            let third = Vec3.transforming(localVertices[2], by: transform)
        else {
            return nil
        }
        self.first = first
        self.second = second
        self.third = third
        self.classification = classification
    }

    init?(
        worldVertices: [Vec3],
        classification: ARMeshClassificationSnapshot
    ) {
        guard worldVertices.count == 3 else {
            return nil
        }
        first = worldVertices[0]
        second = worldVertices[1]
        third = worldVertices[2]
        self.classification = classification
    }

    var vertices: [Vec3] { [first, second, third] }
    var minX: Double { vertices.map(\.x).min()! }
    var maxX: Double { vertices.map(\.x).max()! }
    var minY: Double { vertices.map(\.y).min()! }
    var maxY: Double { vertices.map(\.y).max()! }
    var minZ: Double { vertices.map(\.z).min()! }
    var maxZ: Double { vertices.map(\.z).max()! }
    var averageY: Double { (first.y + second.y + third.y) / 3 }
    var horizontalArea: Double {
        abs(
            first.x * (second.z - third.z)
                + second.x * (third.z - first.z)
                + third.x * (first.z - second.z)
        ) / 2
    }

    var longestHorizontalEdge: (Vec3, Vec3)? {
        let edges = [(first, second), (second, third), (third, first)]
        return edges.max { lhs, rhs in
            lhs.0.distanceXZ(to: lhs.1) < rhs.0.distanceXZ(to: rhs.1)
        }
    }

    func intersects(_ rectangle: AxisAlignedRectangle2D) -> Bool {
        maxX >= rectangle.minX
            && minX <= rectangle.maxX
            && maxZ >= rectangle.minZ
            && minZ <= rectangle.maxZ
    }

    func clipped(to rectangle: AxisAlignedRectangle2D) -> ClippedFloorPolygon? {
        let projected = vertices.map { Point2D(x: $0.x, z: $0.z) }
        let clippedVertices = convexIntersection(projected, rectangle.corners)
        guard clippedVertices.count >= 3 else {
            return nil
        }
        let elevations = clippedVertices.compactMap {
            elevation(x: $0.x, z: $0.z)
        }
        guard elevations.count == clippedVertices.count,
            elevations.allSatisfy(\.isFinite)
        else {
            return nil
        }
        return ClippedFloorPolygon(
            vertices: clippedVertices,
            elevations: elevations
        )
    }

    func elevation(x: Double, z: Double) -> Double? {
        let denominator =
            (second.z - third.z) * (first.x - third.x)
            + (third.x - second.x) * (first.z - third.z)
        guard abs(denominator) > 1e-10 else {
            return nil
        }
        let firstWeight =
            ((second.z - third.z) * (x - third.x)
                + (third.x - second.x) * (z - third.z)) / denominator
        let secondWeight =
            ((third.z - first.z) * (x - third.x)
                + (first.x - third.x) * (z - third.z)) / denominator
        let thirdWeight = 1 - firstWeight - secondWeight
        let epsilon = 1e-6
        guard firstWeight >= -epsilon,
            secondWeight >= -epsilon,
            thirdWeight >= -epsilon
        else {
            return nil
        }
        return firstWeight * first.y + secondWeight * second.y + thirdWeight * third.y
    }

    func blocksCell(
        centerX: Double,
        centerZ: Double,
        floorElevation: Double,
        halfWidth: Double
    ) -> Bool {
        guard maxY > floorElevation + 0.05,
            minY < floorElevation + 2.0
        else {
            return false
        }
        return maxX >= centerX - halfWidth
            && minX <= centerX + halfWidth
            && maxZ >= centerZ - halfWidth
            && minZ <= centerZ + halfWidth
    }
}

extension ARMeshClassificationSnapshot {
    fileprivate init?(_ classification: ARPlaneClassificationSnapshot) {
        switch classification {
        case .wall: self = .wall
        case .floor: self = .floor
        case .ceiling: self = .ceiling
        case .table: self = .table
        case .seat: self = .seat
        case .window: self = .window
        case .door: self = .door
        case .none, .unknown: return nil
        }
    }
}

extension Vec3 {
    fileprivate static func transforming(
        _ point: SIMD3<Float>,
        by transform: simd_float4x4
    ) -> Vec3? {
        let transformed = transform * SIMD4<Float>(point.x, point.y, point.z, 1)
        guard transformed.x.isFinite,
            transformed.y.isFinite,
            transformed.z.isFinite,
            transformed.w.isFinite,
            abs(transformed.w) > Float.ulpOfOne
        else {
            return nil
        }
        return try? Vec3(
            x: Double(transformed.x / transformed.w),
            y: Double(transformed.y / transformed.w),
            z: Double(transformed.z / transformed.w)
        )
    }

    fileprivate func distanceXZ(to other: Vec3) -> Double {
        hypot(x - other.x, z - other.z)
    }
}

extension Collection where Element == Double {
    fileprivate var mean: Double? {
        guard !isEmpty else {
            return nil
        }
        return reduce(0, +) / Double(count)
    }
}
