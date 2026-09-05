@preconcurrency import ARKit
@preconcurrency import AVFoundation
import Combine
import Foundation
import RealityKit
import UIKit
import VispaceCore

public enum ARSessionControllerState: Equatable, Sendable {
    case detached
    case waitingForCameraPermission
    case cameraAccessUnavailable
    case ready
    case running
    case paused
    case unavailable(reason: String)
    case failed(message: String)
}

/// A camera pose and classified-floor projection captured from one live AR
/// frame. Keeping these values together prevents navigation from combining a
/// buffered pose with a newer camera frame.
public struct ARCameraFloorPoseEvidence: Equatable, Sendable {
    public let pose: ARPoseSnapshot
    public let floorPosition: FramedPosition

    public init(pose: ARPoseSnapshot, floorPosition: FramedPosition) {
        self.pose = pose
        self.floorPosition = floorPosition
    }
}

/// Owns the app's single ARSession and camera lifecycle.
///
/// The UI layer only supplies the camera-backed `ARView`. Camera pixels leave
/// the ARKit callback solely as bounded, deep-copied, in-memory snapshots and
/// this controller never exposes an API that can persist them.
@MainActor
public final class ARSessionController: ObservableObject, CameraSessionControlling {
    public typealias WorldMapArchiveHandler =
        @Sendable (
            Data,
            ARCaptureIdentity
        ) async throws -> SpatialMapMetadata
    public typealias WorldMapRestoreProvider = @Sendable () async throws -> WorldMapRestoreCandidate?

    @Published public private(set) var state: ARSessionControllerState = .detached {
        didSet { temporalCaptureGate.value = state == .running && sessionIsRunning }
    }
    @Published public private(set) var capabilities: ARCaptureCapabilities?
    @Published public private(set) var persistenceFailureMessage: String?
    private var restoreFailureMessage: String?
    private var saveFailureMessage: String?
    public var onCaptureIdentityChange: (@MainActor (ARCaptureIdentity) -> Void)?

    public var poses: AsyncStream<ARPoseSnapshot> { delegateProxy.poses }
    public var frames: AsyncStream<ARFrameSnapshot> { delegateProxy.frames }
    public var surfaces: AsyncStream<ARSurfaceStateSnapshot> { delegateProxy.surfaces }
    public var events: AsyncStream<ARSessionEvent> { delegateProxy.events }
    public var captureIdentity: ARCaptureIdentity { captureIdentityBox.value }
    public var latestDepthFrame: ARFrameSnapshot? {
        guard state == .running, let frame = delegateProxy.frameChannel.latest,
            confirmedCaptureIdentity(for: frame) == captureIdentity,
            let timestamp = navigationEvaluationTimestamp,
            timestamp >= frame.pose.timestamp, timestamp - frame.pose.timestamp <= 1
        else { return nil }
        return frame
    }

