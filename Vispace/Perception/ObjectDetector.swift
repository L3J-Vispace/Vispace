import CoreGraphics
@preconcurrency import CoreImage
@preconcurrency import CoreML
import Foundation
import ImageIO
@preconcurrency import Vision
import VispaceCore
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
    case incompatibleModelInputs
    case invalidImageGeometry
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

public enum ObjectDetectorCropMode: Equatable, Sendable {
    case scaleFill
    case scaleFit
    case centerCrop

    var geometryMode: ObjectDetectorImageGeometry.Mode {
        switch self {
        case .scaleFill: .scaleFill
        case .scaleFit: .scaleFit
        case .centerCrop: .centerCrop
        }
    }
}

public enum ObjectDetectorDefaults {
    /// This only admits a visual candidate; durable spatial identity has its
    /// own, stronger evidence requirements in the perception controller.
    public static let minimumConfidence: Float = 0.30
    public static let intersectionOverUnionThreshold: Double = 0.45
}

/// Vision supplies the image input; these optional Core ML inputs override
/// the bundled model's very aggressive 0.1 same-class suppression threshold.
final class ObjectDetectorThresholdProvider: MLFeatureProvider {
    let confidenceThreshold: Double
    let intersectionOverUnionThreshold: Double

    init(confidenceThreshold: Double, intersectionOverUnionThreshold: Double) {
        self.confidenceThreshold = confidenceThreshold.isFinite
            ? min(max(confidenceThreshold, 0), 1)
            : Double(ObjectDetectorDefaults.minimumConfidence)
        self.intersectionOverUnionThreshold = intersectionOverUnionThreshold.isFinite
            ? min(max(intersectionOverUnionThreshold, 0), 1)
            : ObjectDetectorDefaults.intersectionOverUnionThreshold
    }

    var featureNames: Set<String> { ["confidenceThreshold", "iouThreshold"] }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        switch featureName {
        case "confidenceThreshold": MLFeatureValue(double: confidenceThreshold)
        case "iouThreshold": MLFeatureValue(double: intersectionOverUnionThreshold)
        default: nil
        }
    }
}

