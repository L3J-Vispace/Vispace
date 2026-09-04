@preconcurrency import ARKit
@preconcurrency import AVFoundation
import Combine
import Foundation
import RealityKit

public enum ARSessionControllerState: Equatable, Sendable {
    case detached
    case waitingForCameraPermission
    case ready
    case running
    case paused
    case unavailable(reason: String)
    case failed(message: String)
}

/// Owns the app's single ARSession and camera lifecycle.
///
/// The UI layer only supplies the camera-backed `ARView`. Camera pixels leave
/// the ARKit callback solely as bounded, deep-copied, in-memory snapshots and
/// this controller never exposes an API that can persist them.
@MainActor
public final class ARSessionController: ObservableObject, CameraSessionControlling {
    public typealias WorldMapArchiveHandler = @Sendable (Data) async throws -> Void

    @Published public private(set) var state: ARSessionControllerState = .detached
    @Published public private(set) var capabilities: ARCaptureCapabilities?

    public var poses: AsyncStream<ARPoseSnapshot> { delegateProxy.poses }
    public var frames: AsyncStream<ARFrameSnapshot> { delegateProxy.frames }
    public var events: AsyncStream<ARSessionEvent> { delegateProxy.events }

    private weak var arView: ARView?
    private let delegateQueue: DispatchQueue
    private let worldMapArchiveQueue: DispatchQueue
    private let delegateProxy: ARSessionDelegateProxy
    private let imageOrientation: FrameImageOrientationBox
    private let configurationOptions: ARWorldTrackingOptions
    private let worldMapArchiveHandler: WorldMapArchiveHandler?
    #if DEBUG
        private let isSessionDisabledForTesting: Bool
    #endif

    private var activationTask: Task<Void, Never>?
    private var activationGeneration: UInt64 = 0
    private var eventMonitorTask: Task<Void, Never>?
    private var wantsActivation = false
    private var sessionIsRunning = false
    private var sessionIsInterrupted = false
    private var pendingInitialWorldMap: ARWorldMap?

    public init(
        configurationOptions: ARWorldTrackingOptions = .productionDefault,
        maximumSnapshotFramesPerSecond: Double = 10,
        attemptsRelocalization: Bool = true,
        worldMapArchiveHandler: WorldMapArchiveHandler? = nil
    ) {
        let imageOrientation = FrameImageOrientationBox(.right)
        self.imageOrientation = imageOrientation
        self.configurationOptions = configurationOptions
        self.worldMapArchiveHandler = worldMapArchiveHandler
        #if DEBUG
            isSessionDisabledForTesting = ProcessInfo.processInfo.arguments.contains(
                "-VispaceDisableARSession"
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
            attemptsRelocalization: attemptsRelocalization,
            imageOrientationProvider: { imageOrientation.value }
        )
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
        view.environment.background = .color(.black)
        delegateProxy.uninstall(from: view.session)
        eventMonitorTask?.cancel()
        eventMonitorTask = nil
        delegateProxy.endControllerEvents()
        arView = nil
        sessionIsRunning = false
        sessionIsInterrupted = false
        wantsActivation = false
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
        arView?.session.pause()
        arView?.environment.background = .color(.black)
        sessionIsRunning = false
        sessionIsInterrupted = false
        state = arView == nil ? .detached : .paused
    }

    /// Requests a checkpoint from the most recent fully mapped session when a
    /// persistence policy has explicitly supplied an archive handler.
    public func enterBackground() {
        guard
            let handler = worldMapArchiveHandler,
            let session = arView?.session,
            session.currentFrame?.worldMappingStatus == .mapped
        else {
            delegateProxy.emit(
                .worldMapArchiveSkipped(
                    reason: worldMapArchiveHandler == nil
                        ? "No world-map persistence handler is configured."
                        : "World mapping has not reached the mapped state."
                )
            )
            return
        }

        session.getCurrentWorldMap { [delegateProxy, worldMapArchiveQueue] worldMap, error in
            if let error {
                delegateProxy.emit(.worldMapArchiveFailed(message: error.localizedDescription))
                return
            }
            guard let worldMap else {
                delegateProxy.emit(
                    .worldMapArchiveFailed(message: "ARKit returned no world map.")
                )
                return
            }

            let transfer = ImmutableWorldMapTransfer(worldMap)
            worldMapArchiveQueue.async {
                do {
                    let archive = try ARWorldMapArchiveCodec.archive(transfer.value)
                    delegateProxy.emit(.worldMapArchiveCreated(byteCount: archive.count))
                    Task {
                        do {
                            try await handler(archive)
                        } catch {
                            delegateProxy.emit(
                                .worldMapArchiveFailed(message: String(describing: error))
                            )
                        }
                    }
                } catch {
                    delegateProxy.emit(
                        .worldMapArchiveFailed(message: String(describing: error))
                    )
                }
            }
        }
    }

    /// Updates the EXIF orientation copied into subsequent Vision snapshots.
    /// Portrait is `.right` for the unrotated iPhone camera sensor.
    public func setImageOrientation(_ orientation: FrameImageOrientation) {
        imageOrientation.value = orientation
    }

    /// Opts into expensive RGB/depth copies for an active perception consumer.
    /// The camera-only shipping path leaves this disabled, so frame callbacks
    /// publish pose only and perform zero pixel-buffer copies.
    public func setFrameSnapshotsEnabled(_ isEnabled: Bool) {
        delegateProxy.snapshotCaptureEnabled = isEnabled
    }

    /// Securely decodes an application-owned map archive and applies it the
    /// next time the session is run. Pixels are not part of ARWorldMap data.
    public func prepareToRelocalize(from archive: Data) throws {
        pendingInitialWorldMap = try ARWorldMapArchiveCodec.unarchive(archive)
        sessionIsRunning = false
        if wantsActivation {
            startActivationIfPossible()
        }
    }

    private func startActivationIfPossible() {
        guard wantsActivation, let view = arView else {
            if arView == nil {
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
                self.state = .unavailable(reason: "Camera access is required.")
                return
            }
            guard let view, self.arView === view else {
                self.state = .detached
                return
            }

            do {
                let result = try ARWorldTrackingConfigurationBuilder.make(
                    options: self.configurationOptions,
                    initialWorldMap: self.pendingInitialWorldMap
                )
                let runOptions: ARSession.RunOptions =
                    self.pendingInitialWorldMap == nil
                    ? []
                    : [.resetTracking, .removeExistingAnchors]

                self.capabilities = result.capabilities
                view.environment.background = .cameraFeed()
                view.session.run(result.configuration, options: runOptions)
                self.pendingInitialWorldMap = nil
                self.sessionIsRunning = true
                self.sessionIsInterrupted = false
                self.state = .running
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
        activationTask = nil
    }

    private func finishActivation(generation: UInt64) {
        guard activationGeneration == generation else {
            return
        }
        activationTask = nil
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
        switch event {
        case .interrupted:
            sessionIsInterrupted = true
            arView?.environment.background = .color(.black)
            if arView != nil {
                state = .paused
            }
        case .interruptionEnded:
            guard sessionIsInterrupted else {
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
        case .failed(_, let message):
            sessionIsInterrupted = false
            sessionIsRunning = false
            arView?.environment.background = .color(.black)
            state = .failed(message: message)
        case .snapshotCopyFailed,
            .worldMapArchiveCreated,
            .worldMapArchiveSkipped,
            .worldMapArchiveFailed:
            break
        }
    }

    deinit {
        activationTask?.cancel()
        eventMonitorTask?.cancel()
        delegateProxy.endControllerEvents()
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
