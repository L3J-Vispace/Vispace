@preconcurrency import ARKit
import Foundation

public enum ARSessionEvent: Sendable {
    case interrupted
    case interruptionEnded
    case failed(code: Int, message: String)
    case snapshotCopyFailed(message: String)
    case worldMapArchiveCreated(byteCount: Int)
    case worldMapArchiveSkipped(reason: String)
    case worldMapArchiveFailed(message: String)
}

/// Bridges Objective-C ARSession callbacks into bounded Sendable streams.
/// The proxy must be retained by its owner because ARSession.delegate is weak.
public final class ARSessionDelegateProxy: NSObject, ARSessionDelegate, @unchecked Sendable {
    public let poseChannel = LatestValueChannel<ARPoseSnapshot>()
    public let frameChannel = LatestValueChannel<ARFrameSnapshot>()
    public let eventChannel = LatestValueChannel<ARSessionEvent>(bufferLimit: 16)

    public var poses: AsyncStream<ARPoseSnapshot> { poseChannel.stream }
    public var frames: AsyncStream<ARFrameSnapshot> { frameChannel.stream }
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

    private let adapter: ARFrameSnapshotAdapter
    private let cadenceGate: SnapshotCadenceGate
    private let snapshotCaptureGate: SnapshotCaptureGate
    private let imageOrientationProvider: @Sendable () -> FrameImageOrientation
    private let attemptsRelocalization: Bool
    private let controllerEventLock = NSLock()
    private var controllerEventChannel: LatestValueChannel<ARSessionEvent>?

    public init(
        maximumSnapshotFramesPerSecond: Double = 10,
        snapshotCaptureEnabled: Bool = false,
        attemptsRelocalization: Bool = true,
        imageOrientationProvider: @escaping @Sendable () -> FrameImageOrientation
    ) {
        adapter = ARFrameSnapshotAdapter()
        cadenceGate = SnapshotCadenceGate(
            maximumFramesPerSecond: maximumSnapshotFramesPerSecond
        )
        snapshotCaptureGate = SnapshotCaptureGate(isEnabled: snapshotCaptureEnabled)
        self.attemptsRelocalization = attemptsRelocalization
        self.imageOrientationProvider = imageOrientationProvider
        super.init()
    }

    @MainActor
    public func install(on session: ARSession, delegateQueue: DispatchQueue) {
        session.delegateQueue = delegateQueue
        session.delegate = self
    }

    @MainActor
    public func uninstall(from session: ARSession) {
        if session.delegate === self {
            session.delegate = nil
            session.delegateQueue = nil
        }
        cadenceGate.reset()
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let frameID = ARFrameID()
        let pose = adapter.makePose(from: frame, id: frameID)
        poseChannel.send(pose)

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
                imageOrientation: imageOrientationProvider()
            )
            frameChannel.send(snapshot)
        } catch {
            emit(.snapshotCopyFailed(message: String(describing: error)))
        }
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        // An ARKit interruption is already equivalent to pause(). Calling pause
        // here would prevent the normal interruption-ended notification.
        emit(.interrupted)
    }

    public func sessionInterruptionEnded(_ session: ARSession) {
        cadenceGate.reset()
        emit(.interruptionEnded)
    }

    public func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        attemptsRelocalization
    }

    public func session(_ session: ARSession, didFailWithError error: any Error) {
        let nsError = error as NSError
        emit(
            .failed(code: nsError.code, message: nsError.localizedDescription)
        )
    }

    func emit(_ event: ARSessionEvent) {
        eventChannel.send(event)

        controllerEventLock.lock()
        let controllerEventChannel = controllerEventChannel
        controllerEventLock.unlock()
        controllerEventChannel?.send(event)
    }

    /// Creates one lifecycle-consumer stream for the current attachment. The
    /// prior stream is finished so detach/reattach never accumulates monitors.
    func beginControllerEvents() -> AsyncStream<ARSessionEvent> {
        let channel = LatestValueChannel<ARSessionEvent>(bufferLimit: 16)
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

    deinit {
        poseChannel.finish()
        frameChannel.finish()
        eventChannel.finish()
        endControllerEvents()
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