public enum ObjectDetectorFactory {
    /// Loads only Xcode-compiled Core ML resources (`.mlmodelc`). Failure is
    /// intentionally represented by `NoOpObjectDetector`, never a startup trap.
    public static func bundledModel(
        named modelName: String,
        bundle: Bundle = .main,
        minimumConfidence: Float = ObjectDetectorDefaults.minimumConfidence,
        cropMode: ObjectDetectorCropMode = .scaleFit,
        intersectionOverUnionThreshold: Double = ObjectDetectorDefaults.intersectionOverUnionThreshold
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
            let inputs = coreMLModel.modelDescription.inputDescriptionsByName
            guard let imageConstraint = inputs[visionModel.inputImageFeatureName]?.imageConstraint,
                (1...4096).contains(imageConstraint.pixelsWide),
                (1...4096).contains(imageConstraint.pixelsHigh),
                inputs["confidenceThreshold"]?.type == .double,
                inputs["iouThreshold"]?.type == .double
            else { throw ObjectDetectorError.incompatibleModelInputs }
            visionModel.featureProvider = ObjectDetectorThresholdProvider(
                confidenceThreshold: Double(minimumConfidence),
                intersectionOverUnionThreshold: intersectionOverUnionThreshold
            )
            return ObjectDetectorResolution(
                detector: VisionCoreMLObjectDetector(
                    model: visionModel,
                    minimumConfidence: minimumConfidence,
                    cropMode: cropMode,
                    modelImageWidth: imageConstraint.pixelsWide,
                    modelImageHeight: imageConstraint.pixelsHigh
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
    private let modelImageWidth: Int
    private let modelImageHeight: Int

    init(
        model: VNCoreMLModel,
        minimumConfidence: Float,
        cropMode: ObjectDetectorCropMode,
        modelImageWidth: Int,
        modelImageHeight: Int
    ) {
        self.model = model
        self.minimumConfidence =
            minimumConfidence.isFinite
            ? min(max(minimumConfidence, 0), 1)
            : ObjectDetectorDefaults.minimumConfidence
        self.cropMode = cropMode
        self.modelImageWidth = modelImageWidth
        self.modelImageHeight = modelImageHeight
    }

    public func detect(in frame: ARFrameSnapshot) async throws -> [DetectedObject] {
        // Core Image remains lazy until Vision consumes this bounded canvas.
        // Neither original nor prepared pixels are stored or retained between requests.
        try autoreleasepool {
            try detectSynchronously(in: frame)
        }
    }

    private func detectSynchronously(in frame: ARFrameSnapshot) throws -> [DetectedObject] {
        let prepared = try ObjectDetectorImagePreprocessor.prepare(
            image: CIImage(cvPixelBuffer: frame.capturedImage.pixelBuffer),
            orientation: frame.imageOrientation,
            modelImageWidth: modelImageWidth,
            modelImageHeight: modelImageHeight,
            cropMode: cropMode
        )
        let request = VNCoreMLRequest(model: model)
        // The camera has already been oriented and fitted explicitly. Giving
        // Vision an exact-size canvas avoids a second, implicit crop transform.
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(
            ciImage: prepared.image,
            orientation: .up,
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
            guard let bestLabel = observation.labels.first else { return nil }
            return ObjectDetectorResultAdapter.detection(
                label: bestLabel.identifier,
                objectConfidence: observation.confidence,
                labelConfidence: bestLabel.confidence,
                modelBox: .init(
                    x: Double(observation.boundingBox.origin.x),
                    y: Double(observation.boundingBox.origin.y),
                    width: Double(observation.boundingBox.width),
                    height: Double(observation.boundingBox.height)
                ),
                geometry: prepared.geometry,
                minimumConfidence: minimumConfidence
            )
        }
        .sorted { left, right in
            left.confidence > right.confidence
        }
    }
}

enum ObjectDetectorImagePreprocessor {
    static func prepare(
        image: CIImage,
        orientation: FrameImageOrientation,
        modelImageWidth: Int,
        modelImageHeight: Int,
        cropMode: ObjectDetectorCropMode
    ) throws -> (image: CIImage, geometry: ObjectDetectorImageGeometry) {
        let oriented = image.oriented(forExifOrientation: Int32(orientation.rawValue))
        let extent = oriented.extent
        guard extent.origin.x.isFinite, extent.origin.y.isFinite,
            (1...4096).contains(modelImageWidth), (1...4096).contains(modelImageHeight),
            let geometry = ObjectDetectorImageGeometry(
                imageWidth: Double(extent.width), imageHeight: Double(extent.height),
                modelWidth: Double(modelImageWidth), modelHeight: Double(modelImageHeight),
                mode: cropMode.geometryMode
            )
        else { throw ObjectDetectorError.invalidImageGeometry }
        let canvas = CGRect(
            x: 0, y: 0, width: CGFloat(modelImageWidth), height: CGFloat(modelImageHeight))
        let fitted = oriented
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: geometry.scaleX, y: geometry.scaleY))
            .transformed(by: CGAffineTransform(translationX: geometry.offsetX, y: geometry.offsetY))
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas)
        return (fitted.composited(over: background).cropped(to: canvas), geometry)
    }
}

enum ObjectDetectorResultAdapter {
    static func detection(
        label: String,
        objectConfidence: Float,
        labelConfidence: Float,
        modelBox: ObjectDetectorImageGeometry.Box,
        geometry: ObjectDetectorImageGeometry,
        minimumConfidence: Float
    ) -> DetectedObject? {
        guard let confidence = ObjectDetectionConfidence.combined(
            object: objectConfidence, label: labelConfidence), confidence >= minimumConfidence,
            let sourceBox = geometry.sourceNormalizedBox(fromModelBox: modelBox)
        else { return nil }
        let canonicalLabel = ObjectSemanticCatalog.default.canonicalLabel(for: label)
        let boundingBox = NormalizedBoundingBox(
            x: sourceBox.x, y: sourceBox.y, width: sourceBox.width, height: sourceBox.height)
        guard !canonicalLabel.isEmpty, boundingBox.isValidNonEmpty else { return nil }
        return DetectedObject(label: canonicalLabel, confidence: confidence, boundingBox: boundingBox)
    }
}

extension FrameImageOrientation {
    var cgImageOrientation: CGImagePropertyOrientation {
        // FrameImageOrientation intentionally uses the same stable EXIF raw values.
        CGImagePropertyOrientation(rawValue: rawValue) ?? .up
    }
}
