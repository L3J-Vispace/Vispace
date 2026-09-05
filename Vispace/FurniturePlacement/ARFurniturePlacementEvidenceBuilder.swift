import Foundation
import VispaceCore
import simd

public enum ARFurniturePlacementEvidenceIssue: String, Error, Hashable, Sendable {
    case poseUnavailable
    case surfaceUnavailable
    case capabilitiesUnavailable
    case candidateUnavailable
    case worldTrackingUnavailable
    case captureNotConfirmed
    case trackingUnstable
    case worldMappingIncomplete
    case incompleteSurfaceSnapshot
    case coordinateContextMismatch
    case currentMapUnavailable
    case candidateCoordinateMismatch
    case candidatePositionStale
    case candidatePositionUncertain
    case surfaceSnapshotStale
    case surfaceCapacityExceeded
    case objectCapacityExceeded
    case invalidSurfaceGeometry
    case objectMetadataUnavailable
    case lidarEvidenceIncomplete
}

public struct ARFurniturePlacementEvidenceBuilderPolicy: Hashable, Sendable {
    public static let absoluteMaximumPlanes = 1_024
    public static let absoluteMaximumMeshes = 128
    public static let absoluteMaximumObjects = 2_048

    public let maximumCandidatePoseAge: TimeInterval
    public let maximumSurfacePoseAge: TimeInterval
    public let conservativePlaneScale: Double
    public let localEvidenceRadius: Double
    public let minimumLocalClassifiedTriangleCount: Int
    public let minimumMeshCoverageMargin: Double
    public let minimumSurfaceDimension: Double
    public let doorwayKeepClearDepth: Double
    public let requiredPassageWidth: Double
    public let maximumPlanes: Int
    public let maximumMeshes: Int
    public let maximumObjects: Int
    public let maximumWallSegments: Int
    public let maximumDoorways: Int
    public let maximumObstacles: Int

    public init(
        maximumCandidatePoseAge: TimeInterval = 2,
        maximumSurfacePoseAge: TimeInterval = 60,
        conservativePlaneScale: Double = 0.85,
        localEvidenceRadius: Double = 4,
        minimumLocalClassifiedTriangleCount: Int = 128,
        minimumMeshCoverageMargin: Double = 0.25,
        minimumSurfaceDimension: Double = 0.05,
        doorwayKeepClearDepth: Double = 1.2,
        requiredPassageWidth: Double = 0.8,
        maximumPlanes: Int = 256,
        maximumMeshes: Int = 64,
        maximumObjects: Int = 512,
        maximumWallSegments: Int = 512,
        maximumDoorways: Int = 64,
        maximumObstacles: Int = 512
    ) {
        self.maximumCandidatePoseAge = Self.positive(
            maximumCandidatePoseAge,
            fallback: 2
        )
        self.maximumSurfacePoseAge = Self.positive(
            maximumSurfacePoseAge,
            fallback: 60
        )
        self.conservativePlaneScale = min(
            0.95,
            max(0.25, conservativePlaneScale.isFinite ? conservativePlaneScale : 0.85)
        )
        self.localEvidenceRadius = Self.positive(localEvidenceRadius, fallback: 4)
        self.minimumLocalClassifiedTriangleCount = max(
            1,
            minimumLocalClassifiedTriangleCount
        )
        self.minimumMeshCoverageMargin = max(
            0,
            minimumMeshCoverageMargin.isFinite ? minimumMeshCoverageMargin : 0.25
        )
        self.minimumSurfaceDimension = Self.positive(
            minimumSurfaceDimension,
            fallback: 0.05
        )
        self.doorwayKeepClearDepth = Self.positive(
            doorwayKeepClearDepth,
            fallback: 1.2
        )
        self.requiredPassageWidth = Self.positive(
            requiredPassageWidth,
            fallback: 0.8
        )
        self.maximumPlanes = min(max(1, maximumPlanes), Self.absoluteMaximumPlanes)
        self.maximumMeshes = min(max(1, maximumMeshes), Self.absoluteMaximumMeshes)
        self.maximumObjects = min(max(1, maximumObjects), Self.absoluteMaximumObjects)
        self.maximumWallSegments = max(1, maximumWallSegments)
        self.maximumDoorways = max(1, maximumDoorways)
        self.maximumObstacles = max(1, maximumObstacles)
    }

    public static let `default` = Self()

    private static func positive(_ value: Double, fallback: Double) -> Double {
        value.isFinite && value > 0 ? value : fallback
    }
}

public enum ARFurnitureDefaults {
    public static func dimensions(for kind: FurnitureKind) -> FurnitureDimensions {
        switch kind {
        case .sofa:
            return try! FurnitureDimensions(kind: kind, width: 2.0, depth: 0.9, height: 0.9)
        case .bed:
            return try! FurnitureDimensions(kind: kind, width: 1.6, depth: 2.0, height: 0.6)
        case .desk:
            return try! FurnitureDimensions(kind: kind, width: 1.4, depth: 0.7, height: 0.75)
        }
    }
}

