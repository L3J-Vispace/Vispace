import XCTest

@testable import VispaceCore

final class ObjectDetectorImageGeometryTests: XCTestCase {
    func testPortraitLetterboxPreservesShapeAndRemovesHorizontalPadding() throws {
        let geometry = try XCTUnwrap(ObjectDetectorImageGeometry(
            imageWidth: 1080, imageHeight: 1920, modelWidth: 416, modelHeight: 416,
            mode: .scaleFit))
        XCTAssertEqual(geometry.scaleX, geometry.scaleY)
        XCTAssertEqual(geometry.offsetX, 91)
        XCTAssertEqual(geometry.offsetY, 0)
        // Camera box x=.2, y=.3, w=.4, h=.2 after a 234x416 fit.
        let result = try XCTUnwrap(geometry.sourceNormalizedBox(fromModelBox: .init(
            x: 137.8 / 416, y: 0.3, width: 93.6 / 416, height: 0.2)))
        assertBox(result, x: 0.2, y: 0.3, width: 0.4, height: 0.2)
    }

    func testLandscapeLetterboxRemovesVerticalPadding() throws {
        let geometry = try XCTUnwrap(ObjectDetectorImageGeometry(
            imageWidth: 1920, imageHeight: 1080, modelWidth: 416, modelHeight: 416,
            mode: .scaleFit))
        XCTAssertEqual(geometry.offsetX, 0)
        XCTAssertEqual(geometry.offsetY, 91)
        let result = try XCTUnwrap(geometry.sourceNormalizedBox(fromModelBox: .init(
            x: 0.2, y: 161.2 / 416, width: 0.4, height: 46.8 / 416)))
        assertBox(result, x: 0.2, y: 0.3, width: 0.4, height: 0.2)
    }

    func testPartialEdgeBoxIsClippedButPaddingOnlyBoxIsRejected() throws {
        let geometry = try XCTUnwrap(ObjectDetectorImageGeometry(
            imageWidth: 100, imageHeight: 200, modelWidth: 400, modelHeight: 400,
            mode: .scaleFit))
        XCTAssertNil(geometry.sourceNormalizedBox(fromModelBox: .init(
            x: 0.01, y: 0.4, width: 0.1, height: 0.2)))
        let clipped = try XCTUnwrap(geometry.sourceNormalizedBox(fromModelBox: .init(
            x: 0.2, y: 0.4, width: 0.15, height: 0.2)))
        assertBox(clipped, x: 0, y: 0.4, width: 0.2, height: 0.2)
    }

    func testScaleFillAndCenterCropKeepTheirExplicitCoordinateContract() throws {
        let fill = try XCTUnwrap(ObjectDetectorImageGeometry(
            imageWidth: 100, imageHeight: 200, modelWidth: 400, modelHeight: 400,
            mode: .scaleFill))
        XCTAssertEqual(fill.scaleX, 4)
        XCTAssertEqual(fill.scaleY, 2)
        let box = ObjectDetectorImageGeometry.Box(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
        assertBox(try XCTUnwrap(fill.sourceNormalizedBox(fromModelBox: box)),
            x: 0.2, y: 0.3, width: 0.4, height: 0.2)

        let crop = try XCTUnwrap(ObjectDetectorImageGeometry(
            imageWidth: 100, imageHeight: 200, modelWidth: 400, modelHeight: 400,
            mode: .centerCrop))
        XCTAssertEqual(crop.offsetY, -200)
        assertBox(try XCTUnwrap(crop.sourceNormalizedBox(fromModelBox: .init(
            x: 0, y: 0, width: 1, height: 1))), x: 0, y: 0.25, width: 1, height: 0.5)
    }

    func testNonSquareModelDimensionsAndInvalidInputs() throws {
        let geometry = try XCTUnwrap(ObjectDetectorImageGeometry(
            imageWidth: 400, imageHeight: 400, modelWidth: 640, modelHeight: 320,
            mode: .scaleFit))
        XCTAssertEqual(geometry.offsetX, 160)
        assertBox(try XCTUnwrap(geometry.sourceNormalizedBox(fromModelBox: .init(
            x: 0.25, y: 0, width: 0.5, height: 1))), x: 0, y: 0, width: 1, height: 1)
        for invalid in [Double.nan, .infinity, 0, -1, 16_385] {
            XCTAssertNil(ObjectDetectorImageGeometry(imageWidth: invalid, imageHeight: 200,
                modelWidth: 416, modelHeight: 416, mode: .scaleFit))
        }
        for box in [
            ObjectDetectorImageGeometry.Box(x: .nan, y: 0, width: 0.1, height: 0.1),
            .init(x: 0, y: 0, width: .infinity, height: 0.1),
            .init(x: 0, y: 0, width: -0.1, height: 0.1),
            .init(x: 1.2, y: 0, width: 0.1, height: 0.1),
        ] {
            XCTAssertNil(geometry.sourceNormalizedBox(fromModelBox: box))
        }
    }

    private func assertBox(
        _ box: ObjectDetectorImageGeometry.Box,
        x: Double, y: Double, width: Double, height: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(box.x, x, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(box.y, y, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(box.width, width, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(box.height, height, accuracy: 0.000_001, file: file, line: line)
    }
}
