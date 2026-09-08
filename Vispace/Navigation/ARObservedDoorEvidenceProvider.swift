import Foundation
import VispaceCore
import simd

/// A classified surface only locates a candidate door. Its retained geometry
/// never establishes that the walking volume is currently empty.
struct ARObservedDoorSurface: Sendable {
    let identifier: String
    let bounds: AABB
    let vertices: [Vec3]
    let tangentX: Double
    let tangentZ: Double
    let minimumTangent: Double
    let maximumTangent: Double
    let planeCoordinate: Double
    let supportsOpeningMeasurement: Bool

    init?(identifier: String, vertices: [Vec3], supportsOpeningMeasurement: Bool) {
        guard vertices.count >= 3,
            let minX = vertices.map(\.x).min(), let maxX = vertices.map(\.x).max(),
            let minY = vertices.map(\.y).min(), let maxY = vertices.map(\.y).max(),
            let minZ = vertices.map(\.z).min(), let maxZ = vertices.map(\.z).max(),
            let bounds = try? AABB(
                min: Vec3(x: minX, y: minY, z: minZ),
                max: Vec3(x: maxX, y: maxY, z: maxZ))
        else { return nil }
        self.identifier = identifier
        self.bounds = bounds
        self.vertices = vertices
        // Project the longest horizontal extent, preserving arbitrary doorway
        // yaw instead of assuming AR world axes align to the room's walls.
        guard let first = vertices.first,
            let opposite = vertices.max(by: {
                hypot($0.x - first.x, $0.z - first.z) < hypot($1.x - first.x, $1.z - first.z)
            })
        else { return nil }
        let length = hypot(opposite.x - first.x, opposite.z - first.z)
        let tangentX = length > 0.001 ? (opposite.x - first.x) / length : 1
        let tangentZ = length > 0.001 ? (opposite.z - first.z) / length : 0
        self.tangentX = tangentX
        self.tangentZ = tangentZ
        let tangents = vertices.map { $0.x * tangentX + $0.z * tangentZ }
        let normals = vertices.map { -$0.x * tangentZ + $0.z * tangentX }
        let minimumTangent = tangents.min()!
        let maximumTangent = tangents.max()!
        self.minimumTangent = minimumTangent
        self.maximumTangent = maximumTangent
        planeCoordinate = (normals.min()! + normals.max()!) / 2
        let thickness = normals.max()! - normals.min()!
        let width = maximumTangent - minimumTangent
        // A complete vertical rectangle supplies measured width and height.
        // Partial/nonvertical sheets stay local blockers.
        let cornersCovered = [minY, maxY].allSatisfy { height in
            [minimumTangent, maximumTangent].allSatisfy { endpoint in
                vertices.contains { vertex in
                    abs(vertex.y - height) <= 0.02
                        && abs(vertex.x * tangentX + vertex.z * tangentZ - endpoint) <= 0.02
                }
            }
        }
        self.supportsOpeningMeasurement =
            supportsOpeningMeasurement && thickness <= 0.04
            && width >= 0.60 && width <= 3 && maxY - minY >= 1.90 && cornersCovered
    }

    var width: Double { maximumTangent - minimumTangent }

    func overlaps(center: Vec3, halfCell: Double) -> Bool {
        bounds.max.y > center.y + 0.05 && bounds.min.y < center.y + 1.8
            && bounds.max.x >= center.x - halfCell - 0.025
            && bounds.min.x <= center.x + halfCell + 0.025
            && bounds.max.z >= center.z - halfCell - 0.025
            && bounds.min.z <= center.z + halfCell + 0.025
    }

    func covers(_ other: ARObservedDoorSurface) -> Bool {
        guard supportsOpeningMeasurement else { return false }
        return other.vertices.allSatisfy { vertex in
            let tangent = vertex.x * tangentX + vertex.z * tangentZ
            return abs(-vertex.x * tangentZ + vertex.z * tangentX - planeCoordinate) <= 0.04
                && tangent >= minimumTangent - 0.04 && tangent <= maximumTangent + 0.04
                && vertex.y >= bounds.min.y - 0.04 && vertex.y <= bounds.max.y + 0.04
        }
    }