public struct ARFurniturePlacementEvidenceSummary: Equatable, Sendable {
    public let floorRegionCount: Int
    public let observedRegionCount: Int
    public let wallSegmentCount: Int
    public let doorwayCount: Int
    public let obstacleCount: Int
    public let passageCount: Int
    public let localClassifiedTriangleCount: Int
    public let lidarEvidenceComplete: Bool

    public init(
        floorRegionCount: Int,
        observedRegionCount: Int,
        wallSegmentCount: Int,
        doorwayCount: Int,
        obstacleCount: Int,
        passageCount: Int,
        localClassifiedTriangleCount: Int,
        lidarEvidenceComplete: Bool
    ) {
        self.floorRegionCount = floorRegionCount
        self.observedRegionCount = observedRegionCount
        self.wallSegmentCount = wallSegmentCount
        self.doorwayCount = doorwayCount
        self.obstacleCount = obstacleCount
        self.passageCount = passageCount
        self.localClassifiedTriangleCount = localClassifiedTriangleCount
        self.lidarEvidenceComplete = lidarEvidenceComplete
    }
}

public struct ARFurniturePlacementPreparedInput: Sendable {
    public let sourcePosition: FramedPosition
    public let candidate: FurniturePlacementCandidate
    public let evidence: FurniturePlacementEvidence
    public let summary: ARFurniturePlacementEvidenceSummary

    public init(
        sourcePosition: FramedPosition,
        candidate: FurniturePlacementCandidate,
        evidence: FurniturePlacementEvidence,
        summary: ARFurniturePlacementEvidenceSummary
    ) {
        self.sourcePosition = sourcePosition
        self.candidate = candidate
        self.evidence = evidence
        self.summary = summary
    }
}

public enum ARFurniturePlacementEvidenceBuildOutcome: Sendable {
    case ready(ARFurniturePlacementPreparedInput)
    case insufficient(ARFurniturePlacementEvidenceIssue)
}

/// Converts bounded AR snapshots into conservative evaluator evidence. The
/// candidate coordinate is accepted only from the caller; this builder has no
/// raycast, projection, or coordinate-generation API.
public struct ARFurniturePlacementEvidenceBuilder: Sendable {
    public let policy: ARFurniturePlacementEvidenceBuilderPolicy

    public init(policy: ARFurniturePlacementEvidenceBuilderPolicy = .default) {
        self.policy = policy
    }

