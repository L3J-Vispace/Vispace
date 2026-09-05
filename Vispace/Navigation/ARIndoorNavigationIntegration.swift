import Combine
import Foundation
import VispaceCore

public enum ARIndoorNavigationEvidenceIssue: String, Equatable, Sendable {
    case captureNotConfirmed
    case surfaceSnapshotIncomplete
    case currentMapUnavailable
    case coordinateContextMismatch
    case surfaceRevisionMismatch
    case surfaceTimestampMismatch
    case floorCoverageUnavailable
    case freeSpaceCoverageUnavailable
    case coverageAttestationUnavailable
    case surfaceObservationStale
    case dynamicOccupancyUnavailable
}

public enum ARIndoorNavigationEvidenceAdaptation: Sendable {
    case ready(IndoorNavigationEvidence)
    case insufficientEvidence(ARIndoorNavigationEvidenceIssue)
}

/// Validates separately produced navigation evidence against the exact surface
/// snapshot that triggered routing. Raw ARKit planes and meshes do not prove
/// free-space volume, open-door state, or that every obstacle was observed, so
/// this adapter deliberately returns insufficient evidence when no attested
/// evidence is supplied.
public struct ARSurfaceIndoorNavigationEvidenceAdapter: Sendable {
    public let timestampTolerance: TimeInterval

    public init(timestampTolerance: TimeInterval = 0.001) {
        self.timestampTolerance = max(
            0,
            timestampTolerance.isFinite ? timestampTolerance : 0
        )
    }

    public func adapt(
        _ snapshot: ARSurfaceStateSnapshot,
        currentIdentity: ARCaptureIdentity,
        verifiedEvidence: IndoorNavigationEvidence? = nil
    ) -> ARIndoorNavigationEvidenceAdaptation {
        guard currentIdentity.status == .confirmed,
            snapshot.coordinateFrameStatus == .confirmed
        else {
            return .insufficientEvidence(.captureNotConfirmed)
        }
        guard snapshot.isComplete else {
            return .insufficientEvidence(.surfaceSnapshotIncomplete)
        }
        guard let currentMapID = currentIdentity.mapID,
            let snapshotMapID = snapshot.mapID
        else {
            return .insufficientEvidence(.currentMapUnavailable)
        }
        guard snapshot.coordinateFrameID == currentIdentity.coordinateFrameID,
            snapshot.segmentID == currentIdentity.segmentID,
            snapshotMapID == currentMapID
        else {
            return .insufficientEvidence(.coordinateContextMismatch)
        }
        guard let verifiedEvidence else {
            return .insufficientEvidence(.freeSpaceCoverageUnavailable)
        }
        guard verifiedEvidence.coordinateFrameID == snapshot.coordinateFrameID,
            verifiedEvidence.mapID == snapshotMapID
        else {
            return .insufficientEvidence(.coordinateContextMismatch)
        }
        guard verifiedEvidence.revision == snapshot.revision else {
            return .insufficientEvidence(.surfaceRevisionMismatch)
        }
        guard abs(verifiedEvidence.observedAt - snapshot.timestamp) <= timestampTolerance else {
            return .insufficientEvidence(.surfaceTimestampMismatch)
        }
        guard !verifiedEvidence.floors.isEmpty else {
            return .insufficientEvidence(.floorCoverageUnavailable)
        }
        guard !verifiedEvidence.mesh.isEmpty else {
            return .insufficientEvidence(.freeSpaceCoverageUnavailable)
        }
        let completeness = verifiedEvidence.completeness
        guard completeness.wallsAroundObservedCellsMapped,
            completeness.doorwayStatesMapped,
            completeness.obstaclesAroundObservedCellsMapped
        else {
            return .insufficientEvidence(.coverageAttestationUnavailable)
        }
        return .ready(verifiedEvidence)
    }
}

public enum ARIndoorNavigationPoseIssue: String, Equatable, Sendable {
    case captureNotConfirmed
    case trackingNotNormal
    case coordinateContextMismatch
    case positionGroundingUnavailable
    case positionTimestampMismatch
    case positionUncertaintyUnavailable
    case positionDoesNotMatchCamera
}

public enum ARIndoorNavigationPoseAdaptation: Sendable {
    case ready(FramedPosition)
    case insufficientEvidence(ARIndoorNavigationPoseIssue)
}

/// Binds a floor-projected, uncertainty-bearing start position to a live pose.
/// ARPoseSnapshot itself has no floor raycast or metric uncertainty payload, so
/// callers must provide that verified position instead of this type inventing it.
public struct ARPoseIndoorNavigationAdapter: Sendable {
    public let horizontalTolerance: Double
    public let timestampTolerance: TimeInterval

    public init(
        horizontalTolerance: Double = 0.05,
        timestampTolerance: TimeInterval = 0.001
    ) {
        self.horizontalTolerance = max(
            0,
            horizontalTolerance.isFinite ? horizontalTolerance : 0
        )
        self.timestampTolerance = max(
            0,
            timestampTolerance.isFinite ? timestampTolerance : 0
        )
    }

    public func adapt(
        _ pose: ARPoseSnapshot,
        currentIdentity: ARCaptureIdentity,
        verifiedFloorPosition: FramedPosition? = nil
    ) -> ARIndoorNavigationPoseAdaptation {
        guard currentIdentity.status == .confirmed,
            pose.coordinateFrameStatus == .confirmed
        else {
            return .insufficientEvidence(.captureNotConfirmed)
        }
        guard pose.trackingState == .normal else {
            return .insufficientEvidence(.trackingNotNormal)
        }
        guard pose.coordinateFrameID == currentIdentity.coordinateFrameID,
            pose.segmentID == currentIdentity.segmentID,
            pose.mapID == currentIdentity.mapID
        else {
            return .insufficientEvidence(.coordinateContextMismatch)
        }
        guard let verifiedFloorPosition else {
            return .insufficientEvidence(.positionGroundingUnavailable)
        }
        guard verifiedFloorPosition.coordinateFrameID == pose.coordinateFrameID,
            verifiedFloorPosition.trackingQuality == .normal
        else {
            return .insufficientEvidence(.coordinateContextMismatch)
        }
        guard abs(verifiedFloorPosition.observedAt - pose.timestamp) <= timestampTolerance else {
            return .insufficientEvidence(.positionTimestampMismatch)
        }
        switch verifiedFloorPosition.uncertainty {
        case .mediumConfidenceDepth, .highConfidenceDepth, .raycastEstimate:
            break
        case .unavailable, .lowConfidenceDepth, .unknown:
            return .insufficientEvidence(.positionUncertaintyUnavailable)
        }
        let camera = pose.cameraTransform.column3
        let values = [camera.x, camera.z]
        guard values.allSatisfy(\.isFinite),
            abs(verifiedFloorPosition.value.x - Double(camera.x)) <= horizontalTolerance,
            abs(verifiedFloorPosition.value.z - Double(camera.z)) <= horizontalTolerance
        else {
            return .insufficientEvidence(.positionDoesNotMatchCamera)
        }
        return .ready(verifiedFloorPosition)
    }
}

