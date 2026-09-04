import CoreGraphics
@preconcurrency import CoreML
import Foundation
import ImageIO
@preconcurrency import Vision

/// Vision normalized coordinates: origin at the lower-left of the image.
public struct NormalizedBoundingBox: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }
}

public struct DetectedObject: Equatable, Sendable {
    public let label: String
    public let confidence: Float
    public let boundingBox: NormalizedBoundingBox

    public init(
        label: String,
        confidence: Float,
        boundingBox: NormalizedBoundingBox
    ) {
        self.label = label
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public protocol ObjectDetector: Sendable {
    func detect(in frame: ARFrameSnapshot) async throws -> [DetectedObject]
}

/// Safe production fallback used when an optional bundled model is absent or
/// fails validation. The camera continues to function without pretending that
/// perception results exist.
public struct NoOpObjectDetector: ObjectDetector {
    public let reason: String

    public init(reason: String = "No object-detection model is installed.") {
        self.reason = reason
    }

    public func detect(in frame: ARFrameSnapshot) async throws -> [DetectedObject] {
        []
    }
}

public enum ObjectDetectorAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

public struct ObjectDetectorResolution: Sendable {
    public let detector: any ObjectDetector
    public let availability: ObjectDetectorAvailability

    public init(
        detector: any ObjectDetector,
        availability: ObjectDetectorAvailability
    ) {
        self.detector = detector
        self.availability = availability
    }
}

public enum ObjectDetectorCropMode: Sendable {
    case scaleFill
    case scaleFit
    case centerCrop

    fileprivate var visionValue: VNImageCropAndScaleOption {
        switch self {
        case .scaleFill: .scaleFill
        case .scaleFit: .scaleFit
        case .centerCrop: .centerCrop
        }
    }
}

public enum ObjectDetectorFactory {
    /// Loads only Xcode-compiled Core ML resources (`.mlmodelc`). Failure is
    /// intentionally represented by `NoOpObjectDetector`, never a startup trap.
    public static func bundledModel(
        named modelName: String,
        bundle: Bundle = .main,
        minimumConfidence: Float = 0.45,
        cropMode: ObjectDetectorCropMode = .scaleFill
    ) -> ObjectDetectorResolution {
        guard let modelURL = bundle.url(forResource: modelName, withExtension: "mlmodelc") else {
            let reason = "Bundled model \(modelName).mlmodelc was not found."
            return ObjectDetectorResolution(
                detector: NoOpObjectDetector(reason: reason),
                availability: .unavailable(reason: reason)
            )
        }

        do {
            let configuration = MLModelConfiguration()
            let coreMLModel = try MLModel(contentsOf: modelURL, configuration: configuration)
            let visionModel = try VNCoreMLModel(for: coreMLModel)
            return ObjectDetectorResolution(
                detector: VisionCoreMLObjectDetector(
                    model: visionModel,
                    minimumConfidence: minimumConfidence,
                    cropMode: cropMode
                ),
                availability: .available
            )
        } catch {
            let reason = "Bundled model could not be loaded: \(error.localizedDescription)"
            return ObjectDetectorResolution(
                detector: NoOpObjectDetector(reason: reason),
                availability: .unavailable(reason: reason)
            )
        }
    }
}

/// Actor isolation keeps Vision request/model reference types on one executor.
public actor VisionCoreMLObjectDetector: ObjectDetector {
    private let model: VNCoreMLModel
    private let minimumConfidence: Float
    private let cropMode: ObjectDetectorCropMode

    init(
        model: VNCoreMLModel,
        minimumConfidence: Float,
        cropMode: ObjectDetectorCropMode
    ) {
        self.model = model
        self.minimumConfidence =
            minimumConfidence.isFinite
            ? min(max(minimumConfidence, 0), 1)
            : 0.45
        self.cropMode = cropMode
    }

    public func detect(in frame: ARFrameSnapshot) async throws -> [DetectedObject] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = cropMode.visionValue

        let handler = VNImageRequestHandler(
            cvPixelBuffer: frame.capturedImage.pixelBuffer,
            orientation: frame.imageOrientation.cgImageOrientation,
            options: [:]
        )
        try handler.perform([request])

        let observations = request.results as? [VNRecognizedObjectObservation] ?? []
        return observations.compactMap { observation in
            guard
                let bestLabel = observation.labels.first,
                bestLabel.confidence.isFinite,
                bestLabel.confidence >= minimumConfidence
            else {
                return nil
            }

            return DetectedObject(
                label: bestLabel.identifier,
                confidence: bestLabel.confidence,
                boundingBox: NormalizedBoundingBox(observation.boundingBox)
            )
        }
        .sorted { left, right in
            left.confidence > right.confidence
        }
    }
}

extension FrameImageOrientation {
    var cgImageOrientation: CGImagePropertyOrientation {
        // FrameImageOrientation intentionally uses the same stable EXIF raw values.
        CGImagePropertyOrientation(rawValue: rawValue) ?? .up
    }
}
