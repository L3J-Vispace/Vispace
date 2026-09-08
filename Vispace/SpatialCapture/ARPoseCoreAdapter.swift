import Foundation
import VispaceCore

extension Matrix4x4Snapshot {
    /// Converts ARKit's column-major SIMD storage into the core package's
    /// explicit row-major transform without transposing the represented pose.
    public func coreTransform() throws -> Transform3D {
        try Transform3D(rowMajorElements: [
            Double(column0.x), Double(column1.x), Double(column2.x), Double(column3.x),
            Double(column0.y), Double(column1.y), Double(column2.y), Double(column3.y),
            Double(column0.z), Double(column1.z), Double(column2.z), Double(column3.z),
            Double(column0.w), Double(column1.w), Double(column2.w), Double(column3.w),
        ])
    }
}

public struct FramedPoseSample: Sendable {
    public let coordinateFrameID: CoordinateFrameID
    public let segmentID: CaptureSegmentID
    public let mapID: MapID?
    public let coordinateFrameStatus: ARCaptureIdentity.Status
    public let sample: PoseSample
    public let trackingState: ARTrackingStateSnapshot
    public let worldMappingStatus: ARWorldMappingStatusSnapshot
}

public struct ARPoseCoreAdapter: Sendable {
    public struct ConfidencePolicy: Equatable, Sendable {
        public let normal: Double
        public let limited: Double
        public let unavailable: Double

        public init(normal: Double = 1, limited: Double = 0.35, unavailable: Double = 0) {
            self.normal = normal
            self.limited = limited
            self.unavailable = unavailable
        }
    }

    public let confidencePolicy: ConfidencePolicy

    public init(confidencePolicy: ConfidencePolicy = ConfidencePolicy()) {
        self.confidencePolicy = confidencePolicy
    }

    public func adapt(_ pose: ARPoseSnapshot) throws -> FramedPoseSample {
        let confidenceValue: Double =
            switch pose.trackingState {
            case .normal: confidencePolicy.normal
            case .limited: confidencePolicy.limited
            case .unavailable: confidencePolicy.unavailable
            }
        let confidence = try ConfidenceScore(validating: confidenceValue)
        let sample = try PoseSample(
            frameID: FrameID(rawValue: pose.id.rawValue),
            timestamp: pose.timestamp,
            transform: pose.cameraTransform.coreTransform(),
            trackingConfidence: confidence
        )
        return FramedPoseSample(
            coordinateFrameID: pose.coordinateFrameID,
            segmentID: pose.segmentID,
            mapID: pose.mapID,
            coordinateFrameStatus: pose.coordinateFrameStatus,
            sample: sample,
            trackingState: pose.trackingState,
            worldMappingStatus: pose.worldMappingStatus
        )
    }
}
