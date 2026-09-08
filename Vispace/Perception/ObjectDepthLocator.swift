import Foundation
import VispaceCore
import simd

public enum ObjectDepthLocationFailure: Equatable, Sendable {
    case invalidBoundingBox
    case identityMismatch
    case insufficientDepthSamples(required: Int, actual: Int)
    case inconsistentDepth
}

public enum ObjectDepthLocationResult: Equatable, Sendable {
    case located(LocatedObjectDetection)
    case unavailable(ObjectDepthLocationFailure)
}

public struct LocatedObjectDetection: Equatable, Sendable {
    public let detection: DetectedObject
    public let boundingBox: NormalizedBoundingBox2D
    public let position: FramedPosition
    public let bounds: AABB
    public let geometryConfidence: ConfidenceScore
    public let depthSource: ARDepthSource
    public let supportingSampleCount: Int
}

public struct ObjectDepthLocatorPolicy: Equatable, Sendable {
    public let minimumValidSamples: Int
    public let maximumWorldSpread: Float

    public init(minimumValidSamples: Int = 2, maximumWorldSpread: Float = 0.30) {
        self.minimumValidSamples = max(1, minimumValidSamples)
        self.maximumWorldSpread =
            maximumWorldSpread.isFinite && maximumWorldSpread > 0
            ? maximumWorldSpread
            : 0.30
    }
}

/// Samples a small interior grid rather than trusting the bounding-box center
/// alone. A medoid-supported world-space cluster rejects holes and background
/// depth that commonly appear inside chairs, tables, and partly occluded items.
public struct ObjectDepthLocator: Sendable {
    public let policy: ObjectDepthLocatorPolicy
    public let depthSampler: ARDepthSampler

    private let relativeSamplePoints: [SIMD2<Double>] = [
        SIMD2<Double>(0.50, 0.50),
        SIMD2<Double>(0.35, 0.35),
        SIMD2<Double>(0.65, 0.35),
        SIMD2<Double>(0.35, 0.65),
        SIMD2<Double>(0.65, 0.65),
    ]

    public init(
        policy: ObjectDepthLocatorPolicy = ObjectDepthLocatorPolicy(),
        depthSampler: ARDepthSampler = ARDepthSampler()
    ) {
        self.policy = policy
        self.depthSampler = depthSampler
    }

    public func locate(
        _ detection: DetectedObject,
        in frame: ARFrameSnapshot,
        currentIdentity: ARCaptureIdentity
    ) -> ObjectDepthLocationResult {
        guard detection.boundingBox.isValidNonEmpty else {
            return .unavailable(.invalidBoundingBox)
        }
        guard
            currentIdentity.status == .confirmed,
            currentIdentity.coordinateFrameID == frame.pose.coordinateFrameID,
            currentIdentity.segmentID == frame.pose.segmentID
        else {
            return .unavailable(.identityMismatch)
        }

        let sampled = relativeSamplePoints.compactMap { relativePoint -> ARDepthSample? in
            guard
                let imagePoint = detection.boundingBox.cameraImageTopLeftPoint(
                    relativeToTopLeft: relativePoint,
                    for: frame.imageOrientation
                )
            else {
                return nil
            }
            guard
                case .sample(let sample) = depthSampler.sample(
                    normalizedImagePoint: imagePoint,
                    in: frame
                )
            else {
                return nil
            }
            return sample
        }
        // Multiple requested points can collapse onto the same low-resolution
        // depth texel. Count that texel once so support confidence reflects
        // independent sensor evidence rather than repeated reads.
        var uniqueSamples: [DepthSampleKey: ARDepthSample] = [:]
        for sample in sampled {
            let key = DepthSampleKey(
                source: sample.source,
                x: sample.depthPixel.x,
                y: sample.depthPixel.y
            )
            uniqueSamples[key] = uniqueSamples[key] ?? sample
        }
        let samples = uniqueSamples.values.sorted { left, right in
            if left.source.rawValue != right.source.rawValue {
                return left.source.rawValue < right.source.rawValue
            }
            if left.depthPixel.y != right.depthPixel.y {
                return left.depthPixel.y < right.depthPixel.y
            }
            return left.depthPixel.x < right.depthPixel.x
        }
        guard samples.count >= policy.minimumValidSamples else {
            return .unavailable(
                .insufficientDepthSamples(
                    required: policy.minimumValidSamples,
                    actual: samples.count
                )
            )
        }

        guard let cluster = strongestCluster(in: samples),
            cluster.count >= policy.minimumValidSamples,
            let representative = medoid(in: cluster)
        else {
            return .unavailable(.inconsistentDepth)
        }
        let maximumSpread =
            cluster.map {
                simd_distance($0.worldPosition, representative.worldPosition)
            }.max() ?? .infinity
        guard maximumSpread <= policy.maximumWorldSpread else {
            return .unavailable(.inconsistentDepth)
        }
        guard
            let bounds = conservativeBounds(
                for: detection,
                representative: representative,
                supportingSamples: cluster,
                frame: frame
            )
        else {
            return .unavailable(.inconsistentDepth)
        }

        do {
            let positionValue = try Vec3(
                x: Double(representative.worldPosition.x),
                y: Double(representative.worldPosition.y),
                z: Double(representative.worldPosition.z)
            )
            let position = try FramedPosition(
                coordinateFrameID: currentIdentity.coordinateFrameID,
                value: positionValue,
                observedAt: frame.pose.capturedAt,
                trackingQuality: .normal,
                uncertainty: conservativeUncertainty(in: cluster)
            )
            let box = try NormalizedBoundingBox2D(
                x: detection.boundingBox.x,
                y: detection.boundingBox.y,
                width: detection.boundingBox.width,
                height: detection.boundingBox.height
            )
            return .located(
                LocatedObjectDetection(
                    detection: detection,
                    boundingBox: box,
                    position: position,
                    bounds: bounds,
                    geometryConfidence: geometryConfidence(
                        cluster: cluster,
                        maximumSpread: maximumSpread
                    ),
                    depthSource: representative.source,
                    supportingSampleCount: cluster.count
                )
            )
        } catch {
            return .unavailable(.inconsistentDepth)
        }
    }

