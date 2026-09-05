@preconcurrency import ARKit
import Foundation

public struct ARSessionFrameContext: Equatable, Sendable {
    public let captureIdentity: ARCaptureIdentity
    public let sessionRunGeneration: UInt64
    public let frameTimestamp: TimeInterval
}

public struct ARSessionRunContext: Equatable, Sendable {
    public let generation: UInt64
    public let startedAt: TimeInterval

    public init(generation: UInt64, startedAt: TimeInterval) {
        self.generation = generation
        self.startedAt = startedAt
    }
}

public enum ARSessionEvent: Equatable, Sendable {
    case interrupted(context: ARSessionRunContext)
    case interruptionEnded(context: ARSessionRunContext)
    case failed(code: Int, message: String, context: ARSessionRunContext)
    case trackingStateChanged(ARTrackingStateSnapshot, context: ARSessionFrameContext)
    case worldMappingStatusChanged(ARWorldMappingStatusSnapshot, context: ARSessionFrameContext)
    case snapshotCopyFailed(message: String)
    case surfaceSnapshotFailed(message: String)
    case worldMapArchiveCreated(byteCount: Int)
    case worldMapArchiveSkipped(reason: String)
    case worldMapArchiveFailed(message: String)
    case worldMapRestoreLoaded
    case worldMapRestoreSkipped(reason: String)
    case worldMapRelocalizationSucceeded
    case worldMapRelocalizationTimedOut
}

/// Bridges Objective-C ARSession callbacks into bounded Sendable streams.
/// The proxy must be retained by its owner because ARSession.delegate is weak.
public final class ARSessionDelegateProxy: NSObject, ARSessionDelegate, @unchecked Sendable {
    public let poseChannel = LatestValueChannel<ARPoseSnapshot>()
    public let frameChannel = LatestValueChannel<ARFrameSnapshot>()
    public let surfaceChannel = LatestValueChannel<ARSurfaceStateSnapshot>()
    public let eventChannel = LatestValueChannel<ARSessionEvent>(bufferLimit: 16)

    public var poses: AsyncStream<ARPoseSnapshot> { poseChannel.stream }
    public var frames: AsyncStream<ARFrameSnapshot> { frameChannel.stream }
    public var surfaces: AsyncStream<ARSurfaceStateSnapshot> { surfaceChannel.stream }
    public var events: AsyncStream<ARSessionEvent> { eventChannel.stream }
    public var snapshotCaptureEnabled: Bool {
        get { snapshotCaptureGate.isEnabled }
        set {
            snapshotCaptureGate.isEnabled = newValue
            if !newValue {
                cadenceGate.reset()
            }
        }
    }
    public var surfaceCaptureEnabled: Bool {
        get { surfaceCaptureGate.isEnabled }
        set {
            surfaceCommitLock.lock()
            defer { surfaceCommitLock.unlock() }
            surfaceCaptureGate.isEnabled = newValue
            if !newValue {
                invalidateSurfaceStateLocked()
            }
        }
    }

    private let adapter: ARFrameSnapshotAdapter
    private let cadenceGate: SnapshotCadenceGate
    private let snapshotCaptureGate: SnapshotCaptureGate
    private let surfaceCaptureGate: SnapshotCaptureGate
    private let imageOrientationProvider: @Sendable () -> FrameImageOrientation
    private let captureIdentityProvider: @Sendable () -> ARCaptureIdentity
    private let sessionRunContextProvider: @Sendable () -> ARSessionRunContext
    private let displayGeometryProvider: @Sendable () -> FrameDisplayGeometry?
    private let trackingStateGate = TrackingStateChangeGate()
    private let worldMappingStatusGate = WorldMappingStatusChangeGate()
    private let surfaceAdapter = ARSurfaceObservationAdapter()
    private let surfaceAccumulator = ARSurfaceStateAccumulator()
    private let surfaceCommitLock = NSLock()
    private let activeSessionLock = NSLock()
    private weak var activeSession: ARSession?
    private var activeAttachmentEpoch: UInt64 = 0
    private let controllerEventLock = NSLock()
    private var controllerEventChannel: ControllerEventChannel?
    private let surfaceProcessingQueue = DispatchQueue(
        label: "com.l3j.vispace.arkit.surface-processing",
        qos: .utility
    )
    private let surfaceProcessingLock = NSLock()
    private var surfaceProcessingIsInFlight = false
    private var pendingSurfaceProcessingRequest: SurfaceProcessingRequest?
    private let surfaceUpdateLock = NSLock()
    private var surfaceDelegateQueue: DispatchQueue?
    private var lastSurfaceUpdateTimestamp: TimeInterval?
    private var pendingSurfaceUpdate: DispatchWorkItem?
    private var surfaceIdentityRepublishEpoch: UInt64?
    private var surfaceScheduleGeneration: UInt64 = 0
    private let minimumSurfaceUpdateInterval: TimeInterval = 0.5

