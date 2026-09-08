import Foundation
import VispaceCore
import simd

enum ARDepthNavigationCellObservation {
    case free
    case blocked
    case unobserved
    case uncertain
}

/// Raw (unsmoothed) depth is a current observation, unlike retained mesh.
/// Only fully visible, confident rays through the entire walking volume can
/// establish a free cell. Occluded, out-of-view and unmeasured cells stay unknown.
struct ARDepthNavigationOccupancy: Sendable {
    private let depth: ARDepthSnapshot
    private let confidence: [UInt8]
    private let camera: simd_float4x4
    private let worldToCamera: simd_float4x4
    private let fx: Float
    private let fy: Float
    private let cx: Float
    private let cy: Float
    private static let maximumPixelChecks = 1_000_000

    init?(
        pose: ARPoseSnapshot, intrinsics: Matrix3x3Snapshot,
        imageDimensions: ImageDimensions, depth: ARDepthSnapshot
    ) {
        let width = depth.dimensions.width
        let height = depth.dimensions.height
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, count <= 1_000_000,
            depth.depthMeters.count == count, let confidence = depth.confidence,
            confidence.count == count, imageDimensions.width > 0, imageDimensions.height > 0
        else { return nil }
        let fx = intrinsics.column0.x * Float(width) / Float(imageDimensions.width)
        let fy = intrinsics.column1.y * Float(height) / Float(imageDimensions.height)
        let cx = intrinsics.column2.x * Float(width) / Float(imageDimensions.width)
        let cy = intrinsics.column2.y * Float(height) / Float(imageDimensions.height)
        let camera = pose.cameraTransform.simdValue
        let rotation = simd_float3x3(columns: (
            SIMD3<Float>(camera.columns.0.x, camera.columns.0.y, camera.columns.0.z),
            SIMD3<Float>(camera.columns.1.x, camera.columns.1.y, camera.columns.1.z),
            SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        ))
        let orthogonality = rotation.transpose * rotation
        guard [fx, fy, cx, cy].allSatisfy(\.isFinite), fx > 0, fy > 0,
            abs(simd_determinant(camera) - 1) < 0.001,
            abs(camera.columns.0.w) < 0.000_001, abs(camera.columns.1.w) < 0.000_001,
            abs(camera.columns.2.w) < 0.000_001, abs(camera.columns.3.w - 1) < 0.000_001,
            (0..<3).allSatisfy({ column in (0..<3).allSatisfy { row in
                abs(orthogonality[column][row] - (column == row ? 1 : 0)) < 0.001
            } }),
            (0..<4).allSatisfy({ column in (0..<4).allSatisfy { camera[column][$0].isFinite } })
        else { return nil }
        self.depth = depth
        self.confidence = confidence
        self.camera = camera
        self.worldToCamera = camera.inverse
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
    }

    func occupancy(
        centerX: Double, centerZ: Double, floorElevation: Double, halfWidth: Double,
        remainingChecks: inout Int
    ) -> IndoorNavigationMeshOccupancy {
        switch observation(centerX: centerX, centerZ: centerZ, floorElevation: floorElevation,
            halfWidth: halfWidth, remainingChecks: &remainingChecks) {
        case .free: .free
        case .blocked: .blocked
        case .unobserved, .uncertain: .unknown
        }
    }

