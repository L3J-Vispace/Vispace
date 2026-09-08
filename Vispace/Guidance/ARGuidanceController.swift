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
    /// The immutable source record used by the query before any frame transform.
    public let sourceMetadata: SpatialObjectMetadata?

    public init(
        objectID: ObjectID,
        semanticLabel: String,
        activeMapID: MapID?,
        activeSegmentID: CaptureSegmentID,
        position: FramedPosition,
        confidenceGrade: ConfidenceGrade,
        representsLastSeenLocation: Bool,
        resolvedAt: TimeInterval,
        sourceMetadata: SpatialObjectMetadata? = nil
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
        self.sourceMetadata = sourceMetadata
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
    public typealias SourceMetadataProvider =
        @Sendable (ObjectID, MapID) async throws -> SpatialObjectMetadata?
    @Published public private(set) var state: ARGuidanceControllerState = .inactive
    @Published public private(set) var target: ARGuidanceTarget?
    @Published public private(set) var latestProjection: ARGuidanceProjection?
    public var onTargetInvalidated: (@MainActor () -> Void)?

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
    private let sourceMetadataProvider: SourceMetadataProvider?
    private let nowProvider: @Sendable () -> TimeInterval
    private let maximumTargetAge: TimeInterval
    private var validationTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var trackedValidations: [UUID: Task<Void, Never>] = [:]
    private var targetGeneration: UInt64 = 0
    private var validatedGeneration: UInt64?
    private var latestPose: ARPoseSnapshot?

    public convenience init(
        poses: AsyncStream<ARPoseSnapshot>,
        projector: ARGuidanceProjector = ARGuidanceProjector(),
        sourceMetadataProvider: SourceMetadataProvider? = nil,
        maximumTargetAge: TimeInterval = 30,
        nowProvider: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.init(
            poseStreamProvider: { poses },
            refreshStreamOnActivation: false,
            projector: projector,
            sourceMetadataProvider: sourceMetadataProvider,
            maximumTargetAge: maximumTargetAge,
            nowProvider: nowProvider
        )
    }

    public convenience init(
        poseStreamProvider: @escaping PoseStreamProvider,
        projector: ARGuidanceProjector = ARGuidanceProjector(),
        sourceMetadataProvider: SourceMetadataProvider? = nil,
        maximumTargetAge: TimeInterval = 30,
        nowProvider: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.init(
            poseStreamProvider: poseStreamProvider,
            refreshStreamOnActivation: true,
            projector: projector,
            sourceMetadataProvider: sourceMetadataProvider,
            maximumTargetAge: maximumTargetAge,
            nowProvider: nowProvider
        )
    }

    private init(
        poseStreamProvider: @escaping PoseStreamProvider,
        refreshStreamOnActivation: Bool,
        projector: ARGuidanceProjector,
        sourceMetadataProvider: SourceMetadataProvider?,
        maximumTargetAge: TimeInterval,
        nowProvider: @escaping @Sendable () -> TimeInterval
    ) {
        self.poseStreamProvider = poseStreamProvider
        self.refreshStreamOnActivation = refreshStreamOnActivation
        self.projector = projector
        self.sourceMetadataProvider = sourceMetadataProvider
        self.maximumTargetAge = maximumTargetAge.isFinite ? max(0, maximumTargetAge) : 0
        self.nowProvider = nowProvider
    }

    deinit {
        monitorTask?.cancel()
        validationTask?.cancel()
        expirationTask?.cancel()
        for task in trackedValidations.values { task.cancel() }
    }

    public func activate() {
        guard !isActive else {
            return
        }
        isActive = true
        startValidation()
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
        validationTask?.cancel()
        validationTask = nil
        expirationTask?.cancel()
        expirationTask = nil
        latestPose = nil
        if refreshStreamOnActivation {
            monitorTask?.cancel()
            monitorTask = nil
        }
        latestProjection = nil
        state = .inactive
    }

    public func deactivateAndWaitForPendingWork() async {
        let pendingValidations = Array(trackedValidations.values)
        deactivate()
        for task in pendingValidations { task.cancel() }
        for task in pendingValidations { await task.value }
    }

    public func show(_ target: ARGuidanceTarget) {
        targetGeneration &+= 1
        validatedGeneration = nil
        self.target = target
        latestProjection = nil
        if isActive {
            state = .waitingForStableTracking
            startValidation()
        }
    }

    public func clear() {
        targetGeneration &+= 1
        validatedGeneration = nil
        validationTask?.cancel()
        validationTask = nil
        expirationTask?.cancel()
        expirationTask = nil
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
        latestPose = pose
        guard targetIsFresh(target) else {
            invalidateTarget()
            return
        }
        guard sourceMetadataProvider == nil || validatedGeneration == targetGeneration else {
            latestProjection = nil
            state = .waitingForStableTracking
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

    private func targetIsFresh(_ target: ARGuidanceTarget) -> Bool {
        let now = nowProvider()
        return now.isFinite && now >= 0 && now - target.resolvedAt <= maximumTargetAge
            && target.resolvedAt - now <= 0.25
            && target.position.observedAt <= now
            && (target.sourceMetadata.map {
                $0.position.observedAt <= now && $0.object.lastSeenAt <= now
                    && $0.object.stateUpdatedAt <= now
            } ?? true)
    }

    private func invalidateTarget() {
        guard target != nil else { return }
        clear()
        onTargetInvalidated?()
    }

    /// Independent of pose callbacks: frozen camera streams cannot keep an old
    /// target alive, and durable record changes revoke the original handoff.
    private func startValidation() {
        validationTask?.cancel()
        guard isActive, target != nil else { return }
        let generation = targetGeneration
        expirationTask?.cancel()
        let remaining = max(0, maximumTargetAge - (nowProvider() - (target?.resolvedAt ?? 0)))
        expirationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(remaining.isFinite ? remaining : 0)) }
            catch { return }
            guard let self, self.isActive, self.targetGeneration == generation else { return }
            self.invalidateTarget()
        }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.trackedValidations[taskID] = nil }
            while !Task.isCancelled {
                guard let self, self.isActive, self.targetGeneration == generation,
                    let target = self.target else { return }
                guard self.targetIsFresh(target) else { self.invalidateTarget(); return }
                if let provider = self.sourceMetadataProvider {
                    guard let source = target.sourceMetadata else { self.invalidateTarget(); return }
                    do {
                        let current = try await provider(target.objectID, source.mapID)
                        guard !Task.isCancelled, self.targetGeneration == generation else { return }
                        let now = self.nowProvider()
                        guard let current,
                            now.isFinite, now >= 0,
                            current.position.observedAt <= now,
                            current.object.lastSeenAt <= now,
                            current.object.stateUpdatedAt <= now,
                            current.mapID == source.mapID,
                            current.object.id == source.object.id,
                            current.object.semanticLabel == source.object.semanticLabel,
                            current.object.presence == source.object.presence,
                            current.object.presence != .removed || target.representsLastSeenLocation,
                            current.object.certainty == source.object.certainty,
                            current.object.confidence == source.object.confidence,
                            current.position.coordinateFrameID == source.position.coordinateFrameID,
                            current.position.value == source.position.value,
                            current.position.trackingQuality == source.position.trackingQuality,
                            current.position.uncertainty == source.position.uncertainty,
                            self.targetIsFresh(target)
                        else { self.invalidateTarget(); return }
                    } catch {
                        guard !Task.isCancelled, self.targetGeneration == generation else { return }
                        self.invalidateTarget()
                        return
                    }
                }
                self.validatedGeneration = generation
                if let pose = self.latestPose { self.consume(pose) }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        validationTask = task
        trackedValidations[taskID] = task
    }
}