    public func build(
        kind: FurnitureKind,
        candidatePosition: FramedPosition,
        surface: ARSurfaceStateSnapshot,
        pose: ARPoseSnapshot,
        capabilities: ARCaptureCapabilities,
        objects: [SpatialObjectMetadata],
        furnitureDimensions: FurnitureDimensions? = nil
    ) -> ARFurniturePlacementEvidenceBuildOutcome {
        guard !Task.isCancelled else { return .insufficient(.surfaceUnavailable) }
        guard capabilities.supportsWorldTracking else {
            return .insufficient(.worldTrackingUnavailable)
        }
        guard pose.coordinateFrameStatus == .confirmed else {
            return .insufficient(.captureNotConfirmed)
        }
        guard pose.trackingState == .normal else {
            return .insufficient(.trackingUnstable)
        }
        guard pose.worldMappingStatus == .mapped else {
            return .insufficient(.worldMappingIncomplete)
        }
        guard surface.isComplete else {
            return .insufficient(.incompleteSurfaceSnapshot)
        }
        guard let currentMapID = pose.mapID else {
            return .insufficient(.currentMapUnavailable)
        }
        guard surface.coordinateFrameID == pose.coordinateFrameID,
            surface.segmentID == pose.segmentID,
            surface.mapID == currentMapID,
            surface.coordinateFrameStatus == pose.coordinateFrameStatus
        else {
            return .insufficient(.coordinateContextMismatch)
        }
        guard candidatePosition.coordinateFrameID == pose.coordinateFrameID else {
            return .insufficient(.candidateCoordinateMismatch)
        }
        guard candidatePosition.trackingQuality == .normal else {
            return .insufficient(.candidatePositionUncertain)
        }
        switch candidatePosition.uncertainty {
        case .highConfidenceDepth, .mediumConfidenceDepth, .raycastEstimate:
            break
        case .unavailable, .lowConfidenceDepth, .unknown:
            return .insufficient(.candidatePositionUncertain)
        }
        guard
            abs(candidatePosition.observedAt - pose.capturedAt)
                <= policy.maximumCandidatePoseAge
        else {
            return .insufficient(.candidatePositionStale)
        }
        let surfaceAge = pose.timestamp - surface.timestamp
        guard surfaceAge >= -0.25, surfaceAge <= policy.maximumSurfacePoseAge,
            surface.hasFreshSurfaces(at: pose.timestamp, maximumAge: policy.maximumSurfacePoseAge)
        else {
            return .insufficient(.surfaceSnapshotStale)
        }
        guard surface.planes.count <= policy.maximumPlanes,
            surface.meshes.count <= policy.maximumMeshes
        else {
            return .insufficient(.surfaceCapacityExceeded)
        }
        guard objects.count <= policy.maximumObjects else {
            return .insufficient(.objectCapacityExceeded)
        }
        guard let yaw = cameraAlignedYaw(pose.cameraTransform) else {
            return .insufficient(.trackingUnstable)
        }

        let dimensions = furnitureDimensions ?? ARFurnitureDefaults.dimensions(for: kind)
        guard dimensions.kind == kind else { return .insufficient(.candidatePositionUncertain) }
        guard
            let candidate = try? FurniturePlacementCandidate(
                position: candidatePosition.value,
                yawRadians: yaw,
                furniture: dimensions
            )
        else {
            return .insufficient(.candidatePositionUncertain)
        }

        var floors: [PlacementFloorEvidence] = []
        var observations: [PlacementObservationEvidence] = []
        var floorBoundaries: [[Vec3]] = []
        var passageObservationIdentifiers = Set<String>()
        var walls: [PlacementWallEvidence] = []
        var doorways: [PlacementDoorwayEvidence] = []
        var ceilingObstacles: [PlacementObstacleEvidence] = []
        let coverageMargin = max(policy.minimumMeshCoverageMargin, 0.10)
        guard
            let requiredRegion = try? PlacementHorizontalRegion(
                center: candidate.position,
                width: dimensions.width + 2 * coverageMargin,
                depth: dimensions.depth + 2 * coverageMargin,
                yawRadians: candidate.yawRadians
            )
        else { return .insufficient(.invalidSurfaceGeometry) }

        for plane in surface.planes.values.sorted(by: Self.planeOrder) {
            guard !Task.isCancelled else { return .insufficient(.surfaceUnavailable) }
            switch (plane.alignment, plane.classification) {
            case (.horizontal, .floor):
                guard let boundary = worldPoints(plane.boundaryVertices, transform: plane.transform),
                    boundary.count >= 3,
                    boundary.count <= ARSurfaceObservationAdapter.maximumPlaneBoundaryVertices
                else {
                    return .insufficient(.invalidSurfaceGeometry)
                }
                // Extents are only a bounding rectangle. The actual footprint
                // and observation margin must lie inside the measured polygon.
                guard HorizontalFootprintCoverage.polygonCovers(requiredRegion, polygon: boundary) else {
                    continue
                }
                floorBoundaries.append(boundary)
                let region: PlacementHorizontalRegion
                let includesPassageEvidence: Bool
                if let broadRegion = horizontalRegion(from: plane),
                    HorizontalFootprintCoverage.polygonCovers(broadRegion, polygon: boundary)
                {
                    region = broadRegion
                    includesPassageEvidence = true
                } else if let localRegion = try? PlacementHorizontalRegion(
                    center: candidate.position,
                    width: dimensions.width + 2 * max(coverageMargin, policy.requiredPassageWidth),
                    depth: dimensions.depth + 2 * max(coverageMargin, policy.requiredPassageWidth),
                    yawRadians: candidate.yawRadians
                ), HorizontalFootprintCoverage.polygonCovers(localRegion, polygon: boundary) {
                    region = localRegion
                    includesPassageEvidence = true
                } else {
                    region = requiredRegion
                    includesPassageEvidence = false
                }
                let confidence = ConfidenceScore(clamping: 0.9)
                guard
                    let floor = try? PlacementFloorEvidence(
                        identifier: "plane-floor-\(plane.anchorID.uuidString.lowercased())",
                        region: region,
                        elevation: region.center.y,
                        confidence: confidence
                    ),
                    let observation = try? PlacementObservationEvidence(
                        identifier: "plane-observed-\(plane.anchorID.uuidString.lowercased())",
                        region: region,
                        confidence: confidence
                    )
                else {
                    return .insufficient(.invalidSurfaceGeometry)
                }
                floors.append(floor)
                observations.append(observation)
                if includesPassageEvidence {
                    passageObservationIdentifiers.insert(observation.identifier)
                }
            case (.horizontal, .ceiling):
                guard ceilingObstacles.count < policy.maximumObstacles else {
                    return .insufficient(.surfaceCapacityExceeded)
                }
                guard plane.boundaryVertices.count >= 3,
                    plane.boundaryVertices.count <= ARSurfaceObservationAdapter.maximumPlaneBoundaryVertices,
                    let points = worldPoints(plane.boundaryVertices, transform: plane.transform),
                    let obstacle = meshObstacle(anchorID: plane.anchorID, points: points)
                else { return .insufficient(.invalidSurfaceGeometry) }
                ceilingObstacles.append(obstacle)
            case (.vertical, .wall), (.vertical, .window):
                guard walls.count < policy.maximumWallSegments else {
                    return .insufficient(.surfaceCapacityExceeded)
                }
                guard let wall = wallEvidence(from: plane) else {
                    return .insufficient(.invalidSurfaceGeometry)
                }
                walls.append(wall)
            case (.vertical, .door):
                guard doorways.count < policy.maximumDoorways else {
                    return .insufficient(.surfaceCapacityExceeded)
                }
                guard let doorway = doorwayEvidence(from: plane) else {
                    return .insufficient(.invalidSurfaceGeometry)
                }
                doorways.append(doorway)
            default:
                continue
            }
        }

        let mesh: MeshEvidence
        if capabilities.supportsMeshReconstruction
            && capabilities.supportsMeshClassification
        {
            let meshOutcome = meshEvidence(
                meshes: surface.meshes.values.sorted(by: Self.meshOrder),
                around: candidatePosition.value,
                requiredRegion: requiredRegion
            )
            switch meshOutcome {
            case .success(let resolvedMesh): mesh = resolvedMesh
            case .failure(let issue): return .insufficient(issue)
            }
        } else {
            mesh = MeshEvidence(
                walls: [],
                doorways: [],
                obstacles: [],
                floorTriangles: [],
                localClassifiedTriangleCount: 0,
                hasEnoughLocalClassifiedGeometry: false
            )
        }
        guard walls.count + mesh.walls.count <= policy.maximumWallSegments,
            doorways.count + mesh.doorways.count <= policy.maximumDoorways,
            ceilingObstacles.count + mesh.obstacles.count <= policy.maximumObstacles
        else { return .insufficient(.surfaceCapacityExceeded) }
        walls.append(contentsOf: mesh.walls)
        doorways.append(contentsOf: mesh.doorways)

        let objectOutcome = objectEvidence(
            objects,
            mapID: currentMapID,
            coordinateFrameID: pose.coordinateFrameID,
            around: candidatePosition.value,
            meshObstacles: ceilingObstacles + mesh.obstacles
        )
        let objectEvidence: ObjectEvidence
        switch objectOutcome {
        case .success(let resolved): objectEvidence = resolved
        case .failure(let issue): return .insufficient(issue)
        }

        // A plane polygon alone does not establish observed free space. Keep
        // only rectangles completely covered by classified floor triangles at
        // the candidate elevation; holes and overhead geometry are not floor.
        observations = observations.filter {
            HorizontalFootprintCoverage.trianglesCover($0.region, triangles: mesh.floorTriangles)
        }
        // The observed mesh can cover the candidate and a usable passage
        // without spanning the plane's entire extent. Prove that local area
        // before falling back to only the minimum observation margin.
        if observations.isEmpty, mesh.hasEnoughLocalClassifiedGeometry,
            let localRegion = try? PlacementHorizontalRegion(
                center: candidate.position,
                width: dimensions.width + 2 * max(coverageMargin, policy.requiredPassageWidth),
                depth: dimensions.depth + 2 * max(coverageMargin, policy.requiredPassageWidth),
                yawRadians: candidate.yawRadians
            ),
            floorBoundaries.contains(where: {
                HorizontalFootprintCoverage.polygonCovers(localRegion, polygon: $0)
            }),
            HorizontalFootprintCoverage.trianglesCover(localRegion, triangles: mesh.floorTriangles),
            let observation = try? PlacementObservationEvidence(
                identifier: "candidate-observed-passage",
                region: localRegion,
                confidence: ConfidenceScore(clamping: 0.85)
            )
        {
            observations = [observation]
            passageObservationIdentifiers.insert(observation.identifier)
        }
        if observations.isEmpty, mesh.hasEnoughLocalClassifiedGeometry, !floors.isEmpty,
            let observation = try? PlacementObservationEvidence(
                identifier: "candidate-observed-floor",
                region: requiredRegion,
                confidence: ConfidenceScore(clamping: 0.85)
            )
        {
            observations = [observation]
        }
        // A minimum scan margin proves observation coverage, not the
        // boundaries of a physical passage. Missing surrounding scans must
        // remain insufficient evidence rather than a narrow-passage rejection.
        let passages = passageEvidence(
            from: observations.filter {
                passageObservationIdentifiers.contains($0.identifier)
            })
        let lidarComplete =
            capabilities.supportsMeshReconstruction
            && capabilities.supportsMeshClassification
            && mesh.hasEnoughLocalClassifiedGeometry
        let completeness = PlacementEvidenceCompleteness(
            wallsMapped: lidarComplete,
            doorwaysMapped: lidarComplete,
            obstaclesMapped: lidarComplete && objectEvidence.isComplete,
            passagesMapped: lidarComplete && !passages.isEmpty
        )
        let evidence = FurniturePlacementEvidence(
            floors: floors,
            observations: observations,
            walls: walls,
            doorways: doorways,
            obstacles: Array(objectEvidence.obstacles.prefix(policy.maximumObstacles)),
            passages: passages,
            completeness: completeness
        )
        let summary = ARFurniturePlacementEvidenceSummary(
            floorRegionCount: floors.count,
            observedRegionCount: observations.count,
            wallSegmentCount: evidence.walls.count,
            doorwayCount: evidence.doorways.count,
            obstacleCount: evidence.obstacles.count,
            passageCount: evidence.passages.count,
            localClassifiedTriangleCount: mesh.localClassifiedTriangleCount,
            lidarEvidenceComplete: lidarComplete
        )
        return .ready(
            ARFurniturePlacementPreparedInput(
                sourcePosition: candidatePosition,
                candidate: candidate,
                evidence: evidence,
                summary: summary
            )
        )
    }

