import VispaceCore
import XCTest

@testable import Vispace

final class ARCaptureIdentityBoxTests: XCTestCase {
    func testStatusTransitionPreservesCheckpointRecordedAfterIdentityWasObserved() {
        let observedIdentity = ARCaptureIdentity(status: .relocalizing)
        let box = ARCaptureIdentityBox(observedIdentity)
        let checkpointMapID = MapID()

        box.recordCheckpoint(mapID: checkpointMapID, matching: observedIdentity)
        let transitioned = box.transitionStatus(
            to: .confirmed,
            matching: observedIdentity
        )

        XCTAssertEqual(transitioned?.coordinateFrameID, observedIdentity.coordinateFrameID)
        XCTAssertEqual(transitioned?.segmentID, observedIdentity.segmentID)
        XCTAssertEqual(transitioned?.mapID, checkpointMapID)
        XCTAssertEqual(transitioned?.status, .confirmed)
        XCTAssertEqual(box.value, transitioned)
    }

    func testStatusTransitionRejectsMismatchedCoordinateFrame() {
        let storedIdentity = ARCaptureIdentity(
            mapID: MapID(),
            status: .relocalizing
        )
        let box = ARCaptureIdentityBox(storedIdentity)
        let staleIdentity = ARCaptureIdentity(
            coordinateFrameID: CoordinateFrameID(),
            segmentID: storedIdentity.segmentID,
            status: .relocalizing
        )

        XCTAssertNil(
            box.transitionStatus(to: .confirmed, matching: staleIdentity)
        )
        XCTAssertEqual(box.value, storedIdentity)
    }

    func testStatusTransitionRejectsMismatchedSegment() {
        let storedIdentity = ARCaptureIdentity(
            mapID: MapID(),
            status: .relocalizing
        )
        let box = ARCaptureIdentityBox(storedIdentity)
        let staleIdentity = ARCaptureIdentity(
            coordinateFrameID: storedIdentity.coordinateFrameID,
            segmentID: CaptureSegmentID(),
            status: .relocalizing
        )

        XCTAssertNil(
            box.transitionStatus(to: .confirmed, matching: staleIdentity)
        )
        XCTAssertEqual(box.value, storedIdentity)
    }
}