public enum ARIndoorNavigationTargetIssue: String, Equatable, Sendable {
    case captureNotConfirmed
    case currentMapUnavailable
    case sourceMetadataUnavailable
    case searchTargetMismatch
    case targetNotGrounded
    case targetStale
    case unsupportedSearchIntent
    case confidenceTooLow
    case coordinateContextMismatch
    case derivedMetadataInvalid
}

public enum ARIndoorNavigationTargetResolution: Sendable {
    case ready(SpatialObjectMetadata)
    case invalid(ARIndoorNavigationTargetIssue)
}

/// Converts only a current-frame metadata record or the query controller's
/// grounded handoff plus its original persisted record into an engine target.
public struct ARIndoorNavigationTargetAdapter: Sendable {
    public let maximumGroundedTargetAge: TimeInterval
    public let maximumFutureTimestampSkew: TimeInterval
    public let minimumConfidence: ConfidenceScore

    public init(
        maximumGroundedTargetAge: TimeInterval = 30,
        maximumFutureTimestampSkew: TimeInterval = 0.25,
        minimumConfidence: ConfidenceScore = ConfidenceScore(clamping: 0.50)
    ) {
        self.maximumGroundedTargetAge = max(
            0,
            maximumGroundedTargetAge.isFinite ? maximumGroundedTargetAge : 0
        )
        self.maximumFutureTimestampSkew = max(
            0,
            maximumFutureTimestampSkew.isFinite ? maximumFutureTimestampSkew : 0
        )
        self.minimumConfidence = minimumConfidence
    }

    public func resolve(
        metadata: SpatialObjectMetadata,
        currentIdentity: ARCaptureIdentity
    ) -> ARIndoorNavigationTargetResolution {
        guard currentIdentity.status == .confirmed else {
            return .invalid(.captureNotConfirmed)
        }
        guard let mapID = currentIdentity.mapID else {
            return .invalid(.currentMapUnavailable)
        }
        guard metadata.mapID == mapID,
            metadata.position.coordinateFrameID == currentIdentity.coordinateFrameID
        else {
            return .invalid(.coordinateContextMismatch)
        }
        return .ready(metadata)
    }

    public func resolve(
        groundedTarget: GroundedSpatialObjectQueryTarget,
        sourceMetadata: SpatialObjectMetadata,
        currentIdentity: ARCaptureIdentity,
        now: TimeInterval
    ) -> ARIndoorNavigationTargetResolution {
        guard currentIdentity.status == .confirmed else {
            return .invalid(.captureNotConfirmed)
        }
        guard let currentMapID = currentIdentity.mapID else {
            return .invalid(.currentMapUnavailable)
        }
        guard now.isFinite, now >= 0,
            groundedTarget.resolvedAt.isFinite,
            groundedTarget.resolvedAt >= 0,
            now - groundedTarget.resolvedAt <= maximumGroundedTargetAge,
            groundedTarget.resolvedAt - now <= maximumFutureTimestampSkew
        else {
            return .invalid(.targetStale)
        }
        guard
            groundedTarget.intent == .navigate
                || groundedTarget.intent == .searchObject
                || groundedTarget.intent == .lastSeen
        else {
            return .invalid(.unsupportedSearchIntent)
        }
        guard groundedTarget.effectiveConfidence >= minimumConfidence,
            groundedTarget.confidenceGrade >= .medium
        else {
            return .invalid(.confidenceTooLow)
        }
        guard groundedTarget.objectID == sourceMetadata.object.id,
            groundedTarget.sourceMapID == sourceMetadata.mapID,
            groundedTarget.sourcePosition == sourceMetadata.position,
            groundedTarget.semanticLabel == sourceMetadata.object.semanticLabel
        else {
            return .invalid(.searchTargetMismatch)
        }
        guard groundedTarget.currentMapID == currentMapID,
            groundedTarget.currentSegmentID == currentIdentity.segmentID,
            groundedTarget.currentCoordinateFrameID == currentIdentity.coordinateFrameID,
            groundedTarget.currentFramePosition.observedAt
                == groundedTarget.sourcePosition.observedAt
        else {
            return .invalid(.coordinateContextMismatch)
        }
        if groundedTarget.sourceCoordinateFrameID
            != groundedTarget.currentCoordinateFrameID
        {
            guard groundedTarget.sourceMapID != currentMapID,
                let alignmentConfidence = groundedTarget.alignmentConfidence,
                alignmentConfidence >= minimumConfidence
            else {
                return .invalid(.targetNotGrounded)
            }
        }

        let original = sourceMetadata.object
        let effective = groundedTarget.effectiveConfidence
        let confidence = ConfidenceVector(
            semantic: min(original.confidence.semantic, effective),
            geometry: min(original.confidence.geometry, effective),
            tracking: min(original.confidence.tracking, effective),
            place: min(original.confidence.place, effective),
            identity: min(original.confidence.identity, effective),
            objectState: min(original.confidence.objectState, effective),
            relation: min(original.confidence.relation, effective)
        )
        guard
            let transformedObject = try? SpatialObject(
                id: original.id,
                semanticLabel: original.semanticLabel,
                nodeID: nil,
                position: groundedTarget.currentFramePosition.value,
                bounds: nil,
                certainty: original.certainty,
                presence: original.presence,
                confidence: confidence,
                firstSeenAt: original.firstSeenAt,
                lastSeenAt: original.lastSeenAt,
                stateUpdatedAt: original.stateUpdatedAt,
                displayName: original.displayName
            ),
            let transformedMetadata = try? SpatialObjectMetadata(
                mapID: currentMapID,
                object: transformedObject,
                position: groundedTarget.currentFramePosition
            )
        else {
            return .invalid(.derivedMetadataInvalid)
        }
        return .ready(transformedMetadata)
    }
}

public struct ARIndoorNavigationPathSegment: Equatable, Hashable, Sendable {
    public let start: Vec3
    public let end: Vec3

    public init(start: Vec3, end: Vec3) {
        self.start = start
        self.end = end
    }
}

public enum ARIndoorNavigationOutputError: Error, Equatable, Sendable {
    case incompatibleCoordinateContext
    case surfaceRevisionMismatch
    case emptyPath
}

/// Renderer seam. The renderer receives only adjacent route segments; there is
/// intentionally no camera-to-destination shortcut that could cross a wall.
public struct ARIndoorNavigationPathOutput: Equatable, Hashable, Sendable {
    public let destinationObjectID: ObjectID
    public let semanticLabel: String
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let segmentID: CaptureSegmentID
    public let surfaceRevision: UInt64
    public let waypoints: [Vec3]
    public let segments: [ARIndoorNavigationPathSegment]
    public let totalDistance: Double
    public let confidenceScore: ConfidenceScore
    public let confidence: ConfidenceGrade