    public init(
        maximumSnapshotFramesPerSecond: Double = 10,
        snapshotCaptureEnabled: Bool = false,
        surfaceCaptureEnabled: Bool = false,
        imageOrientationProvider: @escaping @Sendable () -> FrameImageOrientation,
        captureIdentityProvider: @escaping @Sendable () -> ARCaptureIdentity,
        sessionRunContextProvider: @escaping @Sendable () -> ARSessionRunContext,
        displayGeometryProvider: @escaping @Sendable () -> FrameDisplayGeometry?
    ) {
        adapter = ARFrameSnapshotAdapter()
        cadenceGate = SnapshotCadenceGate(
            maximumFramesPerSecond: maximumSnapshotFramesPerSecond
        )
        snapshotCaptureGate = SnapshotCaptureGate(isEnabled: snapshotCaptureEnabled)
        surfaceCaptureGate = SnapshotCaptureGate(isEnabled: surfaceCaptureEnabled)
        self.imageOrientationProvider = imageOrientationProvider
        self.captureIdentityProvider = captureIdentityProvider
        self.sessionRunContextProvider = sessionRunContextProvider
        self.displayGeometryProvider = displayGeometryProvider
        super.init()
    }

    @MainActor
    public func install(on session: ARSession, delegateQueue: DispatchQueue) {
        session.delegateQueue = delegateQueue
        surfaceUpdateLock.lock()
        surfaceDelegateQueue = delegateQueue
        surfaceUpdateLock.unlock()
        activateCallbacks(for: session)
        surfaceCommitLock.lock()
        invalidateSurfaceStateLocked()
        surfaceCommitLock.unlock()
        session.delegate = self
    }

    @MainActor
    public func uninstall(from session: ARSession) {
        invalidateCallbacks(from: session)
        if session.delegate === self {
            session.delegate = nil
            session.delegateQueue = nil
        }
        cadenceGate.reset()
        trackingStateGate.reset()
        worldMappingStatusGate.reset()
        surfaceCommitLock.lock()
        invalidateSurfaceStateLocked(clearQueue: true)
        surfaceCommitLock.unlock()
    }

    func activateCallbacks(for session: ARSession) {
        activeSessionLock.lock()
        activeAttachmentEpoch &+= 1
        activeSession = session
        activeSessionLock.unlock()
    }

