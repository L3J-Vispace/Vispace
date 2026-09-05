import Combine
import Foundation
import VispaceCore
import simd

public enum PerceptionProcessingBudget: Equatable, Sendable {
    case normal
    case lowPower
    case thermallyConstrained
    case pausedForThermalPressure

    public static var current: Self {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: return .pausedForThermalPressure
        case .serious: return .thermallyConstrained
        case .nominal, .fair:
            return ProcessInfo.processInfo.isLowPowerModeEnabled ? .lowPower : .normal
        @unknown default: return .thermallyConstrained
        }
    }

    var minimumFrameInterval: TimeInterval {
        switch self {
        case .normal: 0
        case .lowPower: 0.5
        case .thermallyConstrained: 1
        case .pausedForThermalPressure: .infinity
        }
    }
}

public enum SpatialPerceptionState: Equatable, Sendable {
    case inactive
    case unavailable(reason: String)
    case waitingForStableTracking
    case waitingForMap
    case scanning
    case failed(message: String)
}

public struct SpatialPerceptionMetrics: Equatable, Sendable {
    public var framesStarted: UInt64 = 0
    public var framesSuperseded: UInt64 = 0
    public var staleResultsRejected: UInt64 = 0
    public var depthFailures: UInt64 = 0
    public var promotedObjects: UInt64 = 0
    public var reidentifiedObjects: UInt64 = 0
    public var genuinelyNewObjects: UInt64 = 0
    public var ambiguousReidentifications: UInt64 = 0

    public init() {}
}

/// Owns the Phase 1 perception flow from bounded AR frame admission through
/// multi-frame object promotion and durable metadata persistence.
///
/// All mutable scheduling and promotion state is main-actor isolated. Vision
/// performs model work on its detector actor, while lifecycle generation and
/// frame-token checks prevent a late result from crossing ARSession runs.
@MainActor
public final class SpatialPerceptionController: ObservableObject {
    public typealias FrameStreamProvider =
        @MainActor @Sendable () -> AsyncStream<ARFrameSnapshot>
    public typealias ConfirmedIdentityProvider =
        @MainActor (
            ARFrameSnapshot
        ) -> ARCaptureIdentity?
    public typealias MetadataWriter =
        @Sendable (
            SpatialObjectMetadata
        ) async throws -> Void
    public typealias MetadataProvider = @Sendable () async throws -> [SpatialObjectMetadata]
    public typealias ProcessingBudgetProvider = @MainActor () -> PerceptionProcessingBudget
    public typealias TemporalMemoryProcessor =
        @Sendable (
            TemporalSpatialRecognitionBatch,
            ARPoseSnapshot
        ) async throws -> TemporalSpatialMemoryServiceResult

    @Published public private(set) var state: SpatialPerceptionState = .inactive
    @Published public private(set) var latestDetections: [DetectedObject] = []
    @Published public private(set) var metrics = SpatialPerceptionMetrics()
    /// Persists across ordinary scanning state changes until a durable write succeeds.
    @Published public private(set) var persistenceFailureMessage: String?
    @Published public private(set) var objectCapacityReached = false
    @Published public private(set) var processingBudget: PerceptionProcessingBudget = .normal

    public var isDetectorAvailable: Bool {
        detectorResolution.availability == .available
    }

    var isProcessingForTesting: Bool {
        processingTask != nil
    }

    var pendingProcessingTaskCountForTesting: Int {
        processingTasks.count
    }

    var bufferedFrameCountForTesting: Int {
        bufferedFrames.count
    }

    private let frameStreamProvider: FrameStreamProvider
    private let refreshStreamOnActivation: Bool
    private let detectorResolution: ObjectDetectorResolution
    private let tracker: any ObjectTracking
    private let depthLocator: ObjectDepthLocator
    private let confirmedIdentityProvider: ConfirmedIdentityProvider
    private let metadataWriter: MetadataWriter
    private let metadataProvider: MetadataProvider
    private let temporalMemoryProcessor: TemporalMemoryProcessor?
    private let admissionPolicy: FrameAdmissionPolicy
    private let promotionPolicy: ObjectObservationPromotionPolicy
    private let detectorInterval: TimeInterval
    private let reidentificationResolver: PersistentObjectReidentificationResolver
    private let reidentificationContextBuilder: ObjectReidentificationContextBuilder
    private let processingBudgetProvider: ProcessingBudgetProvider
    private var lastResourceAcceptedTimestamp: TimeInterval?

    private var monitorTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var currentProcessingTaskID: UUID?
    private var processingTasks: [UUID: Task<Void, Never>] = [:]
    private var isActive = false
    private var scheduler: FrameAdmissionScheduler
    private var promoter: ObjectObservationPromoter
    private var bufferedFrames: [FrameID: ARFrameSnapshot] = [:]
    private var persistedObjectIDs: Set<ObjectID> = []
    private var promotionEvidenceByObjectID: [ObjectID: [ObjectPromotionObservation]] = [:]
    private var nextSequenceNumber: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var activeFrameToken: ARSessionFrameToken?
    private var activeTracks: [VisionTrackID: ActiveTrack] = [:]
    private var lastDetectorTimestamp: TimeInterval?
    private var temporalIdentityByPromotedObjectID: [ObjectID: TemporalIdentityResolution] = [:]
    private var latestTemporalMetadataByObjectID: [ObjectID: SpatialObjectMetadata] = [:]
    private var lastTemporalSequenceNumber: UInt64?
    private var lastCalendarSample: (wall: TimeInterval, monotonic: TimeInterval)?