    public init(
        path: IndoorNavigationPath,
        semanticLabel: String,
        identity: ARCaptureIdentity,
        surfaceRevision: UInt64
    ) throws {
        guard identity.mapID == path.mapID,
            identity.coordinateFrameID == path.coordinateFrameID,
            identity.status == .confirmed
        else {
            throw ARIndoorNavigationOutputError.incompatibleCoordinateContext
        }
        guard path.evidenceRevision == surfaceRevision else {
            throw ARIndoorNavigationOutputError.surfaceRevisionMismatch
        }
        let waypoints = path.waypoints.map(\.position)
        guard !waypoints.isEmpty else {
            throw ARIndoorNavigationOutputError.emptyPath
        }
        self.destinationObjectID = path.destinationObjectID
        self.semanticLabel = String(semanticLabel.prefix(80))
        self.mapID = path.mapID
        self.coordinateFrameID = path.coordinateFrameID
        self.segmentID = identity.segmentID
        self.surfaceRevision = surfaceRevision
        self.waypoints = waypoints
        segments = zip(waypoints, waypoints.dropFirst()).map {
            ARIndoorNavigationPathSegment(start: $0.0, end: $0.1)
        }
        totalDistance = path.totalDistance
        confidenceScore = path.confidenceScore
        confidence = path.confidence
    }
}

public struct ARIndoorNavigationPresentation: Equatable, Sendable {
    public let destinationObjectID: ObjectID
    public let semanticLabel: String
    public let result: IndoorNavigationResult?
    public let evidenceIssue: ARIndoorNavigationEvidenceIssue?
    public let poseIssue: ARIndoorNavigationPoseIssue?
    public let targetIssue: ARIndoorNavigationTargetIssue?
    public let pathOutput: ARIndoorNavigationPathOutput?
    public let message: String

    public var canRenderPath: Bool {
        result?.status == .success && pathOutput != nil
    }
}

public enum ARIndoorNavigationControllerState: String, Equatable, Sendable {
    case inactive
    case waitingForSurface
    case waitingForPose
    case ready
    case routing
    case navigating
    case arrived
    case noPath
    case invalidated
}

public struct ARIndoorNavigationControllerMetrics: Equatable, Sendable {
    public var requestsStarted: UInt64 = 0
    public var requestsCancelled: UInt64 = 0
    public var staleResultsRejected: UInt64 = 0
    public var outOfOrderSurfacesRejected: UInt64 = 0
    public var outOfOrderPosesRejected: UInt64 = 0
    public var routeInvalidations: UInt64 = 0
    public var routesPublished: UInt64 = 0
    public var noPathResultsPublished: UInt64 = 0

    public init() {}
}

/// Phase 6 app coordinator. Surface revisions and capture transitions revoke a
/// route before any asynchronous replacement can be published.
@MainActor
public final class IndoorNavigationController: ObservableObject {
    public typealias SurfaceStreamProvider =
        @MainActor @Sendable () -> AsyncStream<ARSurfaceStateSnapshot>
    public typealias PoseStreamProvider =
        @MainActor @Sendable () -> AsyncStream<ARPoseSnapshot>
    public typealias CurrentIdentityProvider = @MainActor @Sendable () -> ARCaptureIdentity
    /// Current AR session timestamp, independent of the Unix-epoch query clock.
    /// Return nil when no current capture frame can establish evaluation time.
    public typealias EvaluationTimestampProvider = @MainActor @Sendable () -> TimeInterval?
    public typealias EvidenceProvider =
        @Sendable (
            _ surface: ARSurfaceStateSnapshot,
            _ identity: ARCaptureIdentity
        ) async throws -> ARIndoorNavigationEvidenceAdaptation
    public typealias StartPositionProvider =
        @Sendable (
            _ pose: ARPoseSnapshot,
            _ identity: ARCaptureIdentity
        ) async throws -> ARIndoorNavigationPoseAdaptation
    public typealias SourceMetadataProvider =
        @Sendable (
            _ objectID: ObjectID,
            _ sourceMapID: MapID
        ) async throws -> SpatialObjectMetadata?

    @Published public private(set) var state: ARIndoorNavigationControllerState = .inactive
    @Published public private(set) var latestPresentation: ARIndoorNavigationPresentation?
    @Published public private(set) var renderablePath: ARIndoorNavigationPathOutput?
    @Published public private(set) var metrics = ARIndoorNavigationControllerMetrics()

    var isRoutingForTesting: Bool {
        routeTask != nil || routeDebounceTask != nil
    }

    private let surfaceStreamProvider: SurfaceStreamProvider
    private let poseStreamProvider: PoseStreamProvider
    private let refreshStreamsOnActivation: Bool
    private let currentIdentityProvider: CurrentIdentityProvider
    private let evidenceProvider: EvidenceProvider
    private let startPositionProvider: StartPositionProvider
    private let sourceMetadataProvider: SourceMetadataProvider?
    private let engine: IndoorARNavigationEngine
    private let targetAdapter: ARIndoorNavigationTargetAdapter
    private let surfaceStabilityDelay: Duration
    private let evaluationTimestampProvider: EvaluationTimestampProvider?
    private let nowProvider: @Sendable () -> TimeInterval

    private var surfaceMonitorTask: Task<Void, Never>?
    private var poseMonitorTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var routeDebounceTask: Task<Void, Never>?
    private var trackedRouteTasks: [UUID: Task<Void, Never>] = [:]
    private var isActive = false
    private var latestSurface: ARSurfaceStateSnapshot?
    private var latestPose: ARPoseSnapshot?
    private var latestPoseReceivedUptime: TimeInterval?
    private var evaluationClockAnchor: (timestamp: TimeInterval, uptime: TimeInterval)?
    private var monitoredIdentity: ARCaptureIdentity?
    private var latestPoseSessionToken: ARSessionFrameToken?
    private var pendingDestination: PendingNavigationDestination?
    private var requestID: UInt64 = 0
    private var operationID: UInt64 = 0
    private var contextGeneration: UInt64 = 0
    private var routeOriginPose: ARPoseSnapshot?
    private var routeLeaseTask: Task<Void, Never>?
    private var hasArrived = false
    private let movementReevaluationDistance = 0.25
    private let arrivalDistance = 0.35

