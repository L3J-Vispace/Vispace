import Foundation
import XCTest

@testable import VispaceCore

final class CoordinateFrameAlignmentTests: XCTestCase {
    private let sourceFrameID = CoordinateFrameID(rawValue: testUUID(40_001))
    private let targetFrameID = CoordinateFrameID(rawValue: testUUID(40_002))
    private let yaw = 35.0 * Double.pi / 180.0
    private let translation = vec(2.0, 0.4, -1.2)

    func testExactYawAndTranslationAreRecovered() throws {
        let correspondences = try exactCorrespondences()

        let result = try CoordinateFrameAlignmentEstimator().estimate(
            correspondences: correspondences
        )

        XCTAssertEqual(result.sourceCoordinateFrameID, sourceFrameID)
        XCTAssertEqual(result.targetCoordinateFrameID, targetFrameID)
        XCTAssertEqual(result.evidenceCount, correspondences.count)
        XCTAssertGreaterThan(result.confidence.value, 0.999_999)
        XCTAssertLessThan(result.residuals.rootMeanSquare, 1e-12)
        XCTAssertLessThan(result.residuals.maximum, 1e-12)
        assertTransform(result.sourceToTarget, equals: expectedTransform(), accuracy: 1e-12)
    }

    func testSmallMeasurementNoiseStillProducesHighConfidenceAlignment() throws {
        let sourcePoints = baseSourcePoints()
        let noise = [
            vec(0.004, 0.001, -0.003),
            vec(-0.005, -0.002, 0.004),
            vec(0.003, 0.002, 0.005),
            vec(-0.002, -0.001, -0.004),
            vec(0.001, 0.0, -0.001),
        ]
        let correspondences = try sourcePoints.enumerated().map { index, point in
            try correspondence(
                index: index,
                sourcePosition: point,
                targetPosition: applyExpectedTransform(point) + noise[index],
                identityConfidence: score(0.96)
            )
        }

        let result = try CoordinateFrameAlignmentEstimator().estimate(
            correspondences: correspondences
        )

        XCTAssertEqual(ConfidencePolicy.default.grade(for: result.confidence), .high)
        XCTAssertGreaterThanOrEqual(result.confidence.value, 0.80)
        XCTAssertLessThan(result.residuals.horizontalRootMeanSquare, 0.01)
        XCTAssertLessThan(result.residuals.verticalRootMeanSquare, 0.003)
        assertTransform(result.sourceToTarget, equals: expectedTransform(), accuracy: 0.01)
    }

    func testLargeOutlierFailsClosed() throws {
        var targetPoints = baseSourcePoints().map(applyExpectedTransform)
        targetPoints[4] = targetPoints[4] + vec(1.5, 0, -0.8)
        let correspondences = try baseSourcePoints().enumerated().map { index, point in
            try correspondence(
                index: index,
                sourcePosition: point,
                targetPosition: targetPoints[index]
            )
        }

        XCTAssertThrowsError(
            try CoordinateFrameAlignmentEstimator().estimate(correspondences: correspondences)
        ) { error in
            guard case CoordinateFrameAlignmentError.excessiveHorizontalResidual = error else {
                return XCTFail("Expected horizontal outlier rejection, got \(error)")
            }
        }
    }

    func testLargeVerticalResidualFailsClosed() throws {
        var targetPoints = baseSourcePoints().map(applyExpectedTransform)
        targetPoints[2] = targetPoints[2] + vec(0, 0.8, 0)
        let correspondences = try baseSourcePoints().enumerated().map { index, point in
            try correspondence(
                index: index,
                sourcePosition: point,
                targetPosition: targetPoints[index]
            )
        }

        XCTAssertThrowsError(
            try CoordinateFrameAlignmentEstimator().estimate(correspondences: correspondences)
        ) { error in
            guard case CoordinateFrameAlignmentError.excessiveVerticalResidual = error else {
                return XCTFail("Expected vertical outlier rejection, got \(error)")
            }
        }
    }

    func testReflectionCannotBeAcceptedAsYawAlignment() throws {
        let reflectedTargets = baseSourcePoints().map { point in
            vec(-point.x + 2, point.y + 0.4, point.z - 1.2)
        }
        let correspondences = try baseSourcePoints().enumerated().map { index, point in
            try correspondence(
                index: index,
                sourcePosition: point,
                targetPosition: reflectedTargets[index]
            )
        }

        XCTAssertThrowsError(
            try CoordinateFrameAlignmentEstimator().estimate(correspondences: correspondences)
        )
    }