    func clearWidth(crossingFrom first: Vec3, to second: Vec3) -> Double? {
        let firstDistance = -first.x * tangentZ + first.z * tangentX - planeCoordinate
        let secondDistance = -second.x * tangentZ + second.z * tangentX - planeCoordinate
        guard (firstDistance <= 0 && secondDistance > 0) || (secondDistance <= 0 && firstDistance > 0),
            abs(firstDistance - secondDistance) > 0.000_001
        else { return nil }
        let fraction = firstDistance / (firstDistance - secondDistance)
        let x = first.x + fraction * (second.x - first.x)
        let z = first.z + fraction * (second.z - first.z)
        let tangent = x * tangentX + z * tangentZ
        guard tangent >= minimumTangent, tangent <= maximumTangent, width > 0 else { return nil }
        return max(0.01, min(tangent - minimumTangent, maximumTangent - tangent) * 2 - 0.10)
    }
}

/// Door passage requires two recent, spatially separate raw-depth views. Each
/// view checks every confident ray through every full-height touched grid cell;
/// one positive ray, a semantic label, or a retained mesh cannot open a portal.
struct ARObservedDoorEvidenceProvider: Sendable {
    struct Result {
        let mesh: [IndoorNavigationMeshEvidence]
        let doors: [IndoorNavigationDoorEvidence]
    }