    public convenience init(
        surfaces: AsyncStream<ARSurfaceStateSnapshot>,
        poses: AsyncStream<ARPoseSnapshot>,
        currentIdentityProvider: @escaping CurrentIdentityProvider,
        evidenceProvider: @escaping EvidenceProvider = { snapshot, identity in
            ARSurfaceIndoorNavigationEvidenceAdapter().adapt(
                snapshot,
                currentIdentity: identity
            )
        },
        startPositionProvider: @escaping StartPositionProvider = { pose, identity in
            ARPoseIndoorNavigationAdapter().adapt(
                pose,
                currentIdentity: identity
            )
        },
        sourceMetadataProvider: SourceMetadataProvider? = nil,
        engine: IndoorARNavigationEngine = IndoorARNavigationEngine(),
        targetAdapter: ARIndoorNavigationTargetAdapter = ARIndoorNavigationTargetAdapter(),
        surfaceStabilityDelay: Duration = .zero,
        evaluationTimestampProvider: EvaluationTimestampProvider? = nil,
        nowProvider: @escaping @Sendable () -> TimeInterval = {
            Date().timeIntervalSince1970
        }
    ) {
        self.init(
            surfaceStreamProvider: { surfaces },
            poseStreamProvider: { poses },
            refreshStreamsOnActivation: false,
            currentIdentityProvider: currentIdentityProvider,
            evidenceProvider: evidenceProvider,
            startPositionProvider: startPositionProvider,
            sourceMetadataProvider: sourceMetadataProvider,
            engine: engine,
            targetAdapter: targetAdapter,
            surfaceStabilityDelay: surfaceStabilityDelay,
            evaluationTimestampProvider: evaluationTimestampProvider,
            nowProvider: nowProvider
        )
    }

    public convenience init(
        surfaceStreamProvider: @escaping SurfaceStreamProvider,
        poseStreamProvider: @escaping PoseStreamProvider,
        currentIdentityProvider: @escaping CurrentIdentityProvider,
        evidenceProvider: @escaping EvidenceProvider = { snapshot, identity in
            ARSurfaceIndoorNavigationEvidenceAdapter().adapt(
                snapshot,
                currentIdentity: identity
            )
        },
        startPositionProvider: @escaping StartPositionProvider = { pose, identity in
            ARPoseIndoorNavigationAdapter().adapt(
                pose,
                currentIdentity: identity
            )
        },
        sourceMetadataProvider: SourceMetadataProvider? = nil,
        engine: IndoorARNavigationEngine = IndoorARNavigationEngine(),
        targetAdapter: ARIndoorNavigationTargetAdapter = ARIndoorNavigationTargetAdapter(),
        surfaceStabilityDelay: Duration = .zero,
        evaluationTimestampProvider: EvaluationTimestampProvider? = nil,
        nowProvider: @escaping @Sendable () -> TimeInterval = {
            Date().timeIntervalSince1970
        }
    ) {
        self.init(
            surfaceStreamProvider: surfaceStreamProvider,
            poseStreamProvider: poseStreamProvider,
            refreshStreamsOnActivation: true,
            currentIdentityProvider: currentIdentityProvider,
            evidenceProvider: evidenceProvider,
            startPositionProvider: startPositionProvider,
            sourceMetadataProvider: sourceMetadataProvider,
            engine: engine,
            targetAdapter: targetAdapter,
            surfaceStabilityDelay: surfaceStabilityDelay,
            evaluationTimestampProvider: evaluationTimestampProvider,
            nowProvider: nowProvider
        )
    }

    private init(
        surfaceStreamProvider: @escaping SurfaceStreamProvider,
        poseStreamProvider: @escaping PoseStreamProvider,
        refreshStreamsOnActivation: Bool,
        currentIdentityProvider: @escaping CurrentIdentityProvider,
        evidenceProvider: @escaping EvidenceProvider,
        startPositionProvider: @escaping StartPositionProvider,
        sourceMetadataProvider: SourceMetadataProvider?,
        engine: IndoorARNavigationEngine,
        targetAdapter: ARIndoorNavigationTargetAdapter,
        surfaceStabilityDelay: Duration,
        evaluationTimestampProvider: EvaluationTimestampProvider?,
        nowProvider: @escaping @Sendable () -> TimeInterval
    ) {
        self.surfaceStreamProvider = surfaceStreamProvider
        self.poseStreamProvider = poseStreamProvider
        self.refreshStreamsOnActivation = refreshStreamsOnActivation
        self.currentIdentityProvider = currentIdentityProvider
        self.evidenceProvider = evidenceProvider
        self.startPositionProvider = startPositionProvider
        self.sourceMetadataProvider = sourceMetadataProvider
        self.engine = engine
        self.targetAdapter = targetAdapter
        self.surfaceStabilityDelay = max(.zero, surfaceStabilityDelay)
        self.evaluationTimestampProvider = evaluationTimestampProvider
        self.nowProvider = nowProvider
    }

    deinit {
        surfaceMonitorTask?.cancel()
        poseMonitorTask?.cancel()
        routeTask?.cancel()
        routeDebounceTask?.cancel()
        routeLeaseTask?.cancel()
        for task in trackedRouteTasks.values {
            task.cancel()
        }
    }

    public func activate() {
        isActive = true
        startMonitoringIfNeeded()
        synchronizeCaptureIdentity(currentIdentityProvider())
        updateReadyState()
        scheduleRouteIfPossible()
    }

    public func deactivate() {
        isActive = false
        if refreshStreamsOnActivation {
            surfaceMonitorTask?.cancel()
            surfaceMonitorTask = nil
            poseMonitorTask?.cancel()
            poseMonitorTask = nil
        }
        cancelRoute(countCancellation: true)
        revokePublishedRoute(countInvalidation: false)
        state = .inactive
    }

    /// Cancels stream consumers and route work, then waits for any source
    /// metadata read or detached route calculation to return. This forms a
    /// deletion barrier for the shared spatial store.
    public func deactivateAndWaitForPendingWork() async {
        let pendingSurfaceMonitor = surfaceMonitorTask
        let pendingPoseMonitor = poseMonitorTask
        let pendingRouteWork = Array(trackedRouteTasks.values)
        deactivate()
        pendingSurfaceMonitor?.cancel()
        pendingPoseMonitor?.cancel()
        surfaceMonitorTask = nil
        poseMonitorTask = nil
        for task in pendingRouteWork {
            task.cancel()
        }
        for task in [pendingSurfaceMonitor, pendingPoseMonitor].compactMap({ $0 }) {
            await task.value
        }
        for task in pendingRouteWork {
            await task.value
        }
    }

    public func navigate(to metadata: SpatialObjectMetadata) {
        beginRequest(.metadata(metadata))
    }

    public func navigate(to groundedTarget: GroundedSpatialObjectQueryTarget) {
        beginRequest(.grounded(groundedTarget, sourceMetadata: nil))
    }

    public func navigate(
        to groundedTarget: GroundedSpatialObjectQueryTarget,
        sourceMetadata: SpatialObjectMetadata
    ) {
        beginRequest(.grounded(groundedTarget, sourceMetadata: sourceMetadata))
    }

    public func clearRoute() {
        requestID &+= 1
        pendingDestination = nil
        hasArrived = false
        cancelRoute(countCancellation: true)
        revokePublishedRoute(countInvalidation: false)
        updateReadyState()
    }

