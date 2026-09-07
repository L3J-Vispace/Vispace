import Foundation
import VispaceCore

/// Display geometry for an already verified floor path. This builder never
/// smooths a corner or joins nonadjacent waypoints across unobserved space.
enum ARNavigationRibbonGeometry {
    struct Mesh: Sendable {
        var positions: [SIMD3<Float>] = []
        var triangleIndices: [UInt32] = []

        fileprivate mutating func appendQuad(_ points: [SIMD3<Double>]) {
            let base = UInt32(positions.count)
            positions.append(contentsOf: points.map { SIMD3<Float>($0) })
            for indices in [[0, 1, 2], [0, 2, 3]] {
                let first = points[indices[1]] - points[indices[0]]
                let second = points[indices[2]] - points[indices[0]]
                let facesUp = first.z * second.x - first.x * second.z >= 0
                let order = facesUp ? indices : [indices[0], indices[2], indices[1]]
                triangleIndices.append(contentsOf: order.map { base + UInt32($0) })
            }
        }
    }

    struct Geometry: Sendable {
        let origin: SIMD3<Float>
        let endpoint: SIMD3<Float>
        let halfWidth: Float
        let surface: Mesh
        let borders: Mesh
        let chevrons: Mesh
        let destination: Mesh
    }

    private struct Segment {
        let start: SIMD3<Double>
        let end: SIMD3<Double>
        let length: Double
        let direction: SIMD3<Double>
        let side: SIMD3<Double>
        let distanceFromStart: Double

        var slope: Double { (end.y - start.y) / length }
        var displacement: SIMD3<Double> { end - start }
    }

    private struct Run {
        let firstSegment: Int
        var lastSegment: Int
    }

    /// Caps work and preserves centimetre-scale Float precision in a local AR
    /// coordinate system. Invalid imported geometry must not reach RealityKit.
    static func make(
        waypoints: [Vec3],
        maximumHalfWidth: Double = 0.18
    ) -> Geometry? {
        guard !waypoints.isEmpty, waypoints.count <= 4_096,
              maximumHalfWidth.isFinite, maximumHalfWidth > 0 else { return nil }
        let halfWidth = min(0.18, maximumHalfWidth)
        // Widths below Float's useful floor-rendering precision have no visible
        // footprint; do not widen a narrow policy to make it renderable.
        guard halfWidth >= 0.0001 else { return nil }
        guard waypoints.allSatisfy({ point in
            [point.x, point.y, point.z].allSatisfy { $0.isFinite && abs($0) <= 10_000 }
        }) else { return nil }
        let first = waypoints[0]
        let origin = SIMD3<Double>(first.x, first.y, first.z)
        var points: [SIMD3<Double>] = []
        points.reserveCapacity(waypoints.count)
        for waypoint in waypoints {
            let point = SIMD3<Double>(waypoint.x, waypoint.y, waypoint.z) - origin
            guard abs(point.x) <= 1_000, abs(point.y) <= 1_000,
                  abs(point.z) <= 1_000 else { return nil }
            if let previous = points.last {
                if point == previous { continue }
                // A vertical jump is not evidence of a walkable ramp.
                guard hypot(point.x - previous.x, point.z - previous.z) >= 0.0001 else {
                    return nil
                }
            }
            points.append(point)
        }

        var segments: [Segment] = []
        var distance = 0.0
        if points.count > 1 {
            for index in 0..<(points.count - 1) {
                let start = points[index]
                let end = points[index + 1]
                let delta = end - start
                let length = hypot(delta.x, delta.z)
                distance += length
                guard distance <= 2_000 else { return nil }
                let direction = SIMD3<Double>(delta.x / length, 0, delta.z / length)
                segments.append(Segment(
                    start: start, end: end, length: length, direction: direction,
                    side: SIMD3<Double>(-direction.z, 0, direction.x),
                    distanceFromStart: distance - length
                ))
            }
        }

        var surface = Mesh()
        var borders = Mesh()
        let borderWidth = 0.012 * halfWidth / 0.18
        for (index, segment) in segments.enumerated() {
            // Do not normalize this average: miters can extend outside the
            // verified clearance. These offsets have magnitude at most one,
            // so each quad lies inside its original segment's swept capsule.
            let startSide = index == 0 ? segment.side : (segments[index - 1].side + segment.side) / 2
            let endSide = index == segments.count - 1 ? segment.side : (segment.side + segments[index + 1].side) / 2
            surface.appendQuad(quad(
                segment, startSide: startSide, endSide: endSide,
                lowerWidth: -halfWidth, upperWidth: halfWidth, lift: 0.012
            ))
            for side in [-1.0, 1.0] {
                borders.appendQuad(quad(
                    segment, startSide: startSide, endSide: endSide,
                    lowerWidth: side * (halfWidth - borderWidth),
                    upperWidth: side * halfWidth, lift: 0.014
                ))
            }
        }

        let endpoint = points[points.count - 1]
        return Geometry(
            origin: SIMD3<Float>(origin), endpoint: SIMD3<Float>(endpoint),
            halfWidth: Float(halfWidth), surface: surface, borders: borders,
            chevrons: makeChevrons(segments, halfWidth: halfWidth),
            destination: makeDestination(at: endpoint, radius: min(0.16, halfWidth))
        )
    }