    func observe(
        surfaces: [ARObservedDoorSurface], gridOrigin: Vec3, cellSize: Double,
        floors: [IndoorNavigationFloorEvidence], mesh: [IndoorNavigationMeshEvidence],
        frames: [ARNavigationDepthFrame], confidence: ConfidenceScore
    ) -> Result? {
        guard surfaces.count <= 1_000, floors.count <= 20_000, frames.count <= 16 else { return nil }
        if surfaces.isEmpty { return Result(mesh: mesh, doors: []) }
        let floorByCell = Dictionary(uniqueKeysWithValues: floors.map { ($0.cell, $0) })
        let meshByCell = Dictionary(uniqueKeysWithValues: mesh.map { ($0.cell, $0) })
        let occupancies = frames.compactMap {
            ARDepthNavigationOccupancy(
                pose: $0.pose, intrinsics: $0.intrinsics,
                imageDimensions: $0.imageDimensions, depth: $0.depth)
        }
        guard occupancies.count == frames.count else { return nil }
        var checks = 0
        var observationCache: [Int: [IndoorNavigationCell: ARDepthNavigationCellObservation]] = [:]
        func center(_ floor: IndoorNavigationFloorEvidence) -> Vec3? {
            try? Vec3(
                x: gridOrigin.x + Double(floor.cell.column) * cellSize, y: floor.elevation,
                z: gridOrigin.z + Double(floor.cell.row) * cellSize)
        }
        func observation(_ floor: IndoorNavigationFloorEvidence, frameIndex: Int)
            -> ARDepthNavigationCellObservation
        {
            if let cached = observationCache[frameIndex]?[floor.cell] { return cached }
            guard let center = center(floor) else { return .uncertain }
            let result = occupancies[frameIndex].observation(
                centerX: center.x, centerZ: center.z,
                floorElevation: floor.elevation, halfWidth: cellSize / 2, remainingChecks: &checks)
            observationCache[frameIndex, default: [:]][floor.cell] = result
            return result
        }
        var observations:
            [(
                surface: ARObservedDoorSurface, cells: [IndoorNavigationFloorEvidence],
                state: IndoorNavigationDoorState
            )] = []
        for surface in surfaces {
            guard !Task.isCancelled else { return nil }
            let cells = floors.filter { floor in
                center(floor).map { surface.overlaps(center: $0, halfCell: cellSize / 2) } == true
            }
            if cells.isEmpty { continue }
            var state = IndoorNavigationDoorState.unknown
            if !frames.isEmpty {
                let current = cells.map { observation($0, frameIndex: 0) }
                if current.contains(where: {
                    if case .blocked = $0 { return true }
                    return false
                }) {
                    // Closed describes the observed passage volume: a leaf or
                    // an object in the doorway both forbid traversal.
                    state = .closed
                } else if surface.supportsOpeningMeasurement,
                    cells.allSatisfy({
                        abs($0.elevation - surface.bounds.min.y) <= 0.15
                            && meshByCell[$0.cell]?.occupancy == .free
                    }),
                    current.allSatisfy({
                        if case .free = $0 { return true }
                        return false
                    }),
                    let first = frames.first
                {
                    let camera = first.pose.cameraTransform.column3
                    let independentView = frames.indices.dropFirst().contains { index in
                        let previous = frames[index]
                        let age = first.pose.timestamp - previous.pose.timestamp
                        let previousCamera = previous.pose.cameraTransform.column3
                        let baseline = hypot(
                            Double(camera.x - previousCamera.x), Double(camera.z - previousCamera.z))
                        guard age >= 0.1, age <= 1, baseline >= 0.05,
                            previous.pose.sessionToken == first.pose.sessionToken,
                            previous.pose.mapID == first.pose.mapID,
                            previous.pose.coordinateFrameID == first.pose.coordinateFrameID,
                            previous.pose.segmentID == first.pose.segmentID
                        else { return false }
                        return cells.allSatisfy {
                            if case .free = observation($0, frameIndex: index) { return true }
                            return false
                        }
                    }
                    if independentView { state = .open }
                }
            }
            observations.append((surface, cells, state))
        }
        var masked: [IndoorNavigationCell: IndoorNavigationMeshOccupancy] = [:]
        var doors: [String: IndoorNavigationDoorEvidence] = [:]
        let verifiedOpenSurfaces = observations.filter { $0.state == .open }.map(\.surface)
        for observed in observations {
            // Retained triangular door faces inside a fully verified plane are
            // covered by that same depth proof. Faces outside it stay blocking.
            if !observed.surface.supportsOpeningMeasurement,
                verifiedOpenSurfaces.contains(where: { $0.covers(observed.surface) })
            {
                continue
            }
            let surface = observed.surface
            for floor in observed.cells {
                if observed.state != .open {
                    let occupancy: IndoorNavigationMeshOccupancy =
                        observed.state == .closed ? .blocked : .unknown
                    if masked[floor.cell] != .blocked { masked[floor.cell] = occupancy }
                }
                guard let firstCenter = center(floor) else { return nil }
                for offset in [(1, 0), (0, 1)] {
                    let nextCell = IndoorNavigationCell(
                        level: floor.cell.level,
                        column: floor.cell.column + offset.0, row: floor.cell.row + offset.1)
                    guard let next = floorByCell[nextCell], let secondCenter = center(next) else { continue }
                    guard let clearWidth = surface.clearWidth(crossingFrom: firstCenter, to: secondCenter)
                    else { continue }
                    let state = observed.state == .open && clearWidth < cellSize ? .unknown : observed.state
                    let key =
                        "door-portal-\(floor.cell.level)-\(floor.cell.column)-\(floor.cell.row)-\(nextCell.column)-\(nextCell.row)"
                    if let existing = doors[key],
                        existing.state == .closed || (existing.state == .unknown && state == .open)
                    {
                        continue
                    }
                    let timestamp = frames.first?.pose.timestamp
                    guard doors.count < 1_000 || doors[key] != nil,
                        let door = try? IndoorNavigationDoorEvidence(
                            identifier: key,
                            firstCell: floor.cell, secondCell: nextCell, state: state,
                            confidence: confidence, clearWidth: clearWidth, observedAt: timestamp,
                            validUntil: timestamp.map { $0 + 0.75 })
                    else { return nil }
                    doors[key] = door
                }
            }
        }
        return Result(
            mesh: mesh.map { cell in
                guard cell.occupancy != .blocked, let state = masked[cell.cell] else { return cell }
                return IndoorNavigationMeshEvidence(
                    cell: cell.cell, occupancy: state, confidence: cell.confidence)
            }, doors: doors.values.sorted { $0.identifier < $1.identifier })
    }
}