    func observation(
        centerX: Double, centerZ: Double, floorElevation: Double, halfWidth: Double,
        remainingChecks: inout Int
    ) -> ARDepthNavigationCellObservation {
        guard !Task.isCancelled,
            remainingChecks >= 0, remainingChecks <= Self.maximumPixelChecks,
            [centerX, centerZ, floorElevation, halfWidth].allSatisfy(\.isFinite), halfWidth > 0
        else { return .uncertain }
        let lower = SIMD3<Float>(Float(centerX - halfWidth), Float(floorElevation + 0.10), Float(centerZ - halfWidth))
        let upper = SIMD3<Float>(Float(centerX + halfWidth), Float(floorElevation + 1.80), Float(centerZ + halfWidth))
        var minU = Float.infinity
        var maxU = -Float.infinity
        var minV = Float.infinity
        var maxV = -Float.infinity
        var allCornersInFront = true
        var allCornersWithinRange = true
        var hasFrontCorner = false
        for x in [lower.x, upper.x] {
            for y in [lower.y, upper.y] {
                for z in [lower.z, upper.z] {
                    let point = worldToCamera * SIMD4<Float>(x, y, z, 1)
                    let meters = -point.z
                    guard meters.isFinite else { return .uncertain }
                    if meters <= 0.15 { allCornersInFront = false; continue }
                    hasFrontCorner = true
                    if meters > 5 { allCornersWithinRange = false }
                    let u = fx * point.x / meters + cx
                    let v = -fy * point.y / meters + cy
                    guard u.isFinite, v.isFinite else { return .uncertain }
                    minU = min(minU, u); maxU = max(maxU, u)
                    minV = min(minV, v); maxV = max(maxV, v)
                }
            }
        }
        let width = depth.dimensions.width
        let height = depth.dimensions.height
        guard hasFrontCorner else { return .unobserved }
        if !allCornersInFront {
            minU = 0; maxU = Float(width - 1)
            minV = 0; maxV = Float(height - 1)
        }
        // A texel margin avoids treating an edge-clipped volume as covered.
        let fullyVisible = allCornersInFront && allCornersWithinRange && minU >= 1 && minV >= 1
            && maxU < Float(width - 1) && maxV < Float(height - 1)
        guard maxU >= 0, maxV >= 0, minU <= Float(width - 1), minV <= Float(height - 1)
        else { return .unobserved }
        let xRange = Int(floor(max(0, minU)))...Int(ceil(min(Float(width - 1), maxU)))
        let yRange = Int(floor(max(0, minV)))...Int(ceil(min(Float(height - 1), maxV)))
        let required = xRange.count * yRange.count
        guard required <= Self.maximumPixelChecks - remainingChecks else { return .uncertain }
        remainingChecks += required
        let origin = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        var intersectingRays = 0
        var hasUnknownRay = false
        for v in yRange {
            guard !Task.isCancelled else { return .uncertain }
            for u in xRange {
                let rawDirection = camera * SIMD4<Float>((Float(u) - cx) / fx, -(Float(v) - cy) / fy, -1, 0)
                let direction = SIMD3<Float>(rawDirection.x, rawDirection.y, rawDirection.z)
                guard let range = intersection(origin: origin, direction: direction, lower: lower, upper: upper)
                else { continue }
                intersectingRays += 1
                let index = v * width + u
                let observed = depth.depthMeters[index]
                guard confidence[index] == ARDepthConfidence.high.rawValue,
                    observed.isFinite, observed >= 0.15, observed <= 8
                else { hasUnknownRay = true; continue }
                if observed < range.lowerBound - 0.05 { hasUnknownRay = true; continue }
                if observed <= range.upperBound + 0.05 { return .blocked }
            }
        }
        if hasUnknownRay { return .uncertain }
        return intersectingRays > 0 && fullyVisible ? .free : .unobserved
    }

    private func intersection(
        origin: SIMD3<Float>, direction: SIMD3<Float>, lower: SIMD3<Float>, upper: SIMD3<Float>
    ) -> ClosedRange<Float>? {
        var near: Float = 0
        var far = Float.infinity
        for axis in 0..<3 {
            if abs(direction[axis]) < 0.000_001 {
                guard origin[axis] >= lower[axis], origin[axis] <= upper[axis] else { return nil }
                continue
            }
            let first = (lower[axis] - origin[axis]) / direction[axis]
            let second = (upper[axis] - origin[axis]) / direction[axis]
            near = max(near, min(first, second))
            far = min(far, max(first, second))
            guard near <= far else { return nil }
        }
        guard near.isFinite, far.isFinite, far > 0 else { return nil }
        return near...far
    }
}
