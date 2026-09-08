import Foundation
import VispaceCore
import simd

public enum ARPlaceFingerprintBuilderError: Error, Equatable, Sendable {
    case incompleteSurfaceSnapshot
    case insufficientSpatialEvidence
}

/// Converts ARKit's current, app-owned surface state into a compact place
/// descriptor. The result contains aggregate bins only: camera pixels, AR
/// feature points, mesh vertices, and anchor identifiers are never retained.
public struct ARPlaceFingerprintBuilder: Sendable {
    static let maximumSampledSurfacePoints = 4_096
    static let maximumLayoutObjects = 128
    static let maximumObjectDistancePairs = 2_048

    public init() {}

    public func makeFingerprint(
        from surfaces: ARSurfaceStateSnapshot,
        objects: [SpatialObjectMetadata],
        visualHistogram: NormalizedPlaceHistogram? = nil
    ) throws -> PlaceFingerprint {
        guard surfaces.isComplete else {
            throw ARPlaceFingerprintBuilderError.incompleteSurfaceSnapshot
        }

        let matchingObjects =
            objects
            .filter { metadata in
                metadata.position.coordinateFrameID == surfaces.coordinateFrameID
                    && metadata.object.certainty == .confirmed
                    && metadata.object.presence != .removed
            }
            .sorted { $0.object.id < $1.object.id }

        let samples = surfaceSamples(from: surfaces)
        let geometry = try normalizedHistogram(geometryBins(from: surfaces))
        let structure = try normalizedHistogram(structureBins(from: surfaces))
        let objectLayout = try objectLayoutHistogram(from: matchingObjects)
        let occupancy = try normalizedHistogram(occupancyBins(from: samples))

        guard geometry != nil || structure != nil || objectLayout != nil || occupancy != nil else {
            throw ARPlaceFingerprintBuilderError.insufficientSpatialEvidence
        }

        return try PlaceFingerprint(
            schema: .v1,
            visualHistogram: visualHistogram,
            geometryHistogram: geometry,
            structureHistogram: structure,
            objectLayoutHistogram: objectLayout,
            spatialOccupancyHistogram: occupancy,
            coarseExtent: try coarseExtent(from: samples),
            observedObjectCount: matchingObjects.count
        )
    }

    private func geometryBins(from surfaces: ARSurfaceStateSnapshot) -> [Double] {
        var bins = Array(repeating: 0.0, count: PlaceFingerprintSchema.v1.geometryBinCount)

        for plane in surfaces.planes.values {
            let area = max(planeArea(plane), 0.01)
            switch plane.alignment {
            case .horizontal:
                bins[0] += area
            case .vertical:
                bins[1] += area
            case .unknown:
                bins[2] += area
            }

            switch area {
            case ..<1:
                bins[4] += 1
            case ..<4:
                bins[5] += 1
            default:
                bins[6] += 1
            }

            if plane.boundaryVertices.count <= 4 {
                bins[10] += 1
            } else {
                bins[11] += min(Double(plane.boundaryVertices.count) / 16, 8)
            }
        }

        for mesh in surfaces.meshes.values {
            let triangleCount = mesh.triangleIndices.count / 3
            bins[3] += log1p(Double(triangleCount))
            switch triangleCount {
            case ..<500:
                bins[7] += 1
            case ..<5_000:
                bins[8] += 1
            default:
                bins[9] += 1
            }
        }

        return bins
    }

    private func structureBins(from surfaces: ARSurfaceStateSnapshot) -> [Double] {
        var bins = Array(repeating: 0.0, count: PlaceFingerprintSchema.v1.structureBinCount)

        for plane in surfaces.planes.values {
            let weight = max(planeArea(plane), 0.01)
            bins[classificationIndex(plane.classification)] += weight
            switch plane.alignment {
            case .horizontal:
                bins[9] += weight
            case .vertical:
                bins[10] += weight
            case .unknown:
                break
            }
        }

        for mesh in surfaces.meshes.values {
            let classifications = deterministicallySample(
                mesh.faceClassifications,
                limit: Self.maximumSampledSurfacePoints
            )
            if classifications.isEmpty {
                bins[0] += 1
            } else {
                for classification in classifications {
                    bins[classificationIndex(classification)] += 1
                }
            }
            bins[11] += log1p(Double(mesh.triangleIndices.count / 3))
        }

        return bins
    }

