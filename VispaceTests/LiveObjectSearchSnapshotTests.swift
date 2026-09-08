import CoreGraphics
import VispaceCore
import XCTest

@testable import Vispace

final class LiveObjectSearchSnapshotTests: XCTestCase {
    func testKeyboardCandidateIsVisibleWithoutStoredMapOrDepthButExpires() {
        let snapshot = makeSnapshot(mapID: nil, hasDepth: false)
        let matches = snapshot.matches(labels: ["키보드"], now: 10.5)
        XCTAssertEqual(matches.count, 1)
        XCTAssertTrue(snapshot.message(for: matches[0]).contains("깊이"))
        XCTAssertTrue(snapshot.matches(labels: ["키보드"], now: 11.6).isEmpty)
        XCTAssertTrue(snapshot.matches(labels: ["키보드"], now: 9).isEmpty)
        XCTAssertTrue(snapshot.matches(labels: ["키보드"], now: .nan).isEmpty)
    }

    func testCatalogAliasesMatchWhileUnrelatedAndInvalidCandidatesAreRejected() {
        let monitor = DetectedObject(label: "tvmonitor", confidence: 0.65,
                                     boundingBox: box)
        let invalid = DetectedObject(label: "keyboard", confidence: .nan, boundingBox: box)
        let snapshot = makeSnapshot(detections: [monitor, invalid])
        XCTAssertEqual(snapshot.matches(labels: ["모니터"], now: 10.1), [monitor])
        XCTAssertTrue(snapshot.matches(labels: ["키보드"], now: 10.1).isEmpty)
        XCTAssertTrue(snapshot.matches(labels: ["mouse"], now: 10.1).isEmpty)
    }

    func testCandidatesDoNotResolveAmbiguityToOneObject() {
        let detections = [DetectedObject(label: "keyboard", confidence: 0.5, boundingBox: box),
                          DetectedObject(label: "keyboard", confidence: 0.7, boundingBox: box)]
        let snapshot = makeSnapshot(detections: detections)
        let result = snapshot.matches(labels: ["keyboard"], now: 10.1)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.confidence, 0.7)
        XCTAssertTrue(snapshot.message(for: result[0]).contains("분류를 확인"))
    }

    func testUnreliableDepthIsExplainedEvenWhenDeviceProvidesADepthBuffer() {
        var snapshot = makeSnapshot()
        let detection = snapshot.detections[0]
        snapshot.recordDepthFailure(for: detection)
        XCTAssertTrue(snapshot.hasDepth)
        XCTAssertTrue(snapshot.message(for: detection).contains("깊이를 안정적으로 확인하지 못해"))
    }

    func testViewportProjectionUsesPortraitOrientationAndRecordedDisplayTransform() throws {
        let transform = ARDisplayTransformSnapshot(
            imageToViewport: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0),
            geometry: FrameDisplayGeometry(orientation: .portrait,
                viewportSize: ViewportSizeSnapshot(width: 400, height: 800)))
        let snapshot = makeSnapshot(orientation: .right, transform: transform)
        let rect = try XCTUnwrap(snapshot.viewportBounds(for: snapshot.detections[0]))
        XCTAssertEqual(rect.minX, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(rect.minY, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(rect.width, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(rect.height, 0.2, accuracy: 0.000_001)
    }

    func testMissingOrSingularDisplayTransformNeverInventsScreenRectangle() {
        let snapshot = makeSnapshot()
        XCTAssertNil(snapshot.viewportBounds(for: snapshot.detections[0]))
        let transform = ARDisplayTransformSnapshot(
            imageToViewport: CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0),
            geometry: FrameDisplayGeometry(orientation: .portrait,
                viewportSize: ViewportSizeSnapshot(width: 400, height: 800)))
        let singular = makeSnapshot(transform: transform)
        XCTAssertNil(singular.viewportBounds(for: singular.detections[0]))
    }

    private var box: NormalizedBoundingBox {
        NormalizedBoundingBox(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
    }

    private func makeSnapshot(detections: [DetectedObject]? = nil, mapID: MapID? = MapID(),
                              hasDepth: Bool = true, orientation: FrameImageOrientation = .up,
                              transform: ARDisplayTransformSnapshot? = nil) -> LiveObjectSearchSnapshot {
        LiveObjectSearchSnapshot(
            detections: detections ?? [DetectedObject(label: "keyboard", confidence: 0.6,
                                                     boundingBox: box)],
            identity: ARCaptureIdentity(mapID: mapID, status: .confirmed), timestamp: 10,
            orientation: orientation, displayTransform: transform, hasDepth: hasDepth)
    }
}