    public convenience init(
        frames: AsyncStream<ARFrameSnapshot>,
        detectorResolution: ObjectDetectorResolution,
        tracker: any ObjectTracking = VisionObjectTracker(),
        depthLocator: ObjectDepthLocator = ObjectDepthLocator(),
        admissionPolicy: FrameAdmissionPolicy = try! FrameAdmissionPolicy(
            minimumStartInterval: 0,
            maximumFrameAge: 0.75
        ),
        promotionPolicy: ObjectObservationPromotionPolicy = .default,
        detectorInterval: TimeInterval = 0.8,
        confirmedIdentityProvider: @escaping ConfirmedIdentityProvider,
        metadataProvider: @escaping MetadataProvider = { [] },
        metadataWriter: @escaping MetadataWriter,
        temporalMemoryProcessor: TemporalMemoryProcessor? = nil,
        processingBudgetProvider: @escaping ProcessingBudgetProvider = { .current }
    ) {
        self.init(
            frameStreamProvider: { frames },
            refreshStreamOnActivation: false,
            detectorResolution: detectorResolution,
            tracker: tracker,
            depthLocator: depthLocator,
            admissionPolicy: admissionPolicy,
            promotionPolicy: promotionPolicy,
            detectorInterval: detectorInterval,
            confirmedIdentityProvider: confirmedIdentityProvider,
            metadataProvider: metadataProvider,
            metadataWriter: metadataWriter,
            temporalMemoryProcessor: temporalMemoryProcessor,
            processingBudgetProvider: processingBudgetProvider
        )
    }

    public convenience init(
        frameStreamProvider: @escaping FrameStreamProvider,
        detectorResolution: ObjectDetectorResolution,
        tracker: any ObjectTracking = VisionObjectTracker(),
        depthLocator: ObjectDepthLocator = ObjectDepthLocator(),
        admissionPolicy: FrameAdmissionPolicy = try! FrameAdmissionPolicy(
            minimumStartInterval: 0,
            maximumFrameAge: 0.75
        ),
        promotionPolicy: ObjectObservationPromotionPolicy = .default,
        detectorInterval: TimeInterval = 0.8,
        confirmedIdentityProvider: @escaping ConfirmedIdentityProvider,
        metadataProvider: @escaping MetadataProvider = { [] },
        metadataWriter: @escaping MetadataWriter,
        temporalMemoryProcessor: TemporalMemoryProcessor? = nil,
        processingBudgetProvider: @escaping ProcessingBudgetProvider = { .current }
    ) {
        self.init(
            frameStreamProvider: frameStreamProvider,
            refreshStreamOnActivation: true,
            detectorResolution: detectorResolution,
            tracker: tracker,
            depthLocator: depthLocator,
            admissionPolicy: admissionPolicy,
            promotionPolicy: promotionPolicy,
            detectorInterval: detectorInterval,
            confirmedIdentityProvider: confirmedIdentityProvider,
            metadataProvider: metadataProvider,
            metadataWriter: metadataWriter,
            temporalMemoryProcessor: temporalMemoryProcessor,
            processingBudgetProvider: processingBudgetProvider
        )
    }

    private init(
        frameStreamProvider: @escaping FrameStreamProvider,
        refreshStreamOnActivation: Bool,
        detectorResolution: ObjectDetectorResolution,
        tracker: any ObjectTracking,
        depthLocator: ObjectDepthLocator,
        admissionPolicy: FrameAdmissionPolicy,
        promotionPolicy: ObjectObservationPromotionPolicy,
        detectorInterval: TimeInterval,
        confirmedIdentityProvider: @escaping ConfirmedIdentityProvider,
        metadataProvider: @escaping MetadataProvider,
        metadataWriter: @escaping MetadataWriter,
        temporalMemoryProcessor: TemporalMemoryProcessor?,
        processingBudgetProvider: @escaping ProcessingBudgetProvider
    ) {
        self.frameStreamProvider = frameStreamProvider
        self.refreshStreamOnActivation = refreshStreamOnActivation
        self.detectorResolution = detectorResolution
        self.tracker = tracker
        self.depthLocator = depthLocator
        self.admissionPolicy = admissionPolicy
        self.promotionPolicy = promotionPolicy
        self.detectorInterval =
            detectorInterval.isFinite && detectorInterval > 0
            ? detectorInterval
            : 0.8
        self.confirmedIdentityProvider = confirmedIdentityProvider
        self.metadataProvider = metadataProvider
        self.metadataWriter = metadataWriter
        self.processingBudgetProvider = processingBudgetProvider
        self.temporalMemoryProcessor = temporalMemoryProcessor
        reidentificationResolver = PersistentObjectReidentificationResolver()
        reidentificationContextBuilder = ObjectReidentificationContextBuilder()
        scheduler = FrameAdmissionScheduler(policy: admissionPolicy)
        promoter = ObjectObservationPromoter(policy: promotionPolicy)
    }

    public func activate() {
        guard !isActive else {
            return
        }
        guard case .available = detectorResolution.availability else {
            if case .unavailable(let reason) = detectorResolution.availability {
                state = .unavailable(reason: reason)
            }
            return
        }

        resetPipeline(incrementGeneration: true)
        isActive = true
        state = .waitingForStableTracking
        guard monitorTask == nil else {
            return
        }
        let stream = frameStreamProvider()
        monitorTask = Task { @MainActor [weak self] in
            for await frame in stream {
                guard !Task.isCancelled, let self else {
                    return
                }
                if self.isActive {
                    self.offer(frame)
                }
            }
        }
    }

    public func deactivate() {
        isActive = false
        if refreshStreamOnActivation {
            monitorTask?.cancel()
            monitorTask = nil
        }
        resetPipeline(incrementGeneration: true)
        state = .inactive
        latestDetections = []
    }

    /// Used by destructive local-data management to ensure a cancelled
    /// detector pass cannot finish a repository write after deletion.
    public func deactivateAndWaitForPendingWork() async {
        let pendingProcessing = Array(processingTasks.values)
        // A direct AsyncStream is intentionally monitored across ordinary
        // deactivate/reactivate cycles. Provider-backed streams create a new
        // subscription per activation, so their old monitor must also unwind.
        let pendingMonitor = refreshStreamOnActivation ? monitorTask : nil
        deactivate()
        for task in pendingProcessing {
            await task.value
        }
        await pendingMonitor?.value
    }