    func testCollinearHorizontalLayoutFailsClosed() throws {
        let points = [
            vec(-1, 0, 0),
            vec(0, 0.2, 0),
            vec(1, -0.1, 0),
            vec(2, 0.4, 0),
        ]
        let correspondences = try points.enumerated().map { index, point in
            try correspondence(
                index: index,
                sourcePosition: point,
                targetPosition: applyExpectedTransform(point)
            )
        }

        XCTAssertThrowsError(
            try CoordinateFrameAlignmentEstimator().estimate(correspondences: correspondences)
        ) { error in
            XCTAssertEqual(
                error as? CoordinateFrameAlignmentError,
                .nearCollinearHorizontalLayout(side: .source)
            )
        }
    }

    func testDuplicateSourceIdentityIsRejected() throws {
        let points = baseSourcePoints()
        let correspondences = [
            try correspondence(index: 0, sourcePosition: points[0]),
            try correspondence(index: 1, sourcePosition: points[1]),
            try correspondence(
                index: 2,
                sourceObjectID: alignmentObjectID(0),
                sourcePosition: points[2]
            ),
        ]

        XCTAssertThrowsError(
            try CoordinateFrameAlignmentEstimator().estimate(correspondences: correspondences)
        ) { error in
            XCTAssertEqual(
                error as? CoordinateFrameAlignmentError,
                .duplicateSourceObjectID(self.alignmentObjectID(0))
            )
        }
    }

    func testDuplicateTargetIdentityIsRejected() throws {
        let points = baseSourcePoints()
        let correspondences = [
            try correspondence(index: 0, sourcePosition: points[0]),
            try correspondence(index: 1, sourcePosition: points[1]),
            try correspondence(
                index: 2,
                targetObjectID: alignmentObjectID(100),
                sourcePosition: points[2]
            ),
        ]

        XCTAssertThrowsError(
            try CoordinateFrameAlignmentEstimator().estimate(correspondences: correspondences)
        ) { error in
            XCTAssertEqual(
                error as? CoordinateFrameAlignmentError,
                .duplicateTargetObjectID(self.alignmentObjectID(100))
            )
        }
    }

    func testInputOrderDoesNotChangeResult() throws {
        let correspondences = try exactCorrespondences()
        let shuffled = [
            correspondences[3],
            correspondences[0],
            correspondences[4],
            correspondences[1],
            correspondences[2],
        ]
        let estimator = CoordinateFrameAlignmentEstimator()

        let first = try estimator.estimate(correspondences: correspondences)
        let second = try estimator.estimate(correspondences: shuffled)

        XCTAssertEqual(first, second)
    }

    func testTransformDirectionIsSourceToTarget() throws {
        let result = try CoordinateFrameAlignmentEstimator().estimate(
            correspondences: exactCorrespondences()
        )
        let sourcePoint = vec(0.7, 1.3, -0.4)
        let expectedTarget = applyExpectedTransform(sourcePoint)

        let transformedSource = try result.sourceToTarget.transformed(sourcePoint)
        let incorrectlyTransformedTarget = try result.sourceToTarget.transformed(expectedTarget)

        assertVector(transformedSource, equals: expectedTarget, accuracy: 1e-12)
        XCTAssertGreaterThan(incorrectlyTransformedTarget.distance(to: sourcePoint), 0.5)
    }

    func testInvertedAlignmentRoundTripsPositions() throws {
        let result = try CoordinateFrameAlignmentEstimator().estimate(
            correspondences: exactCorrespondences()
        )
        let inverse = try result.inverted()

        for sourcePoint in baseSourcePoints() + [vec(0.7, 1.3, -0.4)] {
            let targetPoint = try result.sourceToTarget.transformed(sourcePoint)
            let recoveredSource = try inverse.sourceToTarget.transformed(targetPoint)
            assertVector(recoveredSource, equals: sourcePoint, accuracy: 1e-12)
        }
    }

