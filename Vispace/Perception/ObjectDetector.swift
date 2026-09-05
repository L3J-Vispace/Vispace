import CoreGraphics
@preconcurrency import CoreML
import Foundation
import ImageIO
@preconcurrency import Vision
import simd

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

    public var isValidNonEmpty: Bool {
        x.isFinite
            && y.isFinite
            && width.isFinite
            && height.isFinite
            && width > 0
            && height > 0
            && x >= 0
            && y >= 0
            && x + width <= 1
            && y + height <= 1
    }

    public func intersectionOverUnion(with other: Self) -> Double {
        guard isValidNonEmpty, other.isValidNonEmpty else {
            return 0
        }
        let overlapWidth = max(
            0,
            min(x + width, other.x + other.width) - max(x, other.x)
        )
        let overlapHeight = max(
            0,
            min(y + height, other.y + other.height) - max(y, other.y)
        )
        let intersection = overlapWidth * overlapHeight
        let union = width * height + other.width * other.height - intersection
        return union > 0 ? intersection / union : 0
    }

    public func centerDistance(to other: Self) -> Double {
        guard isValidNonEmpty, other.isValidNonEmpty else {
            return .infinity
        }
        let dx = (x + width * 0.5) - (other.x + other.width * 0.5)
        let dy = (y + height * 0.5) - (other.y + other.height * 0.5)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Converts the Vision box center (oriented, lower-left origin) into the
    /// normalized raw-camera, top-left-origin coordinate expected by ARKit
    /// depth sampling. Invalid or out-of-image boxes fail closed.
    public func cameraImageTopLeftCenter(
        for orientation: FrameImageOrientation
    ) -> SIMD2<Float>? {
        cameraImageTopLeftPoint(
            relativeToTopLeft: SIMD2<Double>(0.5, 0.5),
            for: orientation
        )
    }

    /// Converts a point inside this Vision box to normalized raw-camera
    /// coordinates. The relative point uses a conventional top-left origin.
    public func cameraImageTopLeftPoint(
        relativeToTopLeft relativePoint: SIMD2<Double>,
        for orientation: FrameImageOrientation
    ) -> SIMD2<Float>? {
        guard isValidNonEmpty else {
            return nil
        }
        guard
            relativePoint.x.isFinite,
            relativePoint.y.isFinite,
            (0...1).contains(relativePoint.x),
            (0...1).contains(relativePoint.y)
        else {
            return nil
        }

        let orientedX = x + (width * relativePoint.x)
        let orientedBottomY = y + (height * (1 - relativePoint.y))
        let orientedTopY = 1 - orientedBottomY
        let raw: (x: Double, y: Double) =
            switch orientation {
            case .up:
                (orientedX, orientedTopY)
            case .upMirrored:
                (1 - orientedX, orientedTopY)
            case .down:
                (1 - orientedX, 1 - orientedTopY)
            case .downMirrored:
                (orientedX, 1 - orientedTopY)
            case .right:
                (orientedTopY, 1 - orientedX)
            case .rightMirrored:
                (orientedTopY, orientedX)
            case .left:
                (1 - orientedTopY, orientedX)
            case .leftMirrored:
                (1 - orientedTopY, 1 - orientedX)
            }
        return SIMD2<Float>(Float(raw.x), Float(raw.y))
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

public enum ObjectDetectorError: Error, Equatable, Sendable {
    case missingResults
    case unexpectedResultTypes([String])
}

public enum ObjectDetectionConfidence {
    /// Vision exposes objectness and label classification as independent
    /// confidence values. Their product is the confidence of the labeled box.
    public static func combined(object: Float, label: Float) -> Float? {
        guard
            object.isFinite,
            label.isFinite,
            (0...1).contains(object),
            (0...1).contains(label)
        else {
            return nil
        }
        return object * label
    }
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

        guard let results = request.results else {
            throw ObjectDetectorError.missingResults
        }
        let unexpectedTypes = Set(
            results.compactMap { observation -> String? in
                observation is VNRecognizedObjectObservation
                    ? nil
                    : String(reflecting: type(of: observation))
            }
        ).sorted()
        guard unexpectedTypes.isEmpty else {
            throw ObjectDetectorError.unexpectedResultTypes(unexpectedTypes)
        }

        let observations = results.compactMap { $0 as? VNRecognizedObjectObservation }
        return observations.compactMap { observation in
            guard
                let bestLabel = observation.labels.first,
                let confidence = ObjectDetectionConfidence.combined(
                    object: observation.confidence,
                    label: bestLabel.confidence
                ),
                confidence >= minimumConfidence
            else {
                return nil
            }

            let label = bestLabel.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let boundingBox = NormalizedBoundingBox(observation.boundingBox)
            guard !label.isEmpty, boundingBox.isValidNonEmpty else {
                return nil
            }

            return DetectedObject(
                label: label,
                confidence: confidence,
                boundingBox: boundingBox
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