    private func beginRequest(_ destination: PendingNavigationDestination) {
        requestID &+= 1
        pendingDestination = destination
        hasArrived = false
        cancelRoute(countCancellation: true)
        revokePublishedRoute(countInvalidation: false)
        guard isActive else {
            state = .inactive
            return
        }
        scheduleRouteIfPossible()
    }

    private func startMonitoringIfNeeded() {
        if surfaceMonitorTask == nil {
            let stream = surfaceStreamProvider()
            surfaceMonitorTask = Task { @MainActor [weak self, stream] in
                for await snapshot in stream {
                    guard !Task.isCancelled, let self else { return }
                    self.consume(snapshot)
                }
            }
        }
        if poseMonitorTask == nil {
            let stream = poseStreamProvider()
            poseMonitorTask = Task { @MainActor [weak self, stream] in
                for await pose in stream {
                    guard !Task.isCancelled, let self else { return }
                    self.consume(pose)
                }
            }
        }
    }

    private func consume(_ snapshot: ARSurfaceStateSnapshot) {
        let currentIdentity = currentIdentityProvider()
        synchronizeCaptureIdentity(currentIdentity)
        guard snapshotMatches(snapshot, identity: currentIdentity) else {
            metrics.outOfOrderSurfacesRejected &+= 1
            return
        }

        if !snapshot.isCurrentSessionData {
            contextGeneration &+= 1
            cancelRoute(countCancellation: true)
            latestSurface = snapshot
            revokePublishedRoute(countInvalidation: true)
            updateReadyState()
            return
        }
        if let previous = latestSurface,
            previous.isCurrentSessionData,
            sameSurfaceIdentity(previous, snapshot),
            snapshot.revision <= previous.revision
        {
            metrics.outOfOrderSurfacesRejected &+= 1
            return
        }

        let changedRevision =
            latestSurface.map {
                !sameSurfaceIdentity($0, snapshot) || $0.revision != snapshot.revision
            } ?? false
        latestSurface = snapshot
        if changedRevision {
            contextGeneration &+= 1
            cancelRoute(countCancellation: true)
            revokePublishedRoute(countInvalidation: true)
        }
        updateReadyState()
        if latestPresentation == nil {
            scheduleRouteIfPossible()
        }
    }

    private func consume(_ pose: ARPoseSnapshot) {
        let currentIdentity = currentIdentityProvider()
        synchronizeCaptureIdentity(currentIdentity)
        guard poseMatches(pose, identity: currentIdentity) else {
            metrics.outOfOrderPosesRejected &+= 1
            return
        }
        if let latestPose {
            if latestPose.sessionToken == pose.sessionToken,
                pose.timestamp <= latestPose.timestamp
            {
                metrics.outOfOrderPosesRejected &+= 1
                return
            }
            if latestPose.sessionToken != pose.sessionToken {
                latestPoseSessionToken = pose.sessionToken
                contextGeneration &+= 1
                cancelRoute(countCancellation: true)
                revokePublishedRoute(countInvalidation: true)
            }
        } else {
            latestPoseSessionToken = pose.sessionToken
        }
        latestPose = pose
        latestPoseReceivedUptime = ProcessInfo.processInfo.systemUptime
        guard poseIsUsableForNavigation(pose) else {
            contextGeneration &+= 1
            cancelRoute(countCancellation: true)
            revokePublishedRoute(countInvalidation: true)
            updateReadyState()
            return
        }
        if let path = renderablePath, let destination = path.waypoints.last,
            hypot(Double(pose.cameraTransform.column3.x) - destination.x,
                  Double(pose.cameraTransform.column3.z) - destination.z) <= arrivalDistance
        {
            cancelRoute(countCancellation: true)
            revokePublishedRoute(countInvalidation: false)
            hasArrived = true
            if let pendingDestination {
                latestPresentation = ARIndoorNavigationPresentation(
                    destinationObjectID: pendingDestination.objectID,
                    semanticLabel: pendingDestination.semanticLabel,
                    result: nil, evidenceIssue: nil, poseIssue: nil, targetIssue: nil,
                    pathOutput: nil, message: "목적지의 기록된 위치에 도착했어요. 주변에서 물체를 확인해 주세요."
                )
            }
            state = .arrived
            return
        }
        if let origin = routeOriginPose,
            horizontalDistance(origin, pose) >= movementReevaluationDistance
                || (renderablePath == nil && latestPresentation != nil
                    && pose.timestamp - origin.timestamp >= 1)
        {
            contextGeneration &+= 1
            cancelRoute(countCancellation: true)
            revokePublishedRoute(countInvalidation: true)
        }
        updateReadyState()
        if latestPresentation == nil {
            scheduleRouteIfPossible()
        }
    }

    private func synchronizeCaptureIdentity(_ identity: ARCaptureIdentity) {
        guard monitoredIdentity != identity else { return }
        let hadIdentity = monitoredIdentity != nil
        monitoredIdentity = identity
        latestSurface = nil
        latestPose = nil
        latestPoseReceivedUptime = nil
        evaluationClockAnchor = nil
        latestPoseSessionToken = nil
        routeOriginPose = nil
        hasArrived = false
        contextGeneration &+= 1
        cancelRoute(countCancellation: true)
        revokePublishedRoute(countInvalidation: hadIdentity)
    }

    private func updateReadyState() {
        guard isActive else {
            state = .inactive
            return
        }
        if hasArrived {
            state = .arrived
            return
        }
        if routeTask != nil || routeDebounceTask != nil {
            state = .routing
            return
        }
        if renderablePath != nil {
            state = .navigating
            return
        }
        if latestPresentation != nil {
            state = .noPath
            return
        }
        guard latestSurface != nil else {
            state = .waitingForSurface
            return
        }
        guard let latestPose, poseIsUsableForNavigation(latestPose) else {
            state = .waitingForPose
            return
        }
        state = pendingDestination == nil ? .ready : .invalidated
    }