    func invalidateCallbacks(from session: ARSession) {
        activeSessionLock.lock()
        if activeSession === session {
            activeSession = nil
            activeAttachmentEpoch &+= 1
        }
        activeSessionLock.unlock()
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let frameID = ARFrameID()
        guard let callbackContext = callbackContext(for: session) else {
            return
        }
        let runContext = callbackContext.runContext
        // A frame produced before the current run can be delivered after an
        // ARSession reset. Never let that stale tracking result confirm the
        // new run's coordinate frame or suppress its first state transition.
        guard frame.timestamp >= runContext.startedAt else {
            return
        }
        let captureIdentity = captureIdentityProvider()
        let sessionToken = ARSessionFrameToken(
            sessionRunGeneration: runContext.generation,
            attachmentEpoch: callbackContext.attachmentEpoch
        )
        let capturedAt = Date().timeIntervalSince1970
        let context = ARSessionFrameContext(
            captureIdentity: captureIdentity,
            sessionRunGeneration: runContext.generation,
            frameTimestamp: frame.timestamp
        )
        publishSurfaceIdentityOnNextFrameIfNeeded(
            from: frame.anchors,
            attachmentEpoch: callbackContext.attachmentEpoch
        )
        let pose = adapter.makePose(
            from: frame,
            id: frameID,
            sessionToken: sessionToken,
            capturedAt: capturedAt,
            captureIdentity: captureIdentity
        )
        poseChannel.send(pose)
        if trackingStateGate.shouldEmit(pose.trackingState) {
            emit(.trackingStateChanged(pose.trackingState, context: context))
        }
        if worldMappingStatusGate.shouldEmit(pose.worldMappingStatus) {
            emit(.worldMappingStatusChanged(pose.worldMappingStatus, context: context))
        }

        guard snapshotCaptureGate.isEnabled else {
            return
        }
        guard cadenceGate.admits(timestamp: frame.timestamp) else {
            return
        }

        do {
            let snapshot = try adapter.makeSnapshot(
                from: frame,
                id: frameID,
                imageOrientation: imageOrientationProvider(),
                sessionToken: sessionToken,
                capturedAt: capturedAt,
                captureIdentity: captureIdentity,
                displayGeometry: displayGeometryProvider()
            )
            frameChannel.send(snapshot)
        } catch {
            emit(.snapshotCopyFailed(message: String(describing: error)))
        }
    }

    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard let attachmentEpoch = activeAttachmentEpoch(for: session) else {
            return
        }
        publishCurrentSurfaceState(
            session: session,
            fallbackAnchors: anchors,
            fallbackChange: .added,
            attachmentEpoch: attachmentEpoch
        )
    }

    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let attachmentEpoch = activeAttachmentEpoch(for: session) else {
            return
        }
        publishCoalescedSurfaceState(
            from: anchors,
            session: session,
            attachmentEpoch: attachmentEpoch
        )
    }

    public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        guard let attachmentEpoch = activeAttachmentEpoch(for: session) else {
            return
        }
        publishCurrentSurfaceState(
            session: session,
            fallbackAnchors: anchors,
            fallbackChange: .removed,
            attachmentEpoch: attachmentEpoch
        )
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        // An ARKit interruption is already equivalent to pause(). Calling pause
        // here would prevent the normal interruption-ended notification.
        guard let context = runContext(for: session) else {
            return
        }
        emit(.interrupted(context: context))
    }

    public func sessionInterruptionEnded(_ session: ARSession) {
        guard let context = runContext(for: session) else {
            return
        }
        cadenceGate.reset()
        trackingStateGate.reset()
        emit(.interruptionEnded(context: context))
    }

    public func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        // This controller preserves coordinate-frame identity across an
        // interruption, so opting out would violate that identity contract.
        isActive(session)
    }

    public func session(_ session: ARSession, didFailWithError error: any Error) {
        guard let context = runContext(for: session) else {
            return
        }
        let nsError = error as NSError
        emit(
            .failed(
                code: nsError.code,
                message: nsError.localizedDescription,
                context: context
            )
        )
    }

    /// Invalidates queued geometry carrying old coordinate metadata, then emits
    /// an authoritative snapshot for the new identity. The live ARSession is
    /// touched only on its delegate queue.
    func requestAuthoritativeSurfaceRepublish(afterNextFrame: Bool = false) {
        surfaceCommitLock.lock()
        invalidateSurfaceStateLocked()
        surfaceCommitLock.unlock()

        if afterNextFrame {
            guard let attachment = activeSessionSnapshot() else {
                return
            }
            surfaceUpdateLock.lock()
            surfaceIdentityRepublishEpoch = attachment.epoch
            surfaceUpdateLock.unlock()
            return
        }

        surfaceUpdateLock.lock()
        let queue = surfaceDelegateQueue
        surfaceUpdateLock.unlock()
        guard let attachment = activeSessionSnapshot() else {
            return
        }
        let attachmentEpoch = attachment.epoch
        queue?.async { [weak self, weak session = attachment.session] in
            guard
                let self,
                let session,
                self.surfaceCaptureGate.isEnabled,
                self.isActive(session, attachmentEpoch: attachmentEpoch)
            else {
                return
            }
            self.publishSurfaceState(
                from: session.currentFrame?.anchors ?? [],
                change: .updated,
                isAuthoritative: true,
                attachmentEpoch: attachmentEpoch
            )
        }
    }

    private func publishSurfaceIdentityOnNextFrameIfNeeded(
        from anchors: [ARAnchor],
        attachmentEpoch: UInt64
    ) {
        surfaceUpdateLock.lock()
        let shouldPublish = surfaceIdentityRepublishEpoch == attachmentEpoch
        if shouldPublish {
            surfaceIdentityRepublishEpoch = nil
        }
        surfaceUpdateLock.unlock()
        guard shouldPublish else {
            return
        }
        publishSurfaceState(
            from: anchors,
            change: .updated,
            isAuthoritative: true,
            attachmentEpoch: attachmentEpoch
        )
    }

    private func isActive(_ session: ARSession) -> Bool {
        activeSessionLock.lock()
        defer { activeSessionLock.unlock() }
        return activeSession === session
    }

    private func isActive(_ session: ARSession, attachmentEpoch: UInt64) -> Bool {
        activeSessionLock.lock()
        defer { activeSessionLock.unlock() }
        return activeSession === session && activeAttachmentEpoch == attachmentEpoch
    }

    private func activeAttachmentEpoch(for session: ARSession) -> UInt64? {
        activeSessionLock.lock()
        defer { activeSessionLock.unlock() }
        guard activeSession === session else {
            return nil
        }
        return activeAttachmentEpoch
    }

    private func runContext(for session: ARSession) -> ARSessionRunContext? {
        callbackContext(for: session)?.runContext
    }

    private func callbackContext(for session: ARSession) -> ActiveSessionCallbackContext? {
        activeSessionLock.lock()
        defer { activeSessionLock.unlock() }
        guard activeSession === session else {
            return nil
        }
        // Capture both tokens while membership is locked. A callback that
        // outlives uninstall/reinstall cannot be reassigned to a later run.
        return ActiveSessionCallbackContext(
            runContext: sessionRunContextProvider(),
            attachmentEpoch: activeAttachmentEpoch
        )
    }

    private func activeSessionSnapshot() -> ActiveSessionAttachment? {
        activeSessionLock.lock()
        defer { activeSessionLock.unlock() }
        guard let activeSession else {
            return nil
        }
        return ActiveSessionAttachment(
            session: activeSession,
            epoch: activeAttachmentEpoch
        )
    }

    /// Returns the token of the currently attached ARSession run. Consumers of
    /// buffered or asynchronous frame work must compare this token again after
    /// processing because Vision requests cannot be synchronously cancelled.
    func currentFrameToken() -> ARSessionFrameToken? {
        activeSessionLock.lock()
        defer { activeSessionLock.unlock() }
        guard activeSession != nil else {
            return nil
        }
        return ARSessionFrameToken(
            sessionRunGeneration: sessionRunContextProvider().generation,
            attachmentEpoch: activeAttachmentEpoch
        )
    }

    func emit(_ event: ARSessionEvent) {
        eventChannel.send(event)

        // Diagnostic volume must never evict lifecycle state used by the
        // controller. Tracking and mapping changes are already change-gated,
        // so this dedicated unbounded stream remains small and lossless.
        switch event {
        case .interrupted,
            .interruptionEnded,
            .failed,
            .trackingStateChanged,
            .worldMappingStatusChanged,
            .worldMapArchiveFailed:
            break
        case .snapshotCopyFailed,
            .surfaceSnapshotFailed,
            .worldMapArchiveCreated,
            .worldMapArchiveSkipped,
            .worldMapRestoreLoaded,
            .worldMapRestoreSkipped,
            .worldMapRelocalizationSucceeded,
            .worldMapRelocalizationTimedOut:
            return
        }

        controllerEventLock.lock()
        let controllerEventChannel = controllerEventChannel
        controllerEventLock.unlock()
        controllerEventChannel?.send(event)
    }

    private func publishSurfaceState(
        from anchors: [ARAnchor],
        change: ARSurfaceObservationChange,
        isAuthoritative: Bool = false,
        attachmentEpoch: UInt64
    ) {
        guard
            surfaceCaptureGate.isEnabled,
            activeAttachmentEpochIsCurrent(attachmentEpoch)
        else {
            return
        }
        surfaceUpdateLock.lock()
        let generation = surfaceScheduleGeneration
        surfaceUpdateLock.unlock()
        let timestamp = ProcessInfo.processInfo.systemUptime
        let rawCapture = surfaceAdapter.makeRawCapture(
            from: anchors,
            change: change,
            captureIdentity: captureIdentityProvider(),
            timestamp: timestamp,
            isAuthoritative: isAuthoritative
        )
        let request = SurfaceProcessingRequest(
            rawCapture: rawCapture,
            generation: generation,
            attachmentEpoch: attachmentEpoch
        )

        surfaceProcessingLock.lock()
        if surfaceProcessingIsInFlight {
            pendingSurfaceProcessingRequest = request
            surfaceProcessingLock.unlock()
            return
        }
        surfaceProcessingIsInFlight = true
        surfaceProcessingLock.unlock()
        surfaceProcessingQueue.async { [weak self] in
            self?.processSurfaceState(request)
        }
    }

    private func processSurfaceState(_ request: SurfaceProcessingRequest) {
        defer { finishSurfaceProcessingRequest() }
        guard surfaceRequestIsCurrent(request) else {
            return
        }
        let batch = surfaceAdapter.makeObservations(
            from: request.rawCapture
        )
        surfaceCommitLock.lock()
        defer { surfaceCommitLock.unlock() }
        guard surfaceRequestIsCurrent(request) else {
            return
        }
        for failure in batch.failures {
            emit(
                .surfaceSnapshotFailed(
                    message: "\(failure.anchorID.uuidString): \(failure.error)"
                )
            )
        }
        if let state = surfaceAccumulator.applying(batch) {
            surfaceChannel.send(state)
        }
    }

    private func finishSurfaceProcessingRequest() {
        surfaceProcessingLock.lock()
        guard let next = pendingSurfaceProcessingRequest else {
            surfaceProcessingIsInFlight = false
            surfaceProcessingLock.unlock()
            return
        }
        pendingSurfaceProcessingRequest = nil
        surfaceProcessingLock.unlock()
        surfaceProcessingQueue.async { [weak self] in
            self?.processSurfaceState(next)
        }
    }

    private func surfaceRequestIsCurrent(_ request: SurfaceProcessingRequest) -> Bool {
        guard surfaceCaptureGate.isEnabled else {
            return false
        }
        surfaceUpdateLock.lock()
        let isCurrent = request.generation == surfaceScheduleGeneration
        surfaceUpdateLock.unlock()
        guard isCurrent, activeAttachmentEpochIsCurrent(request.attachmentEpoch) else {
            return false
        }
        return request.rawCapture.captureIdentity == captureIdentityProvider()
    }

    private func activeAttachmentEpochIsCurrent(_ attachmentEpoch: UInt64) -> Bool {
        activeSessionLock.lock()
        defer { activeSessionLock.unlock() }
        return activeSession != nil && activeAttachmentEpoch == attachmentEpoch
    }

    private func publishCurrentSurfaceState(
        session: ARSession,
        fallbackAnchors: [ARAnchor],
        fallbackChange: ARSurfaceObservationChange,
        attachmentEpoch: UInt64
    ) {
        guard isActive(session, attachmentEpoch: attachmentEpoch) else {
            return
        }
        if let currentAnchors = session.currentFrame?.anchors {
            publishSurfaceState(
                from: currentAnchors,
                change: .updated,
                isAuthoritative: true,
                attachmentEpoch: attachmentEpoch
            )
        } else {
            publishSurfaceState(
                from: fallbackAnchors,
                change: fallbackChange,
                attachmentEpoch: attachmentEpoch
            )
        }
    }

    /// Mesh parsing is expensive. Reconcile immediately at most twice per
    /// second, then process the newest complete anchor list on the trailing
    /// edge so the coalesced state does not become permanently stale.
    private func publishCoalescedSurfaceState(
        from fallbackAnchors: [ARAnchor],
        session: ARSession,
        attachmentEpoch: UInt64
    ) {
        guard surfaceCaptureGate.isEnabled else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        var publishesImmediately = false

        surfaceUpdateLock.lock()
        if pendingSurfaceUpdate == nil,
            lastSurfaceUpdateTimestamp.map({
                now - $0 >= minimumSurfaceUpdateInterval
            }) ?? true
        {
            lastSurfaceUpdateTimestamp = now
            publishesImmediately = true
        } else if pendingSurfaceUpdate == nil, let queue = surfaceDelegateQueue {
            let elapsed = now - (lastSurfaceUpdateTimestamp ?? now)
            let delay = max(0, minimumSurfaceUpdateInterval - elapsed)
            let generation = surfaceScheduleGeneration
            let work = DispatchWorkItem { [weak self, weak session] in
                self?.performTrailingSurfaceUpdate(
                    session: session,
                    generation: generation,
                    attachmentEpoch: attachmentEpoch
                )
            }
            pendingSurfaceUpdate = work
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
        surfaceUpdateLock.unlock()

        if publishesImmediately {
            publishCurrentSurfaceState(
                session: session,
                fallbackAnchors: fallbackAnchors,
                fallbackChange: .updated,
                attachmentEpoch: attachmentEpoch
            )
        }
    }

    private func performTrailingSurfaceUpdate(
        session: ARSession?,
        generation: UInt64,
        attachmentEpoch: UInt64
    ) {
        surfaceUpdateLock.lock()
        guard generation == surfaceScheduleGeneration else {
            surfaceUpdateLock.unlock()
            return
        }
        pendingSurfaceUpdate = nil
        lastSurfaceUpdateTimestamp = ProcessInfo.processInfo.systemUptime
        surfaceUpdateLock.unlock()

        guard
            surfaceCaptureGate.isEnabled,
            let session,
            isActive(session, attachmentEpoch: attachmentEpoch),
            let anchors = session.currentFrame?.anchors
        else {
            return
        }
        publishSurfaceState(
            from: anchors,
            change: .updated,
            isAuthoritative: true,
            attachmentEpoch: attachmentEpoch
        )
    }

    private func resetSurfaceUpdateScheduling(clearQueue: Bool = false) {
        surfaceUpdateLock.lock()
        surfaceScheduleGeneration &+= 1
        pendingSurfaceUpdate?.cancel()
        pendingSurfaceUpdate = nil
        surfaceIdentityRepublishEpoch = nil
        lastSurfaceUpdateTimestamp = nil
        if clearQueue {
            surfaceDelegateQueue = nil
        }
        surfaceUpdateLock.unlock()
        surfaceProcessingLock.lock()
        pendingSurfaceProcessingRequest = nil
        surfaceProcessingLock.unlock()
    }

    /// Creates one lifecycle-consumer stream for the current attachment. The
    /// prior stream is finished so detach/reattach never accumulates monitors.
    func beginControllerEvents() -> AsyncStream<ARSessionEvent> {
        let channel = ControllerEventChannel()
        controllerEventLock.lock()
        let previous = controllerEventChannel
        controllerEventChannel = channel
        controllerEventLock.unlock()
        previous?.finish()
        return channel.stream
    }

    func endControllerEvents() {
        controllerEventLock.lock()
        let channel = controllerEventChannel
        controllerEventChannel = nil
        controllerEventLock.unlock()
        channel?.finish()
    }

    func resetObservationGatesForNewRun() {
        trackingStateGate.reset()
        worldMappingStatusGate.reset()
        surfaceCommitLock.lock()
        invalidateSurfaceStateLocked()
        surfaceCommitLock.unlock()
    }

    /// Must be called while `surfaceCommitLock` is held so a decoded batch
    /// cannot repopulate the accumulator between reset and invalid publication.
    private func invalidateSurfaceStateLocked(clearQueue: Bool = false) {
        resetSurfaceUpdateScheduling(clearQueue: clearQueue)
        let invalid = surfaceAccumulator.invalidated(
            captureIdentity: captureIdentityProvider(),
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        surfaceChannel.send(invalid)
    }

    deinit {
        poseChannel.finish()
        frameChannel.finish()
        surfaceChannel.finish()
        eventChannel.finish()
        endControllerEvents()
    }
}

/// A lossless channel reserved for the small, change-gated set of events that
/// drives controller lifecycle state. High-volume diagnostics use the bounded
/// public event channel instead.
private final class ControllerEventChannel: @unchecked Sendable {
    let stream: AsyncStream<ARSessionEvent>

    private let continuation: AsyncStream<ARSessionEvent>.Continuation

    init() {
        let pair = AsyncStream<ARSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        stream = pair.stream
        continuation = pair.continuation
    }

    func send(_ event: ARSessionEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }
}

/// Only app-owned bytes cross from ARKit's delegate queue to this worker. The
/// in-flight plus latest-pending policy bounds retained raw batches at two.
private struct SurfaceProcessingRequest: Sendable {
    let rawCapture: ARSurfaceRawCaptureBatch
    let generation: UInt64
    let attachmentEpoch: UInt64
}

private struct ActiveSessionCallbackContext {
    let runContext: ARSessionRunContext
    let attachmentEpoch: UInt64
}

private struct ActiveSessionAttachment {
    let session: ARSession
    let epoch: UInt64
}

final class TrackingStateChangeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: ARTrackingStateSnapshot?

    func shouldEmit(_ value: ARTrackingStateSnapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value != previous else {
            return false
        }
        previous = value
        return true
    }

    func reset() {
        lock.lock()
        previous = nil
        lock.unlock()
    }
}

final class WorldMappingStatusChangeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: ARWorldMappingStatusSnapshot?

    func shouldEmit(_ value: ARWorldMappingStatusSnapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value != previous else {
            return false
        }
        previous = value
        return true
    }

    func reset() {
        lock.lock()
        previous = nil
        lock.unlock()
    }
}

/// Internal so the lock semantics can be unit-tested without constructing ARFrame.
final class SnapshotCaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(isEnabled: Bool) {
        storedValue = isEnabled
    }

    var isEnabled: Bool {
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