    /// An unrelated anchor delta cannot renew retained geometry. The same
    /// observation deadline also bounds the controller's published preview.
    func surfaceExpirationTimestamp(_ surface: ARSurfaceStateSnapshot) -> TimeInterval? {
        guard surface.timestamp.isFinite, surface.timestamp >= 0 else { return nil }
        var oldest = surface.timestamp
        for anchorID in Set(surface.planes.keys).union(surface.meshes.keys) {
            guard let observedAt = surface.anchorObservedAt[anchorID],
                observedAt.isFinite, observedAt >= 0, observedAt <= surface.timestamp + 0.25
            else { return nil }
            oldest = min(oldest, observedAt)
        }
        let expiration = oldest + policy.maximumSurfacePoseAge
        return expiration.isFinite ? expiration : nil
    }

    private func horizontalRegion(
        from plane: ARPlaneObservationSnapshot
    ) -> PlacementHorizontalRegion? {
        let rotation = Double(plane.extentRotationOnYAxis)
        let cosine = cos(rotation)
        let sine = sin(rotation)
        var centerU = 0.0
        var centerV = 0.0
        var width = Double(abs(plane.extent.x))
        var depth = Double(abs(plane.extent.z))

        if !plane.boundaryVertices.isEmpty {
            let coordinates = plane.boundaryVertices.map { vertex -> (Double, Double) in
                let dx = Double(vertex.x - plane.center.x)
                let dz = Double(vertex.z - plane.center.z)
                return (dx * cosine + dz * sine, -dx * sine + dz * cosine)
            }
            guard let minU = coordinates.map(\.0).min(),
                let maxU = coordinates.map(\.0).max(),
                let minV = coordinates.map(\.1).min(),
                let maxV = coordinates.map(\.1).max()
            else {
                return nil
            }
            centerU = (minU + maxU) * 0.5
            centerV = (minV + maxV) * 0.5
            width = min(width, maxU - minU)
            depth = min(depth, maxV - minV)
        }
        width *= policy.conservativePlaneScale
        depth *= policy.conservativePlaneScale
        guard width >= policy.minimumSurfaceDimension,
            depth >= policy.minimumSurfaceDimension
        else {
            return nil
        }

        let localCenter = SIMD3<Float>(
            plane.center.x + Float(centerU * cosine - centerV * sine),
            plane.center.y,
            plane.center.z + Float(centerU * sine + centerV * cosine)
        )
        let localWidthAxis = SIMD3<Float>(Float(cosine), 0, Float(sine))
        guard let worldCenter = worldPoint(localCenter, transform: plane.transform),
            let yaw = worldYaw(localAxis: localWidthAxis, transform: plane.transform),
            let region = try? PlacementHorizontalRegion(
                center: worldCenter,
                width: width,
                depth: depth,
                yawRadians: yaw
            )
        else {
            return nil
        }
        return region
    }

