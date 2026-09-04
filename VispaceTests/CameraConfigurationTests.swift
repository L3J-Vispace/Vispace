import ARKit
import XCTest

@testable import Vispace

final class CameraConfigurationTests: XCTestCase {
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