    /// Evaluation time shares ARKit's monotonic session clock with geometry
    /// and poses. Wall-clock Date values are not comparable to those samples.
    public var navigationEvaluationTimestamp: TimeInterval? {
        guard state == .running, sessionIsRunning else { return nil }
        guard let frameTimestamp = arView?.session.currentFrame?.timestamp else { return nil }
        return ARNavigationEvaluationClock.timestamp(
            frameTimestamp: frameTimestamp, systemUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    /// Revalidates an asynchronous perception result against the exact live
    /// ARSession attachment/run and returns the latest map identity. A map ID
    /// may legitimately be assigned while inference is in flight, but the
    /// coordinate frame and segment may never change underneath that work.
    public func confirmedCaptureIdentity(
        for frame: ARFrameSnapshot
    ) -> ARCaptureIdentity? {
        PerceptionFrameValidator().confirmedIdentity(
            for: frame.pose,
            currentToken: delegateProxy.currentFrameToken(),
            currentIdentity: captureIdentityBox.value,
            sessionIsRunning: state == .running
        )
    }

    /// Synchronous authority for the journal commit boundary. Captures only
    /// thread-safe boxes/proxy, so the service neither retains this controller
    /// nor hops actors after deciding whether an old capture is still current.
    public func makeTemporalPoseValidator() -> TemporalSpatialMemoryService.PoseValidator {
        let proxy = delegateProxy
        let identityBox = captureIdentityBox
        let gate = temporalCaptureGate
        return { pose in
            guard gate.value else { return false }
            let token = proxy.currentFrameToken()
            let identity = identityBox.value
            guard identity.mapID == pose.mapID,
                PerceptionFrameValidator().confirmedIdentity(
                    for: pose, currentToken: token, currentIdentity: identity, sessionIsRunning: true
                ) != nil else { return false }
            // A lifecycle transition between the independent locked reads
            // invalidates admission instead of splicing two run identities.
            return gate.value && token == proxy.currentFrameToken() && identity == identityBox.value
        }
    }

    private weak var arView: ARView?
    private let delegateQueue: DispatchQueue
    private let worldMapArchiveQueue: DispatchQueue
    private let delegateProxy: ARSessionDelegateProxy
    private let imageOrientation: FrameImageOrientationBox
    private let displayGeometry: FrameDisplayGeometryBox
    private let captureIdentityBox: ARCaptureIdentityBox
    private let sessionRunContextBox: ARSessionRunContextBox
    private let temporalCaptureGate = ARTemporalCaptureRunningGate()
    private let configurationOptions: ARWorldTrackingOptions
    private let worldMapArchiveHandler: WorldMapArchiveHandler?
    private let worldMapRestoreProvider: WorldMapRestoreProvider?
    private let relocalizationTimeout: Duration
    #if DEBUG
        private let isSessionDisabledForTesting: Bool
        private let simulatesDeniedCameraAccess: Bool
    #endif

    private var activationTask: Task<Void, Never>?
    private var activationGeneration: UInt64 = 0
    private var eventMonitorTask: Task<Void, Never>?
    private var relocalizationTimeoutTask: Task<Void, Never>?
    private var wantsActivation = false
    private var sessionIsRunning = false {
        didSet { temporalCaptureGate.value = state == .running && sessionIsRunning }
    }
    private var sessionIsInterrupted = false
    private var pendingInitialWorldMap: ARWorldMap?
    private var hasAttemptedRestore = false
    private var interruptionRecoveryOriginalIdentity: ARCaptureIdentity?
    private var worldMapPersistenceGeneration: UInt64 = 0
    private var worldMapPersistenceTasks: [UUID: Task<Void, Never>] = [:]
    private var worldMapCheckpointCancellations: [UUID: WorldMapCheckpointCancellation] = [:]
    private let worldMapCheckpointGate = WorldMapCheckpointGate()
    private var relocalizationStateMachine = RelocalizationStateMachine()

    public init(
        configurationOptions: ARWorldTrackingOptions = .productionDefault,
        maximumSnapshotFramesPerSecond: Double = 10,
        worldMapArchiveHandler: WorldMapArchiveHandler? = nil,
        worldMapRestoreProvider: WorldMapRestoreProvider? = nil,
        relocalizationTimeout: Duration = .seconds(15)
    ) {
        let imageOrientation = FrameImageOrientationBox(.right)
        let displayGeometry = FrameDisplayGeometryBox()
        let captureIdentityBox = ARCaptureIdentityBox()
        let sessionRunContextBox = ARSessionRunContextBox()
        self.imageOrientation = imageOrientation
        self.displayGeometry = displayGeometry
        self.captureIdentityBox = captureIdentityBox
        self.sessionRunContextBox = sessionRunContextBox
        self.configurationOptions = configurationOptions
        self.worldMapArchiveHandler = worldMapArchiveHandler
        self.worldMapRestoreProvider = worldMapRestoreProvider
        self.relocalizationTimeout = relocalizationTimeout
        #if DEBUG
            isSessionDisabledForTesting = ProcessInfo.processInfo.arguments.contains(
                "-VispaceDisableARSession"
            )
            simulatesDeniedCameraAccess = ProcessInfo.processInfo.arguments.contains(
                "-VispaceSimulateCameraDenied"
            )
        #endif
        delegateQueue = DispatchQueue(
            label: "com.l3j.vispace.arkit.delegate",
            qos: .userInitiated,
            autoreleaseFrequency: .workItem
        )
        worldMapArchiveQueue = DispatchQueue(
            label: "com.l3j.vispace.world-map.archive",
            qos: .utility,
            autoreleaseFrequency: .workItem
        )
        delegateProxy = ARSessionDelegateProxy(
            maximumSnapshotFramesPerSecond: maximumSnapshotFramesPerSecond,
            imageOrientationProvider: { imageOrientation.value },
            captureIdentityProvider: { captureIdentityBox.value },
            sessionRunContextProvider: { sessionRunContextBox.value },
            displayGeometryProvider: { displayGeometry.value }
        )
    }

    public static func live(
        repository: WorldMapCheckpointRepository = WorldMapCheckpointRepository(
            directoryURL: VispaceStoragePaths.spatialCaptureDirectory()
        ),
        preferredMapProvider: @escaping @Sendable () async -> MapID? = { nil }
    ) -> ARSessionController {
        let controller = ARSessionController(
            maximumSnapshotFramesPerSecond: 5,
            worldMapArchiveHandler: { archive, identity in
                try await repository.saveCheckpoint(
                    archive: archive,
                    captureIdentity: identity
                )
            },
            worldMapRestoreProvider: {
                try await repository.loadLatestValidCheckpoint(mapID: preferredMapProvider())
            }
        )
        return controller
    }

    /// Attaches RealityKit's camera surface without placing overlays or other
    /// rendered content on top of it.
    public func attach(to view: ARView) {
        if arView === view {
            return
        }

        let shouldReactivate = wantsActivation
        if let previousView = arView {
            detach(from: previousView)
            wantsActivation = shouldReactivate
        }

        arView = view
        startEventMonitoringIfNeeded()
        view.automaticallyConfigureSession = false
        view.environment.background = .color(.black)
        delegateProxy.install(on: view.session, delegateQueue: delegateQueue)
        state = .ready

        if wantsActivation {
            startActivationIfPossible()
        }
    }

    public func detach(from view: ARView) {
        guard arView === view else {
            return
        }

        cancelActivation()
        view.session.pause()
        delegateProxy.invalidateCallbacks(from: view.session)
        delegateQueue.sync {}
        suspendRelocalizationForLifecycle()
        view.environment.background = .color(.black)
        delegateProxy.uninstall(from: view.session)
        eventMonitorTask?.cancel()
        eventMonitorTask = nil
        delegateProxy.endControllerEvents()
        arView = nil
        sessionIsRunning = false
        sessionIsInterrupted = false
        wantsActivation = false
        if pendingInitialWorldMap == nil {
            invalidateCoordinateFrameForNewSession()
        }
        state = .detached
    }

    /// Requests permission when needed, constructs a capability-gated
    /// configuration, and starts the already-attached session.
    public func activate() {
        wantsActivation = true
        startActivationIfPossible()
    }

    /// Stops camera and motion capture as soon as this scene is no longer active.
    /// This is separate from responding to ARKit's interruption callback, where
    /// calling `pause()` would suppress the matching interruption-ended event.
    public func deactivate() {
        wantsActivation = false
        cancelActivation()
        if let session = arView?.session {
            session.pause()
            delegateProxy.invalidateCallbacks(from: session)
            delegateQueue.sync {}
        }
        suspendRelocalizationForLifecycle()
        arView?.environment.background = .color(.black)
        sessionIsRunning = false
        sessionIsInterrupted = false
        state = arView == nil ? .detached : .paused
    }

    /// Stops capture, revokes any not-yet-committed checkpoint, and waits for
    /// an already-started repository operation before a user-requested data
    /// deletion proceeds. A fresh coordinate context is created so deleted
    /// maps cannot be silently re-associated after capture resumes.
    public func prepareForSpatialDataDeletion() async {
        let pendingActivation = activationTask
        deactivate()
        // A cancelled restore can still be inside an actor-isolated repository
        // operation. Do not remove its files until that operation has actually
        // returned and released the repository gate.
        if let pendingActivation {
            await pendingActivation.value
        }
        worldMapPersistenceGeneration &+= 1
        for cancellation in worldMapCheckpointCancellations.values {
            cancellation.cancel()
        }
        let pendingPersistence = Array(worldMapPersistenceTasks.values)
        for task in pendingPersistence {
            task.cancel()
        }
        for task in pendingPersistence {
            await task.value
        }
        worldMapPersistenceTasks.removeAll(keepingCapacity: false)
        worldMapCheckpointCancellations.removeAll(keepingCapacity: false)
        invalidateCoordinateFrameForNewSession()
        delegateProxy.requestAuthoritativeSurfaceRepublish()
    }

    /// Requests a checkpoint from the most recent fully mapped session when a
    /// persistence policy has explicitly supplied an archive handler.
    public func enterBackground() {
        let identity = captureIdentityBox.value
        let requestTime = ProcessInfo.processInfo.systemUptime
        let persistenceGeneration = worldMapPersistenceGeneration
        guard
            let handler = worldMapArchiveHandler,
            let session = arView?.session,
            session.currentFrame?.worldMappingStatus == .mapped,
            identity.status == .confirmed
        else {
            let reason: String
            if worldMapArchiveHandler == nil {
                reason = "No world-map persistence handler is configured."
            } else if identity.status != .confirmed {
                reason = "The coordinate frame is not confirmed."
            } else {
                reason = "World mapping has not reached the mapped state."
            }
            delegateProxy.emit(
                .worldMapArchiveSkipped(reason: reason)
            )
            return
        }
        switch worldMapCheckpointGate.begin(requestTime: requestTime) {
        case .accepted:
            break
        case .inFlight:
            delegateProxy.emit(
                .worldMapArchiveSkipped(reason: "A world-map checkpoint is already in flight.")
            )
            return
        case .tooRecent:
            delegateProxy.emit(
                .worldMapArchiveSkipped(reason: "A world-map checkpoint was requested recently.")
            )
            return
        }
        let checkpointID = UUID()
        let checkpointCancellation = WorldMapCheckpointCancellation()
        worldMapCheckpointCancellations[checkpointID] = checkpointCancellation
        let backgroundTaskLease = BackgroundTaskLease()
        let checkpointCompletion = WorldMapCheckpointCompletion(
            gate: worldMapCheckpointGate,
            backgroundTaskLease: backgroundTaskLease,
            onFinish: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.checkpointDidFinish(checkpointID)
                }
            }
        )
        backgroundTaskLease.begin { [weak self, checkpointCancellation, checkpointCompletion] in
            checkpointCancellation.cancel()
            checkpointCompletion.endBackgroundExecution()
            Task { @MainActor [weak self] in
                guard let self else {
                    checkpointCompletion.finish()
                    return
                }
                self.expireWorldMapCheckpoint(
                    checkpointID,
                    completion: checkpointCompletion
                )
            }
        }

        session.getCurrentWorldMap {
            [
                checkpointCancellation,
                checkpointCompletion,
                delegateProxy,
                worldMapArchiveQueue,
            ] worldMap, error in
            guard !checkpointCancellation.isCancelled else {
                checkpointCompletion.finish()
                return
            }
            if let error {
                delegateProxy.emit(.worldMapArchiveFailed(message: error.localizedDescription))
                checkpointCompletion.finish()
                return
            }
            guard let worldMap else {
                delegateProxy.emit(
                    .worldMapArchiveFailed(message: "ARKit returned no world map.")
                )
                checkpointCompletion.finish()
                return
            }

            let transfer = ImmutableWorldMapTransfer(worldMap)
            worldMapArchiveQueue.async { [weak self] in
                do {
                    guard !checkpointCancellation.isCancelled else {
                        checkpointCompletion.finish()
                        return
                    }
                    let archive = try ARWorldMapArchiveCodec.archive(transfer.value)
                    guard !checkpointCancellation.isCancelled else {
                        checkpointCompletion.finish()
                        return
                    }
                    delegateProxy.emit(.worldMapArchiveCreated(byteCount: archive.count))
                    Task { @MainActor [weak self] in
                        guard let self else {
                            checkpointCompletion.finish()
                            return
                        }
                        await self.persistWorldMapArchive(
                            archive,
                            checkpointID: checkpointID,
                            identity: identity,
                            generation: persistenceGeneration,
                            cancellation: checkpointCancellation,
                            handler: handler,
                            completion: checkpointCompletion
                        )
                    }
                } catch {
                    delegateProxy.emit(
                        .worldMapArchiveFailed(message: String(describing: error))
                    )
                    checkpointCompletion.finish()
                }
            }
        }
    }

