import VispaceCore
import XCTest

@testable import Vispace

final class RelocalizationStateMachineTests: XCTestCase {
    func testLimitedTrackingDoesNotConfirmRestoredCoordinateFrame() {
        var machine = RelocalizationStateMachine()
        let identity = ARCaptureIdentity()
        _ = machine.begin(identity: identity, sessionRunGeneration: 1)

        XCTAssertEqual(
            machine.observe(
                .limited(.relocalizing),
                identity: relocalizing(identity),
                sessionRunGeneration: 1
            ),
            .none
        )
        guard case .awaitingNormal = machine.state else {
            return XCTFail("Relocalization must remain provisional until normal tracking.")
        }
    }

    func testNormalTrackingConfirmsRestoredCoordinateFrame() {
        var machine = RelocalizationStateMachine()
        let identity = ARCaptureIdentity(mapID: MapID())
        _ = machine.begin(identity: identity, sessionRunGeneration: 7)

        let outcome = machine.observe(
            .normal,
            identity: relocalizing(identity),
            sessionRunGeneration: 7
        )

        guard case .confirmed(let confirmed) = outcome else {
            return XCTFail("Expected confirmation after normal tracking.")
        }
        XCTAssertEqual(confirmed.coordinateFrameID, identity.coordinateFrameID)
        XCTAssertEqual(confirmed.segmentID, identity.segmentID)
        XCTAssertEqual(confirmed.mapID, identity.mapID)
        XCTAssertEqual(confirmed.status, .confirmed)
    }

    func testNormalTrackingFromStaleRunOrIdentityIsIgnored() {
        var machine = RelocalizationStateMachine()
        let identity = ARCaptureIdentity(mapID: MapID())
        _ = machine.begin(identity: identity, sessionRunGeneration: 2)

        XCTAssertEqual(
            machine.observe(
                .normal,
                identity: relocalizing(identity),
                sessionRunGeneration: 1
            ),
            .none
        )
        XCTAssertEqual(
            machine.observe(
                .normal,
                identity: ARCaptureIdentity(status: .relocalizing),
                sessionRunGeneration: 2
            ),
            .none
        )
    }

    func testCheckpointMapIDCanAdvanceDuringCoordinateRecovery() {
        var machine = RelocalizationStateMachine()
        let initial = ARCaptureIdentity(status: .relocalizing)
        let checkpointID = MapID()
        _ = machine.begin(identity: initial, sessionRunGeneration: 3)
        let checkpointed = ARCaptureIdentity(
            coordinateFrameID: initial.coordinateFrameID,
            segmentID: initial.segmentID,
            mapID: checkpointID,
            status: .relocalizing
        )

        let outcome = machine.observe(
            .normal,
            identity: checkpointed,
            sessionRunGeneration: 3
        )

        guard case .confirmed(let confirmed) = outcome else {
            return XCTFail("A new checkpoint ID must not invalidate the same coordinate frame.")
        }
        XCTAssertEqual(confirmed.mapID, checkpointID)
    }

    func testTimeoutStartsFreshSegmentAndStaleTimeoutIsIgnored() {
        var machine = RelocalizationStateMachine()
        let staleGeneration = machine.begin(
            identity: ARCaptureIdentity(),
            sessionRunGeneration: 1
        )
        let activeGeneration = machine.begin(
            identity: ARCaptureIdentity(),
            sessionRunGeneration: 2
        )

        XCTAssertEqual(machine.timeout(generation: staleGeneration), .none)
        XCTAssertEqual(machine.timeout(generation: activeGeneration), .startFreshSegment)
        guard case .timedOut(let generation) = machine.state else {
            return XCTFail("Expected a terminal timed-out state.")
        }
        XCTAssertEqual(generation, activeGeneration)
    }
    private func relocalizing(_ identity: ARCaptureIdentity) -> ARCaptureIdentity {
        ARCaptureIdentity(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: identity.mapID,
            status: .relocalizing
        )
    }
}
