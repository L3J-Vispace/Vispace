import Foundation
import XCTest

@testable import VispaceCore

final class UserObjectRegistrationTests: XCTestCase {
    func testMovingAnExplicitlySelectedManualObjectPreservesIdentityAndOrigin() throws {
        let identity = makeIdentity()
        let original = try registeredObject(identity: identity, offset: 0)
        var update = try UserObjectRegistrationAccumulator(name: "내 스피커", replacing: original)
        _ = try update.append(sample(identity: identity, offset: 10, x: 2))
        _ = try update.append(sample(identity: identity, offset: 10.15, x: 2.02))
        let moved = try XCTUnwrap(update.append(sample(identity: identity, offset: 10.31, x: 2.03)))
        XCTAssertEqual(moved.object.id, original.object.id)
        XCTAssertEqual(moved.object.firstSeenAt, original.object.firstSeenAt)
        XCTAssertEqual(moved.object.displayName, original.object.displayName)
        XCTAssertEqual(moved.position.value.x, 2.02, accuracy: 0.000_001)
        XCTAssertGreaterThan(moved.object.lastSeenAt, original.object.lastSeenAt)
        XCTAssertTrue(UserObjectRegistrationAccumulator.isManualRegistration(moved))
    }

    func testSameNameAloneNeverMergesTwoPhysicalObjects() throws {
        let identity = makeIdentity()
        let first = try registeredObject(identity: identity, offset: 0)
        let second = try registeredObject(identity: identity, offset: 10)
        XCTAssertEqual(first.object.displayName, second.object.displayName)
        XCTAssertNotEqual(first.object.id, second.object.id)
    }

    func testManualUpdateRejectsDifferentSpaceOldEvidenceAndImplicitRename() throws {
        let identity = makeIdentity()
        let original = try registeredObject(identity: identity, offset: 0)
        XCTAssertThrowsError(try UserObjectRegistrationAccumulator(name: "다른 이름", replacing: original)) {
            XCTAssertEqual($0 as? UserObjectRegistrationError, .invalidExistingObject)
        }
        for other in [makeIdentity(), makeIdentity(mapID: identity.mapID)] {
            var update = try UserObjectRegistrationAccumulator(name: "내 스피커", replacing: original)
            XCTAssertThrowsError(try update.append(sample(identity: other, offset: 10))) {
                XCTAssertEqual($0 as? UserObjectRegistrationError, .staleExistingObject)
            }
        }
        var update = try UserObjectRegistrationAccumulator(name: "내 스피커", replacing: original)
        XCTAssertThrowsError(try update.append(sample(identity: identity, offset: 0.15))) {
            XCTAssertEqual($0 as? UserObjectRegistrationError, .staleExistingObject)
        }
    }

    private func registeredObject(identity: UserObjectRegistrationIdentity,
                                  offset: TimeInterval) throws -> SpatialObjectMetadata {
        var accumulator = try UserObjectRegistrationAccumulator(name: "내 스피커")
        _ = try accumulator.append(sample(identity: identity, offset: offset))
        _ = try accumulator.append(sample(identity: identity, offset: offset + 0.15))
        return try XCTUnwrap(accumulator.append(sample(identity: identity, offset: offset + 0.31)))
    }