    private func persistWorldMapArchive(
        _ archive: Data,
        checkpointID: UUID,
        identity: ARCaptureIdentity,
        generation: UInt64,
        cancellation: WorldMapCheckpointCancellation,
        handler: @escaping WorldMapArchiveHandler,
        completion: WorldMapCheckpointCompletion
    ) async {
        guard generation == worldMapPersistenceGeneration,
            !cancellation.isCancelled
        else {
            completion.finish()
            return
        }

        let persistenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard !cancellation.isCancelled else {
                    throw CancellationError()
                }
                let metadata = try await handler(archive, identity)
                try Task.checkCancellation()
                guard generation == self.worldMapPersistenceGeneration,
                    !cancellation.isCancelled
                else {
                    return
                }
                self.captureIdentityBox.recordCheckpoint(
                    mapID: metadata.mapID,
                    matching: identity
                )
                self.saveFailureMessage = nil
                self.publishPersistenceFailure()
                self.onCaptureIdentityChange?(self.captureIdentity)
                self.delegateProxy.requestAuthoritativeSurfaceRepublish()
            } catch is CancellationError {
                // User-requested deletion intentionally revokes this write.
            } catch {
                self.delegateProxy.emit(
                    .worldMapArchiveFailed(message: String(describing: error))
                )
            }
        }
        worldMapPersistenceTasks[checkpointID] = persistenceTask
        await persistenceTask.value
        worldMapPersistenceTasks[checkpointID] = nil
        completion.finish()
    }

    private func expireWorldMapCheckpoint(
        _ checkpointID: UUID,
        completion: WorldMapCheckpointCompletion
    ) {
        if let persistenceTask = worldMapPersistenceTasks[checkpointID] {
            persistenceTask.cancel()
        } else {
            // The shared cancellation token prevents a still-pending ARKit or
            // archive callback from ever entering persistence, so the request
            // gate can safely admit a later checkpoint.
            completion.finish()
        }
    }

    private func checkpointDidFinish(_ checkpointID: UUID) {
        worldMapCheckpointCancellations[checkpointID] = nil
    }

    /// Requests an on-demand checkpoint after repeated place evidence proves
    /// that the current confirmed coordinate frame is a new place. The same
    /// bounded gate and integrity-preserving repository path used for
    /// background checkpoints is reused here.
    public func requestWorldMapCheckpoint() {
        enterBackground()
    }

    public func resetPersistenceStatus() {
        restoreFailureMessage = nil
        saveFailureMessage = nil
        publishPersistenceFailure()
    }

    private func publishPersistenceFailure() {
        persistenceFailureMessage = restoreFailureMessage ?? saveFailureMessage
    }

    /// Associates the live capture with an already-persisted map only when
    /// both sides name the exact same confirmed coordinate frame. Cross-frame
    /// place matches must go through validated alignment and a fresh
    /// checkpoint instead of borrowing an unrelated map identifier.
    @discardableResult
    public func associateCurrentCapture(
        with mapID: MapID,
        coordinateFrameID: CoordinateFrameID
    ) -> Bool {
        let identity = captureIdentityBox.value
        guard
            state == .running,
            identity.status == .confirmed,
            identity.coordinateFrameID == coordinateFrameID,
            identity.mapID == nil || identity.mapID == mapID
        else {
            return false
        }

        captureIdentityBox.recordCheckpoint(mapID: mapID, matching: identity)
        let didAssociate = captureIdentityBox.value.mapID == mapID
        if didAssociate {
            onCaptureIdentityChange?(captureIdentity)
            delegateProxy.requestAuthoritativeSurfaceRepublish(afterNextFrame: true)
        }
        return didAssociate
    }

    /// Updates the EXIF orientation copied into subsequent Vision snapshots.
    /// Portrait is `.right` for the unrotated iPhone camera sensor.
    public func setImageOrientation(_ orientation: FrameImageOrientation) {
        imageOrientation.value = orientation
    }

    public func setDisplayGeometry(_ geometry: FrameDisplayGeometry) {
        displayGeometry.value = geometry
        switch geometry.orientation {
        case .portrait:
            imageOrientation.value = .right
        case .portraitUpsideDown:
            imageOrientation.value = .left
        case .landscapeLeft:
            imageOrientation.value = .up
        case .landscapeRight:
            imageOrientation.value = .down
        }
    }

    /// Returns the screen-center point only when ARKit confirms that the ray
    /// hit existing, classified floor geometry in the currently owned frame.
    /// Estimated planes and unclassified horizontal surfaces are deliberately
    /// excluded so placement advice cannot be grounded on an invented floor.
    public func verifiedPlacementPositionAtScreenCenter() -> FramedPosition? {
        guard state == .running,
            let view = arView,
            view.bounds.width > 0,
            view.bounds.height > 0,
            let frame = view.session.currentFrame,
            case .normal = frame.camera.trackingState
        else {
            return nil
        }

        let identity = captureIdentityBox.value
        guard identity.status == .confirmed else {
            return nil
        }
        let point = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard
            let result = view.raycast(
                from: point,
                allowing: .existingPlaneGeometry,
                alignment: .horizontal
            ).first,
            let plane = result.anchor as? ARPlaneAnchor,
            plane.classification == .floor,
            captureIdentityBox.value == identity
        else {
            return nil
        }

        let translation = result.worldTransform.columns.3
        guard
            let position = try? Vec3(
                x: Double(translation.x),
                y: Double(translation.y),
                z: Double(translation.z)
            )
        else {
            return nil
        }
        return try? FramedPosition(
            coordinateFrameID: identity.coordinateFrameID,
            value: position,
            observedAt: max(0, Date().timeIntervalSince1970),
            trackingQuality: .normal,
            uncertainty: .raycastEstimate
        )
    }

    /// Projects the exact live camera pose vertically onto classified floor
    /// geometry. This is a transient navigation start point, not a durable
    /// object observation, so its timestamp intentionally uses ARKit's session
    /// clock to match `ARPoseSnapshot.timestamp`.
    public func verifiedCameraFloorPosition(
        for referencePose: ARPoseSnapshot
    ) -> FramedPosition? {
        guard state == .running,
            let view = arView,
            let frame = view.session.currentFrame,
            case .normal = frame.camera.trackingState,
            abs(frame.timestamp - referencePose.timestamp) <= 0.001,
            Matrix4x4Snapshot(frame.camera.transform) == referencePose.cameraTransform
        else {
            return nil
        }

        let identity = captureIdentityBox.value
        guard identity.status == .confirmed,
            referencePose.coordinateFrameStatus == .confirmed,
            referencePose.coordinateFrameID == identity.coordinateFrameID,
            referencePose.segmentID == identity.segmentID,
            referencePose.mapID == identity.mapID
        else {
            return nil
        }

        let camera = frame.camera.transform.columns.3
        let query = ARRaycastQuery(
            origin: SIMD3<Float>(camera.x, camera.y, camera.z),
            direction: SIMD3<Float>(0, -1, 0),
            allowing: .existingPlaneGeometry,
            alignment: .horizontal
        )
        guard let result = view.session.raycast(query).first,
            let plane = result.anchor as? ARPlaneAnchor,
            plane.classification == .floor,
            captureIdentityBox.value == identity
        else {
            return nil
        }

        let translation = result.worldTransform.columns.3
        guard
            let position = try? Vec3(
                x: Double(translation.x),
                y: Double(translation.y),
                z: Double(translation.z)
            )
        else {
            return nil
        }
        return try? FramedPosition(
            coordinateFrameID: identity.coordinateFrameID,
            value: position,
            observedAt: referencePose.timestamp,
            trackingQuality: .normal,
            uncertainty: .raycastEstimate
        )
    }

    /// Captures the live camera pose and its classified-floor projection as a
    /// single evidence unit. The caller-provided identity is rechecked before
    /// and after raycasting so a relocalization or session restart cannot mix
    /// coordinate contexts into one route request.
    public func currentVerifiedCameraFloorPoseEvidence(
        matching expectedIdentity: ARCaptureIdentity
    ) -> ARCameraFloorPoseEvidence? {
        guard state == .running,
            sessionIsRunning,
            expectedIdentity.status == .confirmed,
            captureIdentityBox.value == expectedIdentity,
            let view = arView,
            let frame = view.session.currentFrame,
            case .normal = frame.camera.trackingState,
            let sessionToken = delegateProxy.currentFrameToken()
        else {
            return nil
        }

        let pose = ARFrameSnapshotAdapter().makePose(
            from: frame,
            sessionToken: sessionToken,
            capturedAt: max(0, Date().timeIntervalSince1970),
            captureIdentity: expectedIdentity
        )
        let camera = frame.camera.transform.columns.3
        let query = ARRaycastQuery(
            origin: SIMD3<Float>(camera.x, camera.y, camera.z),
            direction: SIMD3<Float>(0, -1, 0),
            allowing: .existingPlaneGeometry,
            alignment: .horizontal
        )
        guard let result = view.session.raycast(query).first,
            let plane = result.anchor as? ARPlaneAnchor,
            plane.classification == .floor,
            state == .running,
            sessionIsRunning,
            arView === view,
            delegateProxy.currentFrameToken() == sessionToken,
            captureIdentityBox.value == expectedIdentity
        else {
            return nil
        }

        let translation = result.worldTransform.columns.3
        guard
            let position = try? Vec3(
                x: Double(translation.x),
                y: Double(translation.y),
                z: Double(translation.z)
            ),
            let floorPosition = try? FramedPosition(
                coordinateFrameID: expectedIdentity.coordinateFrameID,
                value: position,
                observedAt: pose.timestamp,
                trackingQuality: .normal,
                uncertainty: .raycastEstimate
            )
        else {
            return nil
        }
        return ARCameraFloorPoseEvidence(
            pose: pose,
            floorPosition: floorPosition
        )
    }

    /// Opts into expensive RGB/depth copies for an active perception consumer.
    /// The camera-only shipping path leaves this disabled, so frame callbacks
    /// publish pose only and perform zero pixel-buffer copies.
    public func setFrameSnapshotsEnabled(_ isEnabled: Bool) {
        delegateProxy.snapshotCaptureEnabled = isEnabled
    }

    /// Opts into bounded plane/mesh value snapshots for an active spatial
    /// consumer. ARKit mapping itself continues while this copy path is off.
    public func setSurfaceSnapshotsEnabled(_ isEnabled: Bool) {
        let wasEnabled = delegateProxy.surfaceCaptureEnabled
        delegateProxy.surfaceCaptureEnabled = isEnabled
        if isEnabled, !wasEnabled {
            delegateProxy.requestAuthoritativeSurfaceRepublish(afterNextFrame: true)
        }
    }

    /// Securely decodes an application-owned map archive and applies it the
    /// next time the session is run. Pixels are not part of ARWorldMap data.
    public func prepareToRelocalize(
        from archive: Data,
        coordinateFrameID: CoordinateFrameID = CoordinateFrameID(),
        mapID: MapID? = nil
    ) throws {
        // Decode first so an invalid archive leaves the active session intact.
        let worldMap = try ARWorldMapArchiveCodec.unarchive(archive)
        cancelActivation()
        relocalizationTimeoutTask?.cancel()
        relocalizationTimeoutTask = nil
        relocalizationStateMachine.cancel()
        interruptionRecoveryOriginalIdentity = nil
        if let view = arView {
            // Close and drain the old run before publishing the replacement
            // identity; otherwise a queued old frame could be mislabeled.
            _ = prepareForSessionRun(view)
            view.environment.background = .color(.black)
        }
        pendingInitialWorldMap = worldMap
        hasAttemptedRestore = true
        captureIdentityBox.value = ARCaptureIdentity(
            coordinateFrameID: coordinateFrameID,
            mapID: mapID,
            status: .relocalizing
        )
        sessionIsRunning = false
        sessionIsInterrupted = false
        if wantsActivation {
            startActivationIfPossible()
        }
    }

    private func startActivationIfPossible() {
        guard wantsActivation, let view = arView else {
            if arView == nil, state != .detached {
                state = .detached
            }
            return
        }
        #if DEBUG
            // Simulator UI tests opt out before touching camera authorization or
            // ARSession.run. The entire seam is absent from Release binaries.
            guard !isSessionDisabledForTesting else {
                state = .ready
                return
            }
            guard !simulatesDeniedCameraAccess else {
                state = .cameraAccessUnavailable
                return
            }
        #endif
        if sessionIsRunning {
            state = sessionIsInterrupted ? .paused : .running
            return
        }
        guard activationTask == nil else {
            return
        }

        state = .waitingForCameraPermission
        activationGeneration &+= 1
        let generation = activationGeneration
        activationTask = Task { @MainActor [weak self, weak view] in
            let hasPermission = await Self.requestCameraPermissionIfNeeded()
            guard let self else { return }
            defer { self.finishActivation(generation: generation) }
            guard !Task.isCancelled, self.wantsActivation else {
                return
            }
            guard hasPermission else {
                self.state = .cameraAccessUnavailable
                return
            }
            await self.loadRestoreCandidateIfNeeded()
            guard !Task.isCancelled, self.wantsActivation else {
                return
            }
            guard let view, self.arView === view else {
                self.state = .detached
                return
            }

            do {
                let isRestoringWorldMap = self.pendingInitialWorldMap != nil
                let requiresCoordinateConfirmation =
                    isRestoringWorldMap
                    || self.interruptionRecoveryOriginalIdentity != nil
                let result = try ARWorldTrackingConfigurationBuilder.make(
                    options: self.configurationOptions,
                    initialWorldMap: self.pendingInitialWorldMap
                )
                let runOptions: ARSession.RunOptions =
                    !isRestoringWorldMap
                    ? []
                    : [.resetTracking, .removeExistingAnchors]

                self.capabilities = result.capabilities
                let runContext = self.prepareForSessionRun(view)
                let timeoutGeneration: UInt64?
                if requiresCoordinateConfirmation {
                    let identity = self.captureIdentityBox.value
                    timeoutGeneration = self.relocalizationStateMachine.begin(
                        identity: identity,
                        sessionRunGeneration: runContext.generation
                    )
                    _ = self.captureIdentityBox.transitionStatus(
                        to: .relocalizing,
                        matching: identity
                    )
                } else {
                    timeoutGeneration = nil
                }
                view.environment.background = .cameraFeed()
                self.delegateProxy.activateCallbacks(for: view.session)
                view.session.run(result.configuration, options: runOptions)
                self.delegateProxy.requestAuthoritativeSurfaceRepublish(
                    afterNextFrame: true
                )
                if !isRestoringWorldMap {
                    self.pendingInitialWorldMap = nil
                }
                self.sessionIsRunning = true
                self.sessionIsInterrupted = false
                self.state = .running
                if let timeoutGeneration {
                    self.startRelocalizationTimeout(generation: timeoutGeneration)
                }
            } catch ARWorldTrackingConfigurationError.worldTrackingUnsupported {
                view.environment.background = .color(.black)
                self.state = .unavailable(reason: "AR world tracking is unsupported.")
            } catch {
                view.environment.background = .color(.black)
                self.state = .failed(message: String(describing: error))
            }
        }
    }

    private func cancelActivation() {
        activationGeneration &+= 1
        activationTask?.cancel()
    }

    private func prepareForSessionRun(_ view: ARView) -> ARSessionRunContext {
        // Stop delivery and drain the serial delegate queue before assigning a
        // new run token. The timestamp check in the proxy is a second guard
        // against a pre-reset frame arriving after this boundary.
        view.session.pause()
        delegateProxy.invalidateCallbacks(from: view.session)
        delegateQueue.sync {
            delegateProxy.resetObservationGatesForNewRun()
        }
        return sessionRunContextBox.advance(
            startedAt: ProcessInfo.processInfo.systemUptime
        )
    }

    private func loadRestoreCandidateIfNeeded() async {
        guard pendingInitialWorldMap == nil, !hasAttemptedRestore else {
            return
        }
        guard let worldMapRestoreProvider else {
            hasAttemptedRestore = true
            delegateProxy.emit(
                .worldMapRestoreSkipped(reason: "No world-map restore provider is configured.")
            )
            return
        }

        do {
            let candidate = try await worldMapRestoreProvider()
            guard !Task.isCancelled else {
                return
            }
            guard let candidate else {
                restoreFailureMessage = nil
                publishPersistenceFailure()
                hasAttemptedRestore = true
                delegateProxy.emit(.worldMapRestoreSkipped(reason: "No saved world map exists."))
                return
            }
            let archive = candidate.archive
            let transfer = try await Task.detached(priority: .userInitiated) {
                ImmutableWorldMapTransfer(try ARWorldMapArchiveCodec.unarchive(archive))
            }.value
            guard !Task.isCancelled else {
                return
            }
            hasAttemptedRestore = true
            pendingInitialWorldMap = transfer.value
            restoreFailureMessage = nil
            publishPersistenceFailure()
            captureIdentityBox.value = ARCaptureIdentity(
                coordinateFrameID: candidate.metadata.coordinateFrameID,
                segmentID: CaptureSegmentID(),
                mapID: candidate.metadata.mapID,
                status: .relocalizing
            )
            delegateProxy.emit(.worldMapRestoreLoaded)
        } catch {
            guard !Task.isCancelled else {
                return
            }
            hasAttemptedRestore = true
            restoreFailureMessage = String(localized: "storage.restore.failed")
            publishPersistenceFailure()
            delegateProxy.emit(
                .worldMapRestoreSkipped(reason: String(describing: error))
            )
        }
    }

    private func startRelocalizationTimeout(generation: UInt64) {
        relocalizationTimeoutTask?.cancel()
        relocalizationTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.relocalizationTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            if self.relocalizationStateMachine.timeout(generation: generation)
                == .startFreshSegment
            {
                self.startFreshSegmentAfterRelocalizationFailure()
            }
        }
    }

    private func startFreshSegmentAfterRelocalizationFailure() {
        relocalizationTimeoutTask?.cancel()
        relocalizationTimeoutTask = nil
        pendingInitialWorldMap = nil
        interruptionRecoveryOriginalIdentity = nil
        let preparedView = arView
        if let preparedView {
            // Seal the failed run before publishing a brand-new coordinate
            // identity. A callback from the old map must never inherit it.
            _ = prepareForSessionRun(preparedView)
        }
        let identity = ARCaptureIdentity(status: .newSegment)
        captureIdentityBox.value = identity
        delegateProxy.emit(.worldMapRelocalizationTimedOut)

        guard wantsActivation, let view = preparedView else {
            sessionIsRunning = false
            return
        }
        do {
            let result = try ARWorldTrackingConfigurationBuilder.make(
                options: configurationOptions,
                initialWorldMap: nil
            )
            capabilities = result.capabilities
            delegateProxy.activateCallbacks(for: view.session)
            view.session.run(
                result.configuration,
                options: [.resetTracking, .removeExistingAnchors]
            )
            delegateProxy.requestAuthoritativeSurfaceRepublish(afterNextFrame: true)
            sessionIsRunning = true
            sessionIsInterrupted = false
            state = .running
        } catch ARWorldTrackingConfigurationError.worldTrackingUnsupported {
            view.environment.background = .color(.black)
            state = .unavailable(reason: "AR world tracking is unsupported.")
        } catch {
            view.environment.background = .color(.black)
            state = .failed(message: String(describing: error))
        }
    }

    private func suspendRelocalizationForLifecycle() {
        relocalizationTimeoutTask?.cancel()
        relocalizationTimeoutTask = nil
        relocalizationStateMachine.cancel()
        // Keep the decoded initial map and provisional identity. Reactivation
        // reruns the same restore attempt with a fresh run generation.
        if sessionIsRunning, pendingInitialWorldMap == nil {
            let identity =
                interruptionRecoveryOriginalIdentity
                ?? captureIdentityBox.value
            interruptionRecoveryOriginalIdentity = identity
            _ = captureIdentityBox.transitionStatus(
                to: .relocalizing,
                matching: identity
            )
            delegateProxy.requestAuthoritativeSurfaceRepublish()
        }
    }

    private func invalidateCoordinateFrameForNewSession() {
        relocalizationTimeoutTask?.cancel()
        relocalizationTimeoutTask = nil
        relocalizationStateMachine.cancel()
        pendingInitialWorldMap = nil
        interruptionRecoveryOriginalIdentity = nil
        hasAttemptedRestore = false
        captureIdentityBox.value = ARCaptureIdentity(status: .newSegment)
    }

    private func finishActivation(generation: UInt64) {
        activationTask = nil
        // Reactivation may have been requested while an older cancelled task
        // was unwinding. Serialize the two attempts instead of allowing the
        // older task to race the replacement restore.
        if wantsActivation, generation != activationGeneration {
            startActivationIfPossible()
        }
    }

    private static func requestCameraPermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func startEventMonitoringIfNeeded() {
        guard eventMonitorTask == nil else {
            return
        }

        let events = delegateProxy.beginControllerEvents()
        eventMonitorTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled else {
                    return
                }
                self?.handleSessionEvent(event)
            }
        }
    }

    private func handleSessionEvent(_ event: ARSessionEvent) {
        defer { onCaptureIdentityChange?(captureIdentity) }
        switch event {
        case .interrupted(let context):
            guard sessionIsRunning, isCurrentSessionRunContext(context) else {
                return
            }
            sessionIsInterrupted = true
            relocalizationTimeoutTask?.cancel()
            relocalizationTimeoutTask = nil
            if case .awaitingNormal = relocalizationStateMachine.state {
                // Preserve an in-progress initial-map restore.
            } else {
                let identity = captureIdentityBox.value
                interruptionRecoveryOriginalIdentity = identity
                _ = relocalizationStateMachine.begin(
                    identity: identity,
                    sessionRunGeneration: context.generation
                )
                _ = captureIdentityBox.transitionStatus(
                    to: .relocalizing,
                    matching: identity
                )
                delegateProxy.requestAuthoritativeSurfaceRepublish()
            }
            arView?.environment.background = .color(.black)
            if arView != nil {
                state = .paused
            }
        case .interruptionEnded(let context):
            guard sessionIsInterrupted, isCurrentSessionRunContext(context) else {
                return
            }
            sessionIsInterrupted = false
            // ARKit resumes an interrupted configured session itself. Preserve
            // that session and never issue a duplicate run here.
            if sessionIsRunning {
                if wantsActivation {
                    arView?.environment.background = .cameraFeed()
                }
                state = wantsActivation ? .running : .paused
            }
            if case .awaitingNormal(let generation, _, _) = relocalizationStateMachine.state {
                // Time spent interrupted must not consume the relocalization
                // window. Give the resumed ARKit session a fresh full window.
                startRelocalizationTimeout(generation: generation)
            }
        case .trackingStateChanged(let trackingState, let context):
            guard isCurrentSessionFrameContext(context) else {
                return
            }
            switch relocalizationStateMachine.observe(
                trackingState,
                identity: context.captureIdentity,
                sessionRunGeneration: context.sessionRunGeneration
            ) {
            case .confirmed(let identity):
                guard
                    captureIdentityBox.transitionStatus(
                        to: .confirmed,
                        matching: identity
                    ) != nil
                else {
                    return
                }
                relocalizationTimeoutTask?.cancel()
                relocalizationTimeoutTask = nil
                pendingInitialWorldMap = nil
                interruptionRecoveryOriginalIdentity = nil
                delegateProxy.requestAuthoritativeSurfaceRepublish()
                delegateProxy.emit(.worldMapRelocalizationSucceeded)
            case .none, .startFreshSegment:
                if trackingState == .normal,
                    captureIdentityBox.value.status == .newSegment,
                    context.captureIdentity.coordinateFrameID
                        == captureIdentityBox.value.coordinateFrameID,
                    context.captureIdentity.segmentID == captureIdentityBox.value.segmentID
                {
                    let identity = captureIdentityBox.value
                    if captureIdentityBox.transitionStatus(
                        to: .confirmed,
                        matching: identity
                    ) != nil {
                        delegateProxy.requestAuthoritativeSurfaceRepublish()
                    }
                }
            }
        case .worldMappingStatusChanged(let mappingStatus, let context):
            let currentIdentity = captureIdentityBox.value
            if mappingStatus == .mapped,
                isCurrentSessionFrameContext(context),
                context.captureIdentity.coordinateFrameID == currentIdentity.coordinateFrameID,
                context.captureIdentity.segmentID == currentIdentity.segmentID,
                context.captureIdentity.mapID == currentIdentity.mapID
            {
                // Capture one active-session checkpoint as soon as the map is
                // stable; background remains a best-effort final refresh.
                enterBackground()
            }
        case .failed(_, let message, let context):
            guard sessionIsRunning, isCurrentSessionRunContext(context) else {
                return
            }
            if let view = arView {
                // Seal the failed run before publishing a replacement identity.
                // This also replaces any buffered surface map with an explicit
                // fail-closed snapshot.
                _ = prepareForSessionRun(view)
            }
            invalidateCoordinateFrameForNewSession()
            delegateProxy.requestAuthoritativeSurfaceRepublish()
            sessionIsInterrupted = false
            sessionIsRunning = false
            arView?.environment.background = .color(.black)
            state = .failed(message: message)
        case .worldMapArchiveFailed:
            saveFailureMessage = String(localized: "storage.save.failed")
            publishPersistenceFailure()
        case .snapshotCopyFailed,
            .surfaceSnapshotFailed,
            .worldMapArchiveCreated,
            .worldMapArchiveSkipped,
            .worldMapRestoreLoaded,
            .worldMapRestoreSkipped,
            .worldMapRelocalizationSucceeded,
            .worldMapRelocalizationTimedOut:
            break
        }
    }

    private func isCurrentSessionFrameContext(_ context: ARSessionFrameContext) -> Bool {
        let activeRun = sessionRunContextBox.value
        return context.sessionRunGeneration == activeRun.generation
            && context.frameTimestamp >= activeRun.startedAt
    }

    private func isCurrentSessionRunContext(_ context: ARSessionRunContext) -> Bool {
        context.generation == sessionRunContextBox.value.generation
    }

    deinit {
        temporalCaptureGate.value = false
        activationTask?.cancel()
        eventMonitorTask?.cancel()
        relocalizationTimeoutTask?.cancel()
        for cancellation in worldMapCheckpointCancellations.values {
            cancellation.cancel()
        }
        for task in worldMapPersistenceTasks.values {
            task.cancel()
        }
        delegateProxy.endControllerEvents()
    }
}

