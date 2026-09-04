import Foundation
import XCTest

@testable import VispaceCore

final class GeometryAndConfidenceTests: XCTestCase {
    func testVec3RejectsNonFiniteComponents() {
        XCTAssertThrowsError(try Vec3(x: .nan, y: 0, z: 0)) { error in
            XCTAssertEqual(error as? GeometryError, .nonFiniteValue)
        }
    }

    func testTransformCompositionAndCodableRoundTrip() throws {
        let a = Transform3D.translation(vec(1, 2, 3))
        let b = Transform3D.translation(vec(4, 5, 6))
        let result = try (a * b).transformed(.zero)
        XCTAssertEqual(result, vec(5, 7, 9))

        let encoded = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(Transform3D.self, from: encoded)
        XCTAssertEqual(decoded, a)
    }

    func testTransformRejectsWrongElementCountAndZeroHomogeneousW() throws {
        XCTAssertThrowsError(try Transform3D(rowMajorElements: [1, 2, 3])) { error in
            XCTAssertEqual(
                error as? GeometryError,
                .invalidMatrixElementCount(expected: 16, actual: 3)
            )
        }
        let zeroW = try Transform3D(rowMajorElements: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 0,
        ])
        XCTAssertThrowsError(try zeroW.transformed(.zero)) { error in
            XCTAssertEqual(error as? GeometryError, .nonInvertibleHomogeneousCoordinate)
        }
    }

    func testAABBIntersectionIoUAndDistanceBoundaries() {
        let first = box(minX: 0, minY: 0, minZ: 0, maxX: 2, maxY: 2, maxZ: 2)
        let second = box(minX: 1, minY: 1, minZ: 1, maxX: 3, maxY: 3, maxZ: 3)
        XCTAssertTrue(first.intersects(second))
        XCTAssertEqual(first.intersection(with: second)?.volume, 1)
        XCTAssertEqual(first.intersectionOverUnion(with: second), 1.0 / 15.0, accuracy: 1e-12)

        let touching = box(minX: 2, minY: 0, minZ: 0, maxX: 3, maxY: 1, maxZ: 1)
        XCTAssertTrue(first.intersects(touching))
        XCTAssertEqual(first.intersectionOverUnion(with: touching), 0)
        XCTAssertEqual(first.distance(to: touching), 0)

        let distant = box(minX: 5, minY: 0, minZ: 0, maxX: 6, maxY: 1, maxZ: 1)
        XCTAssertEqual(first.distance(to: distant), 3)
    }

    func testAABBRejectsInvertedBounds() {
        XCTAssertThrowsError(try AABB(min: vec(2), max: vec(1))) { error in
            XCTAssertEqual(error as? GeometryError, .invalidBounds)
        }
    }

    func testConfidenceThresholdsAreInclusive() {
        let policy = ConfidencePolicy.default
        XCTAssertEqual(policy.grade(for: score(0.499)), .low)
        XCTAssertEqual(policy.grade(for: score(0.5)), .medium)
        XCTAssertEqual(policy.grade(for: score(0.799)), .medium)
        XCTAssertEqual(policy.grade(for: score(0.8)), .high)
        XCTAssertEqual(policy.grade(for: score(1)), .high)
    }

    func testConfidenceValidationAndClamping() {
        XCTAssertThrowsError(try ConfidenceScore(validating: -.ulpOfOne))
        XCTAssertThrowsError(try ConfidenceScore(validating: 1.000_001))
        XCTAssertThrowsError(try ConfidenceScore(validating: .nan))
        XCTAssertEqual(ConfidenceScore(clamping: -5), .zero)
        XCTAssertEqual(ConfidenceScore(clamping: 5), .one)
        XCTAssertEqual(ConfidenceScore(clamping: .nan), .zero)
        XCTAssertThrowsError(
            try ConfidencePolicy(mediumThreshold: score(0.8), highThreshold: score(0.8))
        )
    }

    func testCodableCannotBypassConfidenceOrAABBValidation() {
        let invalidConfidence = Data(#"{"value":2}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ConfidenceScore.self, from: invalidConfidence)
        )

        let invertedBounds = Data(
            #"{"min":{"x":2,"y":0,"z":0},"max":{"x":1,"y":0,"z":0}}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(AABB.self, from: invertedBounds))
    }
}