    private func strongestCluster(in samples: [ARDepthSample]) -> [ARDepthSample]? {
        samples.map { candidate in
            samples.filter {
                simd_distance($0.worldPosition, candidate.worldPosition)
                    <= policy.maximumWorldSpread
            }
        }
        .sorted { left, right in
            if left.count != right.count {
                return left.count > right.count
            }
            let leftSpread = totalPairwiseDistance(in: left)
            let rightSpread = totalPairwiseDistance(in: right)
            if leftSpread != rightSpread {
                return leftSpread < rightSpread
            }
            return depthPixelSortKey(left) < depthPixelSortKey(right)
        }
        .first
    }

    private func medoid(in samples: [ARDepthSample]) -> ARDepthSample? {
        samples.min { left, right in
            let leftDistance = samples.reduce(Float.zero) {
                $0 + simd_distance(left.worldPosition, $1.worldPosition)
            }
            let rightDistance = samples.reduce(Float.zero) {
                $0 + simd_distance(right.worldPosition, $1.worldPosition)
            }
            if leftDistance != rightDistance {
                return leftDistance < rightDistance
            }
            if left.depthPixel.y != right.depthPixel.y {
                return left.depthPixel.y < right.depthPixel.y
            }
            return left.depthPixel.x < right.depthPixel.x
        }
    }

    private func totalPairwiseDistance(in samples: [ARDepthSample]) -> Float {
        guard samples.count > 1 else {
            return 0
        }
        var total = Float.zero
        for first in samples.indices {
            for second in samples.indices where second > first {
                total += simd_distance(
                    samples[first].worldPosition,
                    samples[second].worldPosition
                )
            }
        }
        return total
    }

    private func depthPixelSortKey(_ samples: [ARDepthSample]) -> String {
        samples
            .map { "\($0.depthPixel.y):\($0.depthPixel.x)" }
            .sorted()
            .joined(separator: ",")
    }

    private func geometryConfidence(
        cluster: [ARDepthSample],
        maximumSpread: Float
    ) -> ConfidenceScore {
        let depthConfidence =
            cluster.map { sample -> Double in
                switch sample.confidence {
                case .low: 0.45
                case .medium: 0.72
                case .high: 0.95
                }
            }.reduce(0, +) / Double(cluster.count)
        let support = Double(cluster.count) / Double(relativeSamplePoints.count)
        let consistency =
            1
            - min(
                1,
                Double(maximumSpread / policy.maximumWorldSpread)
            )
        return ConfidenceScore(
            clamping: depthConfidence * 0.65 + support * 0.15 + consistency * 0.20
        )
    }