/// ARKit frame timestamps share the uptime clock used by session-run guards.
/// An unchanged last frame must not freeze the clock used to expire evidence.
enum ARNavigationEvaluationClock {
    static func timestamp(frameTimestamp: TimeInterval, systemUptime: TimeInterval) -> TimeInterval? {
        guard frameTimestamp.isFinite, systemUptime.isFinite,
            frameTimestamp >= 0, systemUptime >= frameTimestamp,
            systemUptime - frameTimestamp <= 1
        else { return nil }
        return systemUptime
    }
}

private final class WorldMapCheckpointGate: @unchecked Sendable {
    enum Decision {
        case accepted
        case inFlight
        case tooRecent
    }

    private let lock = NSLock()
    private var isInFlight = false
    private var lastRequestTime: TimeInterval?

    func begin(requestTime: TimeInterval) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        if isInFlight {
            return .inFlight
        }
        if let lastRequestTime, requestTime - lastRequestTime < 5 {
            return .tooRecent
        }
        isInFlight = true
        lastRequestTime = requestTime
        return .accepted
    }

    func finish() {
        lock.lock()
        isInFlight = false
        lock.unlock()
    }
}

private final class WorldMapCheckpointCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

@MainActor
private final class BackgroundTaskLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin(expirationHandler: @escaping @Sendable () -> Void) {
        guard identifier == .invalid else {
            return
        }
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Vispace world-map checkpoint"
        ) { [weak self] in
            // UIKit invokes this handler on the main thread. End the task
            // before returning so expiration cannot strand the checkpoint gate
            // or invite process termination while cleanup is merely queued.
            MainActor.assumeIsolated {
                expirationHandler()
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else {
            return
        }
        let activeIdentifier = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(activeIdentifier)
    }
}

