import Foundation
import VispaceCore

/// Retains depth and calibration only. Camera pixel buffers are never retained
/// by navigation, so the bounded scan window does not duplicate RGB frames.
public struct ARNavigationDepthFrame: Sendable {
    public let pose: ARPoseSnapshot
    public let intrinsics: Matrix3x3Snapshot
    public let imageDimensions: ImageDimensions
    public let depth: ARDepthSnapshot

    public init?(_ frame: ARFrameSnapshot) {
        guard let depth = frame.sceneDepth,
            depth.depthMeters.count <= 307_200,
            depth.confidence?.count == depth.depthMeters.count else { return nil }
        self.init(pose: frame.pose, intrinsics: frame.cameraIntrinsics,
            imageDimensions: frame.cameraImageDimensions, depth: depth)
    }

    init(pose: ARPoseSnapshot, intrinsics: Matrix3x3Snapshot,
         imageDimensions: ImageDimensions, depth: ARDepthSnapshot) {
        self.pose = pose
        self.intrinsics = intrinsics
        self.imageDimensions = imageDimensions
        self.depth = depth
    }
}

@MainActor
public final class ARRecentNavigationDepthHistory {
    public typealias FrameStreamProvider = @MainActor @Sendable () -> AsyncStream<ARFrameSnapshot>
    private let frameStreamProvider: FrameStreamProvider
    private var task: Task<Void, Never>?
    private var retained: [ARNavigationDepthFrame] = []

    public init(frameStreamProvider: @escaping FrameStreamProvider) {
        self.frameStreamProvider = frameStreamProvider
    }

    deinit { task?.cancel() }

    public func activate() {
        guard task == nil else { return }
        let stream = frameStreamProvider()
        task = Task { @MainActor [weak self] in
            for await frame in stream {
                guard !Task.isCancelled, let self else { return }
                self.consume(frame)
            }
        }
    }

    public func deactivate() {
        task?.cancel()
        task = nil
        retained.removeAll(keepingCapacity: false)
    }

    func consume(_ frame: ARFrameSnapshot) {
        guard frame.pose.coordinateFrameStatus == .confirmed,
            frame.pose.trackingState == .normal,
            frame.pose.timestamp.isFinite,
            let lightweight = ARNavigationDepthFrame(frame) else {
            retained.removeAll(keepingCapacity: false)
            return
        }
        if let previous = retained.last,
            (previous.pose.sessionToken != frame.pose.sessionToken
                || previous.pose.coordinateFrameID != frame.pose.coordinateFrameID
                || previous.pose.segmentID != frame.pose.segmentID
                || previous.pose.mapID != frame.pose.mapID)
        { retained.removeAll(keepingCapacity: false) }
        guard retained.last.map({ frame.pose.timestamp > $0.pose.timestamp }) != false else { return }
        retained.removeAll { frame.pose.timestamp - $0.pose.timestamp > 3 }
        // Keep a scan spanning the time window, not merely the last quarter
        // second of a 60 fps stream. The evidence builder receives the current
        // frame separately, so sampling never substitutes for current blockers.
        if let previous = retained.last,
            frame.pose.timestamp - previous.pose.timestamp < 0.2 - 0.000_001 { return }
        retained.append(lightweight)
        if retained.count > 16 { retained.removeFirst(retained.count - 16) }
    }

    public func frames(matching identity: ARCaptureIdentity, evaluatedAt: TimeInterval) -> [ARNavigationDepthFrame] {
        guard evaluatedAt.isFinite, identity.status == .confirmed else { return [] }
        return retained.filter {
            $0.pose.coordinateFrameID == identity.coordinateFrameID
                && $0.pose.segmentID == identity.segmentID && $0.pose.mapID == identity.mapID
                && evaluatedAt - $0.pose.timestamp >= 0
                && evaluatedAt - $0.pose.timestamp <= 3
        }
    }
}