    private func wallEvidence(
        from plane: ARPlaneObservationSnapshot
    ) -> PlacementWallEvidence? {
        guard let line = planeHorizontalLine(plane),
            line.0.distance(to: line.1) >= policy.minimumSurfaceDimension
        else {
            return nil
        }
        return try? PlacementWallEvidence(
            identifier: "plane-wall-\(plane.anchorID.uuidString.lowercased())",
            start: line.0,
            end: line.1,
            confidence: ConfidenceScore(clamping: 0.9)
        )
    }

    private func doorwayEvidence(
        from plane: ARPlaneObservationSnapshot
    ) -> PlacementDoorwayEvidence? {
        guard let line = planeHorizontalLine(plane) else {
            return nil
        }
        let width = line.0.distance(to: line.1)
        guard width >= policy.minimumSurfaceDimension else {
            return nil
        }
        let center = (line.0 + line.1) * 0.5
        let yaw = atan2(line.1.z - line.0.z, line.1.x - line.0.x)
        guard
            let region = try? PlacementHorizontalRegion(
                center: center,
                width: width,
                depth: policy.doorwayKeepClearDepth,
                yawRadians: yaw
            )
        else {
            return nil
        }
        return try? PlacementDoorwayEvidence(
            identifier: "plane-door-\(plane.anchorID.uuidString.lowercased())",
            keepClearRegion: region,
            confidence: ConfidenceScore(clamping: 0.9)
        )
    }

    private func planeHorizontalLine(
        _ plane: ARPlaneObservationSnapshot
    ) -> (Vec3, Vec3)? {
        let rotation = Double(plane.extentRotationOnYAxis)
        let axis = SIMD3<Float>(Float(cos(rotation)), 0, Float(sin(rotation)))
        let halfWidth =
            max(
                policy.minimumSurfaceDimension,
                Double(abs(plane.extent.x))
            ) * 0.5
        let start = plane.center - axis * Float(halfWidth)
        let end = plane.center + axis * Float(halfWidth)
        guard let worldStart = worldPoint(start, transform: plane.transform),
            let worldEnd = worldPoint(end, transform: plane.transform)
        else {
            return nil
        }
        return (worldStart, worldEnd)
    }

