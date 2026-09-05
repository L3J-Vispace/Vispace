import VispaceCore
import XCTest
import simd

@testable import Vispace

final class PerceptionFrameValidatorTests: XCTestCase {
    func testAcceptsCurrentConfirmedNormalFrameAndUsesNewlyAssignedMap() throws {
        let coordinateFrameID = CoordinateFrameID()
        let segmentID = CaptureSegmentID()
        let token = ARSessionFrameToken(sessionRunGeneration: 7, attachmentEpoch: 3)
        let pose = makePose(
            token: token,
            coordinateFrameID: coordinateFrameID,
            segmentID: segmentID,
            mapID: nil
        )
        let current = ARCaptureIdentity(
            coordinateFrameID: coordinateFrameID,
            segmentID: segmentID,
            mapID: MapID(),
            status: .confirmed
        )

        let accepted = PerceptionFrameValidator().confirmedIdentity(
            for: pose,
            currentToken: token,
            currentIdentity: current,
            sessionIsRunning: true
        )

        XCTAssertEqual(accepted, current)
    }

    func testRejectsPreviousRunEvenWhenCoordinateIdentityMatches() throws {
        let coordinateFrameID = CoordinateFrameID()
        let segmentID = CaptureSegmentID()
        let oldToken = ARSessionFrameToken(sessionRunGeneration: 6, attachmentEpoch: 3)
        let newToken = ARSessionFrameToken(sessionRunGeneration: 7, attachmentEpoch: 3)
        let pose = makePose(
            token: oldToken,
            coordinateFrameID: coordinateFrameID,
            segmentID: segmentID,
            mapID: MapID()
        )
        let current = ARCaptureIdentity(
            coordinateFrameID: coordinateFrameID,
            segmentID: segmentID,
            mapID: pose.mapID,
            status: .confirmed
        )

        XCTAssertNil(
            PerceptionFrameValidator().confirmedIdentity(
                for: pose,
                currentToken: newToken,
                currentIdentity: current,
                sessionIsRunning: true
            )
        )
    }

    func testRejectsPreviousAttachmentAndUnconfirmedTracking() throws {
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let oldToken = ARSessionFrameToken(sessionRunGeneration: 1, attachmentEpoch: 1)
        let currentToken = ARSessionFrameToken(sessionRunGeneration: 1, attachmentEpoch: 2)
        let pose = makePose(
            token: oldToken,
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: identity.mapID,
            trackingState: .limited(.relocalizing)
        )

        XCTAssertNil(
            PerceptionFrameValidator().confirmedIdentity(
                for: pose,
                currentToken: currentToken,
                currentIdentity: identity,
                sessionIsRunning: true
            )
        )
    }

    private func makePose(
        token: ARSessionFrameToken,
        coordinateFrameID: CoordinateFrameID,
        segmentID: CaptureSegmentID,
        mapID: MapID?,
        trackingState: ARTrackingStateSnapshot = .normal
    ) -> ARPoseSnapshot {
        ARPoseSnapshot(
            id: ARFrameID(),
            sessionToken: token,
            coordinateFrameID: coordinateFrameID,
            segmentID: segmentID,
            mapID: mapID,
            coordinateFrameStatus: .confirmed,
            capturedAt: 1_700_000_000,
            timestamp: 100,
            cameraTransform: Matrix4x4Snapshot(matrix_identity_float4x4),
            trackingState: trackingState,
            worldMappingStatus: .mapped
        )
    }
}