    private static func quad(
        _ segment: Segment,
        startSide: SIMD3<Double>,
        endSide: SIMD3<Double>,
        lowerWidth: Double,
        upperWidth: Double,
        lift: Double
    ) -> [SIMD3<Double>] {
        let elevation = SIMD3<Double>(0, lift, 0)
        return [
            segment.start + startSide * lowerWidth + elevation,
            segment.end + endSide * lowerWidth + elevation,
            segment.end + endSide * upperWidth + elevation,
            segment.start + startSide * upperWidth + elevation,
        ]
    }

    private static func makeChevrons(_ segments: [Segment], halfWidth: Double) -> Mesh {
        var mesh = Mesh()
        guard !segments.isEmpty else { return mesh }
        var runs = [Run(firstSegment: 0, lastSegment: 0)]
        for index in segments.indices.dropFirst() {
            let previous = segments[index - 1].displacement
            let current = segments[index].displacement
            // Exact collinearity only. A tolerance could erase a small corner
            // or a floor-height change in a densely sampled verified route.
            let cross = SIMD3<Double>(
                previous.y * current.z - previous.z * current.y,
                previous.z * current.x - previous.x * current.z,
                previous.x * current.y - previous.y * current.x
            )
            let dot = previous.x * current.x + previous.y * current.y + previous.z * current.z
            if cross == .zero, dot > 0 {
                runs[runs.count - 1].lastSegment = index
            } else {
                runs.append(Run(firstSegment: index, lastSegment: index))
            }
        }

        let scale = halfWidth / 0.18
        let halfLength = 0.09 * scale
        let spacing = 0.75
        for run in runs {
            let first = segments[run.firstSegment]
            let last = segments[run.lastSegment]
            let runEnd = last.distanceFromStart + last.length
            let clearance = halfLength + 0.01
            let firstIndex = max(0, Int(ceil((first.distanceFromStart + clearance - spacing / 2) / spacing)))
            let lastIndex = Int(floor((runEnd - clearance - spacing / 2) / spacing))
            guard firstIndex <= lastIndex else { continue }
            for index in firstIndex...lastIndex {
                let along = spacing / 2 + Double(index) * spacing - first.distanceFromStart
                let center = first.start + first.direction * along + SIMD3<Double>(0, first.slope * along, 0)
                func point(_ lateral: Double, _ forward: Double) -> SIMD3<Double> {
                    center + first.side * (lateral * scale) + first.direction * (forward * scale)
                        + SIMD3<Double>(0, first.slope * forward * scale + 0.016, 0)
                }
                mesh.appendQuad([point(-0.09, -0.09), point(0, 0.09), point(0, 0.03), point(-0.06, -0.09)])
                mesh.appendQuad([point(0, 0.09), point(0.09, -0.09), point(0.06, -0.09), point(0, 0.03)])
            }
        }
        return mesh
    }

    private static func makeDestination(at endpoint: SIMD3<Double>, radius: Double) -> Mesh {
        var mesh = Mesh()
        let count = 48
        let innerRadius = radius * 0.84
        for index in 0..<count {
            let angle = Double(index) * 2 * .pi / Double(count)
            let next = Double(index + 1) * 2 * .pi / Double(count)
            func point(_ angle: Double, _ distance: Double) -> SIMD3<Double> {
                endpoint + SIMD3<Double>(cos(angle) * distance, 0.016, sin(angle) * distance)
            }
            mesh.appendQuad([point(angle, radius), point(next, radius), point(next, innerRadius), point(angle, innerRadius)])
        }
        return mesh
    }
}
