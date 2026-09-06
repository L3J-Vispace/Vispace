import VispaceCore
import XCTest

@testable import Vispace

final class ARGuidancePresentationTests: XCTestCase {
    func testRegisteredNameReachesGuidanceWithoutReplacingSemanticIdentity() throws {
        let target = try makeTarget(
            semanticLabel: UserObjectRegistrationAccumulator.semanticLabel,
            displayName: "내 스피커"
        )
        XCTAssertEqual(ARGuidancePresentation.displayLabel(for: target), "내 스피커")
        XCTAssertEqual(target.semanticLabel, UserObjectRegistrationAccumulator.semanticLabel)
        XCTAssertEqual(target.sourceMetadata?.object.semanticLabel, UserObjectRegistrationAccumulator.semanticLabel)
        XCTAssertTrue(target.representsLastSeenLocation)
    }

    func testUnnamedAutomaticClassUsesSharedKoreanVocabulary() throws {
        let target = try makeTarget(semanticLabel: "tvmonitor", displayName: nil)
        XCTAssertEqual(ARGuidancePresentation.displayLabel(for: target), "모니터")
        XCTAssertEqual(target.semanticLabel, "tvmonitor")
    }

    func testManualTargetWithoutSourceNeverDisplaysInternalSentinel() throws {
        let target = try makeTarget(
            semanticLabel: UserObjectRegistrationAccumulator.semanticLabel,
            displayName: nil, includesSource: false
        )
        XCTAssertEqual(ARGuidancePresentation.displayLabel(for: target), "직접 등록한 물체")
    }

    func testDisplayNameFromUnrelatedSourceDoesNotLabelTheTarget() throws {
        let target = try makeTarget(semanticLabel: "keyboard", displayName: "다른 물체", matchesSourceID: false)
        XCTAssertEqual(ARGuidancePresentation.displayLabel(for: target), "키보드")
    }

    private func makeTarget(semanticLabel: String, displayName: String?,
                            includesSource: Bool = true, matchesSourceID: Bool = true) throws -> ARGuidanceTarget {
        let mapID = MapID()
        let objectID = ObjectID()
        let position = try FramedPosition(coordinateFrameID: CoordinateFrameID(), value: .zero,
            observedAt: 10, trackingQuality: .normal, uncertainty: .highConfidenceDepth)
        let object = try SpatialObject(id: matchesSourceID ? objectID : ObjectID(),
            semanticLabel: semanticLabel, position: position.value, certainty: .confirmed,
            presence: .lastSeen, confidence: ConfidenceVector(), firstSeenAt: 10, lastSeenAt: 10,
            displayName: displayName)
        let metadata = try SpatialObjectMetadata(mapID: mapID, object: object, position: position)
        return try ARGuidanceTarget(objectID: objectID, semanticLabel: semanticLabel,
            activeMapID: mapID, activeSegmentID: CaptureSegmentID(), position: position,
            confidenceGrade: .high, representsLastSeenLocation: true, resolvedAt: 10,
            sourceMetadata: includesSource ? metadata : nil)
    }
}