    private func surfaceSamples(from surfaces: ARSurfaceStateSnapshot) -> [SurfaceSample] {
        let planeValues = surfaces.planes.values.sorted { lhs, rhs in
            lhs.anchorID.uuidString < rhs.anchorID.uuidString
        }
        let meshValues = surfaces.meshes.values.sorted { lhs, rhs in
            lhs.anchorID.uuidString < rhs.anchorID.uuidString
        }
        let anchorCount = max(1, planeValues.count + meshValues.count)
        let quota = max(4, Self.maximumSampledSurfacePoints / anchorCount)
        var samples: [SurfaceSample] = []
        samples.reserveCapacity(Self.maximumSampledSurfacePoints)

        for plane in planeValues {
            appendTransformed(
                plane.center,
                transform: plane.transform,
                kind: .plane,
                to: &samples
            )
            for vertex in deterministicallySample(
                plane.boundaryVertices,
                limit: max(0, quota - 1)
            ) {
                appendTransformed(
                    vertex,
                    transform: plane.transform,
                    kind: .plane,
                    to: &samples
                )
            }
        }

        for mesh in meshValues {
            for vertex in deterministicallySample(mesh.vertices, limit: quota) {
                appendTransformed(
                    vertex,
                    transform: mesh.transform,
                    kind: .mesh,
                    to: &samples
                )
            }
        }

        if samples.count > Self.maximumSampledSurfacePoints {
            samples.removeLast(samples.count - Self.maximumSampledSurfacePoints)
        }
        return samples
    }

    private func occupancyBins(from samples: [SurfaceSample]) -> [Double] {
        var bins = Array(
            repeating: 0.0,
            count: PlaceFingerprintSchema.v1.spatialOccupancyBinCount
        )
        guard let bounds = sampleBounds(samples) else {
            return bins
        }

        let centerX = (bounds.minimum.x + bounds.maximum.x) * 0.5
        let centerZ = (bounds.minimum.z + bounds.maximum.z) * 0.5
        let heightSpan = max(bounds.maximum.y - bounds.minimum.y, 0.001)
        let maximumRadius = max(
            samples.map { sample in
                hypot(sample.point.x - centerX, sample.point.z - centerZ)
            }.max() ?? 0,
            0.001
        )

        for sample in samples {
            let normalizedHeight = (sample.point.y - bounds.minimum.y) / heightSpan
            let normalizedRadius =
                hypot(
                    sample.point.x - centerX,
                    sample.point.z - centerZ
                ) / maximumRadius
            let heightBin = min(3, max(0, Int(floor(normalizedHeight * 4))))
            let radiusBin = min(3, max(0, Int(floor(normalizedRadius * 4))))
            let sourceOffset = sample.kind == .plane ? 0 : 16
            bins[sourceOffset + (heightBin * 4) + radiusBin] += 1
        }
        return bins
    }

    private func objectLayoutHistogram(
        from objects: [SpatialObjectMetadata]
    ) throws -> NormalizedPlaceHistogram? {
        guard !objects.isEmpty else {
            return nil
        }
        let bounded = Array(objects.prefix(Self.maximumLayoutObjects))
        var labelBins = Array(repeating: 0.0, count: 8)
        var distanceBins = Array(repeating: 0.0, count: 8)

        for metadata in bounded {
            let label = metadata.object.semanticLabel
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            labelBins[Int(stableHash(label) % UInt64(labelBins.count))] += 1
        }

        var pairCount = 0
        if bounded.count > 1 {
            outerLoop: for leftIndex in 0..<(bounded.count - 1) {
                for rightIndex in (leftIndex + 1)..<bounded.count {
                    let distance = bounded[leftIndex].object.position.distance(
                        to: bounded[rightIndex].object.position
                    )
                    distanceBins[distanceBin(for: distance)] += 1
                    pairCount += 1
                    if pairCount >= Self.maximumObjectDistancePairs {
                        break outerLoop
                    }
                }
            }
        }

        let labelTotal = labelBins.reduce(0, +)
        let distanceTotal = distanceBins.reduce(0, +)
        let hasDistances = distanceTotal > 0
        let labelWeight = hasDistances ? 0.5 : 1.0
        let distanceWeight = hasDistances ? 0.5 : 0.0
        let values =
            labelBins.map { ($0 / labelTotal) * labelWeight }
            + distanceBins.map { distanceTotal > 0 ? ($0 / distanceTotal) * distanceWeight : 0 }
        return try NormalizedPlaceHistogram(values: values)
    }