    func testInvertingTwiceRestoresDirectionAndPreservesValidationEvidence() throws {
        let result = try CoordinateFrameAlignmentEstimator().estimate(
            correspondences: exactCorrespondences()
        )
        let inverse = try result.inverted()
        let roundTrip = try inverse.inverted()

        XCTAssertEqual(inverse.sourceCoordinateFrameID, targetFrameID)
        XCTAssertEqual(inverse.targetCoordinateFrameID, sourceFrameID)
        XCTAssertEqual(inverse.confidence, result.confidence)
        XCTAssertEqual(inverse.residuals, result.residuals)
        XCTAssertEqual(inverse.evidenceCount, result.evidenceCount)
        XCTAssertEqual(inverse.policy, result.policy)
        XCTAssertEqual(roundTrip.sourceCoordinateFrameID, result.sourceCoordinateFrameID)
        XCTAssertEqual(roundTrip.targetCoordinateFrameID, result.targetCoordinateFrameID)
        XCTAssertEqual(roundTrip.confidence, result.confidence)
        XCTAssertEqual(roundTrip.residuals, result.residuals)
        XCTAssertEqual(roundTrip.evidenceCount, result.evidenceCount)
        XCTAssertEqual(roundTrip.policy, result.policy)
        assertTransform(roundTrip.sourceToTarget, equals: result.sourceToTarget, accuracy: 1e-12)
    }

    func testInverseTranslationAccountsForNonCommutingYaw() throws {
        let result = try CoordinateFrameAlignmentEstimator().estimate(
            correspondences: exactCorrespondences()
        )
        let inverse = try result.inverted()
        let cosine = cos(yaw)
        let sine = sin(yaw)
        let expectedInverseTranslation = vec(
            -cosine * translation.x + sine * translation.z,
            -translation.y,
            -sine * translation.x - cosine * translation.z
        )
        let naivelyNegatedTranslation = vec(
            -translation.x,
            -translation.y,
            -translation.z
        )

        assertVector(
            inverse.sourceToTarget.translation,
            equals: expectedInverseTranslation,
            accuracy: 1e-12
        )
        XCTAssertGreaterThan(
            inverse.sourceToTarget.translation.distance(to: naivelyNegatedTranslation),
            0.5
        )
    }

    func testSemanticLabelMismatchIsRejectedBeforeEstimation() throws {
        let source = try CoordinateFrameAlignmentSourcePoint(
            objectID: alignmentObjectID(1),
            coordinateFrameID: sourceFrameID,
            semanticLabel: "chair",
            position: vec(0, 0, 0)
        )
        let target = try CoordinateFrameAlignmentTargetPoint(
            objectID: alignmentObjectID(101),
            coordinateFrameID: targetFrameID,
            semanticLabel: "table",
            position: vec(1, 0, 1)
        )

        XCTAssertThrowsError(
            try CoordinateFrameAlignmentCorrespondence(
                source: source,
                target: target,
                identityConfidence: .one
            )
        ) { error in
            XCTAssertEqual(
                error as? CoordinateFrameAlignmentError,
                .semanticLabelMismatch(
                    sourceObjectID: self.alignmentObjectID(1),
                    targetObjectID: self.alignmentObjectID(101)
                )
            )
        }
    }

    func testThreeCorrespondencesAreRequired() throws {
        let correspondences = Array(try exactCorrespondences().prefix(2))

        XCTAssertThrowsError(
            try CoordinateFrameAlignmentEstimator().estimate(correspondences: correspondences)
        ) { error in
            XCTAssertEqual(
                error as? CoordinateFrameAlignmentError,
                .tooFewCorrespondences(minimum: 3)
            )
        }
    }

    func testCorrespondenceCountIsBounded() throws {
        let points = (0...64).map { index in
            let angle = Double(index) * 0.41
            return vec(cos(angle) * 2, Double(index % 3) * 0.1, sin(angle) * 1.4)
        }
        let correspondences = try points.enumerated().map { index, point in
            try correspondence(
                index: index,
                sourcePosition: point,
                targetPosition: applyExpectedTransform(point)
            )
        }

        XCTAssertThrowsError(
            try CoordinateFrameAlignmentEstimator().estimate(correspondences: correspondences)
        ) { error in
            XCTAssertEqual(
                error as? CoordinateFrameAlignmentError,
                .tooManyCorrespondences(maximum: 64)
            )
        }
    }

    func testMediumIdentityEvidenceCannotExposeAlignedResult() throws {
        let correspondences = try baseSourcePoints().enumerated().map { index, point in
            try correspondence(
                index: index,
                sourcePosition: point,
                identityConfidence: score(0.79)
            )
        }

        XCTAssertThrowsError(
            try CoordinateFrameAlignmentEstimator().estimate(correspondences: correspondences)
        ) { error in
            guard
                case .insufficientConfidence(let confidence) =
                    error as? CoordinateFrameAlignmentError
            else {
                return XCTFail("Expected typed insufficient-confidence failure, got \(error)")
            }
            XCTAssertEqual(confidence, score(0.79))
        }
    }