    private func offer(_ frame: ARFrameSnapshot) {
        let nextBudget = processingBudgetProvider()
        if nextBudget == .pausedForThermalPressure {
            if processingBudget != .pausedForThermalPressure {
                resetPipeline(incrementGeneration: true)
            }
            processingBudget = nextBudget
            state = .unavailable(reason: "기기 온도가 높아 공간 인식을 잠시 쉬고 있습니다. 온도가 내려가면 자동으로 다시 시작합니다.")
            return
        }
        processingBudget = nextBudget
        guard let identity = confirmedIdentityProvider(frame) else {
            state = .waitingForStableTracking
            return
        }

        if activeFrameToken != frame.pose.sessionToken {
            resetPipeline(incrementGeneration: true)
            activeFrameToken = frame.pose.sessionToken
        }
        if let lastCalendarSample, frame.pose.timestamp > lastCalendarSample.monotonic,
            frame.pose.capturedAt < lastCalendarSample.wall
        {
            // Promotion windows must contain actual observations from one
            // uninterrupted calendar interval. Start fresh evidence after a
            // system-clock correction; never shift or fabricate their dates.
            resetPipeline(incrementGeneration: true)
            activeFrameToken = frame.pose.sessionToken
        }
        lastCalendarSample = (frame.pose.capturedAt, frame.pose.timestamp)
        state = identity.mapID == nil ? .waitingForMap : .scanning

        if let lastResourceAcceptedTimestamp,
            frame.pose.timestamp - lastResourceAcceptedTimestamp
                < nextBudget.minimumFrameInterval
        {
            return
        }

        let frameID = FrameID(rawValue: frame.pose.id.rawValue)
        let descriptor: FrameDescriptor
        do {
            descriptor = try FrameDescriptor(
                id: frameID,
                sequenceNumber: nextSequenceNumber,
                timestamp: frame.pose.timestamp
            )
        } catch {
            metrics.staleResultsRejected &+= 1
            return
        }
        nextSequenceNumber &+= 1

        let now = ProcessInfo.processInfo.systemUptime
        let previouslyPendingID = scheduler.pendingLatest?.id
        switch scheduler.offer(descriptor, now: now) {
        case .started:
            if let previouslyPendingID,
                previouslyPendingID != scheduler.pendingLatest?.id
            {
                bufferedFrames.removeValue(forKey: previouslyPendingID)
                metrics.framesSuperseded &+= 1
            }
            bufferedFrames[frameID] = frame
            startProcessing(frame, descriptor: descriptor)
        case .queued(_, let dropped):
            if let dropped {
                bufferedFrames.removeValue(forKey: dropped.frame.id)
                metrics.framesSuperseded &+= 1
            }
            bufferedFrames[frameID] = frame
        case .dropped:
            break
        }
    }