private final class WorldMapCheckpointCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private let gate: WorldMapCheckpointGate
    private let backgroundTaskLease: BackgroundTaskLease
    private let onFinish: @Sendable () -> Void

    init(
        gate: WorldMapCheckpointGate,
        backgroundTaskLease: BackgroundTaskLease,
        onFinish: @escaping @Sendable () -> Void = {}
    ) {
        self.gate = gate
        self.backgroundTaskLease = backgroundTaskLease
        self.onFinish = onFinish
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()

        gate.finish()
        onFinish()
        Task { @MainActor [backgroundTaskLease] in
            backgroundTaskLease.end()
        }
    }

    func endBackgroundExecution() {
        Task { @MainActor [backgroundTaskLease] in
            backgroundTaskLease.end()
        }
    }
}

/// `getCurrentWorldMap` returns an immutable point-in-time map intended by
/// Apple for off-queue archiving. This wrapper makes that one-way ownership
/// transfer explicit to Swift's strict concurrency checker.
private final class ImmutableWorldMapTransfer: @unchecked Sendable {
    let value: ARWorldMap

    init(_ value: ARWorldMap) {
        self.value = value
    }
}

private final class FrameImageOrientationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: FrameImageOrientation

    init(_ value: FrameImageOrientation) {
        storedValue = value
    }

    var value: FrameImageOrientation {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private final class ARTemporalCaptureRunningGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isRunning = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return isRunning
        }
        set {
            lock.lock()
            isRunning = newValue
            lock.unlock()
        }
    }
}

private final class ARSessionRunContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = ARSessionRunContext(generation: 0, startedAt: 0)

    var value: ARSessionRunContext {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func advance(startedAt: TimeInterval) -> ARSessionRunContext {
        lock.lock()
        storedValue = ARSessionRunContext(
            generation: storedValue.generation &+ 1,
            startedAt: startedAt
        )
        let value = storedValue
        lock.unlock()
        return value
    }
}