    func testResultCodableRoundTripRevalidatesHighConfidenceInvariant() throws {
        let result = try CoordinateFrameAlignmentEstimator().estimate(
            correspondences: exactCorrespondences()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(result)

        XCTAssertEqual(try JSONDecoder().decode(CoordinateFrameAlignmentResult.self, from: encoded), result)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["confidence"] = ["value": 0.50]
        let corrupted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(
            try JSONDecoder().decode(CoordinateFrameAlignmentResult.self, from: corrupted)
        )

        var residualObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var residuals = try XCTUnwrap(residualObject["residuals"] as? [String: Any])
        residuals["horizontalMaximum"] = 1.0
        residuals["maximum"] = 1.0
        residualObject["residuals"] = residuals
        let excessiveResidual = try JSONSerialization.data(
            withJSONObject: residualObject,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CoordinateFrameAlignmentResult.self,
                from: excessiveResidual
            )
        )
    }

    func testNonFinitePointIsRejectedAtTypedGeometryBoundary() {
        XCTAssertThrowsError(try Vec3(x: .nan, y: 0, z: 0)) { error in
            XCTAssertEqual(error as? GeometryError, .nonFiniteValue)
        }
    }

    private func exactCorrespondences() throws -> [CoordinateFrameAlignmentCorrespondence] {
        try baseSourcePoints().enumerated().map { index, point in
            try correspondence(index: index, sourcePosition: point)
        }
    }

    private func baseSourcePoints() -> [Vec3] {
        [
            vec(0, 0, 0),
            vec(2.0, 0.2, 0.1),
            vec(0.2, 0.9, 1.7),
            vec(-1.1, 0.5, -0.8),
            vec(1.4, 1.1, -1.3),
        ]
    }

    private func correspondence(
        index: Int,
        sourceObjectID: ObjectID? = nil,
        targetObjectID: ObjectID? = nil,
        sourcePosition: Vec3,
        targetPosition: Vec3? = nil,
        identityConfidence: ConfidenceScore = .one
    ) throws -> CoordinateFrameAlignmentCorrespondence {
        let labels = ["chair", "table", "lamp", "sofa", "shelf"]
        let label = labels[index % labels.count]
        return try CoordinateFrameAlignmentCorrespondence(
            source: CoordinateFrameAlignmentSourcePoint(
                objectID: sourceObjectID ?? alignmentObjectID(index),
                coordinateFrameID: sourceFrameID,
                semanticLabel: label,
                position: sourcePosition
            ),
            target: CoordinateFrameAlignmentTargetPoint(
                objectID: targetObjectID ?? alignmentObjectID(100 + index),
                coordinateFrameID: targetFrameID,
                semanticLabel: label,
                position: targetPosition ?? applyExpectedTransform(sourcePosition)
            ),
            identityConfidence: identityConfidence
        )
    }

    private func alignmentObjectID(_ value: Int) -> ObjectID {
        ObjectID(rawValue: testUUID(41_000 + value))
    }

    private func applyExpectedTransform(_ point: Vec3) -> Vec3 {
        let cosine = cos(yaw)
        let sine = sin(yaw)
        return vec(
            cosine * point.x + sine * point.z + translation.x,
            point.y + translation.y,
            -sine * point.x + cosine * point.z + translation.z
        )
    }

    private func expectedTransform() -> Transform3D {
        let cosine = cos(yaw)
        let sine = sin(yaw)
        return try! Transform3D(rowMajorElements: [
            cosine, 0, sine, translation.x,
            0, 1, 0, translation.y,
            -sine, 0, cosine, translation.z,
            0, 0, 0, 1,
        ])
    }

    private func assertTransform(
        _ actual: Transform3D,
        equals expected: Transform3D,
        accuracy: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for index in 0..<Transform3D.elementCount {
            XCTAssertEqual(
                actual.rowMajorElements[index],
                expected.rowMajorElements[index],
                accuracy: accuracy,
                file: file,
                line: line
            )
        }
    }

    private func assertVector(
        _ actual: Vec3,
        equals expected: Vec3,
        accuracy: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }
}
