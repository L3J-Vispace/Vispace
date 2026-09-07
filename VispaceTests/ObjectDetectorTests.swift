import CoreGraphics
import CoreImage
import CoreML
import Vision
import VispaceCore
import XCTest

@testable import Vispace

final class ObjectDetectorTests: XCTestCase {
    func testThresholdProviderOverridesBothModelInputs() throws {
        let provider = ObjectDetectorThresholdProvider(
            confidenceThreshold: 0.3, intersectionOverUnionThreshold: 0.45)
        XCTAssertEqual(provider.featureNames, ["confidenceThreshold", "iouThreshold"])
        XCTAssertEqual(try XCTUnwrap(provider.featureValue(for: "confidenceThreshold")).doubleValue, 0.3)
        XCTAssertEqual(try XCTUnwrap(provider.featureValue(for: "iouThreshold")).doubleValue, 0.45)
        XCTAssertNil(provider.featureValue(for: "image"))

        let invalid = ObjectDetectorThresholdProvider(
            confidenceThreshold: .nan, intersectionOverUnionThreshold: .infinity)
        XCTAssertEqual(invalid.confidenceThreshold, Double(ObjectDetectorDefaults.minimumConfidence))
        XCTAssertEqual(invalid.intersectionOverUnionThreshold, 0.45)
        let bounded = ObjectDetectorThresholdProvider(
            confidenceThreshold: -0.1, intersectionOverUnionThreshold: 1.2)
        XCTAssertEqual(bounded.confidenceThreshold, 0)
        XCTAssertEqual(bounded.intersectionOverUnionThreshold, 1)
    }

    func testPreprocessorOrientsEveryExifCaseBeforeFitting() throws {
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 200))
        for orientation in FrameImageOrientation.allCases {
            let prepared = try ObjectDetectorImagePreprocessor.prepare(
                image: source, orientation: orientation,
                modelImageWidth: 416, modelImageHeight: 416, cropMode: .scaleFit)
            XCTAssertEqual(prepared.image.extent, CGRect(x: 0, y: 0, width: 416, height: 416))
            switch orientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                XCTAssertEqual(prepared.geometry.imageWidth, 200)
                XCTAssertEqual(prepared.geometry.imageHeight, 100)
            case .up, .upMirrored, .down, .downMirrored:
                XCTAssertEqual(prepared.geometry.imageWidth, 100)
                XCTAssertEqual(prepared.geometry.imageHeight, 200)
            }
            XCTAssertEqual(prepared.geometry.scaleX, prepared.geometry.scaleY)
        }
        XCTAssertThrowsError(try ObjectDetectorImagePreprocessor.prepare(
            image: source, orientation: .up,
            modelImageWidth: 100_000, modelImageHeight: 416, cropMode: .scaleFit))
    }

    func testResultAdapterPreservesConfidenceCanonicalizesAndRemapsEdges() throws {
        let geometry = try XCTUnwrap(ObjectDetectorImageGeometry(
            imageWidth: 100, imageHeight: 200, modelWidth: 400, modelHeight: 400,
            mode: .scaleFit))
        let result = try XCTUnwrap(ObjectDetectorResultAdapter.detection(
            label: " TV ", objectConfidence: 0.8, labelConfidence: 0.5,
            modelBox: .init(x: 0.2, y: 0.4, width: 0.15, height: 0.2),
            geometry: geometry, minimumConfidence: ObjectDetectorDefaults.minimumConfidence))
        XCTAssertEqual(result.label, "tvmonitor")
        XCTAssertEqual(result.confidence, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(result.boundingBox.x, 0)
        XCTAssertEqual(result.boundingBox.width, 0.2, accuracy: 0.000_001)
        XCTAssertTrue(result.boundingBox.isValidNonEmpty)
        let rawCenter = try XCTUnwrap(result.boundingBox.cameraImageTopLeftCenter(for: .right))
        XCTAssertEqual(rawCenter.x, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(rawCenter.y, 0.9, accuracy: 0.000_001)
    }

    func testResultAdapterRejectsWeakInvalidAndPaddingOnlyDetections() throws {
        let geometry = try XCTUnwrap(ObjectDetectorImageGeometry(
            imageWidth: 100, imageHeight: 200, modelWidth: 400, modelHeight: 400,
            mode: .scaleFit))
        func detection(_ label: String, _ confidence: Float, _ box: ObjectDetectorImageGeometry.Box)
            -> DetectedObject? {
            ObjectDetectorResultAdapter.detection(label: label,
                objectConfidence: confidence, labelConfidence: 1,
                modelBox: box, geometry: geometry,
                minimumConfidence: ObjectDetectorDefaults.minimumConfidence)
        }
        let visible = ObjectDetectorImageGeometry.Box(x: 0.3, y: 0.4, width: 0.2, height: 0.2)
        XCTAssertNotNil(detection("keyboard", 0.30, visible))
        XCTAssertNil(detection("keyboard", 0.299, visible))
        XCTAssertNil(detection("keyboard", .nan, visible))
        XCTAssertNil(detection("   ", 0.9, visible))
        XCTAssertNil(detection("keyboard", 0.9, .init(x: 0, y: 0.4, width: 0.1, height: 0.2)))
    }

    func testBundledModelLoadsAndAcceptsRuntimeThresholdsThroughVision() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "YOLOv3Int8LUT", withExtension: "mlmodelc"))
        let configuration = MLModelConfiguration()
        // Keep this contract smoke test independent of GPU/Neural Engine availability.
        configuration.computeUnits = .cpuOnly
        let coreModel = try MLModel(contentsOf: url, configuration: configuration)
        let model = try VNCoreMLModel(for: coreModel)
        model.featureProvider = ObjectDetectorThresholdProvider(
            confidenceThreshold: 0.3, intersectionOverUnionThreshold: 0.45)
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let image = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 416, height: 416))
        try VNImageRequestHandler(ciImage: image, orientation: .up, options: [:]).perform([request])
        let results = try XCTUnwrap(request.results)
        XCTAssertTrue(results.allSatisfy { $0 is VNRecognizedObjectObservation })
        XCTAssertEqual(coreModel.modelDescription.inputDescriptionsByName["confidenceThreshold"]?.type, .double)
        XCTAssertEqual(coreModel.modelDescription.inputDescriptionsByName["iouThreshold"]?.type, .double)
        // Loading/inference is an integration contract, not a recognition-accuracy measurement.
    }
}