    private func meshEvidence(
        meshes: [ARMeshObservationSnapshot],
        around candidate: Vec3,
        requiredRegion: PlacementHorizontalRegion
    ) -> Result<MeshEvidence, ARFurniturePlacementEvidenceIssue> {
        var walls: [PlacementWallEvidence] = []
        var doorways: [PlacementDoorwayEvidence] = []
        var obstacles: [PlacementObstacleEvidence] = []
        var floorTriangles: [[Vec3]] = []
        var localTriangleCount = 0
        var allLocalTrianglesClassified = true
        var processedFaceCount = 0

        for mesh in meshes {
            guard !Task.isCancelled else { return .failure(.surfaceUnavailable) }
            guard mesh.triangleIndices.count.isMultiple(of: 3) else {
                return .failure(.invalidSurfaceGeometry)
            }
            let faceCount = mesh.triangleIndices.count / 3
            processedFaceCount += faceCount
            guard processedFaceCount <= 65_536 else {
                return .failure(.surfaceCapacityExceeded)
            }
            guard mesh.faceClassifications.count == faceCount else {
                return .failure(.invalidSurfaceGeometry)
            }
            var meshObstaclePoints: [Vec3] = []
            var meshCeilingPoints: [Vec3] = []
            var meshDoorPoints: [Vec3] = []

            for faceIndex in 0..<faceCount {
                guard !Task.isCancelled else { return .failure(.surfaceUnavailable) }
                let rawIndices = mesh.triangleIndices[(faceIndex * 3)..<(faceIndex * 3 + 3)]
                let indices = rawIndices.map(Int.init)
                guard indices.allSatisfy({ mesh.vertices.indices.contains($0) }) else {
                    return .failure(.invalidSurfaceGeometry)
                }
                guard
                    let points = worldPoints(
                        indices.map { mesh.vertices[$0] },
                        transform: mesh.transform
                    )
                else {
                    return .failure(.invalidSurfaceGeometry)
                }
                let a = SIMD3<Double>(
                    points[1].x - points[0].x,
                    points[1].y - points[0].y,
                    points[1].z - points[0].z
                )
                let b = SIMD3<Double>(
                    points[2].x - points[0].x,
                    points[2].y - points[0].y,
                    points[2].z - points[0].z
                )
                let normal = simd_cross(a, b)
                let squaredArea = simd_length_squared(normal)
                guard squaredArea.isFinite, squaredArea > 1e-18 else {
                    return .failure(.invalidSurfaceGeometry)
                }
                // A large triangle can cross the candidate even when its
                // centroid is far away. Use overlap of its projected bounds
                // with the local evidence area, never centroid-only culling.
                let minimumX = points.map(\.x).min() ?? .infinity
                let maximumX = points.map(\.x).max() ?? -.infinity
                let minimumZ = points.map(\.z).min() ?? .infinity
                let maximumZ = points.map(\.z).max() ?? -.infinity
                guard maximumX >= candidate.x - policy.localEvidenceRadius,
                    minimumX <= candidate.x + policy.localEvidenceRadius,
                    maximumZ >= candidate.z - policy.localEvidenceRadius,
                    minimumZ <= candidate.z + policy.localEvidenceRadius
                else {
                    continue
                }
                localTriangleCount += 1
                let classification = mesh.faceClassifications[faceIndex]
                if classification == .none || classification == .unknown {
                    allLocalTrianglesClassified = false
                }

                switch classification {
                case .wall, .window:
                    guard walls.count < policy.maximumWallSegments else {
                        return .failure(.surfaceCapacityExceeded)
                    }
                    guard let pair = longestHorizontalPair(points),
                        pair.0.distance(to: pair.1) >= policy.minimumSurfaceDimension,
                        let wall = try? PlacementWallEvidence(
                            identifier: "mesh-wall-\(mesh.anchorID.uuidString.lowercased())-\(faceIndex)",
                            start: pair.0,
                            end: pair.1,
                            confidence: ConfidenceScore(clamping: 0.85)
                        )
                    else { return .failure(.invalidSurfaceGeometry) }
                    walls.append(wall)
                case .door:
                    meshDoorPoints.append(contentsOf: points)
                case .table, .seat:
                    meshObstaclePoints.append(contentsOf: points)
                case .ceiling:
                    meshCeilingPoints.append(contentsOf: points)
                case .floor:
                    guard floorTriangles.count < 32_768 else {
                        return .failure(.surfaceCapacityExceeded)
                    }
                    floorTriangles.append(points)
                case .none, .unknown:
                    break
                }
            }

            if !meshDoorPoints.isEmpty {
                guard doorways.count < policy.maximumDoorways else {
                    return .failure(.surfaceCapacityExceeded)
                }
                guard
                    let doorway = meshDoorway(
                        anchorID: mesh.anchorID,
                        points: meshDoorPoints
                    )
                else { return .failure(.invalidSurfaceGeometry) }
                doorways.append(doorway)
            }
            // Keep overhead and furniture surfaces separate. Merging a table
            // and a high ceiling into one AABB would invent a solid room-sized
            // obstacle between them. Both components retain their source anchor.
            for points in [meshObstaclePoints, meshCeilingPoints] where !points.isEmpty {
                guard obstacles.count < policy.maximumObstacles else {
                    return .failure(.surfaceCapacityExceeded)
                }
                guard
                    let obstacle = meshObstacle(
                        anchorID: mesh.anchorID,
                        points: points
                    )
                else { return .failure(.invalidSurfaceGeometry) }
                obstacles.append(obstacle)
            }
        }

        return .success(
            MeshEvidence(
                walls: walls,
                doorways: doorways,
                obstacles: obstacles,
                floorTriangles: floorTriangles,
                localClassifiedTriangleCount: localTriangleCount,
                hasEnoughLocalClassifiedGeometry:
                    localTriangleCount >= policy.minimumLocalClassifiedTriangleCount
                    && allLocalTrianglesClassified
                    && HorizontalFootprintCoverage.trianglesCover(
                        requiredRegion,
                        triangles: floorTriangles
                    )
            )
        )
    }

