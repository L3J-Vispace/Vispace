import Foundation

/// A compact, privacy-preserving description of a place. Fingerprints contain
/// only aggregate bins, counts, and coarse dimensions; they never retain camera
/// pixels, feature points, or mesh vertices.
public enum PlaceFingerprintModality: String, Codable, CaseIterable, Hashable, Sendable {
    case visual
    case geometry
    case structure
    case objectLayout
    case spatialOccupancy
}

public enum PlaceFingerprintError: Error, Equatable, Sendable {
    case invalidSchemaBinCount(modality: PlaceFingerprintModality, maximum: Int)
    case schemaCapacityExceeded(maximum: Int)
    case invalidHistogramBinCount(actual: Int, maximum: Int)
    case nonFiniteHistogramValue(index: Int)
    case histogramValueOutOfRange(index: Int)
    case histogramNotNormalized
    case histogramBinCountMismatch(
        modality: PlaceFingerprintModality,
        expected: Int,
        actual: Int
    )
    case nonFiniteSpatialExtent
    case spatialExtentOutOfRange(maximumMeters: Double)
    case objectCountOutOfRange(maximum: Int)
    case incompatibleSchemas
}

/// Bin counts are part of the schema so fingerprints with different feature
/// layouts cannot accidentally be compared position by position.
public struct PlaceFingerprintSchema: Codable, Hashable, Sendable {
    public static let maximumBinsPerModality = 64
    public static let maximumTotalBins = 256

    public let version: UInt16
    public let visualBinCount: Int
    public let geometryBinCount: Int
    public let structureBinCount: Int
    public let objectLayoutBinCount: Int
    public let spatialOccupancyBinCount: Int

    public init(
        version: UInt16,
        visualBinCount: Int,
        geometryBinCount: Int,
        structureBinCount: Int,
        objectLayoutBinCount: Int,
        spatialOccupancyBinCount: Int
    ) throws {
        let counts: [(PlaceFingerprintModality, Int)] = [
            (.visual, visualBinCount),
            (.geometry, geometryBinCount),
            (.structure, structureBinCount),
            (.objectLayout, objectLayoutBinCount),
            (.spatialOccupancy, spatialOccupancyBinCount),
        ]
        for (modality, count) in counts {
            guard (1...Self.maximumBinsPerModality).contains(count) else {
                throw PlaceFingerprintError.invalidSchemaBinCount(
                    modality: modality,
                    maximum: Self.maximumBinsPerModality
                )
            }
        }
        guard counts.reduce(0, { $0 + $1.1 }) <= Self.maximumTotalBins else {
            throw PlaceFingerprintError.schemaCapacityExceeded(
                maximum: Self.maximumTotalBins
            )
        }

        self.version = version
        self.visualBinCount = visualBinCount
        self.geometryBinCount = geometryBinCount
        self.structureBinCount = structureBinCount
        self.objectLayoutBinCount = objectLayoutBinCount
        self.spatialOccupancyBinCount = spatialOccupancyBinCount
    }

    /// Version 1 uses small aggregate descriptors. The 4 x 4 x 2 occupancy
    /// grid is normalized and carries no original mesh samples.
    public static let v1 = try! Self(
        version: 1,
        visualBinCount: 16,
        geometryBinCount: 12,
        structureBinCount: 12,
        objectLayoutBinCount: 16,
        spatialOccupancyBinCount: 32
    )

