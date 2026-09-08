import Foundation

/// Owns the placement feature's independent multicast subscriptions and feeds
/// the controller on the main actor. It never retains image frames.
@MainActor
public final class ARFurniturePlacementStreamBridge {
    public typealias PoseStreamProvider =
        @MainActor @Sendable () -> AsyncStream<ARPoseSnapshot>
    public typealias SurfaceStreamProvider =
        @MainActor @Sendable () -> AsyncStream<ARSurfaceStateSnapshot>

    private let poseStreamProvider: PoseStreamProvider
    private let surfaceStreamProvider: SurfaceStreamProvider
    private let refreshStreamsOnActivation: Bool
    private let controller: FurniturePlacementController

    private var poseTask: Task<Void, Never>?
    private var surfaceTask: Task<Void, Never>?
    private var isActive = false

    public convenience init(
        poses: AsyncStream<ARPoseSnapshot>,
        surfaces: AsyncStream<ARSurfaceStateSnapshot>,
        controller: FurniturePlacementController
    ) {
        self.init(
            poseStreamProvider: { poses },
            surfaceStreamProvider: { surfaces },
            refreshStreamsOnActivation: false,
            controller: controller
        )
    }

    public convenience init(
        poseStreamProvider: @escaping PoseStreamProvider,
        surfaceStreamProvider: @escaping SurfaceStreamProvider,
        controller: FurniturePlacementController
    ) {
        self.init(
            poseStreamProvider: poseStreamProvider,
            surfaceStreamProvider: surfaceStreamProvider,
            refreshStreamsOnActivation: true,
            controller: controller
        )
    }

    private init(
        poseStreamProvider: @escaping PoseStreamProvider,
        surfaceStreamProvider: @escaping SurfaceStreamProvider,
        refreshStreamsOnActivation: Bool,
        controller: FurniturePlacementController
    ) {
        self.poseStreamProvider = poseStreamProvider
        self.surfaceStreamProvider = surfaceStreamProvider
        self.refreshStreamsOnActivation = refreshStreamsOnActivation
        self.controller = controller
    }

    deinit {
        poseTask?.cancel()
        surfaceTask?.cancel()
    }

    public func activate() {
        isActive = true
        if poseTask == nil {
            let stream = poseStreamProvider()
            poseTask = Task { @MainActor [weak self, stream] in
                for await pose in stream {
                    guard !Task.isCancelled, let self else {
                        return
                    }
                    if self.isActive {
                        controller.update(pose: pose)
                    }
                }
            }
        }
        if surfaceTask == nil {
            let stream = surfaceStreamProvider()
            surfaceTask = Task { @MainActor [weak self, stream] in
                for await surface in stream {
                    guard !Task.isCancelled, let self else {
                        return
                    }
                    if self.isActive {
                        controller.update(surface: surface)
                    }
                }
            }
        }
    }

    public func deactivate() {
        isActive = false
        if refreshStreamsOnActivation {
            poseTask?.cancel()
            poseTask = nil
            surfaceTask?.cancel()
            surfaceTask = nil
        }
        controller.clearSpatialContext()
    }
}