    private func meshDoorway(
        anchorID: UUID,
        points: [Vec3]
    ) -> PlacementDoorwayEvidence? {
        guard let first = points.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minZ = first.z
        var maxZ = first.z
        for point in points {
            guard !Task.isCancelled else { return nil }
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minZ = min(minZ, point.z)
            maxZ = max(maxZ, point.z)
        }
        // An enclosing rectangle preserves every observed door point. It is
        // conservative for diagonal or disconnected doors and costs O(n),
        // unlike the previous all-pairs diameter search.
        guard max(maxX - minX, maxZ - minZ) >= policy.minimumSurfaceDimension,
            let center = try? Vec3(x: minX * 0.5 + maxX * 0.5, y: first.y, z: minZ * 0.5 + maxZ * 0.5),
            let region = try? PlacementHorizontalRegion(
                center: center,
                width: maxX - minX + policy.doorwayKeepClearDepth,
                depth: maxZ - minZ + policy.doorwayKeepClearDepth
            )
        else {
            return nil
        }
        return try? PlacementDoorwayEvidence(
            identifier: "mesh-door-\(anchorID.uuidString.lowercased())",
            keepClearRegion: region,
            confidence: ConfidenceScore(clamping: 0.85)
        )
    }

    private func meshObstacle(
        anchorID: UUID,
        points: [Vec3]
    ) -> PlacementObstacleEvidence? {
        guard let first = points.first else {
            return nil
        }
        var minimum = first
        var maximum = first
        for point in points.dropFirst() {
            guard !Task.isCancelled else { return nil }
            minimum.x = min(minimum.x, point.x)
            minimum.y = min(minimum.y, point.y)
            minimum.z = min(minimum.z, point.z)
            maximum.x = max(maximum.x, point.x)
            maximum.y = max(maximum.y, point.y)
            maximum.z = max(maximum.z, point.z)
        }
        let halfThickness = policy.minimumSurfaceDimension * 0.5
        if maximum.x - minimum.x < policy.minimumSurfaceDimension {
            let center = (maximum.x + minimum.x) * 0.5
            minimum.x = center - halfThickness
            maximum.x = center + halfThickness
        }
        if maximum.y - minimum.y < policy.minimumSurfaceDimension {
            let center = (maximum.y + minimum.y) * 0.5
            minimum.y = center - halfThickness
            maximum.y = center + halfThickness
        }
        if maximum.z - minimum.z < policy.minimumSurfaceDimension {
            let center = (maximum.z + minimum.z) * 0.5
            minimum.z = center - halfThickness
            maximum.z = center + halfThickness
        }
        guard let bounds = try? AABB(min: minimum, max: maximum) else {
            return nil
        }
        return try? PlacementObstacleEvidence(
            objectID: ObjectID(rawValue: anchorID),
            bounds: bounds,
            confidence: ConfidenceScore(clamping: 0.85)
        )
    }

    private func objectEvidence(
        _ objects: [SpatialObjectMetadata],
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        around candidate: Vec3,
        meshObstacles: [PlacementObstacleEvidence]
    ) -> Result<ObjectEvidence, ARFurniturePlacementEvidenceIssue> {
        let currentMapObjects = objects.filter { $0.mapID == mapID }
        guard
            currentMapObjects.allSatisfy({
                $0.position.coordinateFrameID == coordinateFrameID
            })
        else {
            return .failure(.coordinateContextMismatch)
        }

        var obstacles = meshObstacles
        var isComplete = true
        for metadata in currentMapObjects.sorted(by: Self.objectOrder) {
            guard !Task.isCancelled else { return .failure(.surfaceUnavailable) }
            let object = metadata.object
            guard object.certainty == .confirmed, object.presence != .removed else {
                continue
            }
            let nearby: Bool
            if let bounds = object.bounds {
                nearby =
                    bounds.max.x >= candidate.x - policy.localEvidenceRadius
                    && bounds.min.x <= candidate.x + policy.localEvidenceRadius
                    && bounds.max.z >= candidate.z - policy.localEvidenceRadius
                    && bounds.min.z <= candidate.z + policy.localEvidenceRadius
            } else {
                nearby = horizontalDistance(object.position, candidate) <= policy.localEvidenceRadius
            }
            guard nearby else {
                continue
            }
            guard let bounds = object.bounds else {
                isComplete = false
                continue
            }
            let size = bounds.size
            guard size.x > 0, size.y > 0, size.z > 0 else {
                isComplete = false
                continue
            }
            let confidence = ConfidenceScore(
                clamping: [
                    object.confidence.geometry.value,
                    object.confidence.tracking.value,
                    object.confidence.identity.value,
                    object.confidence.objectState.value,
                ].min() ?? 0)
            if let obstacle = try? PlacementObstacleEvidence(
                objectID: object.id,
                bounds: bounds,
                confidence: confidence
            ) {
                obstacles.append(obstacle)
            } else {
                isComplete = false
            }
        }
        return .success(
            ObjectEvidence(
                obstacles: Array(obstacles.prefix(policy.maximumObstacles)),
                isComplete: isComplete && obstacles.count <= policy.maximumObstacles
            )
        )
    }

