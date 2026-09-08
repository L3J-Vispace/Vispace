import CoreGraphics
import Foundation
import VispaceCore

/// Ephemeral image evidence, deliberately separate from stored object identity
/// and AR guidance. No camera buffer or invented world position is retained.
public struct LiveObjectSearchSnapshot: Equatable, Sendable {
    public let detections: [DetectedObject]
    public let identity: ARCaptureIdentity
    public let timestamp: TimeInterval
    public let orientation: FrameImageOrientation
    public let displayTransform: ARDisplayTransformSnapshot?
    public let hasDepth: Bool
    public private(set) var depthUnavailableDetections: [DetectedObject] = []

    public init(detections: [DetectedObject], identity: ARCaptureIdentity,
                timestamp: TimeInterval, orientation: FrameImageOrientation,
                displayTransform: ARDisplayTransformSnapshot?, hasDepth: Bool) {
        self.detections = Array(detections.prefix(64))
        self.identity = identity
        self.timestamp = timestamp
        self.orientation = orientation
        self.displayTransform = displayTransform
        self.hasDepth = hasDepth
    }

    public func matches(labels: [String], now: TimeInterval) -> [DetectedObject] {
        guard identity.status == .confirmed, timestamp.isFinite, now.isFinite,
              now >= timestamp, now - timestamp <= 1.5 else { return [] }
        let catalog = ObjectSemanticCatalog.default
        let targets = Set(labels.map { catalog.canonicalLabel(for: $0) })
        return Array(detections.filter {
            $0.confidence.isFinite && $0.confidence >= 0.30 && $0.boundingBox.isValidNonEmpty
                && targets.contains(catalog.canonicalLabel(for: $0.label))
        }.sorted { $0.confidence > $1.confidence }.prefix(8))
    }

    /// Vision oriented coordinates -> raw camera -> actual AR viewport.
    public func viewportBounds(for detection: DetectedObject) -> CGRect? {
        guard let displayTransform, displayTransform.geometry.viewportSize.isUsable else { return nil }
        let transform = displayTransform.imageToViewport.cgAffineTransform
        guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
            .allSatisfy(\.isFinite), abs(transform.a * transform.d - transform.b * transform.c) > 1e-9
        else { return nil }
        let points = [SIMD2<Double>(0, 0), SIMD2<Double>(1, 0),
                      SIMD2<Double>(0, 1), SIMD2<Double>(1, 1)].compactMap { point -> CGPoint? in
            guard let raw = detection.boundingBox.cameraImageTopLeftPoint(
                relativeToTopLeft: point, for: orientation) else { return nil }
            return CGPoint(x: CGFloat(raw.x), y: CGFloat(raw.y)).applying(transform)
        }
        guard points.count == 4,
              let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    public func message(for detection: DetectedObject) -> String {
        let name = ObjectSemanticCatalog.default.displayName(for: detection.label)
        let prefix = "화면에서 ‘\(name)’ 후보를 찾았어요. "
        if !hasDepth || depthUnavailableDetections.contains(detection) {
            return prefix + "깊이를 안정적으로 확인하지 못해 위치는 저장하지 않았어요. 물체를 다른 각도에서 비춰 주세요."
        }
        if identity.mapID == nil { return prefix + "주변을 천천히 비춰 공간 지도가 만들어지면 위치를 기억할 수 있어요." }
        if detection.confidence < 0.80 { return prefix + "분류를 확인 중이에요. 더 가까이 비추거나 직접 이름과 위치를 등록해 주세요." }
        return prefix + "위치를 확인 중이에요. 잠시 같은 물체를 비춰 주세요."
    }

    public mutating func recordDepthFailure(for detection: DetectedObject) {
        if detections.contains(detection), !depthUnavailableDetections.contains(detection) {
            depthUnavailableDetections.append(detection)
        }
    }
}