    private func coarseExtent(from samples: [SurfaceSample]) throws -> CoarsePlaceExtent? {
        guard let bounds = sampleBounds(samples) else {
            return nil
        }
        let x = bounds.maximum.x - bounds.minimum.x
        let y = bounds.maximum.y - bounds.minimum.y
        let z = bounds.maximum.z - bounds.minimum.z
        guard x > 0.01, y > 0.01, z > 0.01 else {
            return nil
        }
        return try CoarsePlaceExtent(
            widthMeters: min(x, z),
            heightMeters: y,
            depthMeters: max(x, z)
        )
    }

    private func normalizedHistogram(_ bins: [Double]) throws -> NormalizedPlaceHistogram? {
        let total = bins.reduce(0, +)
        guard total.isFinite, total > 0 else {
            return nil
        }
        return try NormalizedPlaceHistogram(values: bins.map { $0 / total })
    }

    private func sampleBounds(
        _ samples: [SurfaceSample]
    ) -> (minimum: SIMD3<Double>, maximum: SIMD3<Double>)? {
        guard let first = samples.first else {
            return nil
        }
        var minimum = first.point
        var maximum = first.point
        for sample in samples.dropFirst() {
            minimum = simd_min(minimum, sample.point)
            maximum = simd_max(maximum, sample.point)
        }
        return (minimum, maximum)
    }

    private func appendTransformed(
        _ localPoint: SIMD3<Float>,
        transform: Matrix4x4Snapshot,
        kind: SurfaceSample.Kind,
        to samples: inout [SurfaceSample]
    ) {
        guard samples.count < Self.maximumSampledSurfacePoints else {
            return
        }
        let homogeneous =
            transform.simdValue
            * SIMD4<Float>(
                localPoint.x,
                localPoint.y,
                localPoint.z,
                1
            )
        guard homogeneous.w.isFinite, abs(homogeneous.w) > Float.ulpOfOne else {
            return
        }
        let point = SIMD3<Double>(
            Double(homogeneous.x / homogeneous.w),
            Double(homogeneous.y / homogeneous.w),
            Double(homogeneous.z / homogeneous.w)
        )
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
            return
        }
        samples.append(SurfaceSample(point: point, kind: kind))
    }

    private func deterministicallySample<Element>(
        _ values: [Element],
        limit: Int
    ) -> [Element] {
        guard limit > 0, !values.isEmpty else {
            return []
        }
        guard values.count > limit else {
            return values
        }
        let stride = Int(ceil(Double(values.count) / Double(limit)))
        return Swift.stride(from: 0, to: values.count, by: stride)
            .prefix(limit)
            .map { values[$0] }
    }

    private func planeArea(_ plane: ARPlaneObservationSnapshot) -> Double {
        let dimensions = [
            abs(Double(plane.extent.x)),
            abs(Double(plane.extent.y)),
            abs(Double(plane.extent.z)),
        ].sorted(by: >)
        return dimensions[0] * dimensions[1]
    }

    private func classificationIndex(_ value: ARPlaneClassificationSnapshot) -> Int {
        switch value {
        case .none: 0
        case .wall: 1
        case .floor: 2
        case .ceiling: 3
        case .table: 4
        case .seat: 5
        case .window: 6
        case .door: 7
        case .unknown: 8
        }
    }

    private func classificationIndex(_ value: ARMeshClassificationSnapshot) -> Int {
        switch value {
        case .none: 0
        case .wall: 1
        case .floor: 2
        case .ceiling: 3
        case .table: 4
        case .seat: 5
        case .window: 6
        case .door: 7
        case .unknown: 8
        }
    }

    private func distanceBin(for distance: Double) -> Int {
        switch distance {
        case ..<0.25: 0
        case ..<0.5: 1
        case ..<1: 2
        case ..<2: 3
        case ..<3: 4
        case ..<5: 5
        case ..<8: 6
        default: 7
        }
    }

    private func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

private struct SurfaceSample: Sendable {
    enum Kind: Sendable {
        case plane
        case mesh
    }

    let point: SIMD3<Double>
    let kind: Kind
}
