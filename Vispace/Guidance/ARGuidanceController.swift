import Combine
import Foundation
import VispaceCore

public enum ARGuidanceTargetError: Error, Equatable, Sendable {
    case emptySemanticLabel
    case semanticLabelTooLong(maximum: Int)
    case invalidResolutionTime
}

/// A search result that has already been transformed into the coordinate frame
/// owned by the active AR session. Source-map transforms stay in the query
/// layer; the renderer can therefore never apply an unverified transform.
public struct ARGuidanceTarget: Equatable, Sendable {
    public static let maximumSemanticLabelLength = 80

    public let objectID: ObjectID
    public let semanticLabel: String
    public let activeMapID: MapID?
    public let activeSegmentID: CaptureSegmentID
    public let position: FramedPosition
    public let confidenceGrade: ConfidenceGrade
    public let representsLastSeenLocation: Bool
    public let resolvedAt: TimeInterval

    public init(
        objectID: ObjectID,
        semanticLabel: String,
        activeMapID: MapID?,
        activeSegmentID: CaptureSegmentID,
        position: FramedPosition,
        confidenceGrade: ConfidenceGrade,
        representsLastSeenLocation: Bool,
        resolvedAt: TimeInterval
    ) throws {
        let normalizedLabel = semanticLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else {
            throw ARGuidanceTargetError.emptySemanticLabel
        }
        guard normalizedLabel.count <= Self.maximumSemanticLabelLength else {
            throw ARGuidanceTargetError.semanticLabelTooLong(
                maximum: Self.maximumSemanticLabelLength
            )
        }
        guard resolvedAt.isFinite, resolvedAt >= 0 else {
            throw ARGuidanceTargetError.invalidResolutionTime
        }
        self.objectID = objectID
        self.semanticLabel = normalizedLabel
        self.activeMapID = activeMapID
        self.activeSegmentID = activeSegmentID
        self.position = position
        self.confidenceGrade = confidenceGrade
        self.representsLastSeenLocation = representsLastSeenLocation
        self.resolvedAt = resolvedAt
    }
}

public enum ARGuidanceControllerState: Equatable, Sendable {
    case inactive
    case waitingForTarget
    case waitingForStableTracking
    case incompatibleCoordinateContext
    case guiding
    case arrived
}

/// Monitors lightweight pose snapshots and publishes only a camera-relative
/// presentation for a target proven to belong to the active map/frame/segment.
@MainActor
public final class ARGuidanceController: ObservableObject {
    public typealias PoseStreamProvider = @MainActor @Sendable () -> AsyncStream<ARPoseSnapshot>
    @Published public private(set) var state: ARGuidanceControllerState = .inactive
    @Published public private(set) var target: ARGuidanceTarget?
    @Published public private(set) var latestProjection: ARGuidanceProjection?

    public var renderableWorldPosition: Vec3? {
        guard state == .guiding || state == .arrived else {
            return nil
        }
        return target?.position.value
    }

    private let poseStreamProvider: PoseStreamProvider
    private let refreshStreamOnActivation: Bool
    private let projector: ARGuidanceProjector
    private var monitorTask: Task<Void, Never>?
    private var isActive = false

    public convenience init(
        poses: AsyncStream<ARPoseSnapshot>,
        projector: ARGuidanceProjector = ARGuidanceProjector()
    ) {
        self.init(
            poseStreamProvider: { poses },
            refreshStreamOnActivation: false,
            projector: projector
        )
    }

    public convenience init(
        poseStreamProvider: @escaping PoseStreamProvider,
        projector: ARGuidanceProjector = ARGuidanceProjector()
    ) {
        self.init(
            poseStreamProvider: poseStreamProvider,
            refreshStreamOnActivation: true,
            projector: projector
        )
    }

    private init(
        poseStreamProvider: @escaping PoseStreamProvider,
        refreshStreamOnActivation: Bool,
        projector: ARGuidanceProjector
    ) {
        self.poseStreamProvider = poseStreamProvider
        self.refreshStreamOnActivation = refreshStreamOnActivation
        self.projector = projector
    }

    deinit {
        monitorTask?.cancel()
    }

    public func activate() {
        guard !isActive else {
            return
        }
        isActive = true
        state = target == nil ? .waitingForTarget : .waitingForStableTracking
        guard monitorTask == nil else {
            return
        }
        let stream = poseStreamProvider()
        monitorTask = Task { @MainActor [weak self, stream] in
            for await pose in stream {
                guard !Task.isCancelled, let self else {
                    return
                }
                if self.isActive {
                    self.consume(pose)
                }
            }
        }
    }

    public func deactivate() {
        guard isActive || monitorTask != nil else {
            return
        }
        isActive = false
        if refreshStreamOnActivation {
            monitorTask?.cancel()
            monitorTask = nil
        }
        latestProjection = nil
        state = .inactive
    }

    public func show(_ target: ARGuidanceTarget) {
        self.target = target
        latestProjection = nil
        if isActive {
            state = .waitingForStableTracking
        }
    }

    public func clear() {
        target = nil
        latestProjection = nil
        state = isActive ? .waitingForTarget : .inactive
    }

    private func consume(_ pose: ARPoseSnapshot) {
        guard isActive else {
            return
        }
        guard let target else {
            latestProjection = nil
            state = .waitingForTarget
            return
        }
        guard pose.coordinateFrameID == target.position.coordinateFrameID,
            pose.segmentID == target.activeSegmentID,
            target.activeMapID == nil || pose.mapID == target.activeMapID
        else {
            latestProjection = nil
            state = .incompatibleCoordinateContext
            return
        }
        guard pose.coordinateFrameStatus == .confirmed,
            pose.trackingState == .normal
        else {
            latestProjection = nil
            state = .waitingForStableTracking
            return
        }
        guard
            let projection = projector.project(
                target: target.position.value,
                cameraTransform: pose.cameraTransform
            )
        else {
            latestProjection = nil
            state = .waitingForStableTracking
            return
        }
        latestProjection = projection
        state = projection.hasArrived ? .arrived : .guiding
    }
}
