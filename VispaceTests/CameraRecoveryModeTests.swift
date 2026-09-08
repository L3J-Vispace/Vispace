import XCTest

@testable import Vispace

final class CameraRecoveryModeTests: XCTestCase {
    func testTerminalSessionStatesMapToExplicitRecoveryModes() {
        XCTAssertEqual(
            CameraRecoveryMode(sessionState: .cameraAccessUnavailable),
            .permissionDenied
        )
        XCTAssertEqual(
            CameraRecoveryMode(sessionState: .unavailable(reason: "unsupported")),
            .unavailable
        )
        XCTAssertEqual(
            CameraRecoveryMode(sessionState: .failed(message: "failed")),
            .failed
        )
    }

    func testNonterminalSessionStatesKeepTheNormalCameraInterface() {
        XCTAssertNil(CameraRecoveryMode(sessionState: .detached))
        XCTAssertNil(CameraRecoveryMode(sessionState: .waitingForCameraPermission))
        XCTAssertNil(CameraRecoveryMode(sessionState: .ready))
        XCTAssertNil(CameraRecoveryMode(sessionState: .running))
        XCTAssertNil(CameraRecoveryMode(sessionState: .paused))
    }
}
