import ARKit
import XCTest

@testable import Vispace

final class CameraConfigurationTests: XCTestCase {
    func testNavigationEvaluationClockAdvancesAndRejectsFrozenFrames() {
        XCTAssertEqual(ARNavigationEvaluationClock.timestamp(frameTimestamp: 10, systemUptime: 10.5), 10.5)
        XCTAssertNil(ARNavigationEvaluationClock.timestamp(frameTimestamp: 10, systemUptime: 11.01))
        XCTAssertNil(ARNavigationEvaluationClock.timestamp(frameTimestamp: 10, systemUptime: 9))
        XCTAssertNil(ARNavigationEvaluationClock.timestamp(frameTimestamp: .nan, systemUptime: 10))
    }
    func testConfigurationNeverEnablesUnsupportedCapabilities() {
        let configuration = ARSessionConfigurationBuilder.live.makeConfiguration()

        if !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            XCTAssertFalse(configuration.frameSemantics.contains(.sceneDepth))
        }
        if !ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            XCTAssertFalse(configuration.frameSemantics.contains(.smoothedSceneDepth))
        }
        if !ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            XCTAssertEqual(configuration.sceneReconstruction, [])
        }
    }

    func testConfigurationAlwaysDetectsHorizontalAndVerticalPlanes() {
        let configuration = ARSessionConfigurationBuilder.live.makeConfiguration()
        XCTAssertTrue(configuration.planeDetection.contains(.horizontal))
        XCTAssertTrue(configuration.planeDetection.contains(.vertical))
    }
}
