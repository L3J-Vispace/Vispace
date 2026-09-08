import Foundation

/// The image transform is explicit so detection boxes can be returned to the
/// oriented camera image before depth sampling or tracking uses them.
public struct ObjectDetectorImageGeometry: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case scaleFit
        case scaleFill
        case centerCrop
    }

    public struct Box: Equatable, Sendable {
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
    }

    public let imageWidth: Double
    public let imageHeight: Double
    public let modelWidth: Double
    public let modelHeight: Double
    public let scaleX: Double
    public let scaleY: Double
    public let offsetX: Double
    public let offsetY: Double

    public init?(
        imageWidth: Double,
        imageHeight: Double,
        modelWidth: Double,
        modelHeight: Double,
        mode: Mode
    ) {
        guard [imageWidth, imageHeight, modelWidth, modelHeight].allSatisfy({
            $0.isFinite && $0 > 0 && $0 <= 16_384
        }) else { return nil }

        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.modelWidth = modelWidth
        self.modelHeight = modelHeight
        let widthScale = modelWidth / imageWidth
        let heightScale = modelHeight / imageHeight
        switch mode {
        case .scaleFit:
            scaleX = min(widthScale, heightScale)
            scaleY = scaleX
        case .centerCrop:
            scaleX = max(widthScale, heightScale)
            scaleY = scaleX
        case .scaleFill:
            scaleX = widthScale
            scaleY = heightScale
        }
        offsetX = (modelWidth - imageWidth * scaleX) * 0.5
        offsetY = (modelHeight - imageHeight * scaleY) * 0.5
    }

    /// Both coordinate systems have a lower-left origin. Boxes crossing an
    /// image edge retain their visible part; padding-only and invalid boxes
    /// cannot reach the camera's depth coordinates.
    public func sourceNormalizedBox(fromModelBox box: Box) -> Box? {
        guard [box.x, box.y, box.width, box.height].allSatisfy(\.isFinite),
            box.width > 0, box.height > 0
        else { return nil }

        // Intersect with the model canvas first, including for center-crop.
        let modelLeft = max(0, box.x)
        let modelBottom = max(0, box.y)
        let modelRight = min(1, box.x + box.width)
        let modelTop = min(1, box.y + box.height)
        guard modelRight > modelLeft, modelTop > modelBottom else { return nil }

        let left = max(0, (modelLeft * modelWidth - offsetX) / (imageWidth * scaleX))
        let bottom = max(0, (modelBottom * modelHeight - offsetY) / (imageHeight * scaleY))
        let right = min(1, (modelRight * modelWidth - offsetX) / (imageWidth * scaleX))
        let top = min(1, (modelTop * modelHeight - offsetY) / (imageHeight * scaleY))
        guard right > left, top > bottom else { return nil }
        return Box(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}