    func testThreeIndependentSustainedSamplesSaveHonestNamedLastSeenPoint() throws {
        var accumulator = try UserObjectRegistrationAccumulator(name: "  내 스피커  ")
        let identity = makeIdentity()
        let first = try sample(identity: identity, offset: 0, x: 0)
        let middle = try sample(identity: identity, offset: 0.15, x: 0.02)
        let final = try sample(identity: identity, offset: 0.31, x: 0.03)
        XCTAssertNil(try accumulator.append(first))
        XCTAssertNil(try accumulator.append(middle))
        let saved = try XCTUnwrap(accumulator.append(final))
        XCTAssertEqual(saved.mapID, identity.mapID)
        XCTAssertEqual(saved.position.coordinateFrameID, identity.coordinateFrameID)
        XCTAssertEqual(saved.object.displayName, "내 스피커")
        XCTAssertEqual(saved.object.semanticLabel, "user_registered_object")
        XCTAssertNil(saved.object.detectorSemanticLabel)
        XCTAssertEqual(saved.object.presence, .lastSeen)
        XCTAssertNil(saved.object.bounds)
        XCTAssertEqual(saved.position.value, middle.position)
        XCTAssertEqual(saved.object.lastSeenAt, middle.capturedAt)
        XCTAssertEqual(saved.position.observedAt, middle.capturedAt)
        XCTAssertEqual(saved.object.stateUpdatedAt, final.capturedAt)
        XCTAssertEqual(saved.position.uncertainty, .highConfidenceDepth)
        XCTAssertNil(try accumulator.append(final), "A completed request emits one durable object only")
    }

    func testKnownCategoryNameDoesNotPretendAutomaticDetection() throws {
        var accumulator = try UserObjectRegistrationAccumulator(name: "키보드")
        let identity = makeIdentity()
        _ = try accumulator.append(sample(identity: identity, offset: 0))
        _ = try accumulator.append(sample(identity: identity, offset: 0.15))
        let saved = try XCTUnwrap(accumulator.append(sample(identity: identity, offset: 0.31)))
        XCTAssertEqual(saved.object.semanticLabel, "user_registered_object")
        XCTAssertEqual(saved.object.displayName, "키보드")
        XCTAssertNil(saved.object.detectorSemanticLabel)
    }

    func testDuplicateFramesAndDenseFramesCannotSupplyDurationOrIndependentEvidence() throws {
        var accumulator = try UserObjectRegistrationAccumulator(name: "열쇠")
        let identity = makeIdentity()
        let first = try sample(identity: identity, offset: 0)
        _ = try accumulator.append(first)
        XCTAssertNil(try accumulator.append(first))
        for index in 1...5 {
            XCTAssertNil(try accumulator.append(sample(identity: identity, offset: Double(index) * 0.016)))
        }
        XCTAssertEqual(accumulator.sampleCount, 1)
        XCTAssertNil(try accumulator.append(sample(identity: identity, offset: 0.1)))
        XCTAssertNil(try accumulator.append(sample(identity: identity, offset: 0.2)))
        XCTAssertEqual(accumulator.sampleCount, 3)
        XCTAssertNotNil(try accumulator.append(sample(identity: identity, offset: 0.31)))
    }

    func testEveryCaptureIdentityBoundaryRejectsMixedEvidence() throws {
        let identity = makeIdentity()
        let alternatives = [
            makeIdentity(mapID: MapID(), frameID: identity.coordinateFrameID,
                         segmentID: identity.segmentID),
            makeIdentity(mapID: identity.mapID, frameID: CoordinateFrameID(),
                         segmentID: identity.segmentID),
            makeIdentity(mapID: identity.mapID, frameID: identity.coordinateFrameID,
                         segmentID: CaptureSegmentID()),
            makeIdentity(mapID: identity.mapID, frameID: identity.coordinateFrameID,
                         segmentID: identity.segmentID, run: 2),
            makeIdentity(mapID: identity.mapID, frameID: identity.coordinateFrameID,
                         segmentID: identity.segmentID, epoch: 2),
        ]
        for changed in alternatives {
            var accumulator = try UserObjectRegistrationAccumulator(name: "스피커")
            _ = try accumulator.append(sample(identity: identity, offset: 0))
            XCTAssertThrowsError(try accumulator.append(sample(identity: changed, offset: 0.2))) {
                XCTAssertEqual($0 as? UserObjectRegistrationError, .identityChanged)
            }
        }
    }

