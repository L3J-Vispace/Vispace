import Combine
import CoreGraphics
import Foundation
import VispaceCore
import simd

public enum UserObjectRegistrationState: Equatable, Sendable {
    case idle
    case collecting(name: String, sampleCount: Int)
    case saving
    case saved(SpatialObjectMetadata)
    case unavailable(message: String)
}

/// Saves an explicitly user-named, measured LAST-SEEN surface point. It never
/// runs classification or stores images, and it cannot supply occupied bounds.
@MainActor
public final class UserObjectRegistrationController: ObservableObject {
    public typealias SampleLocator = @Sendable (ARFrameSnapshot) -> ARDepthSample?

    @Published public private(set) var state: UserObjectRegistrationState = .idle
    private let frameStreamProvider: SpatialPerceptionController.FrameStreamProvider
    private let confirmedIdentityProvider: SpatialPerceptionController.ConfirmedIdentityProvider
    private let metadataWriter: SpatialPerceptionController.MetadataWriter
    private let sampleLocator: SampleLocator
    private let timeout: Duration
    private let monotonicNow: @MainActor () -> TimeInterval
    private var isActive = false
    private var generation = UUID()
    private var accumulator: UserObjectRegistrationAccumulator?
    private var currentTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        frameStreamProvider: @escaping SpatialPerceptionController.FrameStreamProvider,
        confirmedIdentityProvider: @escaping SpatialPerceptionController.ConfirmedIdentityProvider,
        metadataWriter: @escaping SpatialPerceptionController.MetadataWriter,
        sampleLocator: SampleLocator? = nil,
        timeout: Duration = .seconds(8),
        monotonicNow: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.frameStreamProvider = frameStreamProvider
        self.confirmedIdentityProvider = confirmedIdentityProvider
        self.metadataWriter = metadataWriter
        self.sampleLocator = sampleLocator ?? Self.locateReticleSample
        self.timeout = timeout > .zero ? timeout : .seconds(8)
        self.monotonicNow = monotonicNow
    }

    deinit {
        currentTask?.cancel()
        timeoutTask?.cancel()
        for task in pendingTasks.values { task.cancel() }
    }

    public func activate() { isActive = true }

    public func deactivate() {
        isActive = false
        cancel()
    }

    public func start(name: String) {
        cancel()
        guard isActive else {
            state = .unavailable(message: "카메라를 켠 뒤 물체를 등록해 주세요.")
            return
        }
        do {
            accumulator = try UserObjectRegistrationAccumulator(name: name)
        } catch {
            state = .unavailable(message: "물체 이름을 1~64자로 입력해 주세요.")
            return
        }
        guard let accumulator else { return }
        state = .collecting(name: accumulator.name, sampleCount: 0)
        let requestID = generation
        let stream = frameStreamProvider()
        let task = Task { @MainActor [weak self] in
            for await frame in stream {
                guard !Task.isCancelled, let self, self.generation == requestID else { break }
                if await self.consume(frame, requestID: requestID) { break }
            }
            guard let self else { return }
            self.pendingTasks.removeValue(forKey: requestID)
            if self.generation == requestID {
                self.currentTask = nil
                self.timeoutTask?.cancel()
                self.timeoutTask = nil
                if case .collecting = self.state {
                    self.state = .unavailable(message: "카메라 입력이 중단됐어요. 다시 등록해 주세요.")
                }
            }
        }
        currentTask = task
        pendingTasks[requestID] = task
        let timeout = self.timeout
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.generation == requestID,
                case .collecting = self.state else { return }
            self.cancel()
            self.state = .unavailable(message: "위치를 확인하지 못했어요. 물체 표면에 가운데 표시를 맞추고 다시 등록해 주세요.")
        }
    }

    public func cancel() {
        generation = UUID()
        currentTask?.cancel()
        currentTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        for task in pendingTasks.values { task.cancel() }
        accumulator = nil
        state = .idle
    }

    /// Call after deactivation and before deleting/exporting mutable local
    /// data. A writer that has crossed its commit point must finish first.
    public func cancelAndWait() async {
        let pending = Array(pendingTasks.values)
        cancel()
        for task in pending { await task.value }
    }

    private func consume(_ frame: ARFrameSnapshot, requestID: UUID) async -> Bool {
        guard isActive, generation == requestID, !Task.isCancelled,
            var accumulator else { return true }
        let age = monotonicNow() - frame.pose.timestamp
        guard age.isFinite, age >= 0, age <= 0.75 else { return false }
        guard let identity = confirmedIdentityProvider(frame),
            identity.status == .confirmed, let mapID = identity.mapID,
            frame.pose.mapID == mapID,
            frame.pose.coordinateFrameID == identity.coordinateFrameID,
            frame.pose.segmentID == identity.segmentID,
            frame.pose.coordinateFrameStatus == .confirmed,
            frame.pose.trackingState == .normal else {
            self.accumulator = try? UserObjectRegistrationAccumulator(name: accumulator.name)
            state = .collecting(name: accumulator.name, sampleCount: 0)
            return false
        }
        guard let depth = sampleLocator(frame),
            depth.frameID == frame.pose.id,
            depth.coordinateFrameID == identity.coordinateFrameID,
            depth.segmentID == identity.segmentID,
            depth.mapID == mapID, depth.coordinateFrameStatus == .confirmed,
            depth.trackingState == .normal, depth.confidence == .high,
            depth.source == .raw, depth.uncertainty == .highConfidenceDepth,
            depth.timestamp == frame.pose.timestamp,
            depth.depthMeters.isFinite, (0.1...5).contains(depth.depthMeters),
            let position = try? Vec3(x: Double(depth.worldPosition.x),
                                     y: Double(depth.worldPosition.y),
                                     z: Double(depth.worldPosition.z)) else { return false }
        do {
            let metadata = try accumulator.append(UserObjectRegistrationSample(
                frameID: FrameID(rawValue: frame.pose.id.rawValue),
                identity: UserObjectRegistrationIdentity(
                    mapID: mapID, coordinateFrameID: identity.coordinateFrameID,
                    segmentID: identity.segmentID,
                    sessionRunGeneration: frame.pose.sessionToken.sessionRunGeneration,
                    attachmentEpoch: frame.pose.sessionToken.attachmentEpoch
                ),
                position: position, timestamp: frame.pose.timestamp, capturedAt: frame.pose.capturedAt,
                trackingQuality: .normal, uncertainty: depth.uncertainty,
                isCoordinateFrameConfirmed: true
            ))
            self.accumulator = accumulator
            guard let metadata else {
                state = .collecting(name: accumulator.name, sampleCount: accumulator.sampleCount)
                return false
            }
            guard generation == requestID, isActive,
                confirmedIdentityProvider(frame) == identity else { return true }
            timeoutTask?.cancel()
            timeoutTask = nil
            state = .saving
            try Task.checkCancellation()
            try await metadataWriter(metadata)
            guard generation == requestID, isActive, !Task.isCancelled else { return true }
            guard confirmedIdentityProvider(frame) == identity else {
                state = .unavailable(message: "등록 중 공간 연결이 바뀌었어요. 저장된 위치는 물체 목록에서 확인해 주세요.")
                return true
            }
            state = .saved(metadata)
        } catch is CancellationError {
            // A later start/cancel/deactivation owns the published state.
        } catch {
            guard generation == requestID, isActive, !Task.isCancelled else { return true }
            if error is UserObjectRegistrationError {
                state = .unavailable(message: "같은 물체의 위치를 안정적으로 확인하지 못했어요. 가운데 표시를 맞추고 다시 등록해 주세요.")
            } else {
                state = .unavailable(message: "물체 위치를 저장하지 못했어요. 다시 시도해 주세요.")
            }
        }
        return true
    }

    nonisolated static func locateReticleSample(in frame: ARFrameSnapshot) -> ARDepthSample? {
        guard let display = frame.displayTransform, display.geometry.viewportSize.isUsable,
            frame.sceneDepth != nil else { return nil }
        let transform = display.imageToViewport.cgAffineTransform
        let values = [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
        guard values.allSatisfy(\.isFinite),
            abs(transform.a * transform.d - transform.b * transform.c) > 0.000_001 else { return nil }
        let imagePoint = CGPoint(x: 0.5, y: 0.5).applying(transform.inverted())
        guard imagePoint.x.isFinite, imagePoint.y.isFinite,
            (0...1).contains(imagePoint.x), (0...1).contains(imagePoint.y) else { return nil }
        // One actual center texel per raw frame prevents a neighboring
        // background surface or temporally smoothed pixel from substituting.
        let result = ARDepthSampler(minimumConfidence: .high, neighborhoodRadius: 0).sample(
            normalizedImagePoint: SIMD2<Float>(Float(imagePoint.x), Float(imagePoint.y)),
            in: frame, prefersSmoothedDepth: false
        )
        guard case .sample(let sample) = result, sample.source == .raw else { return nil }
        return sample
    }
}
