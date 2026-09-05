import Foundation

/// Exact planar coverage checks for a requested rectangle. Bounding boxes,
/// triangle counts, and a few sampled points cannot establish floor coverage.
/// Invalid geometry, cancellation, or exhausted work budgets fail closed.
public enum HorizontalFootprintCoverage {
    private static let epsilon = 1e-9
    private static let maximumPolygonVertices = 512
    private static let maximumTriangles = 32_768
    private static let maximumFragments = 2_048
    private static let maximumOperations = 500_000

    public static func polygonCovers(
        _ region: PlacementHorizontalRegion,
        polygon: [Vec3],
        elevationTolerance: Double = 0.05
    ) -> Bool {
        guard !Task.isCancelled, (3...maximumPolygonVertices).contains(polygon.count),
            let points = projected(polygon, into: region, elevationTolerance: elevationTolerance)
        else { return false }
        var boundary = points
        if boundary.first == boundary.last { boundary.removeLast() }
        guard boundary.count >= 3, abs(signedArea(boundary)) > epsilon else { return false }
        for index in boundary.indices {
            guard !Task.isCancelled else { return false }
            let next = (index + 1) % boundary.count
            guard boundary[index] != boundary[next] else { return false }
            for other in boundary.indices where other > index {
                let otherNext = (other + 1) % boundary.count
                if next == other || otherNext == index { continue }
                if intersects(boundary[index], boundary[next], boundary[other], boundary[otherNext]) {
                    return false
                }
            }
        }
        let corners = rectangle(region)
        guard corners.allSatisfy({ contains($0, polygon: boundary) }) else { return false }
        // A concave notch can enter the footprint even when every corner is
        // inside. Reject any polygon boundary that crosses its open interior.
        let halfWidth = region.width * 0.5
        let halfDepth = region.depth * 0.5
        for index in boundary.indices {
            var segment = [boundary[index], boundary[(index + 1) % boundary.count]]
            for edge in corners.indices {
                segment = clip(segment, from: corners[edge], to: corners[(edge + 1) % 4], inside: true)
                if segment.isEmpty { break }
            }
            if !segment.isEmpty {
                let center = Point(
                    x: segment.reduce(0) { $0 + $1.x } / Double(segment.count),
                    z: segment.reduce(0) { $0 + $1.z } / Double(segment.count)
                )
                if abs(center.x) < halfWidth - epsilon && abs(center.z) < halfDepth - epsilon {
                    return false
                }
            }
        }
        return true
    }

    public static func trianglesCover(
        _ region: PlacementHorizontalRegion,
        triangles: [[Vec3]],
        elevationTolerance: Double = 0.05
    ) -> Bool {
        guard !Task.isCancelled, triangles.count <= maximumTriangles else { return false }
        var uncovered = [rectangle(region)]
        var operations = 0
        for triangle in triangles {
            guard !Task.isCancelled, triangle.count == 3 else { return false }
            guard var face = projected(triangle, into: region, elevationTolerance: elevationTolerance)
            else { continue }
            let area = signedArea(face)
            guard area.isFinite, abs(area) > epsilon else { continue }
            if area < 0 { face.reverse() }
            var next: [[Point]] = []
            for fragment in uncovered {
                operations += 1
                guard operations <= maximumOperations, !Task.isCancelled else { return false }
                var remaining = fragment
                // Subtract one convex triangle: keep each outside half-plane
                // while passing its inside remainder to the next edge.
                for edge in 0..<3 {
                    let outside = clip(remaining, from: face[edge], to: face[(edge + 1) % 3], inside: false)
                    if abs(signedArea(outside)) > epsilon { next.append(outside) }
                    remaining = clip(remaining, from: face[edge], to: face[(edge + 1) % 3], inside: true)
                    if remaining.isEmpty { break }
                }
                guard next.count <= maximumFragments else { return false }
            }
            uncovered = next
        }
        return !Task.isCancelled && uncovered.isEmpty
    }

    private struct Point: Equatable {
        let x: Double
        let z: Double
    }

    private static func projected(
        _ points: [Vec3], into region: PlacementHorizontalRegion, elevationTolerance: Double
    ) -> [Point]? {
        guard elevationTolerance.isFinite, elevationTolerance >= 0,
            region.width.isFinite, region.depth.isFinite,
            region.width > 0, region.depth > 0,
            region.width <= 1_000_000, region.depth <= 1_000_000
        else { return nil }
        let cosine = cos(region.yawRadians)
        let sine = sin(region.yawRadians)
        var result: [Point] = []
        for point in points {
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
                abs(point.y - region.center.y) <= elevationTolerance
            else { return nil }
            let dx = point.x - region.center.x
            let dz = point.z - region.center.z
            let local = Point(x: dx * cosine + dz * sine, z: -dx * sine + dz * cosine)
            guard local.x.isFinite, local.z.isFinite,
                abs(local.x) <= 1_000_000, abs(local.z) <= 1_000_000
            else { return nil }
            result.append(local)
        }
        return result
    }

    private static func rectangle(_ region: PlacementHorizontalRegion) -> [Point] {
        let x = region.width * 0.5
        let z = region.depth * 0.5
        return [Point(x: -x, z: -z), Point(x: x, z: -z), Point(x: x, z: z), Point(x: -x, z: z)]
    }

    private static func cross(_ a: Point, _ b: Point, _ p: Point) -> Double {
        (b.x - a.x) * (p.z - a.z) - (b.z - a.z) * (p.x - a.x)
    }

    private static func signedArea(_ polygon: [Point]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        return polygon.indices.reduce(0) { value, index in
            let next = polygon[(index + 1) % polygon.count]
            return value + polygon[index].x * next.z - next.x * polygon[index].z
        } * 0.5
    }

    private static func onSegment(_ p: Point, _ a: Point, _ b: Point) -> Bool {
        abs(cross(a, b, p)) <= epsilon
            && p.x >= min(a.x, b.x) - epsilon && p.x <= max(a.x, b.x) + epsilon
            && p.z >= min(a.z, b.z) - epsilon && p.z <= max(a.z, b.z) + epsilon
    }

    private static func intersects(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        if onSegment(a, c, d) || onSegment(b, c, d) || onSegment(c, a, b) || onSegment(d, a, b) {
            return true
        }
        return (cross(a, b, c) > 0) != (cross(a, b, d) > 0)
            && (cross(c, d, a) > 0) != (cross(c, d, b) > 0)
    }

    private static func contains(_ point: Point, polygon: [Point]) -> Bool {
        var result = false
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            if onSegment(point, a, b) { return true }
            if (a.z > point.z) != (b.z > point.z),
                point.x < (b.x - a.x) * (point.z - a.z) / (b.z - a.z) + a.x
            {
                result.toggle()
            }
        }
        return result
    }

    private static func clip(_ polygon: [Point], from a: Point, to b: Point, inside: Bool) -> [Point] {
        guard let last = polygon.last else { return [] }
        var previous = last
        var previousDistance = cross(a, b, previous)
        var result: [Point] = []
        for current in polygon {
            let distance = cross(a, b, current)
            let previousInside = inside ? previousDistance >= 0 : previousDistance <= 0
            let currentInside = inside ? distance >= 0 : distance <= 0
            if previousInside != currentInside {
                let amount = previousDistance / (previousDistance - distance)
                result.append(
                    Point(
                        x: previous.x + (current.x - previous.x) * amount,
                        z: previous.z + (current.z - previous.z) * amount
                    ))
            }
            if currentInside { result.append(current) }
            previous = current
            previousDistance = distance
        }
        return result
    }
}