    func testClockRollbackFutureJumpAndLongObservationGapAreRejected() throws {
        let identity = makeIdentity()
        for (offset, calendarOffset) in [(-0.1, -0.1), (0.2, -1.0), (0.2, 10.0), (2.0, 2.0)] {
            var accumulator = try UserObjectRegistrationAccumulator(name: "열쇠")
            _ = try accumulator.append(sample(identity: identity, offset: 0))
            XCTAssertThrowsError(try accumulator.append(sample(
                identity: identity, offset: offset, calendarOffset: calendarOffset
            ))) {
                XCTAssertEqual($0 as? UserObjectRegistrationError, .inconsistentTime)
            }
        }
    }

    func testDifferentSurfacesAreNotAveragedIntoAnInventedPoint() throws {
        var accumulator = try UserObjectRegistrationAccumulator(name: "스피커")
        let identity = makeIdentity()
        _ = try accumulator.append(sample(identity: identity, offset: 0))
        XCTAssertThrowsError(try accumulator.append(sample(identity: identity, offset: 0.2, x: 0.081))) {
            XCTAssertEqual($0 as? UserObjectRegistrationError, .unstablePosition)
        }
    }

    func testOnlyConfirmedNormalTrackingWithHighDepthConfidenceIsAccepted() throws {
        let identity = makeIdentity()
        for (tracking, uncertainty, confirmed) in [
            (SpatialTrackingQuality.limited, SpatialPositionUncertainty.highConfidenceDepth, true),
            (.normal, .mediumConfidenceDepth, true),
            (.normal, .unknown, true),
            (.normal, .highConfidenceDepth, false),
        ] {
            var accumulator = try UserObjectRegistrationAccumulator(name: "스피커")
            let input = UserObjectRegistrationSample(
                frameID: FrameID(), identity: identity, position: .zero,
                timestamp: 10, capturedAt: 1_000, trackingQuality: tracking,
                uncertainty: uncertainty, isCoordinateFrameConfirmed: confirmed
            )
            XCTAssertThrowsError(try accumulator.append(input)) {
                XCTAssertEqual($0 as? UserObjectRegistrationError, .invalidSample)
            }
        }
    }

    func testUntrustedNameAndNonfiniteSampleAreRejected() throws {
        for name in ["", "  ", String(repeating: "가", count: 65), "열\n쇠", "🔑"] {
            XCTAssertThrowsError(try UserObjectRegistrationAccumulator(name: name)) {
                XCTAssertEqual($0 as? UserObjectRegistrationError, .invalidName)
            }
        }
        var accumulator = try UserObjectRegistrationAccumulator(name: "열쇠")
        let input = UserObjectRegistrationSample(
            frameID: FrameID(), identity: makeIdentity(), position: .zero,
            timestamp: .nan, capturedAt: 1_000, trackingQuality: .normal,
            uncertainty: .highConfidenceDepth, isCoordinateFrameConfirmed: true
        )
        XCTAssertThrowsError(try accumulator.append(input)) {
            XCTAssertEqual($0 as? UserObjectRegistrationError, .invalidSample)
        }
    }

    private func makeIdentity(mapID: MapID = MapID(), frameID: CoordinateFrameID = CoordinateFrameID(),
                              segmentID: CaptureSegmentID = CaptureSegmentID(),
                              run: UInt64 = 1, epoch: UInt64 = 1) -> UserObjectRegistrationIdentity {
        UserObjectRegistrationIdentity(mapID: mapID, coordinateFrameID: frameID,
            segmentID: segmentID, sessionRunGeneration: run, attachmentEpoch: epoch)
    }

    private func sample(identity: UserObjectRegistrationIdentity, offset: TimeInterval,
                        x: Double = 0, calendarOffset: TimeInterval? = nil) throws -> UserObjectRegistrationSample {
        UserObjectRegistrationSample(frameID: FrameID(), identity: identity,
            position: try Vec3(x: x, y: 0, z: -1), timestamp: 10 + offset,
            capturedAt: 1_000 + (calendarOffset ?? offset), trackingQuality: .normal,
            uncertainty: .highConfidenceDepth, isCoordinateFrameConfirmed: true)
    }
}