    private func scheduleRouteIfPossible() {
        guard isActive, !hasArrived, routeTask == nil, routeDebounceTask == nil,
            pendingDestination != nil,
            let surface = latestSurface,
            let pose = latestPose
        else {
            updateReadyState()
            return
        }
        let identity = currentIdentityProvider()
        guard snapshotMatches(surface, identity: identity),
            poseMatches(pose, identity: identity),
            poseIsUsableForNavigation(pose)
        else {
            updateReadyState()
            return
        }

        guard surfaceStabilityDelay > .zero else {
            startRouteIfPossible()
            return
        }

        let capturedRequestID = requestID
        let capturedGeneration = contextGeneration
        let delay = surfaceStabilityDelay
        state = .routing
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.trackedRouteDidFinish(taskID) }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            self.routeDebounceTask = nil
            guard self.isActive,
                self.requestID == capturedRequestID,
                self.contextGeneration == capturedGeneration
            else {
                self.updateReadyState()
                return
            }
            self.startRouteIfPossible()
        }
        routeDebounceTask = task
        trackedRouteTasks[taskID] = task
    }

    private func startRouteIfPossible() {
        guard isActive, routeTask == nil,
            let destination = pendingDestination,
            let surface = latestSurface,
            let pose = latestPose
        else {
            updateReadyState()
            return
        }
        let identity = currentIdentityProvider()
        guard snapshotMatches(surface, identity: identity),
            poseMatches(pose, identity: identity),
            poseIsUsableForNavigation(pose)
        else {
            updateReadyState()
            return
        }

        let capturedRequestID = requestID
        operationID &+= 1
        routeOriginPose = pose
        let capturedOperationID = operationID
        let capturedGeneration = contextGeneration
        let evidenceProvider = self.evidenceProvider
        let startPositionProvider = self.startPositionProvider
        let engine = self.engine
        metrics.requestsStarted &+= 1
        state = .routing

        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.trackedRouteDidFinish(taskID) }
            do {
                guard let self else { return }
                let resolvedDestination = try await self.resolveDestination(
                    destination,
                    identity: identity
                )
                try Task.checkCancellation()
                guard
                    self.isCurrent(
                        requestID: capturedRequestID,
                        operationID: capturedOperationID,
                        generation: capturedGeneration,
                        surface: surface,
                        identity: identity
                    )
                else {
                    self.rejectStale(
                        requestID: capturedRequestID,
                        operationID: capturedOperationID
                    )
                    return
                }
                guard case .ready(let metadata) = resolvedDestination else {
                    if case .invalid(let issue) = resolvedDestination {
                        self.publishTargetIssue(issue, destination: destination)
                    }
                    self.finish(
                        requestID: capturedRequestID,
                        operationID: capturedOperationID
                    )
                    return
                }

                async let evidenceAdaptation = evidenceProvider(surface, identity)
                async let poseAdaptation = startPositionProvider(pose, identity)
                let (evidenceResult, startResult) = try await (
                    evidenceAdaptation,
                    poseAdaptation
                )
                try Task.checkCancellation()
                guard
                    self.isCurrent(
                        requestID: capturedRequestID,
                        operationID: capturedOperationID,
                        generation: capturedGeneration,
                        surface: surface,
                        identity: identity
                    )
                else {
                    self.rejectStale(
                        requestID: capturedRequestID,
                        operationID: capturedOperationID
                    )
                    return
                }
                guard case .ready(let evidence) = evidenceResult else {
                    if case .insufficientEvidence(let issue) = evidenceResult {
                        self.publishEvidenceIssue(issue, destination: destination)
                    }
                    self.finish(
                        requestID: capturedRequestID,
                        operationID: capturedOperationID
                    )
                    return
                }
                guard case .ready(let startPosition) = startResult else {
                    if case .insufficientEvidence(let issue) = startResult {
                        self.publishPoseIssue(issue, destination: destination)
                    }
                    self.finish(
                        requestID: capturedRequestID,
                        operationID: capturedOperationID
                    )
                    return
                }

                // Evaluate both observations against the same current capture
                // clock. A newer camera pose does not make older geometry future
                // dated, and geometry is never restamped to hide its age.
                // Omitted providers retain snapshot-only compatibility for
                // existing clients; live composition supplies the session clock.
                let evaluatedAt = self.currentEvaluationTime(fallback: max(
                        evidence.observedAt,
                        startPosition.observedAt,
                        self.latestPose?.timestamp ?? pose.timestamp
                    ))
                let evaluationUptime = ProcessInfo.processInfo.systemUptime
                let routeWork = Task.detached(priority: .userInitiated) {
                    engine.route(
                        from: startPosition, to: metadata, using: evidence, evaluatedAt: evaluatedAt
                    )
                }
                let result = await withTaskCancellationHandler {
                    await routeWork.value
                } onCancel: {
                    routeWork.cancel()
                }
                try Task.checkCancellation()
                guard
                    self.isCurrent(
                        requestID: capturedRequestID,
                        operationID: capturedOperationID,
                        generation: capturedGeneration,
                        surface: surface,
                        identity: identity
                    )
                else {
                    self.rejectStale(
                        requestID: capturedRequestID,
                        operationID: capturedOperationID
                    )
                    return
                }
                let currentEvaluationTime = self.currentEvaluationTime(
                    fallback: evaluatedAt + max(0, ProcessInfo.processInfo.systemUptime - evaluationUptime)
                )
                guard result.status != .success || (currentEvaluationTime.isFinite &&
                    currentEvaluationTime - evidence.observedAt <= engine.policy.maximumEvidenceAge &&
                    currentEvaluationTime - startPosition.observedAt <= engine.policy.maximumStartAge &&
                    self.latestPose.map({ self.horizontalDistance(pose, $0) < self.movementReevaluationDistance }) == true)
                else {
                    self.publishEvidenceIssue(.surfaceObservationStale, destination: destination)
                    self.finish(requestID: capturedRequestID, operationID: capturedOperationID)
                    return
                }
                self.publish(
                    result: result,
                    destination: destination,
                    identity: identity,
                    surfaceRevision: surface.revision
                )
                if self.renderablePath != nil {
                    self.startRouteLease(duration: min(
                        1,
                        engine.policy.maximumEvidenceAge - (currentEvaluationTime - evidence.observedAt),
                        engine.policy.maximumStartAge - (currentEvaluationTime - startPosition.observedAt)
                    ))
                }
                self.finish(
                    requestID: capturedRequestID,
                    operationID: capturedOperationID
                )
            } catch is CancellationError {
                self?.rejectStale(
                    requestID: capturedRequestID,
                    operationID: capturedOperationID
                )
            } catch {
                guard let self,
                    self.isCurrent(
                        requestID: capturedRequestID,
                        operationID: capturedOperationID,
                        generation: capturedGeneration,
                        surface: surface,
                        identity: identity
                    )
                else {
                    self?.rejectStale(
                        requestID: capturedRequestID,
                        operationID: capturedOperationID
                    )
                    return
                }
                self.publishEvidenceIssue(.coverageAttestationUnavailable, destination: destination)
                self.finish(
                    requestID: capturedRequestID,
                    operationID: capturedOperationID
                )
            }
        }
        routeTask = task
        trackedRouteTasks[taskID] = task
    }

    private func resolveDestination(
        _ destination: PendingNavigationDestination,
        identity: ARCaptureIdentity
    ) async throws -> ARIndoorNavigationTargetResolution {
        switch destination {
        case .metadata(let metadata):
            if let sourceMetadataProvider {
                guard let current = try await sourceMetadataProvider(metadata.object.id, metadata.mapID),
                    current.position == metadata.position,
                    current.object == metadata.object
                else { return .invalid(.searchTargetMismatch) }
            }
            return targetAdapter.resolve(metadata: metadata, currentIdentity: identity)
        case .grounded(let target, let suppliedMetadata):
            let metadata: SpatialObjectMetadata?
            if let sourceMetadataProvider {
                metadata = try await sourceMetadataProvider(target.objectID, target.sourceMapID)
            } else if let suppliedMetadata {
                metadata = suppliedMetadata
            } else {
                metadata = nil
            }
            guard let metadata else {
                return .invalid(.sourceMetadataUnavailable)
            }
            return targetAdapter.resolve(
                groundedTarget: target,
                sourceMetadata: metadata,
                currentIdentity: identity,
                now: nowProvider()
            )
        }
    }

    private func publish(
        result: IndoorNavigationResult,
        destination: PendingNavigationDestination,
        identity: ARCaptureIdentity,
        surfaceRevision: UInt64
    ) {
        let output: ARIndoorNavigationPathOutput?
        if let path = result.path {
            output = try? ARIndoorNavigationPathOutput(
                path: path,
                semanticLabel: destination.semanticLabel,
                identity: identity,
                surfaceRevision: surfaceRevision
            )
        } else {
            output = nil
        }
        guard result.status != .success || output != nil else {
            publishEvidenceIssue(.coordinateContextMismatch, destination: destination)
            return
        }
        let presentation = ARIndoorNavigationPresentation(
            destinationObjectID: destination.objectID,
            semanticLabel: destination.semanticLabel,
            result: result,
            evidenceIssue: nil,
            poseIssue: nil,
            targetIssue: nil,
            pathOutput: output,
            message: Self.koreanMessage(for: result, label: destination.semanticLabel)
        )
        latestPresentation = presentation
        renderablePath = output
        if output != nil {
            state = .navigating
            metrics.routesPublished &+= 1
        } else {
            state = .noPath
            metrics.noPathResultsPublished &+= 1
        }
    }

    private func publishEvidenceIssue(
        _ issue: ARIndoorNavigationEvidenceIssue,
        destination: PendingNavigationDestination
    ) {
        latestPresentation = ARIndoorNavigationPresentation(
            destinationObjectID: destination.objectID,
            semanticLabel: destination.semanticLabel,
            result: nil,
            evidenceIssue: issue,
            poseIssue: nil,
            targetIssue: nil,
            pathOutput: nil,
            message: Self.koreanMessage(for: issue)
        )
        renderablePath = nil
        state = .noPath
        metrics.noPathResultsPublished &+= 1
    }

    private func publishPoseIssue(
        _ issue: ARIndoorNavigationPoseIssue,
        destination: PendingNavigationDestination
    ) {
        latestPresentation = ARIndoorNavigationPresentation(
            destinationObjectID: destination.objectID,
            semanticLabel: destination.semanticLabel,
            result: nil,
            evidenceIssue: nil,
            poseIssue: issue,
            targetIssue: nil,
            pathOutput: nil,
            message: Self.koreanMessage(for: issue)
        )
        renderablePath = nil
        state = .noPath
        metrics.noPathResultsPublished &+= 1
    }

    private func publishTargetIssue(
        _ issue: ARIndoorNavigationTargetIssue,
        destination: PendingNavigationDestination
    ) {
        latestPresentation = ARIndoorNavigationPresentation(
            destinationObjectID: destination.objectID,
            semanticLabel: destination.semanticLabel,
            result: nil,
            evidenceIssue: nil,
            poseIssue: nil,
            targetIssue: issue,
            pathOutput: nil,
            message: Self.koreanMessage(for: issue)
        )
        renderablePath = nil
        state = .noPath
        metrics.noPathResultsPublished &+= 1
    }

    private func isCurrent(
        requestID: UInt64,
        operationID: UInt64,
        generation: UInt64,
        surface: ARSurfaceStateSnapshot,
        identity: ARCaptureIdentity
    ) -> Bool {
        guard isActive, self.requestID == requestID,
            self.operationID == operationID,
            contextGeneration == generation,
            currentIdentityProvider() == identity,
            monitoredIdentity == identity,
            let latestSurface
        else { return false }
        return sameSurfaceIdentity(latestSurface, surface)
            && latestSurface.revision == surface.revision
            && latestSurface.timestamp == surface.timestamp
    }

    private func rejectStale(requestID: UInt64, operationID: UInt64) {
        metrics.staleResultsRejected &+= 1
        finish(requestID: requestID, operationID: operationID)
    }

    private func finish(requestID: UInt64, operationID: UInt64) {
        guard self.requestID == requestID, self.operationID == operationID else { return }
        routeTask = nil
        updateReadyState()
    }

    private func trackedRouteDidFinish(_ taskID: UUID) {
        trackedRouteTasks[taskID] = nil
    }

    private func cancelRoute(countCancellation: Bool) {
        guard routeTask != nil || routeDebounceTask != nil else { return }
        operationID &+= 1
        routeTask?.cancel()
        routeTask = nil
        routeDebounceTask?.cancel()
        routeDebounceTask = nil
        if countCancellation {
            metrics.requestsCancelled &+= 1
        }
    }

    private func revokePublishedRoute(countInvalidation: Bool) {
        routeLeaseTask?.cancel()
        routeLeaseTask = nil
        let hadRoute = renderablePath != nil || latestPresentation != nil
        renderablePath = nil
        latestPresentation = nil
        if countInvalidation, hadRoute {
            metrics.routeInvalidations &+= 1
            state = .invalidated
        }
    }

    private func horizontalDistance(_ first: ARPoseSnapshot, _ second: ARPoseSnapshot) -> Double {
        hypot(Double(first.cameraTransform.column3.x - second.cameraTransform.column3.x),
              Double(first.cameraTransform.column3.z - second.cameraTransform.column3.z))
    }

    private func currentEvaluationTime(fallback: TimeInterval) -> TimeInterval {
        if let evaluationTimestampProvider {
            guard let supplied = evaluationTimestampProvider(), supplied.isFinite else { return .nan }
            let uptime = ProcessInfo.processInfo.systemUptime
            if evaluationClockAnchor?.timestamp != supplied {
                evaluationClockAnchor = (supplied, uptime)
            }
            return supplied + max(0, uptime - (evaluationClockAnchor?.uptime ?? uptime))
        }
        guard let latestPose, let latestPoseReceivedUptime else { return fallback }
        return max(fallback, latestPose.timestamp
            + max(0, ProcessInfo.processInfo.systemUptime - latestPoseReceivedUptime))
    }

    /// A short render lease expires even when surface and pose streams stop.
    /// Re-evaluation fetches current metadata and current obstacle evidence.
    private func startRouteLease(duration: TimeInterval) {
        routeLeaseTask?.cancel()
        let generation = contextGeneration
        let request = requestID
        routeLeaseTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, duration))) } catch { return }
            guard let self, self.isActive, self.contextGeneration == generation,
                self.requestID == request else { return }
            self.contextGeneration &+= 1
            self.cancelRoute(countCancellation: true)
            self.revokePublishedRoute(countInvalidation: true)
            self.scheduleRouteIfPossible()
        }
    }

    private func snapshotMatches(
        _ snapshot: ARSurfaceStateSnapshot,
        identity: ARCaptureIdentity
    ) -> Bool {
        snapshot.coordinateFrameID == identity.coordinateFrameID
            && snapshot.segmentID == identity.segmentID
            && snapshot.mapID == identity.mapID
            && snapshot.coordinateFrameStatus == identity.status
    }

    private func poseMatches(
        _ pose: ARPoseSnapshot,
        identity: ARCaptureIdentity
    ) -> Bool {
        pose.coordinateFrameID == identity.coordinateFrameID
            && pose.segmentID == identity.segmentID
            && pose.mapID == identity.mapID
            && pose.coordinateFrameStatus == identity.status
    }

    private func poseIsUsableForNavigation(_ pose: ARPoseSnapshot) -> Bool {
        guard pose.trackingState == .normal else {
            return false
        }
        switch pose.worldMappingStatus {
        case .mapped, .extending:
            return true
        case .notAvailable, .limited, .unknown:
            return false
        }
    }

    private func sameSurfaceIdentity(
        _ lhs: ARSurfaceStateSnapshot,
        _ rhs: ARSurfaceStateSnapshot
    ) -> Bool {
        lhs.coordinateFrameID == rhs.coordinateFrameID
            && lhs.segmentID == rhs.segmentID
            && lhs.mapID == rhs.mapID
            && lhs.coordinateFrameStatus == rhs.coordinateFrameStatus
    }

    private static func koreanMessage(
        for result: IndoorNavigationResult,
        label: String
    ) -> String {
        let label = String(label.prefix(80))
        switch result.status {
        case .success:
            let distance = result.path?.totalDistance ?? 0
            return String(
                format: "관측된 바닥을 따라 ‘%@’까지 약 %.1f미터예요. 이동 중 주변 장애물을 직접 확인해 주세요.",
                label,
                distance
            )
        case .unreachable:
            return "‘\(label)’까지 벽과 장애물을 피하는 확인된 경로가 없어요. 공간을 더 둘러봐 주세요."
        case .insufficientEvidence:
            return "‘\(label)’까지 안전한 길을 확정할 공간 정보가 아직 부족해요. 바닥과 통로를 더 비춰 주세요."
        case .invalidStart:
            return "현재 위치를 안정적으로 확인하지 못해 길 안내를 시작하지 않았어요."
        case .invalidDestination:
            return "‘\(label)’의 저장 위치를 현재 공간에서 검증하지 못해 길 안내를 시작하지 않았어요."
        case .invalidEvidence:
            return "공간 지도 증거가 서로 맞지 않아 안전을 위해 경로를 표시하지 않았어요."
        case .capacityExceeded:
            return "공간 정보가 너무 커서 안전하게 경로를 계산하지 못했어요. 범위를 줄여 다시 시도해 주세요."
        }
    }

    private static func koreanMessage(for issue: ARIndoorNavigationEvidenceIssue) -> String {
        switch issue {
        case .captureNotConfirmed:
            return "카메라 위치가 아직 안정화되지 않아 길 안내를 표시하지 않았어요."
        case .surfaceSnapshotIncomplete:
            return "현재 공간 표면 정보를 완전히 읽지 못해 안전한 경로를 확정할 수 없어요."
        case .currentMapUnavailable, .coordinateContextMismatch:
            return "현재 공간 지도와 저장된 좌표가 연결되지 않아 길 안내를 표시하지 않았어요."
        case .surfaceRevisionMismatch, .surfaceTimestampMismatch:
            return "공간 지도가 갱신되어 이전 경로를 폐기했어요. 최신 지도로 다시 계산해 주세요."
        case .floorCoverageUnavailable:
            return "이동할 바닥 영역을 충분히 확인하지 못했어요. 바닥을 천천히 더 비춰 주세요."
        case .freeSpaceCoverageUnavailable:
            return "AR 표면만으로 빈 통로와 장애물 누락 여부를 확인할 수 없어 경로를 추정하지 않았어요."
        case .coverageAttestationUnavailable:
            return "벽, 문, 장애물의 확인 범위가 부족해 안전한 경로를 확정할 수 없어요."
        case .surfaceObservationStale:
            return "관측한 공간 정보가 오래되어 경로를 지웠어요. 바닥과 통로를 다시 비춰 주세요."
        case .dynamicOccupancyUnavailable:
            return "현재 통로의 장애물 정보를 확인하지 못해 경로를 표시하지 않았어요."
        }
    }

    private static func koreanMessage(for issue: ARIndoorNavigationPoseIssue) -> String {
        switch issue {
        case .captureNotConfirmed, .trackingNotNormal:
            return "현재 위치 추적이 안정될 때까지 길 안내를 잠시 보류했어요."
        case .coordinateContextMismatch:
            return "현재 카메라 좌표와 공간 지도가 일치하지 않아 경로를 표시하지 않았어요."
        case .positionGroundingUnavailable, .positionUncertaintyUnavailable:
            return "현재 위치가 바닥의 어느 지점인지 확인하지 못해 경로를 추정하지 않았어요."
        case .positionTimestampMismatch, .positionDoesNotMatchCamera:
            return "현재 위치 증거가 최신 카메라 위치와 맞지 않아 경로를 폐기했어요."
        }
    }

    private static func koreanMessage(for issue: ARIndoorNavigationTargetIssue) -> String {
        switch issue {
        case .sourceMetadataUnavailable, .searchTargetMismatch, .targetNotGrounded:
            return "검증된 검색 결과와 저장된 물체 기록이 일치하지 않아 길 안내를 시작하지 않았어요."
        case .targetStale:
            return "검색 결과가 오래되어 길 안내를 시작하지 않았어요. 물체를 다시 검색해 주세요."
        case .unsupportedSearchIntent:
            return "이 검색 요청은 실내 길 안내 대상으로 확정할 수 없어요."
        case .confidenceTooLow:
            return "물체 위치의 신뢰도가 낮아 안전을 위해 길 안내를 표시하지 않았어요."
        case .captureNotConfirmed, .currentMapUnavailable, .coordinateContextMismatch:
            return "물체 위치를 현재 공간 좌표로 확인하지 못해 길 안내를 시작하지 않았어요."
        case .derivedMetadataInvalid:
            return "물체 위치 기록을 안전한 경로 입력으로 변환하지 못했어요."
        }
    }
}

private enum PendingNavigationDestination: Sendable {
    case metadata(SpatialObjectMetadata)
    case grounded(
        GroundedSpatialObjectQueryTarget,
        sourceMetadata: SpatialObjectMetadata?
    )

    var objectID: ObjectID {
        switch self {
        case .metadata(let metadata): metadata.object.id
        case .grounded(let target, _): target.objectID
        }
    }

    var semanticLabel: String {
        switch self {
        case .metadata(let metadata): metadata.object.semanticLabel
        case .grounded(let target, _): target.semanticLabel
        }
    }
}
