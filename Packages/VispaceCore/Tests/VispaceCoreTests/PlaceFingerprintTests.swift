import Foundation
import XCTest

@testable import VispaceCore

final class PlaceFingerprintTests: XCTestCase {
    func testVersionOneFingerprintRoundTripsWithoutRawSpatialData() throws {
        let fingerprint = try PlaceFingerprint(
            visualHistogram: uniformHistogram(count: PlaceFingerprintSchema.v1.visualBinCount),
            geometryHistogram: uniformHistogram(count: PlaceFingerprintSchema.v1.geometryBinCount),
            structureHistogram: uniformHistogram(count: PlaceFingerprintSchema.v1.structureBinCount),
            objectLayoutHistogram: uniformHistogram(
                count: PlaceFingerprintSchema.v1.objectLayoutBinCount
            ),
            spatialOccupancyHistogram: uniformHistogram(
                count: PlaceFingerprintSchema.v1.spatialOccupancyBinCount
            ),
            coarseExtent: try CoarsePlaceExtent(
                widthMeters: 4.2,
                heightMeters: 2.6,
                depthMeters: 5.1
            ),
            observedObjectCount: 12
        )

        let encoded = try JSONEncoder().encode(fingerprint)
        let decoded = try JSONDecoder().decode(PlaceFingerprint.self, from: encoded)

        XCTAssertEqual(decoded, fingerprint)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("camera"))
        XCTAssertFalse(json.contains("mesh"))
        XCTAssertFalse(json.contains("featurePoints"))
    }

    func testHistogramRejectsEmptyOversizedNonFiniteOutOfRangeAndUnnormalizedValues() {
        XCTAssertThrowsError(try NormalizedPlaceHistogram(values: [])) { error in
            XCTAssertEqual(
                error as? PlaceFingerprintError,
                .invalidHistogramBinCount(
                    actual: 0,
                    maximum: NormalizedPlaceHistogram.maximumBinCount
                )
            )
        }
        XCTAssertThrowsError(
            try NormalizedPlaceHistogram(
                values: Array(
                    repeating: 1.0 / 65.0,
                    count: NormalizedPlaceHistogram.maximumBinCount + 1
                )
            )
        )
        XCTAssertThrowsError(try NormalizedPlaceHistogram(values: [.nan, 1])) { error in
            XCTAssertEqual(
                error as? PlaceFingerprintError,
                .nonFiniteHistogramValue(index: 0)
            )
        }
        XCTAssertThrowsError(try NormalizedPlaceHistogram(values: [-0.1, 1])) { error in
            XCTAssertEqual(
                error as? PlaceFingerprintError,
                .histogramValueOutOfRange(index: 0)
            )
        }
        XCTAssertThrowsError(try NormalizedPlaceHistogram(values: [0.2, 0.2])) { error in
            XCTAssertEqual(error as? PlaceFingerprintError, .histogramNotNormalized)
        }
    }

    func testSchemaRejectsPerModalityAndAggregateCapacityViolations() {
        XCTAssertThrowsError(
            try PlaceFingerprintSchema(
                version: 1,
                visualBinCount: 0,
                geometryBinCount: 1,
                structureBinCount: 1,
                objectLayoutBinCount: 1,
                spatialOccupancyBinCount: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaceFingerprintError,
                .invalidSchemaBinCount(
                    modality: .visual,
                    maximum: PlaceFingerprintSchema.maximumBinsPerModality
                )
            )
        }

        XCTAssertThrowsError(
            try PlaceFingerprintSchema(
                version: 1,
                visualBinCount: 64,
                geometryBinCount: 64,
                structureBinCount: 64,
                objectLayoutBinCount: 64,
                spatialOccupancyBinCount: 64
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaceFingerprintError,
                .schemaCapacityExceeded(maximum: PlaceFingerprintSchema.maximumTotalBins)
            )
        }
    }

    func testFingerprintRejectsWrongModalitySizeAndObjectCountCaps() throws {
        let schema = try compactSchema(version: 1)
        let oneBin = try NormalizedPlaceHistogram(values: [1])

        XCTAssertThrowsError(
            try PlaceFingerprint(schema: schema, visualHistogram: oneBin)
        ) { error in
            XCTAssertEqual(
                error as? PlaceFingerprintError,
                .histogramBinCountMismatch(modality: .visual, expected: 2, actual: 1)
            )
        }
        XCTAssertThrowsError(
            try PlaceFingerprint(schema: schema, observedObjectCount: -1)
        ) { error in
            XCTAssertEqual(
                error as? PlaceFingerprintError,
                .objectCountOutOfRange(maximum: PlaceFingerprint.maximumObservedObjectCount)
            )
        }
        XCTAssertThrowsError(
            try PlaceFingerprint(
                schema: schema,
                observedObjectCount: PlaceFingerprint.maximumObservedObjectCount + 1
            )
        )
    }

    func testSpatialExtentRejectsNonFiniteNonPositiveAndExcessiveDimensions() {
        XCTAssertThrowsError(
            try CoarsePlaceExtent(widthMeters: .infinity, heightMeters: 2, depthMeters: 3)
        ) { error in
            XCTAssertEqual(error as? PlaceFingerprintError, .nonFiniteSpatialExtent)
        }
        XCTAssertThrowsError(
            try CoarsePlaceExtent(widthMeters: 0, heightMeters: 2, depthMeters: 3)
        )
        XCTAssertThrowsError(
            try CoarsePlaceExtent(
                widthMeters: CoarsePlaceExtent.maximumDimensionMeters + 0.1,
                heightMeters: 2,
                depthMeters: 3
            )
        )
    }

    func testMalformedDecodingCannotBypassSchemaHistogramExtentOrCountCaps() {
        let oversizedSchema = Data(
            #"{"version":1,"visualBinCount":65,"geometryBinCount":2,"structureBinCount":2,"objectLayoutBinCount":2,"spatialOccupancyBinCount":2}"#
                .utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(PlaceFingerprintSchema.self, from: oversizedSchema)
        )

        let oversizedHistogramValues = Array(repeating: "0.015384615384615385", count: 65)
            .joined(separator: ",")
        let oversizedHistogram = Data("[\(oversizedHistogramValues)]".utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(NormalizedPlaceHistogram.self, from: oversizedHistogram)
        )

        let invalidExtent = Data(
            #"{"widthMeters":101,"heightMeters":2,"depthMeters":3}"#.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(CoarsePlaceExtent.self, from: invalidExtent)
        )

        let malformedFingerprint = Data(
            #"{"schema":{"version":1,"visualBinCount":2,"geometryBinCount":2,"structureBinCount":2,"objectLayoutBinCount":2,"spatialOccupancyBinCount":2},"visualHistogram":[1],"observedObjectCount":4097}"#
                .utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(PlaceFingerprint.self, from: malformedFingerprint)
        )
    }

    func testIdenticalCompleteFingerprintsProducePerfectAvailableScores() throws {
        let fingerprint = try completeFingerprint(
            histogram: [0.75, 0.25],
            extent: (4, 2, 6),
            objectCount: 10
        )

        let result = try PlaceFingerprintComparator().compare(fingerprint, fingerprint)

        XCTAssertEqual(result.visual, .available(.one))
        XCTAssertEqual(result.geometry, .available(.one))
        XCTAssertEqual(result.structure, .available(.one))
        XCTAssertEqual(result.objectLayout, .available(.one))
        XCTAssertEqual(result.spatialOverlap, .available(.one))
        XCTAssertEqual(result.availableModalityCount, 5)
    }

    func testComparisonIsDeterministicSymmetricAndUsesBoundedScores() throws {
        let lhs = try completeFingerprint(
            histogram: [1, 0],
            extent: (4, 2, 6),
            objectCount: 10
        )
        let rhs = try completeFingerprint(
            histogram: [0.5, 0.5],
            extent: (2, 2, 3),
            objectCount: 5
        )
        let comparator = PlaceFingerprintComparator()

        let first = try comparator.compare(lhs, rhs)
        let repeated = try comparator.compare(lhs, rhs)
        let reversed = try comparator.compare(rhs, lhs)

        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first, reversed)
        XCTAssertEqual(availableValue(first.visual), 0.5, accuracy: 1e-12)
        XCTAssertEqual(availableValue(first.structure), 0.5, accuracy: 1e-12)
        XCTAssertEqual(availableValue(first.geometry), 7.0 / 12.0, accuracy: 1e-12)
        XCTAssertEqual(availableValue(first.objectLayout), 0.5, accuracy: 1e-12)
        XCTAssertEqual(availableValue(first.spatialOverlap), 0.375, accuracy: 1e-12)
    }

    func testEmptyEvidenceStaysExplicitlyUnavailableAndBridgesToZeros() throws {
        let schema = try compactSchema(version: 1)
        let empty = try PlaceFingerprint(schema: schema)

        let result = try PlaceFingerprintComparator().compare(empty, empty)

        XCTAssertEqual(result.visual, .unavailable)
        XCTAssertEqual(result.geometry, .unavailable)
        XCTAssertEqual(result.structure, .unavailable)
        XCTAssertEqual(result.objectLayout, .unavailable)
        XCTAssertEqual(result.spatialOverlap, .unavailable)
        XCTAssertEqual(result.availableModalityCount, 0)

        let evidence = result.placeEvidence()
        XCTAssertEqual(evidence.visual, .zero)
        XCTAssertEqual(evidence.geometry, .zero)
        XCTAssertEqual(evidence.structure, .zero)
        XCTAssertEqual(evidence.poseConsistency, .zero)
        XCTAssertEqual(evidence.objectLayout, .zero)
        XCTAssertEqual(evidence.spatialOverlap, .zero)
        XCTAssertEqual(PlaceRecognizer().classify(evidence).classification, .new)
    }

    func testOneSidedModalityIsUnavailableRatherThanFalsePerfectMatch() throws {
        let schema = try compactSchema(version: 1)
        let histogram = try NormalizedPlaceHistogram(values: [1, 0])
        let lhs = try PlaceFingerprint(schema: schema, visualHistogram: histogram)
        let rhs = try PlaceFingerprint(schema: schema)

        let result = try PlaceFingerprintComparator().compare(lhs, rhs)

        XCTAssertEqual(result.visual, .unavailable)
        XCTAssertEqual(result.placeEvidence().visual, .zero)
    }

    func testMeasuredZeroObjectCountMismatchDiffersFromUnavailableCounts() throws {
        let schema = try compactSchema(version: 1)
        let noObjects = try PlaceFingerprint(schema: schema, observedObjectCount: 0)
        let fiveObjects = try PlaceFingerprint(schema: schema, observedObjectCount: 5)
        let neitherMeasured = try PlaceFingerprint(schema: schema)
        let comparator = PlaceFingerprintComparator()

        let mismatch = try comparator.compare(noObjects, fiveObjects)
        let unavailable = try comparator.compare(neitherMeasured, neitherMeasured)

        XCTAssertEqual(mismatch.objectLayout, .available(.zero))
        XCTAssertEqual(unavailable.objectLayout, .unavailable)
    }

    func testDifferentSchemasCannotBeComparedEvenWhenArrayLengthsMatch() throws {
        let schema1 = try compactSchema(version: 1)
        let schema2 = try compactSchema(version: 2)
        let lhs = try PlaceFingerprint(schema: schema1)
        let rhs = try PlaceFingerprint(schema: schema2)

        XCTAssertThrowsError(try PlaceFingerprintComparator().compare(lhs, rhs)) { error in
            XCTAssertEqual(error as? PlaceFingerprintError, .incompatibleSchemas)
        }
    }

    func testExternalPoseEvidenceMustBeSuppliedExplicitly() throws {
        let schema = try compactSchema(version: 1)
        let empty = try PlaceFingerprint(schema: schema)
        let result = try PlaceFingerprintComparator().compare(empty, empty)

        XCTAssertEqual(
            result.placeEvidence(poseConsistency: .available(score(0.73))).poseConsistency,
            score(0.73)
        )
    }

    private func compactSchema(version: UInt16) throws -> PlaceFingerprintSchema {
        try PlaceFingerprintSchema(
            version: version,
            visualBinCount: 2,
            geometryBinCount: 2,
            structureBinCount: 2,
            objectLayoutBinCount: 2,
            spatialOccupancyBinCount: 2
        )
    }

    private func completeFingerprint(
        histogram values: [Double],
        extent: (Double, Double, Double),
        objectCount: Int
    ) throws -> PlaceFingerprint {
        let schema = try compactSchema(version: 1)
        let histogram = try NormalizedPlaceHistogram(values: values)
        return try PlaceFingerprint(
            schema: schema,
            visualHistogram: histogram,
            geometryHistogram: histogram,
            structureHistogram: histogram,
            objectLayoutHistogram: histogram,
            spatialOccupancyHistogram: histogram,
            coarseExtent: try CoarsePlaceExtent(
                widthMeters: extent.0,
                heightMeters: extent.1,
                depthMeters: extent.2
            ),
            observedObjectCount: objectCount
        )
    }

    private func uniformHistogram(count: Int) throws -> NormalizedPlaceHistogram {
        try NormalizedPlaceHistogram(
            values: Array(repeating: 1.0 / Double(count), count: count)
        )
    }

    private func availableValue(
        _ similarity: PlaceFingerprintSimilarity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Double {
        guard case .available(let score) = similarity else {
            XCTFail("Expected available similarity", file: file, line: line)
            return .nan
        }
        return score.value
    }
}