    private func passageEvidence(
        from observations: [PlacementObservationEvidence]
    ) -> [PlacementPassageEvidence] {
        observations.compactMap { observation in
            let region = observation.region
            let travelAxis: PlacementPassageTravelAxis =
                region.width >= region.depth ? .alongWidth : .alongDepth
            let availableCrossWidth =
                travelAxis == .alongWidth
                ? region.depth : region.width
            guard availableCrossWidth >= policy.requiredPassageWidth else {
                return nil
            }
            return try? PlacementPassageEvidence(
                identifier: "passage-\(observation.identifier)",
                region: region,
                travelAxis: travelAxis,
                requiredClearWidth: policy.requiredPassageWidth,
                confidence: observation.confidence
            )
        }
    }

    private func cameraAlignedYaw(_ transform: Matrix4x4Snapshot) -> Double? {
        ARHorizontalCameraBasis(cameraTransform: transform)?.yawRadians
    }

    private func worldPoint(
        _ local: SIMD3<Float>,
        transform: Matrix4x4Snapshot
    ) -> Vec3? {
        let value = transform.simdValue * SIMD4<Float>(local.x, local.y, local.z, 1)
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite,
            value.w.isFinite, abs(value.w) > Float.ulpOfOne
        else {
            return nil
        }
        return try? Vec3(
            x: Double(value.x / value.w),
            y: Double(value.y / value.w),
            z: Double(value.z / value.w)
        )
    }

    private func worldPoints(
        _ local: [SIMD3<Float>],
        transform: Matrix4x4Snapshot
    ) -> [Vec3]? {
        let values = local.compactMap { worldPoint($0, transform: transform) }
        return values.count == local.count ? values : nil
    }

    private func worldYaw(
        localAxis: SIMD3<Float>,
        transform: Matrix4x4Snapshot
    ) -> Double? {
        let value =
            transform.simdValue
            * SIMD4<Float>(
                localAxis.x,
                localAxis.y,
                localAxis.z,
                0
            )
        let length = hypot(Double(value.x), Double(value.z))
        guard length.isFinite, length > 1e-5 else {
            return nil
        }
        return atan2(Double(value.z), Double(value.x))
    }

    private func longestHorizontalPair(_ points: [Vec3]) -> (Vec3, Vec3)? {
        guard (2...3).contains(points.count), !Task.isCancelled else {
            return nil
        }
        var best: (Vec3, Vec3)?
        var bestDistance = -Double.infinity
        for firstIndex in points.indices {
            for secondIndex in points.indices where secondIndex > firstIndex {
                let first = points[firstIndex]
                let second = points[secondIndex]
                let distance = hypot(second.x - first.x, second.z - first.z)
                if distance > bestDistance {
                    bestDistance = distance
                    best = (first, second)
                }
            }
        }
        return best
    }

    private func horizontalDistance(_ lhs: Vec3, _ rhs: Vec3) -> Double {
        hypot(lhs.x - rhs.x, lhs.z - rhs.z)
    }

    private static func planeOrder(
        _ lhs: ARPlaneObservationSnapshot,
        _ rhs: ARPlaneObservationSnapshot
    ) -> Bool {
        lhs.anchorID.uuidString < rhs.anchorID.uuidString
    }

    private static func meshOrder(
        _ lhs: ARMeshObservationSnapshot,
        _ rhs: ARMeshObservationSnapshot
    ) -> Bool {
        lhs.anchorID.uuidString < rhs.anchorID.uuidString
    }

    private static func objectOrder(
        _ lhs: SpatialObjectMetadata,
        _ rhs: SpatialObjectMetadata
    ) -> Bool {
        lhs.object.id < rhs.object.id
    }
}

private struct MeshEvidence: Sendable {
    let walls: [PlacementWallEvidence]
    let doorways: [PlacementDoorwayEvidence]
    let obstacles: [PlacementObstacleEvidence]
    let floorTriangles: [[Vec3]]
    let localClassifiedTriangleCount: Int
    let hasEnoughLocalClassifiedGeometry: Bool
}

private struct ObjectEvidence: Sendable {
    let obstacles: [PlacementObstacleEvidence]
    let isComplete: Bool
}