    /// Projects the detector box at a near and far object depth. The resulting
    /// world AABB intentionally overestimates uncertain thickness so scene
    /// relations and placement collision checks never treat an observed point
    /// as the whole object volume.
    private func conservativeBounds(
        for detection: DetectedObject,
        representative: ARDepthSample,
        supportingSamples: [ARDepthSample],
        frame: ARFrameSnapshot
    ) -> AABB? {
        let relativeCorners = [
            SIMD2<Double>(0.05, 0.05),
            SIMD2<Double>(0.95, 0.05),
            SIMD2<Double>(0.95, 0.95),
            SIMD2<Double>(0.05, 0.95),
        ]
        let imageCorners = relativeCorners.compactMap {
            detection.boundingBox.cameraImageTopLeftPoint(
                relativeToTopLeft: $0,
                for: frame.imageOrientation
            )
        }
        guard imageCorners.count == relativeCorners.count else {
            return nil
        }

        let frontPoints = imageCorners.compactMap {
            worldPoint(
                normalizedImagePoint: $0,
                depthMeters: representative.depthMeters,
                frame: frame
            )
        }
        guard frontPoints.count == imageCorners.count,
            let frontMinimum = componentMinimum(frontPoints),
            let frontMaximum = componentMaximum(frontPoints)
        else {
            return nil
        }
        let projectedSpan = simd_length(frontMaximum - frontMinimum)
        let observedDepths = supportingSamples.map(\.depthMeters)
        guard let minimumObservedDepth = observedDepths.min(),
            let maximumObservedDepth = observedDepths.max()
        else {
            return nil
        }
        let observedHalfDepth = (maximumObservedDepth - minimumObservedDepth) / 2
        let conservativeHalfDepth = max(
            0.05,
            min(1.0, max(observedHalfDepth + 0.03, projectedSpan * 0.5))
        )
        let nearDepth = max(0.05, representative.depthMeters - conservativeHalfDepth)
        let farDepth = representative.depthMeters + conservativeHalfDepth
        var worldPoints = supportingSamples.map(\.worldPosition)
        for depth in [nearDepth, farDepth] {
            let projected = imageCorners.compactMap {
                worldPoint(
                    normalizedImagePoint: $0,
                    depthMeters: depth,
                    frame: frame
                )
            }
            guard projected.count == imageCorners.count else {
                return nil
            }
            worldPoints.append(contentsOf: projected)
        }
        guard let minimum = componentMinimum(worldPoints),
            let maximum = componentMaximum(worldPoints)
        else {
            return nil
        }
        let padding = SIMD3<Float>(repeating: 0.02)
        let paddedMinimum = minimum - padding
        let paddedMaximum = maximum + padding
        guard
            let coreMinimum = try? Vec3(
                x: Double(paddedMinimum.x),
                y: Double(paddedMinimum.y),
                z: Double(paddedMinimum.z)
            ),
            let coreMaximum = try? Vec3(
                x: Double(paddedMaximum.x),
                y: Double(paddedMaximum.y),
                z: Double(paddedMaximum.z)
            )
        else {
            return nil
        }
        return try? AABB(min: coreMinimum, max: coreMaximum)
    }

    private func worldPoint(
        normalizedImagePoint: SIMD2<Float>,
        depthMeters: Float,
        frame: ARFrameSnapshot
    ) -> SIMD3<Float>? {
        let width = frame.cameraImageDimensions.width
        let height = frame.cameraImageDimensions.height
        let intrinsics = frame.cameraIntrinsics.simdValue
        guard width > 0, height > 0,
            normalizedImagePoint.x.isFinite,
            normalizedImagePoint.y.isFinite,
            (0...1).contains(normalizedImagePoint.x),
            (0...1).contains(normalizedImagePoint.y),
            depthMeters.isFinite, depthMeters > 0,
            intrinsics.columns.0.x.isFinite,
            intrinsics.columns.1.y.isFinite,
            intrinsics.columns.2.x.isFinite,
            intrinsics.columns.2.y.isFinite,
            abs(intrinsics.columns.0.x) > .ulpOfOne,
            abs(intrinsics.columns.1.y) > .ulpOfOne
        else {
            return nil
        }
        let u = normalizedImagePoint.x * Float(width)
        let v = normalizedImagePoint.y * Float(height)
        let cameraPoint = SIMD3<Float>(
            ((u - intrinsics.columns.2.x) / intrinsics.columns.0.x) * depthMeters,
            -((v - intrinsics.columns.2.y) / intrinsics.columns.1.y) * depthMeters,
            -depthMeters
        )
        let homogeneous =
            frame.pose.cameraTransform.simdValue
            * SIMD4<Float>(cameraPoint, 1)
        guard homogeneous.x.isFinite, homogeneous.y.isFinite,
            homogeneous.z.isFinite, homogeneous.w.isFinite,
            abs(homogeneous.w) > .ulpOfOne
        else {
            return nil
        }
        return SIMD3<Float>(homogeneous.x, homogeneous.y, homogeneous.z)
            / homogeneous.w
    }

    private func componentMinimum(_ points: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard var result = points.first else {
            return nil
        }
        for point in points.dropFirst() {
            result = simd_min(result, point)
        }
        return result
    }

    private func componentMaximum(_ points: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard var result = points.first else {
            return nil
        }
        for point in points.dropFirst() {
            result = simd_max(result, point)
        }
        return result
    }

    private func conservativeUncertainty(
        in samples: [ARDepthSample]
    ) -> SpatialPositionUncertainty {
        let minimum = samples.map(\.confidence).min() ?? .low
        switch minimum {
        case .low:
            return .lowConfidenceDepth
        case .medium:
            return .mediumConfidenceDepth
        case .high:
            return .highConfidenceDepth
        }
    }

    private struct DepthSampleKey: Hashable, Sendable {
        let source: ARDepthSource
        let x: Int
        let y: Int
    }
}