    public func binCount(for modality: PlaceFingerprintModality) -> Int {
        switch modality {
        case .visual:
            visualBinCount
        case .geometry:
            geometryBinCount
        case .structure:
            structureBinCount
        case .objectLayout:
            objectLayoutBinCount
        case .spatialOccupancy:
            spatialOccupancyBinCount
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case visualBinCount
        case geometryBinCount
        case structureBinCount
        case objectLayoutBinCount
        case spatialOccupancyBinCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                version: container.decode(UInt16.self, forKey: .version),
                visualBinCount: container.decode(Int.self, forKey: .visualBinCount),
                geometryBinCount: container.decode(Int.self, forKey: .geometryBinCount),
                structureBinCount: container.decode(Int.self, forKey: .structureBinCount),
                objectLayoutBinCount: container.decode(Int.self, forKey: .objectLayoutBinCount),
                spatialOccupancyBinCount: container.decode(
                    Int.self,
                    forKey: .spatialOccupancyBinCount
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Place fingerprint schema dimensions exceed their bounds."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(visualBinCount, forKey: .visualBinCount)
        try container.encode(geometryBinCount, forKey: .geometryBinCount)
        try container.encode(structureBinCount, forKey: .structureBinCount)
        try container.encode(objectLayoutBinCount, forKey: .objectLayoutBinCount)
        try container.encode(spatialOccupancyBinCount, forKey: .spatialOccupancyBinCount)
    }
}

/// A bounded probability histogram. Requiring normalized input keeps the
/// comparison independent of observation duration and sample volume.
public struct NormalizedPlaceHistogram: Codable, Hashable, Sendable {
    public static let maximumBinCount = PlaceFingerprintSchema.maximumBinsPerModality
    public static let normalizationTolerance = 1e-6

    public let values: [Double]

    public init(values: [Double]) throws {
        guard (1...Self.maximumBinCount).contains(values.count) else {
            throw PlaceFingerprintError.invalidHistogramBinCount(
                actual: values.count,
                maximum: Self.maximumBinCount
            )
        }

        var sum = 0.0
        var compensation = 0.0
        for (index, value) in values.enumerated() {
            guard value.isFinite else {
                throw PlaceFingerprintError.nonFiniteHistogramValue(index: index)
            }
            guard (0...1).contains(value) else {
                throw PlaceFingerprintError.histogramValueOutOfRange(index: index)
            }

            // Kahan summation makes normalization checks stable for larger
            // schemas while preserving deterministic ordering.
            let adjusted = value - compensation
            let updated = sum + adjusted
            compensation = (updated - sum) - adjusted
            sum = updated
        }
        guard abs(sum - 1) <= Self.normalizationTolerance else {
            throw PlaceFingerprintError.histogramNotNormalized
        }
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = try container.decode([Double].self)
        do {
            try self.init(values: values)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Histogram bins must be finite, normalized, and within capacity."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

/// Coarse physical dimensions, bounded to reject corrupt or implausible room
/// extents before they enter place-association state.
public struct CoarsePlaceExtent: Codable, Hashable, Sendable {
    public static let maximumDimensionMeters = 100.0

    public let widthMeters: Double
    public let heightMeters: Double
    public let depthMeters: Double

    public init(widthMeters: Double, heightMeters: Double, depthMeters: Double) throws {
        let values = [widthMeters, heightMeters, depthMeters]
        guard values.allSatisfy(\.isFinite) else {
            throw PlaceFingerprintError.nonFiniteSpatialExtent
        }
        guard values.allSatisfy({ $0 > 0 && $0 <= Self.maximumDimensionMeters }) else {
            throw PlaceFingerprintError.spatialExtentOutOfRange(
                maximumMeters: Self.maximumDimensionMeters
            )
        }
        self.widthMeters = widthMeters
        self.heightMeters = heightMeters
        self.depthMeters = depthMeters
    }

    private enum CodingKeys: String, CodingKey {
        case widthMeters
        case heightMeters
        case depthMeters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                widthMeters: container.decode(Double.self, forKey: .widthMeters),
                heightMeters: container.decode(Double.self, forKey: .heightMeters),
                depthMeters: container.decode(Double.self, forKey: .depthMeters)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .widthMeters,
                in: container,
                debugDescription: "Spatial extents must be finite, positive, and within bounds."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(widthMeters, forKey: .widthMeters)
        try container.encode(heightMeters, forKey: .heightMeters)
        try container.encode(depthMeters, forKey: .depthMeters)
    }
}

public struct PlaceFingerprint: Codable, Hashable, Sendable {
    public static let maximumObservedObjectCount = 4_096

    public let schema: PlaceFingerprintSchema
    public let visualHistogram: NormalizedPlaceHistogram?
    public let geometryHistogram: NormalizedPlaceHistogram?
    public let structureHistogram: NormalizedPlaceHistogram?
    public let objectLayoutHistogram: NormalizedPlaceHistogram?
    public let spatialOccupancyHistogram: NormalizedPlaceHistogram?
    public let coarseExtent: CoarsePlaceExtent?
    public let observedObjectCount: Int?

    public init(
        schema: PlaceFingerprintSchema = .v1,
        visualHistogram: NormalizedPlaceHistogram? = nil,
        geometryHistogram: NormalizedPlaceHistogram? = nil,
        structureHistogram: NormalizedPlaceHistogram? = nil,
        objectLayoutHistogram: NormalizedPlaceHistogram? = nil,
        spatialOccupancyHistogram: NormalizedPlaceHistogram? = nil,
        coarseExtent: CoarsePlaceExtent? = nil,
        observedObjectCount: Int? = nil
    ) throws {
        let histograms: [(PlaceFingerprintModality, NormalizedPlaceHistogram?)] = [
            (.visual, visualHistogram),
            (.geometry, geometryHistogram),
            (.structure, structureHistogram),
            (.objectLayout, objectLayoutHistogram),
            (.spatialOccupancy, spatialOccupancyHistogram),
        ]
        for (modality, histogram) in histograms {
            guard let histogram else { continue }
            let expected = schema.binCount(for: modality)
            guard histogram.values.count == expected else {
                throw PlaceFingerprintError.histogramBinCountMismatch(
                    modality: modality,
                    expected: expected,
                    actual: histogram.values.count
                )
            }
        }
        if let observedObjectCount {
            guard (0...Self.maximumObservedObjectCount).contains(observedObjectCount) else {
                throw PlaceFingerprintError.objectCountOutOfRange(
                    maximum: Self.maximumObservedObjectCount
                )
            }
        }

        self.schema = schema
        self.visualHistogram = visualHistogram
        self.geometryHistogram = geometryHistogram
        self.structureHistogram = structureHistogram
        self.objectLayoutHistogram = objectLayoutHistogram
        self.spatialOccupancyHistogram = spatialOccupancyHistogram
        self.coarseExtent = coarseExtent
        self.observedObjectCount = observedObjectCount
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case visualHistogram
        case geometryHistogram
        case structureHistogram
        case objectLayoutHistogram
        case spatialOccupancyHistogram
        case coarseExtent
        case observedObjectCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                schema: container.decode(PlaceFingerprintSchema.self, forKey: .schema),
                visualHistogram: container.decodeIfPresent(
                    NormalizedPlaceHistogram.self,
                    forKey: .visualHistogram
                ),
                geometryHistogram: container.decodeIfPresent(
                    NormalizedPlaceHistogram.self,
                    forKey: .geometryHistogram
                ),
                structureHistogram: container.decodeIfPresent(
                    NormalizedPlaceHistogram.self,
                    forKey: .structureHistogram
                ),
                objectLayoutHistogram: container.decodeIfPresent(
                    NormalizedPlaceHistogram.self,
                    forKey: .objectLayoutHistogram
                ),
                spatialOccupancyHistogram: container.decodeIfPresent(
                    NormalizedPlaceHistogram.self,
                    forKey: .spatialOccupancyHistogram
                ),
                coarseExtent: container.decodeIfPresent(
                    CoarsePlaceExtent.self,
                    forKey: .coarseExtent
                ),
                observedObjectCount: container.decodeIfPresent(
                    Int.self,
                    forKey: .observedObjectCount
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .schema,
                in: container,
                debugDescription: "Fingerprint contents do not match their schema or capacity."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encodeIfPresent(visualHistogram, forKey: .visualHistogram)
        try container.encodeIfPresent(geometryHistogram, forKey: .geometryHistogram)
        try container.encodeIfPresent(structureHistogram, forKey: .structureHistogram)
        try container.encodeIfPresent(objectLayoutHistogram, forKey: .objectLayoutHistogram)
        try container.encodeIfPresent(
            spatialOccupancyHistogram,
            forKey: .spatialOccupancyHistogram
        )
        try container.encodeIfPresent(coarseExtent, forKey: .coarseExtent)
        try container.encodeIfPresent(observedObjectCount, forKey: .observedObjectCount)
    }
}

/// `.unavailable` is distinct from a measured zero. Consumers can therefore
/// avoid interpreting missing input as either a match or contradictory data.
public enum PlaceFingerprintSimilarity: Codable, Hashable, Sendable {
    case unavailable
    case available(ConfidenceScore)

    public var score: ConfidenceScore? {
        switch self {
        case .unavailable:
            nil
        case .available(let score):
            score
        }
    }

    fileprivate var conservativeScore: ConfidenceScore {
        score ?? .zero
    }
}

public struct PlaceFingerprintComparison: Codable, Hashable, Sendable {
    public let visual: PlaceFingerprintSimilarity
    public let geometry: PlaceFingerprintSimilarity
    public let structure: PlaceFingerprintSimilarity
    public let objectLayout: PlaceFingerprintSimilarity
    public let spatialOverlap: PlaceFingerprintSimilarity

    public init(
        visual: PlaceFingerprintSimilarity,
        geometry: PlaceFingerprintSimilarity,
        structure: PlaceFingerprintSimilarity,
        objectLayout: PlaceFingerprintSimilarity,
        spatialOverlap: PlaceFingerprintSimilarity
    ) {
        self.visual = visual
        self.geometry = geometry
        self.structure = structure
        self.objectLayout = objectLayout
        self.spatialOverlap = spatialOverlap
    }

    public var availableModalityCount: Int {
        [visual, geometry, structure, objectLayout, spatialOverlap]
            .compactMap(\.score)
            .count
    }

    /// Bridges into the existing place-recognition layer. Missing fingerprint
    /// modalities become zero-confidence evidence, never an implicit perfect
    /// match. Pose consistency must come from an independent alignment system.
    public func placeEvidence(
        poseConsistency: PlaceFingerprintSimilarity = .unavailable
    ) -> PlaceEvidence {
        PlaceEvidence(
            visual: visual.conservativeScore,
            geometry: geometry.conservativeScore,
            structure: structure.conservativeScore,
            poseConsistency: poseConsistency.conservativeScore,
            objectLayout: objectLayout.conservativeScore,
            spatialOverlap: spatialOverlap.conservativeScore
        )
    }
}

public struct PlaceFingerprintComparator: Sendable {
    public init() {}

    public func compare(
        _ lhs: PlaceFingerprint,
        _ rhs: PlaceFingerprint
    ) throws -> PlaceFingerprintComparison {
        guard lhs.schema == rhs.schema else {
            throw PlaceFingerprintError.incompatibleSchemas
        }

        let visual = histogramSimilarity(lhs.visualHistogram, rhs.visualHistogram)
        let geometry = combinedSimilarity([
            histogramScore(lhs.geometryHistogram, rhs.geometryHistogram),
            extentShapeScore(lhs.coarseExtent, rhs.coarseExtent),
        ])
        let structure = histogramSimilarity(
            lhs.structureHistogram,
            rhs.structureHistogram
        )
        let objectLayout = combinedSimilarity([
            histogramScore(lhs.objectLayoutHistogram, rhs.objectLayoutHistogram),
            objectCountScore(lhs.observedObjectCount, rhs.observedObjectCount),
        ])
        let spatialOverlap = combinedSimilarity([
            histogramScore(
                lhs.spatialOccupancyHistogram,
                rhs.spatialOccupancyHistogram
            ),
            extentOverlapScore(lhs.coarseExtent, rhs.coarseExtent),
        ])

        return PlaceFingerprintComparison(
            visual: visual,
            geometry: geometry,
            structure: structure,
            objectLayout: objectLayout,
            spatialOverlap: spatialOverlap
        )
    }

    private func histogramSimilarity(
        _ lhs: NormalizedPlaceHistogram?,
        _ rhs: NormalizedPlaceHistogram?
    ) -> PlaceFingerprintSimilarity {
        guard let score = histogramScore(lhs, rhs) else {
            return .unavailable
        }
        return .available(score)
    }

    /// Missing subfeatures contribute neither false agreement nor false
    /// disagreement. A modality is unavailable only when no shared subfeature
    /// can be measured.
    private func combinedSimilarity(
        _ scores: [ConfidenceScore?]
    ) -> PlaceFingerprintSimilarity {
        let available = scores.compactMap { $0 }
        guard !available.isEmpty else {
            return .unavailable
        }
        let value = available.reduce(0.0) { $0 + $1.value } / Double(available.count)
        return .available(ConfidenceScore(clamping: value))
    }

    private func histogramScore(
        _ lhs: NormalizedPlaceHistogram?,
        _ rhs: NormalizedPlaceHistogram?
    ) -> ConfidenceScore? {
        guard let lhs, let rhs, lhs.values.count == rhs.values.count else {
            return nil
        }
        let intersection = zip(lhs.values, rhs.values).reduce(0.0) { partial, pair in
            partial + Swift.min(pair.0, pair.1)
        }
        return ConfidenceScore(clamping: intersection)
    }

    private func extentShapeScore(
        _ lhs: CoarsePlaceExtent?,
        _ rhs: CoarsePlaceExtent?
    ) -> ConfidenceScore? {
        guard let lhs, let rhs else { return nil }
        let ratios = [
            dimensionRatio(lhs.widthMeters, rhs.widthMeters),
            dimensionRatio(lhs.heightMeters, rhs.heightMeters),
            dimensionRatio(lhs.depthMeters, rhs.depthMeters),
        ]
        return ConfidenceScore(clamping: ratios.reduce(0, +) / Double(ratios.count))
    }

    private func extentOverlapScore(
        _ lhs: CoarsePlaceExtent?,
        _ rhs: CoarsePlaceExtent?
    ) -> ConfidenceScore? {
        guard let lhs, let rhs else { return nil }
        let sharedVolume =
            Swift.min(lhs.widthMeters, rhs.widthMeters)
            * Swift.min(lhs.heightMeters, rhs.heightMeters)
            * Swift.min(lhs.depthMeters, rhs.depthMeters)
        let enclosingVolume =
            Swift.max(lhs.widthMeters, rhs.widthMeters)
            * Swift.max(lhs.heightMeters, rhs.heightMeters)
            * Swift.max(lhs.depthMeters, rhs.depthMeters)
        return ConfidenceScore(clamping: sharedVolume / enclosingVolume)
    }

    private func objectCountScore(_ lhs: Int?, _ rhs: Int?) -> ConfidenceScore? {
        guard let lhs, let rhs else { return nil }
        guard lhs != 0 || rhs != 0 else {
            // Two empty observations do not prove that two places are equal.
            return nil
        }
        return ConfidenceScore(
            clamping: Double(Swift.min(lhs, rhs)) / Double(Swift.max(lhs, rhs))
        )
    }

    private func dimensionRatio(_ lhs: Double, _ rhs: Double) -> Double {
        Swift.min(lhs, rhs) / Swift.max(lhs, rhs)
    }
}