    private func startProcessing(
        _ frame: ARFrameSnapshot,
        descriptor: FrameDescriptor
    ) {
        lastResourceAcceptedTimestamp = frame.pose.timestamp
        let generation = lifecycleGeneration
        let taskID = UUID()
        metrics.framesStarted &+= 1
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.finishProcessing(
                    descriptor,
                    generation: generation,
                    taskID: taskID
                )
            }
            do {
                guard self.processingBudgetProvider() != .pausedForThermalPressure else {
                    return
                }
                let frameObservations = try await self.perceptionObservations(
                    in: frame,
                    generation: generation
                )
                guard !Task.isCancelled, generation == self.lifecycleGeneration else {
                    self.metrics.staleResultsRejected &+= 1
                    return
                }
                guard let identity = self.confirmedIdentityProvider(frame) else {
                    self.metrics.staleResultsRejected &+= 1
                    return
                }

                self.latestDetections = frameObservations.observations.map(\.detection)
                await self.consume(
                    frameObservations,
                    frame: frame,
                    identity: identity,
                    generation: generation
                )
            } catch is CancellationError {
                // Lifecycle cancellation is expected and is already accounted
                // for by the generation/token gate.
            } catch {
                if generation == self.lifecycleGeneration {
                    self.state = .failed(message: String(describing: error))
                }
            }
        }
        processingTask = task
        currentProcessingTaskID = taskID
        processingTasks[taskID] = task
    }

    private func consume(
        _ frameObservations: PerceptionFrameObservations,
        frame: ARFrameSnapshot,
        identity: ARCaptureIdentity,
        generation: UInt64
    ) async {
        guard temporalMemoryProcessor != nil else {
            await consumeUsingMetadataWriter(
                frameObservations.observations,
                frame: frame,
                identity: identity,
                generation: generation
            )
            return
        }
        await consumeUsingTemporalMemory(
            frameObservations,
            frame: frame,
            identity: identity,
            generation: generation
        )
    }

    private func consumeUsingMetadataWriter(
        _ observations: [PerceptionObservation],
        frame: ARFrameSnapshot,
        identity: ARCaptureIdentity,
        generation: UInt64
    ) async {
        for observation in observations {
            guard !Task.isCancelled, generation == lifecycleGeneration else {
                metrics.staleResultsRejected &+= 1
                return
            }

            do {
                try await persistUsingMetadataWriter(
                    observation,
                    frame: frame,
                    identity: identity,
                    generation: generation
                )
            } catch is CancellationError {
                return
            } catch {
                // One malformed observation or transient repository failure
                // must not suppress other objects detected in the same frame.
                if generation == lifecycleGeneration {
                    state = .failed(message: String(describing: error))
                }
            }
        }
    }

    private func persistUsingMetadataWriter(
        _ perceptionObservation: PerceptionObservation,
        frame: ARFrameSnapshot,
        identity: ARCaptureIdentity,
        generation: UInt64
    ) async throws {
        let detection = perceptionObservation.detection
        let located: LocatedObjectDetection
        switch depthLocator.locate(
            detection,
            in: frame,
            currentIdentity: identity
        ) {
        case .located(let result):
            located = result
        case .unavailable:
            metrics.depthFailures &+= 1
            return
        }

        let observation = try ObjectPromotionObservation(
            observationID: ObservationID(),
            frameID: FrameID(rawValue: frame.pose.id.rawValue),
            trackID: TrackID(rawValue: perceptionObservation.trackID.rawValue),
            semanticLabel: detection.label,
            coordinateFrameID: identity.coordinateFrameID,
            captureSegmentID: identity.segmentID,
            mapID: identity.mapID,
            boundingBox: located.boundingBox,
            position: located.position,
            bounds: located.bounds,
            semanticConfidence: ConfidenceScore(
                clamping: Double(detection.confidence)
            ),
            geometryConfidence: located.geometryConfidence
        )

        let outcome = try promoter.ingest(observation)
        let promotedMetadata: SpatialObjectMetadata
        switch outcome {
        case .promoted(let value):
            promotedMetadata = value
            guard let observations = promoter.promotionEvidence(for: value.object.id) else {
                return
            }
            promotionEvidenceByObjectID[value.object.id] = observations
        case .alreadyPromoted(let value):
            promotedMetadata = value
        case .pending,
            .ignoredDuplicateFrame,
            .ignoredDuplicateObservation,
            .ambiguous:
            return
        }
        guard !persistedObjectIDs.contains(promotedMetadata.object.id),
            let promotionObservations = promotionEvidenceByObjectID[promotedMetadata.object.id]
        else {
            return
        }

        // Persistence is a separate async boundary. Revalidate immediately
        // before crossing it and require an actual checkpoint-backed map.
        guard !Task.isCancelled,
            generation == lifecycleGeneration,
            let currentIdentity = confirmedIdentityProvider(frame),
            let currentMapID = currentIdentity.mapID,
            currentMapID == promotedMetadata.mapID,
            currentIdentity.coordinateFrameID
                == promotedMetadata.position.coordinateFrameID
        else {
            metrics.staleResultsRejected &+= 1
            return
        }

        let existingObjects = try await metadataProvider()
        try Task.checkCancellation()
        guard generation == lifecycleGeneration,
            confirmedIdentityProvider(frame) == currentIdentity
        else {
            metrics.staleResultsRejected &+= 1
            return
        }
        let context = try reidentificationContextBuilder.makeContexts(
            for: promotedMetadata,
            existingObjects: existingObjects
        )
        let metadata: SpatialObjectMetadata
        let reusedPersistentIdentity: Bool
        if context.candidates.isEmpty {
            metadata = promotedMetadata
            reusedPersistentIdentity = false
        } else {
            let promotionEvidence: ObjectReidentificationPromotionEvidence
            do {
                promotionEvidence = try ObjectReidentificationPromotionEvidence(
                    observations: promotionObservations
                )
            } catch {
                metrics.ambiguousReidentifications &+= 1
                return
            }
            let request = try PersistentObjectReidentificationRequest(
                promotedObject: promotedMetadata,
                promotionEvidence: promotionEvidence,
                incomingContext: context.incoming,
                candidateContexts: context.candidates
            )
            let decision = try reidentificationResolver.resolve(
                request,
                against: context.eligibleExistingObjects
            )
            switch decision {
            case .confirmedExisting(let candidate):
                guard
                    let existing = context.eligibleExistingObjects.first(where: {
                        $0.object.id == candidate.objectID
                    })
                else {
                    metrics.ambiguousReidentifications &+= 1
                    return
                }
                metadata = try metadataReusingPersistentIdentity(
                    promotedMetadata,
                    existing: existing
                )
                reusedPersistentIdentity = true
            case .genuinelyNew:
                metadata = promotedMetadata
                reusedPersistentIdentity = false
            case .ambiguousCandidates:
                metrics.ambiguousReidentifications &+= 1
                return
            }
        }
        guard !persistedObjectIDs.contains(metadata.object.id) else {
            return
        }

        do {
            try await metadataWriter(metadata)
        } catch {
            if generation == lifecycleGeneration, !(error is CancellationError) {
                recordPersistenceFailure(error)
            }
            throw error
        }
        guard !Task.isCancelled, generation == lifecycleGeneration else {
            metrics.staleResultsRejected &+= 1
            return
        }
        persistenceFailureMessage = nil
        persistedObjectIDs.insert(metadata.object.id)
        promotionEvidenceByObjectID.removeValue(forKey: promotedMetadata.object.id)
        if reusedPersistentIdentity {
            metrics.reidentifiedObjects &+= 1
        } else {
            metrics.genuinelyNewObjects &+= 1
        }
        metrics.promotedObjects &+= 1
    }

    private func consumeUsingTemporalMemory(
        _ frameObservations: PerceptionFrameObservations,
        frame: ARFrameSnapshot,
        identity: ARCaptureIdentity,
        generation: UInt64
    ) async {
        guard let temporalMemoryProcessor else {
            return
        }

        var resolved: [ResolvedTemporalObservation] = []
        for observation in frameObservations.observations {
            guard !Task.isCancelled, generation == lifecycleGeneration else {
                metrics.staleResultsRejected &+= 1
                return
            }
            do {
                if let value = try await resolveTemporalObservation(
                    observation,
                    frame: frame,
                    identity: identity,
                    generation: generation
                ) {
                    resolved.append(value)
                }
            } catch is CancellationError {
                return
            } catch {
                if generation == lifecycleGeneration {
                    state = .failed(message: String(describing: error))
                }
            }
        }

        let grouped = Dictionary(grouping: resolved) {
            $0.observation.metadata.object.id
        }
        let duplicateIDs = Set(
            grouped.compactMap { objectID, values in
                values.count > 1 ? objectID : nil
            }
        )
        if !duplicateIDs.isEmpty {
            metrics.ambiguousReidentifications &+= UInt64(duplicateIDs.count)
        }
        let uniqueResolved = resolved.filter {
            !duplicateIDs.contains($0.observation.metadata.object.id)
        }
        let observedObjectIDs = Set(
            uniqueResolved.map { $0.observation.metadata.object.id }
        )
        let expectedVisibleObjectIDs = frameObservations
            .detectorExpectedVisibleObjectIDs
            .union(observedObjectIDs)

        guard !uniqueResolved.isEmpty || !expectedVisibleObjectIDs.isEmpty else {
            return
        }

        do {
            let sequence = try nextTemporalSequence(for: frame.pose.capturedAt)
            let batch = TemporalSpatialRecognitionBatch(
                id: SpatialDeltaID(rawValue: frame.pose.id.rawValue),
                sequence: sequence,
                observations: uniqueResolved.map(\.observation),
                expectedVisibleObjectIDs: expectedVisibleObjectIDs.sorted()
            )
            let result: TemporalSpatialMemoryServiceResult
            do {
                result = try await temporalMemoryProcessor(batch, frame.pose)
            } catch {
                if generation == lifecycleGeneration, !(error is CancellationError) {
                    recordPersistenceFailure(error)
                }
                throw error
            }
            guard !Task.isCancelled, generation == lifecycleGeneration,
                confirmedIdentityProvider(frame) == identity
            else {
                metrics.staleResultsRejected &+= 1
                return
            }

            persistenceFailureMessage = nil
            lastTemporalSequenceNumber = sequence
            let deferredObjectIDs: Set<ObjectID>
            switch result {
            case .applied(let delta):
                deferredObjectIDs = delta.deferredObjectIDs
                objectCapacityReached = !deferredObjectIDs.isEmpty
            case .alreadyProcessed(let snapshot):
                deferredObjectIDs = Set(uniqueResolved.compactMap { value in
                    snapshot.metadata(for: value.observation.metadata.object.id) == nil
                        ? value.observation.metadata.object.id : nil
                })
                objectCapacityReached = !deferredObjectIDs.isEmpty
            }
            for value in uniqueResolved {
                guard !deferredObjectIDs.contains(value.observation.metadata.object.id) else {
                    continue
                }
                if value.establishesIdentity {
                    temporalIdentityByPromotedObjectID[value.promotedObjectID] =
                        value.identityResolution
                    persistedObjectIDs.insert(value.observation.metadata.object.id)
                    if value.identityResolution.reusedPersistentIdentity {
                        metrics.reidentifiedObjects &+= 1
                    } else {
                        metrics.genuinelyNewObjects &+= 1
                    }
                    metrics.promotedObjects &+= 1
                }
                latestTemporalMetadataByObjectID[value.observation.metadata.object.id] =
                    value.observation.metadata
            }
            removeTerminalCoverageObjects(from: result)
        } catch is CancellationError {
            return
        } catch {
            if generation == lifecycleGeneration {
                state = .failed(message: String(describing: error))
            }
        }
    }

    /// Clears a storage warning after the user has erased local data.
    public func resetPersistenceStatus() {
        persistenceFailureMessage = nil
        objectCapacityReached = false
    }

    private func recordPersistenceFailure(_ error: any Error) {
        if let temporalError = error as? TemporalSpatialMemoryError {
            switch temporalError {
            case .outOfOrderTimestamp, .outOfOrderSequence:
                persistenceFailureMessage =
                    "기기의 날짜 또는 시간이 이전 기록보다 과거로 변경되어 저장을 멈췄습니다. 설정에서 날짜 및 시간의 자동 설정을 켠 뒤 앱을 다시 열어 주세요. 기존 기록은 보존됩니다."
                return
            default:
                break
            }
        }
        persistenceFailureMessage =
            "공간 기록을 저장하지 못했습니다. 기기의 저장 공간과 잠금 상태를 확인해 주세요. 다음 관측에서 다시 시도합니다."
    }

    private func resolveTemporalObservation(
        _ perceptionObservation: PerceptionObservation,
        frame: ARFrameSnapshot,
        identity: ARCaptureIdentity,
        generation: UInt64
    ) async throws -> ResolvedTemporalObservation? {
        let detection = perceptionObservation.detection
        let located: LocatedObjectDetection
        switch depthLocator.locate(
            detection,
            in: frame,
            currentIdentity: identity
        ) {
        case .located(let result):
            located = result
        case .unavailable:
            metrics.depthFailures &+= 1
            return nil
        }

        let promotionObservation = try ObjectPromotionObservation(
            observationID: ObservationID(),
            frameID: FrameID(rawValue: frame.pose.id.rawValue),
            trackID: TrackID(rawValue: perceptionObservation.trackID.rawValue),
            semanticLabel: detection.label,
            coordinateFrameID: identity.coordinateFrameID,
            captureSegmentID: identity.segmentID,
            mapID: identity.mapID,
            boundingBox: located.boundingBox,
            position: located.position,
            bounds: located.bounds,
            semanticConfidence: ConfidenceScore(clamping: Double(detection.confidence)),
            geometryConfidence: located.geometryConfidence
        )

        let promotedMetadata: SpatialObjectMetadata
        switch try promoter.ingest(promotionObservation) {
        case .promoted(let value), .alreadyPromoted(let value):
            promotedMetadata = value
        case .pending,
            .ignoredDuplicateFrame,
            .ignoredDuplicateObservation,
            .ambiguous:
            return nil
        }
        guard
            let promotionObservations = promoter.promotionEvidence(
                for: promotedMetadata.object.id
            )
        else {
            return nil
        }
        let promotionEvidence: ObjectReidentificationPromotionEvidence
        do {
            promotionEvidence = try ObjectReidentificationPromotionEvidence(
                observations: promotionObservations
            )
        } catch {
            metrics.ambiguousReidentifications &+= 1
            return nil
        }
        guard !Task.isCancelled,
            generation == lifecycleGeneration,
            let currentIdentity = confirmedIdentityProvider(frame),
            let currentMapID = currentIdentity.mapID,
            currentMapID == promotedMetadata.mapID,
            currentIdentity.coordinateFrameID == promotedMetadata.position.coordinateFrameID
        else {
            metrics.staleResultsRejected &+= 1
            return nil
        }

        let currentPromotedMetadata = try refreshedPromotedMetadata(
            promotedMetadata,
            from: promotionObservation,
            evidence: promotionEvidence
        )
        let established = temporalIdentityByPromotedObjectID[promotedMetadata.object.id]
        if let established, case .genuinelyNew = established.decision {
            // A genuinely-new durable identity is never converted into a
            // repeated observation from transient track continuity alone.
            return nil
        }

        let existingObjects = try await metadataProvider()
        try Task.checkCancellation()
        guard generation == lifecycleGeneration,
            confirmedIdentityProvider(frame) == currentIdentity
        else {
            metrics.staleResultsRejected &+= 1
            return nil
        }
        let context = try reidentificationContextBuilder.makeContexts(
            for: currentPromotedMetadata,
            existingObjects: existingObjects
        )
        let decision: PersistentObjectReidentificationDecision
        let metadata: SpatialObjectMetadata
        let referenceMetadata: SpatialObjectMetadata
        if context.candidates.isEmpty {
            guard established == nil else {
                return nil
            }
            decision = .genuinelyNew
            metadata = currentPromotedMetadata
            referenceMetadata = currentPromotedMetadata
        } else {
            let request = try PersistentObjectReidentificationRequest(
                promotedObject: currentPromotedMetadata,
                promotionEvidence: promotionEvidence,
                incomingContext: context.incoming,
                candidateContexts: context.candidates
            )
            decision = try reidentificationResolver.resolve(
                request,
                against: context.eligibleExistingObjects
            )
            switch decision {
            case .confirmedExisting(let candidate):
                if let established,
                    candidate.objectID != established.referenceMetadata.object.id
                {
                    metrics.ambiguousReidentifications &+= 1
                    return nil
                }
                guard
                    let existing = context.eligibleExistingObjects.first(where: {
                        $0.object.id == candidate.objectID
                    })
                else {
                    metrics.ambiguousReidentifications &+= 1
                    return nil
                }
                metadata = try metadataReusingPersistentIdentity(
                    currentPromotedMetadata,
                    existing: existing
                )
                referenceMetadata = existing
            case .genuinelyNew:
                guard established == nil else {
                    metrics.ambiguousReidentifications &+= 1
                    return nil
                }
                metadata = currentPromotedMetadata
                referenceMetadata = currentPromotedMetadata
            case .ambiguousCandidates:
                metrics.ambiguousReidentifications &+= 1
                return nil
            }
        }
        let resolution = TemporalIdentityResolution(
            decision: decision,
            referenceMetadata: referenceMetadata
        )
        return ResolvedTemporalObservation(
            promotedObjectID: promotedMetadata.object.id,
            observation: try TemporalSpatialObservation(
                metadata: metadata,
                promotionEvidence: promotionEvidence,
                identityDecision: decision
            ),
            identityResolution: resolution,
            establishesIdentity: established == nil
        )
    }

    private func refreshedPromotedMetadata(
        _ promoted: SpatialObjectMetadata,
        from observation: ObjectPromotionObservation,
        evidence: ObjectReidentificationPromotionEvidence
    ) throws -> SpatialObjectMetadata {
        let object = try SpatialObject(
            id: promoted.object.id,
            semanticLabel: promoted.object.semanticLabel,
            nodeID: promoted.object.nodeID,
            position: observation.position.value,
            bounds: observation.bounds ?? promoted.object.bounds,
            certainty: .confirmed,
            presence: .visible,
            confidence: ConfidenceVector(
                semantic: observation.semanticConfidence,
                geometry: observation.geometryConfidence,
                tracking: promoted.object.confidence.tracking,
                place: promoted.object.confidence.place,
                identity: promoted.object.confidence.identity,
                objectState: promoted.object.confidence.objectState,
                relation: promoted.object.confidence.relation
            ),
            // This is transient request metadata for the current evidence
            // window. Reusing an identity preserves its durable firstSeenAt.
            firstSeenAt: evidence.firstObservedAt,
            lastSeenAt: observation.position.observedAt,
            stateUpdatedAt: observation.position.observedAt
        )
        return try SpatialObjectMetadata(
            mapID: promoted.mapID,
            object: object,
            position: observation.position
        )
    }

    private func nextTemporalSequence(
        for capturedAt: TimeInterval
    ) throws -> UInt64 {
        guard capturedAt.isFinite, capturedAt >= 0 else {
            throw TemporalMemoryPipelineError.invalidCaptureTime
        }
        // The service continues the durable journal sequence across launches;
        // this local admission counter never derives ordering from calendar time.
        let (next, overflow) = (lastTemporalSequenceNumber ?? 0).addingReportingOverflow(1)
        guard !overflow else {
            throw TemporalMemoryPipelineError.sequenceOverflow
        }
        return next
    }

    private func removeTerminalCoverageObjects(
        from result: TemporalSpatialMemoryServiceResult
    ) {
        switch result {
        case .applied(let delta):
            for change in delta.changes {
                if case .removed(let objectID, _, _, _) = change {
                    latestTemporalMetadataByObjectID.removeValue(forKey: objectID)
                }
            }
        case .alreadyProcessed(let snapshot):
            for objectID in Array(latestTemporalMetadataByObjectID.keys) {
                guard let metadata = snapshot.metadata(for: objectID),
                    metadata.object.presence != .removed
                else {
                    latestTemporalMetadataByObjectID.removeValue(forKey: objectID)
                    continue
                }
                latestTemporalMetadataByObjectID[objectID] = metadata
            }
        }
    }

    private func perceptionObservations(
        in frame: ARFrameSnapshot,
        generation: UInt64
    ) async throws -> PerceptionFrameObservations {
        let shouldRunDetector =
            activeTracks.isEmpty
            || lastDetectorTimestamp.map {
                frame.pose.timestamp - $0 >= detectorInterval
            } ?? true

        if shouldRunDetector {
            let detections = try await detectorResolution.detector.detect(in: frame)
            try Task.checkCancellation()
            guard generation == lifecycleGeneration else {
                throw CancellationError()
            }

            let observations = associateDetectionsWithTracks(detections)
            await tracker.seed(
                observations.map {
                    TrackingSeed(id: $0.trackID, boundingBox: $0.detection.boundingBox)
                }
            )
            try Task.checkCancellation()
            guard generation == lifecycleGeneration else {
                throw CancellationError()
            }

            activeTracks = Dictionary(
                uniqueKeysWithValues: observations.map { observation in
                    (
                        observation.trackID,
                        ActiveTrack(
                            id: observation.trackID,
                            label: observation.detection.label,
                            semanticConfidence: observation.detection.confidence,
                            boundingBox: observation.detection.boundingBox
                        )
                    )
                }
            )
            lastDetectorTimestamp = frame.pose.timestamp
            return PerceptionFrameObservations(
                observations: observations,
                detectorExpectedVisibleObjectIDs: try await detectorExpectedVisibleObjectIDs(
                    in: frame,
                    detections: detections
                )
            )
        }

        let tracked = try await tracker.track(in: frame)
        try Task.checkCancellation()
        guard generation == lifecycleGeneration else {
            throw CancellationError()
        }

        var nextTracks: [VisionTrackID: ActiveTrack] = [:]
        let observations = tracked.compactMap { trackedObject -> PerceptionObservation? in
            guard
                trackedObject.boundingBox.isValidNonEmpty,
                let previous = activeTracks[trackedObject.id]
            else {
                return nil
            }
            let combinedConfidence = previous.semanticConfidence * trackedObject.confidence
            guard combinedConfidence.isFinite, combinedConfidence > 0 else {
                return nil
            }
            let updated = ActiveTrack(
                id: previous.id,
                label: previous.label,
                semanticConfidence: previous.semanticConfidence,
                boundingBox: trackedObject.boundingBox
            )
            nextTracks[updated.id] = updated
            return PerceptionObservation(
                detection: DetectedObject(
                    label: previous.label,
                    confidence: min(1, combinedConfidence),
                    boundingBox: trackedObject.boundingBox
                ),
                trackID: updated.id
            )
        }
        activeTracks = nextTracks
        return PerceptionFrameObservations(
            observations: observations.sorted { left, right in
                left.trackID.rawValue.uuidString < right.trackID.rawValue.uuidString
            },
            detectorExpectedVisibleObjectIDs: []
        )
    }

    private func associateDetectionsWithTracks(
        _ detections: [DetectedObject]
    ) -> [PerceptionObservation] {
        var availableTracks = activeTracks
        var observations: [PerceptionObservation] = []
        observations.reserveCapacity(detections.count)

        for detection in detections where detection.boundingBox.isValidNonEmpty {
            let normalizedLabel = detection.label
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let candidates = availableTracks.values.compactMap {
                track -> (track: ActiveTrack, score: Double)? in
                guard track.label.lowercased() == normalizedLabel else {
                    return nil
                }
                let iou = track.boundingBox.intersectionOverUnion(
                    with: detection.boundingBox
                )
                let centerDistance = track.boundingBox.centerDistance(
                    to: detection.boundingBox
                )
                guard iou >= 0.20 || centerDistance <= 0.12 else {
                    return nil
                }
                return (track, iou - centerDistance)
            }
            .sorted { left, right in
                if left.score != right.score {
                    return left.score > right.score
                }
                return left.track.id.rawValue.uuidString
                    < right.track.id.rawValue.uuidString
            }
            let trackID = candidates.first?.track.id ?? VisionTrackID()
            availableTracks.removeValue(forKey: trackID)
            observations.append(
                PerceptionObservation(detection: detection, trackID: trackID)
            )
        }
        return observations
    }

    /// Negative evidence is admitted only on a real detector pass. Candidate
    /// objects are reloaded from durable metadata on every pass so a process
    /// restart or foreground transition cannot erase coverage knowledge. The
    /// current-session cache supplements the durable snapshot only for a commit
    /// that has just completed. A candidate must still project into the
    /// conservative interior of the current camera image and have no same-class
    /// image detection in this pass. Reliable raw depth must also prove that
    /// the stored position is unobstructed in this exact frame. Tracker-only
    /// cadence frames never enter this set.
    private func detectorExpectedVisibleObjectIDs(
        in frame: ARFrameSnapshot,
        detections: [DetectedObject]
    ) async throws -> Set<ObjectID> {
        guard temporalMemoryProcessor != nil else {
            return []
        }
        let durableMetadata = try await metadataProvider()
        try Task.checkCancellation()

        var candidateMetadataByObjectID = latestTemporalMetadataByObjectID
        for metadata in durableMetadata {
            // The durable snapshot is authoritative for IDs it contains. In
            // particular, a durable removed state must override a stale visible
            // value left in the in-memory coverage cache.
            candidateMetadataByObjectID[metadata.object.id] = metadata
        }
        let detectedLabels = Set(
            detections.map {
                $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        )
        return Set(
            candidateMetadataByObjectID.values.compactMap { metadata in
                let semanticKey = metadata.object.semanticLabel
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !detectedLabels.contains(semanticKey),
                    projectsIntoReliableDetectorRegion(metadata, in: frame)
                else {
                    return nil
                }
                return metadata.object.id
            }
        )
    }

    private func projectsIntoReliableDetectorRegion(
        _ metadata: SpatialObjectMetadata,
        in frame: ARFrameSnapshot
    ) -> Bool {
        guard metadata.object.certainty == .confirmed,
            metadata.object.presence != .removed,
            metadata.mapID == frame.pose.mapID,
            metadata.position.coordinateFrameID == frame.pose.coordinateFrameID,
            frame.cameraImageDimensions.width > 0,
            frame.cameraImageDimensions.height > 0
        else {
            return false
        }

        let cameraTransform = frame.pose.cameraTransform.simdValue
        let transformValues = [
            cameraTransform.columns.0.x, cameraTransform.columns.0.y,
            cameraTransform.columns.0.z, cameraTransform.columns.0.w,
            cameraTransform.columns.1.x, cameraTransform.columns.1.y,
            cameraTransform.columns.1.z, cameraTransform.columns.1.w,
            cameraTransform.columns.2.x, cameraTransform.columns.2.y,
            cameraTransform.columns.2.z, cameraTransform.columns.2.w,
            cameraTransform.columns.3.x, cameraTransform.columns.3.y,
            cameraTransform.columns.3.z, cameraTransform.columns.3.w,
        ]
        guard transformValues.allSatisfy(\.isFinite) else {
            return false
        }
        let worldToCamera = simd_inverse(cameraTransform)
        let cameraPoint =
            worldToCamera
            * SIMD4<Float>(
                Float(metadata.position.value.x),
                Float(metadata.position.value.y),
                Float(metadata.position.value.z),
                1
            )
        guard cameraPoint.x.isFinite, cameraPoint.y.isFinite,
            cameraPoint.z.isFinite, cameraPoint.w.isFinite,
            abs(cameraPoint.w) > Float.ulpOfOne
        else {
            return false
        }

        let x = cameraPoint.x / cameraPoint.w
        let y = cameraPoint.y / cameraPoint.w
        let depth = -(cameraPoint.z / cameraPoint.w)
        guard depth.isFinite, depth >= 0.20, depth <= 8 else {
            return false
        }
        let intrinsics = frame.cameraIntrinsics.simdValue
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        guard fx.isFinite, fy.isFinite, cx.isFinite, cy.isFinite,
            fx > 0, fy > 0
        else {
            return false
        }
        let pixelX = fx * (x / depth) + cx
        let pixelY = cy - fy * (y / depth)
        let normalizedX = Double(pixelX) / Double(frame.cameraImageDimensions.width)
        let normalizedY = Double(pixelY) / Double(frame.cameraImageDimensions.height)
        let reliableMargin = 0.05
        guard
            normalizedX.isFinite && normalizedY.isFinite
                && normalizedX >= reliableMargin
                && normalizedX <= 1 - reliableMargin
                && normalizedY >= reliableMargin
                && normalizedY <= 1 - reliableMargin
        else {
            return false
        }

        // A neighborhood median can select background beside a foreground
        // occluder, and smoothed depth can retain a surface from an older
        // frame. Neither proves visibility along this exact current ray.
        let sampler = ARDepthSampler(minimumConfidence: .high, neighborhoodRadius: 0)
        guard
            case .sample(let sample) = sampler.sample(
                normalizedImagePoint: SIMD2<Float>(Float(normalizedX), Float(normalizedY)),
                in: frame,
                prefersSmoothedDepth: false
            ), sample.source == .raw,
            sample.frameID == frame.pose.id,
            sample.coordinateFrameID == metadata.position.coordinateFrameID,
            sample.confidence == .high
        else {
            return false
        }
        // Depth at the stored surface can still be the undetected object.
        // Admit a miss only when the measured surface is clearly beyond it.
        return sample.depthMeters > depth + 0.10
    }

    private func finishProcessing(
        _ descriptor: FrameDescriptor,
        generation: UInt64,
        taskID: UUID
    ) {
        processingTasks.removeValue(forKey: taskID)
        guard currentProcessingTaskID == taskID else {
            return
        }
        bufferedFrames.removeValue(forKey: descriptor.id)
        processingTask = nil
        currentProcessingTaskID = nil
        guard generation == lifecycleGeneration else {
            return
        }
        let previouslyPendingID = scheduler.pendingLatest?.id
        let nextDescriptor: FrameDescriptor?
        do {
            nextDescriptor = try scheduler.complete(
                descriptor.id,
                now: ProcessInfo.processInfo.systemUptime
            )
        } catch {
            state = .failed(message: String(describing: error))
            return
        }
        if let previouslyPendingID, previouslyPendingID != nextDescriptor?.id {
            bufferedFrames.removeValue(forKey: previouslyPendingID)
        }
        guard let nextDescriptor,
            let nextFrame = bufferedFrames[nextDescriptor.id]
        else {
            return
        }
        startProcessing(nextFrame, descriptor: nextDescriptor)
    }

    private func resetPipeline(incrementGeneration: Bool) {
        if incrementGeneration {
            lifecycleGeneration &+= 1
        }
        cancelProcessingTasks()
        scheduler = FrameAdmissionScheduler(policy: admissionPolicy)
        promoter = ObjectObservationPromoter(policy: promotionPolicy)
        bufferedFrames.removeAll(keepingCapacity: false)
        persistedObjectIDs.removeAll(keepingCapacity: false)
        promotionEvidenceByObjectID.removeAll(keepingCapacity: false)
        temporalIdentityByPromotedObjectID.removeAll(keepingCapacity: false)
        latestTemporalMetadataByObjectID.removeAll(keepingCapacity: false)
        nextSequenceNumber = 0
        activeFrameToken = nil
        activeTracks.removeAll(keepingCapacity: false)
        lastDetectorTimestamp = nil
        lastResourceAcceptedTimestamp = nil
        lastCalendarSample = nil
    }

    private func cancelProcessingTasks() {
        for task in processingTasks.values {
            task.cancel()
        }
        // Cancellation releases the admission slot, but the registry retains
        // every generation until its async writer has actually returned.
        processingTask = nil
        currentProcessingTaskID = nil
    }

    private struct PerceptionObservation: Sendable {
        let detection: DetectedObject
        let trackID: VisionTrackID
    }

    private struct PerceptionFrameObservations: Sendable {
        let observations: [PerceptionObservation]
        let detectorExpectedVisibleObjectIDs: Set<ObjectID>
    }

    private struct TemporalIdentityResolution: Sendable {
        let decision: PersistentObjectReidentificationDecision
        let referenceMetadata: SpatialObjectMetadata

        var reusedPersistentIdentity: Bool {
            if case .confirmedExisting = decision {
                return true
            }
            return false
        }
    }

    private struct ResolvedTemporalObservation: Sendable {
        let promotedObjectID: ObjectID
        let observation: TemporalSpatialObservation
        let identityResolution: TemporalIdentityResolution
        let establishesIdentity: Bool
    }

    private enum TemporalMemoryPipelineError: Error {
        case invalidCaptureTime
        case sequenceOverflow
    }

    private struct ActiveTrack: Sendable {
        let id: VisionTrackID
        let label: String
        let semanticConfidence: Float
        let boundingBox: NormalizedBoundingBox
    }

    private func metadataReusingPersistentIdentity(
        _ incoming: SpatialObjectMetadata,
        existing: SpatialObjectMetadata
    ) throws -> SpatialObjectMetadata {
        let object = try SpatialObject(
            id: existing.object.id,
            semanticLabel: incoming.object.semanticLabel,
            nodeID: existing.object.nodeID,
            position: incoming.object.position,
            bounds: incoming.object.bounds ?? existing.object.bounds,
            certainty: .confirmed,
            presence: .visible,
            confidence: incoming.object.confidence,
            firstSeenAt: min(existing.object.firstSeenAt, incoming.object.firstSeenAt),
            lastSeenAt: incoming.object.lastSeenAt,
            stateUpdatedAt: incoming.object.lastSeenAt
        )
        return try SpatialObjectMetadata(
            mapID: incoming.mapID,
            object: object,
            position: incoming.position
        )
    }

    deinit {
        monitorTask?.cancel()
        for task in processingTasks.values {
            task.cancel()
        }
    }
}
