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

public struct ObjectIdentityConfirmationCandidate: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let observedObjectID: ObjectID
    public let observedMetadata: SpatialObjectMetadata
    public let existingCandidates: [SpatialObjectMetadata]
    public let frameID: FrameID
    public let capturedAt: TimeInterval
    public let sessionToken: ARSessionFrameToken
}

public enum ObjectIdentityConfirmationError: Error, Equatable, Sendable {
    case staleCandidate
    case staleExistingObject
    case unavailable
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
    @Published public private(set) var identityConfirmationCandidates: [ObjectIdentityConfirmationCandidate] =
        []
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

    #if DEBUG
    /// Joins work after the test has observed admission of its intended frame.
    /// The enclosing XCTest time allowance bounds failures to make progress.
    func waitForProcessingCompletionForTesting() async {
        while let current = processingTask {
            await current.value
        }
    }
    #endif

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
    private struct IdentityReview: Sendable {
        let candidate: ObjectIdentityConfirmationCandidate
        let frame: ARFrameSnapshot
        var pose: ARPoseSnapshot { frame.pose }
    }
    private var acceptedNewObjects: [ObjectID: IdentityReview] = [:]
    private var identityReviews: [ObjectID: IdentityReview] = [:]
    private var queuedIdentityConfirmations: [ObjectID: PersistentObjectIdentitySupport] = [:]
    private var trackingSamples: [VisionTrackID: [ContinuousObjectTrackingSample]] = [:]
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
        identityReviews = identityReviews.filter {
            $0.value.pose.sessionToken == frame.pose.sessionToken
                && $0.value.pose.mapID == identity.mapID
                && $0.value.pose.coordinateFrameID == identity.coordinateFrameID
                && frame.pose.timestamp - $0.value.pose.timestamp <= 2
        }
        queuedIdentityConfirmations = queuedIdentityConfirmations.filter { _, support in
            if case .userConfirmation(
                _, _, let mapID, let coordinateFrameID, let segmentID, _, _, let reviewedAt, _) = support
            {
                return mapID == identity.mapID && coordinateFrameID == identity.coordinateFrameID
                    && segmentID == identity.segmentID && frame.pose.capturedAt - reviewedAt <= 2
            }
            return false
        }
        acceptedNewObjects = acceptedNewObjects.filter { identityReviews[$0.key] != nil }
        refreshIdentityReviewList()
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
                if error as? TemporalSpatialMemoryServiceError == .captureAuthorityMismatch {
                    metrics.staleResultsRejected &+= 1
                    throw CancellationError()
                }
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
                identityReviews.removeValue(forKey: value.promotedObjectID)
                acceptedNewObjects.removeValue(forKey: value.promotedObjectID)
                latestTemporalMetadataByObjectID[value.observation.metadata.object.id] =
                    value.observation.metadata
            }
            refreshIdentityReviewList()
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

        let sample = ContinuousObjectTrackingSample(
            frameID: FrameID(rawValue: frame.pose.id.rawValue),
            position: located.position, captureSegmentID: identity.segmentID,
            monotonicTimestamp: frame.pose.timestamp,
            trackerConfidence: perceptionObservation.trackerConfidence,
            associationMargin: perceptionObservation.associationMargin, bounds: located.bounds,
            geometryConfidence: located.geometryConfidence)
        if perceptionObservation.trackerConfidence.map({ $0.value >= 0.8 }) != true
            || perceptionObservation.associationMargin < 0.15
        {
            trackingSamples[perceptionObservation.trackID] = [sample]
        } else {
            var samples = trackingSamples[perceptionObservation.trackID] ?? []
            if let previous = samples.last,
                (frame.pose.timestamp - previous.monotonicTimestamp > 0.6
                    || previous.captureSegmentID != identity.segmentID)
            {
                samples.removeAll()
            }
            samples.append(sample)
            trackingSamples[perceptionObservation.trackID] = Array(samples.suffix(32))
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
        // The promoter's ID becomes durable when a genuinely-new object is
        // committed. Re-ID requests need a separate, nonpersistent ID so that
        // object remains an eligible candidate on subsequent observations.
        // This ID supplies no identity evidence: the resolver must still verify
        // the rolling observations, geometry, independent context and ambiguity.
        let reidentificationMetadata = try refreshedPromotedMetadata(
            promotedMetadata,
            objectID: ObjectID(),
            from: promotionObservation,
            evidence: promotionEvidence
        )

        let existingObjects = try await metadataProvider()
        try Task.checkCancellation()
        guard generation == lifecycleGeneration,
            confirmedIdentityProvider(frame) == currentIdentity
        else {
            metrics.staleResultsRejected &+= 1
            return nil
        }
        let context = try reidentificationContextBuilder.makeContexts(
            for: reidentificationMetadata,
            existingObjects: existingObjects
        )
        let decision: PersistentObjectReidentificationDecision
        let metadata: SpatialObjectMetadata
        let referenceMetadata: SpatialObjectMetadata
        var identitySupport: PersistentObjectIdentitySupport?
        let establishedExisting = established.flatMap { established in
            existingObjects.first { $0.object.id == established.referenceMetadata.object.id }
        }
        let continuousIncoming: SpatialObjectMetadata
        if let existing = establishedExisting, existing.object.detectorSemanticLabel != nil {
            continuousIncoming = try metadataReusingPersistentIdentity(
                currentPromotedMetadata, existing: existing)
        } else {
            continuousIncoming = currentPromotedMetadata
        }
        let continuousSupport = establishedExisting.map {
            PersistentObjectIdentitySupport.continuousTracking(
                objectID: $0.object.id,
                samples: trackingSamples[perceptionObservation.trackID] ?? [])
        }
        if let review = acceptedNewObjects[promotedMetadata.object.id], established == nil,
            review.pose.sessionToken == frame.pose.sessionToken,
            frame.pose.timestamp - review.pose.timestamp <= 2,
            review.candidate.observedMetadata.position.value.distance(
                to: currentPromotedMetadata.position.value) <= 0.12
        {
            decision = .genuinelyNew
            metadata = currentPromotedMetadata
            referenceMetadata = currentPromotedMetadata
        } else if let support = queuedIdentityConfirmations[promotedMetadata.object.id],
            let existing = existingObjects.first(where: { $0.object.id == support.objectID }),
            let supportedDecision = try reidentificationResolver.resolveSupportedIdentity(
                incoming: metadataReusingPersistentIdentity(currentPromotedMetadata, existing: existing),
                promotionEvidence: promotionEvidence, support: support, against: existing)
        {
            decision = supportedDecision
            identitySupport = support
            metadata = try metadataReusingPersistentIdentity(currentPromotedMetadata, existing: existing)
            referenceMetadata = existing
        } else if let existing = establishedExisting, let support = continuousSupport,
            let supportedDecision = try reidentificationResolver.resolveSupportedIdentity(
                incoming: continuousIncoming, promotionEvidence: promotionEvidence,
                support: support, against: existing)
        {
            decision = supportedDecision
            identitySupport = support
            metadata = try metadataReusingPersistentIdentity(currentPromotedMetadata, existing: existing)
            referenceMetadata = existing
        } else if context.candidates.isEmpty {
            guard established == nil else {
                return nil
            }
            if publishIdentityReview(
                for: currentPromotedMetadata, frame: frame,
                existingObjects: existingObjects)
            {
                return nil
            }
            decision = .genuinelyNew
            metadata = currentPromotedMetadata
            referenceMetadata = currentPromotedMetadata
        } else {
            let request = try PersistentObjectReidentificationRequest(
                promotedObject: reidentificationMetadata,
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
                if publishIdentityReview(
                    for: currentPromotedMetadata, frame: frame,
                    existingObjects: existingObjects)
                {
                    return nil
                }
                metadata = currentPromotedMetadata
                referenceMetadata = currentPromotedMetadata
            case .ambiguousCandidates:
                if established == nil {
                    _ = publishIdentityReview(
                        for: currentPromotedMetadata, frame: frame,
                        existingObjects: existingObjects)
                }
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
                identityDecision: decision,
                identitySupport: identitySupport
            ),
            identityResolution: resolution,
            establishesIdentity: established == nil
        )
    }

    /// Records explicit user authority for the next stable observation. Returning
    /// means the confirmation was queued; the normal temporal batch performs
    /// the durable write and rechecks both identities and the reviewed position.
    public func confirmObservedObjectIdentity(
        candidateID: UUID, existingObjectID: ObjectID,
        expectedTemporalRevision: UInt64?
    ) async throws {
        guard isActive, temporalMemoryProcessor != nil else {
            throw ObjectIdentityConfirmationError.unavailable
        }
        guard let review = identityReviews.values.first(where: { $0.candidate.id == candidateID }),
            review.pose.sessionToken == activeFrameToken,
            ProcessInfo.processInfo.systemUptime - review.pose.timestamp <= 2,
            confirmedIdentityProvider(review.frame)?.mapID == review.pose.mapID,
            confirmedIdentityProvider(review.frame)?.coordinateFrameID == review.pose.coordinateFrameID,
            confirmedIdentityProvider(review.frame)?.segmentID == review.pose.segmentID
        else {
            throw ObjectIdentityConfirmationError.staleCandidate
        }
        guard
            let reviewedExisting = review.candidate.existingCandidates.first(where: {
                $0.object.id == existingObjectID
            }),
            reviewedExisting.object.temporalRevision == expectedTemporalRevision
        else {
            throw ObjectIdentityConfirmationError.staleExistingObject
        }
        let generation = lifecycleGeneration
        let current = try await metadataProvider()
        guard generation == lifecycleGeneration, isActive,
            identityReviews[review.candidate.observedObjectID]?.candidate.id == candidateID
        else {
            throw ObjectIdentityConfirmationError.staleCandidate
        }
        guard current.first(where: { $0.object.id == existingObjectID }) == reviewedExisting else {
            throw ObjectIdentityConfirmationError.staleExistingObject
        }
        queuedIdentityConfirmations[review.candidate.observedObjectID] = .userConfirmation(
            objectID: existingObjectID, expectedTemporalRevision: expectedTemporalRevision,
            mapID: reviewedExisting.mapID, coordinateFrameID: reviewedExisting.position.coordinateFrameID,
            captureSegmentID: review.pose.segmentID, reviewedFrameID: review.candidate.frameID,
            reviewedPosition: review.candidate.observedMetadata.position.value,
            reviewedAt: review.pose.capturedAt,
            confirmedAt: max(review.pose.capturedAt, Date().timeIntervalSince1970))
    }

    /// The user can also establish that a same-class detection is a distinct
    /// physical object. This never merges or edits any existing record.
    public func acceptObservedObjectAsNew(candidateID: UUID) async throws {
        guard isActive, let review = identityReviews.values.first(where: { $0.candidate.id == candidateID }),
            review.pose.sessionToken == activeFrameToken,
            ProcessInfo.processInfo.systemUptime - review.pose.timestamp <= 2,
            confirmedIdentityProvider(review.frame)?.mapID == review.pose.mapID,
            confirmedIdentityProvider(review.frame)?.coordinateFrameID == review.pose.coordinateFrameID,
            confirmedIdentityProvider(review.frame)?.segmentID == review.pose.segmentID
        else {
            throw ObjectIdentityConfirmationError.staleCandidate
        }
        acceptedNewObjects[review.candidate.observedObjectID] = review
    }

    private func publishIdentityReview(
        for metadata: SpatialObjectMetadata, frame: ARFrameSnapshot,
        existingObjects: [SpatialObjectMetadata]
    ) -> Bool {
        let candidates = existingObjects.filter {
            $0.object.id != metadata.object.id && $0.mapID == metadata.mapID
                && $0.position.coordinateFrameID == metadata.position.coordinateFrameID
                && ($0.object.semanticLabel == metadata.object.semanticLabel
                    || $0.object.detectorSemanticLabel == metadata.object.semanticLabel)
                && $0.object.certainty == .confirmed && $0.object.presence != .removed
        }.sorted { $0.object.id < $1.object.id }
        guard !candidates.isEmpty else { return false }
        identityReviews = identityReviews.filter {
            $0.value.pose.sessionToken == frame.pose.sessionToken
                && frame.pose.timestamp - $0.value.pose.timestamp <= 2
        }
        // Keep exactly the snapshot the user is reviewing while its physical
        // hypothesis and existing records remain unchanged within the expiry.
        if let current = identityReviews[metadata.object.id],
            current.pose.sessionToken == frame.pose.sessionToken,
            current.candidate.existingCandidates.map(\.object.id)
                == Array(candidates.prefix(32)).map(\.object.id),
            current.candidate.observedMetadata.position.value.distance(to: metadata.position.value) <= 0.12
        {
            refreshIdentityReviewList()
            return true
        }
        // Bounded UI hypotheses; no provisional identity is written to disk.
        if identityReviews.count >= 32 && identityReviews[metadata.object.id] == nil { return true }
        identityReviews[metadata.object.id] = IdentityReview(
            candidate: ObjectIdentityConfirmationCandidate(
                id: UUID(), observedObjectID: metadata.object.id, observedMetadata: metadata,
                existingCandidates: Array(candidates.prefix(32)),
                frameID: FrameID(rawValue: frame.pose.id.rawValue), capturedAt: frame.pose.capturedAt,
                sessionToken: frame.pose.sessionToken), frame: frame)
        refreshIdentityReviewList()
        return true
    }

    private func refreshIdentityReviewList() {
        identityConfirmationCandidates = identityReviews.values.map(\.candidate).sorted {
            $0.observedObjectID < $1.observedObjectID
        }
    }

    private func refreshedPromotedMetadata(
        _ promoted: SpatialObjectMetadata,
        objectID: ObjectID? = nil,
        from observation: ObjectPromotionObservation,
        evidence: ObjectReidentificationPromotionEvidence
    ) throws -> SpatialObjectMetadata {
        let object = try SpatialObject(
            id: objectID ?? promoted.object.id,
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

            let predictions: [TrackedObject]
            if activeTracks.isEmpty {
                predictions = []
            } else {
                predictions = try await tracker.track(in: frame)
            }
            try Task.checkCancellation()
            guard generation == lifecycleGeneration else { throw CancellationError() }
            let observations = associateDetectionsWithTracks(detections, predictions: predictions)
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
            trackingSamples = trackingSamples.filter { activeTracks[$0.key] != nil }
            if observations.isEmpty {
                identityReviews.removeAll()
                acceptedNewObjects.removeAll()
                queuedIdentityConfirmations.removeAll()
                refreshIdentityReviewList()
            }
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
                trackID: updated.id,
                trackerConfidence: ConfidenceScore(clamping: Double(trackedObject.confidence)),
                associationMargin: 1
                    - (tracked.filter { $0.id != trackedObject.id }.map {
                        $0.boundingBox.intersectionOverUnion(with: trackedObject.boundingBox)
                    }.max() ?? 0)
            )
        }
        activeTracks = nextTracks
        trackingSamples = trackingSamples.filter { nextTracks[$0.key] != nil }
        if observations.isEmpty {
            identityReviews.removeAll()
            acceptedNewObjects.removeAll()
            queuedIdentityConfirmations.removeAll()
            refreshIdentityReviewList()
        }
        return PerceptionFrameObservations(
            observations: observations.sorted { left, right in
                left.trackID.rawValue.uuidString < right.trackID.rawValue.uuidString
            },
            detectorExpectedVisibleObjectIDs: []
        )
    }

    private func associateDetectionsWithTracks(
        _ detections: [DetectedObject], predictions: [TrackedObject]
    ) -> [PerceptionObservation] {
        let predictionsByID = Dictionary(
            predictions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var availableTracks = activeTracks
        var observations: [PerceptionObservation] = []
        observations.reserveCapacity(detections.count)

        for (detectionIndex, detection) in detections.enumerated() where detection.boundingBox.isValidNonEmpty
        {
            let normalizedLabel = detection.label
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let candidates = availableTracks.values.compactMap {
                track -> (track: ActiveTrack, score: Double)? in
                guard track.label.lowercased() == normalizedLabel else {
                    return nil
                }
                let predictedBox = predictionsByID[track.id]?.boundingBox ?? track.boundingBox
                let iou = predictedBox.intersectionOverUnion(with: detection.boundingBox)
                let centerDistance = predictedBox.centerDistance(
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
            let prediction = predictionsByID[trackID]
            let overlap = prediction?.boundingBox.intersectionOverUnion(with: detection.boundingBox) ?? 0
            let otherDetectionOverlap =
                prediction.map { prediction in
                    detections.enumerated().filter { $0.offset != detectionIndex }.map {
                        prediction.boundingBox.intersectionOverUnion(with: $0.element.boundingBox)
                    }.max() ?? 0
                } ?? 0
            let otherTrackOverlap =
                predictions.filter { $0.id != trackID }.map {
                    $0.boundingBox.intersectionOverUnion(with: detection.boundingBox)
                }.max() ?? 0
            let margin = overlap - max(otherDetectionOverlap, otherTrackOverlap)
            observations.append(
                PerceptionObservation(
                    detection: detection, trackID: trackID,
                    trackerConfidence: overlap >= 0.60 && margin >= 0.15
                        ? prediction.map { ConfidenceScore(clamping: Double($0.confidence)) } : nil,
                    associationMargin: margin))
        }
        return observations
    }

    /// Negative evidence is admitted only on a real detector pass. Candidate
    /// objects are reloaded from durable metadata on every pass so a process
    /// restart or foreground transition cannot erase coverage knowledge. The
    /// current-session cache supplements the durable snapshot only for a commit
    /// that has just completed. A candidate must still project into the
    /// conservative interior of the current camera image and have no overlapping
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
        return Set(
            candidateMetadataByObjectID.values.compactMap { metadata in
                projectsIntoReliableDetectorRegion(metadata, in: frame, detections: detections)
                    ? metadata.object.id : nil
            })
    }

    /// Each object's projected volume is evaluated independently. Detections
    /// elsewhere in the image do not hide empty-space evidence for this ID.
    private func projectsIntoReliableDetectorRegion(
        _ metadata: SpatialObjectMetadata, in frame: ARFrameSnapshot,
        detections: [DetectedObject]
    ) -> Bool {
        guard metadata.object.certainty == .confirmed,
            metadata.object.presence != .removed,
            metadata.mapID == frame.pose.mapID,
            metadata.position.coordinateFrameID == frame.pose.coordinateFrameID,
            frame.cameraImageDimensions.width > 0, frame.cameraImageDimensions.height > 0
        else { return false }
        let transform = frame.pose.cameraTransform.simdValue
        let worldToCamera = simd_inverse(transform)
        let intrinsics = frame.cameraIntrinsics.simdValue
        let fx = intrinsics.columns.0.x, fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x, cy = intrinsics.columns.2.y
        guard fx.isFinite, fy.isFinite, cx.isFinite, cy.isFinite, fx > 0, fy > 0
        else { return false }
        func project(_ point: Vec3) -> SIMD3<Float>? {
            let value = worldToCamera * SIMD4<Float>(Float(point.x), Float(point.y), Float(point.z), 1)
            guard value.x.isFinite, value.y.isFinite, value.z.isFinite, value.w.isFinite,
                abs(value.w) > Float.ulpOfOne
            else { return nil }
            let depth = -value.z / value.w
            guard depth >= 0.20, depth <= 8 else { return nil }
            let x = (fx * (value.x / value.w / depth) + cx) / Float(frame.cameraImageDimensions.width)
            let y = (cy - fy * (value.y / value.w / depth)) / Float(frame.cameraImageDimensions.height)
            guard x.isFinite, y.isFinite, x >= 0.05, x <= 0.95, y >= 0.05, y <= 0.95
            else { return nil }
            return SIMD3<Float>(x, y, depth)
        }
        // A point-only legacy record has no measured footprint: a background
        // ray through a chair's opening cannot establish that it was removed.
        guard let bounds = metadata.object.bounds else { return false }
        var points = [metadata.position.value]
        do {
            for x in [bounds.min.x, bounds.max.x] {
                for y in [bounds.min.y, bounds.max.y] {
                    for z in [bounds.min.z, bounds.max.z] {
                        guard let corner = try? Vec3(x: x, y: y, z: z) else { return false }
                        points.append(corner)
                    }
                }
            }
        }
        let projected = points.compactMap(project)
        guard projected.count == points.count, let center = projected.first else { return false }
        let minX = projected.map(\.x).min()!, maxX = projected.map(\.x).max()!
        let minY = projected.map(\.y).min()!, maxY = projected.map(\.y).max()!
        // Match in raw camera-image coordinates, including rotated Vision input.
        // Any label overlapping this footprint may be the object or an occluder.
        for detection in detections where detection.boundingBox.isValidNonEmpty {
            let corners = [
                SIMD2<Double>(0, 0), SIMD2<Double>(1, 0),
                SIMD2<Double>(0, 1), SIMD2<Double>(1, 1),
            ].compactMap {
                detection.boundingBox.cameraImageTopLeftPoint(
                    relativeToTopLeft: $0,
                    for: frame.imageOrientation)
            }
            guard corners.count == 4 else { return false }
            if corners.map(\.x).max()! >= minX - 0.015,
                corners.map(\.x).min()! <= maxX + 0.015,
                corners.map(\.y).max()! >= minY - 0.015,
                corners.map(\.y).min()! <= maxY + 0.015
            {
                return false
            }
        }
        let samplePoints = [
            SIMD2<Float>(center.x, center.y),
            SIMD2<Float>(minX + (maxX - minX) * 0.25, minY + (maxY - minY) * 0.25),
            SIMD2<Float>(minX + (maxX - minX) * 0.75, minY + (maxY - minY) * 0.25),
            SIMD2<Float>(minX + (maxX - minX) * 0.25, minY + (maxY - minY) * 0.75),
            SIMD2<Float>(minX + (maxX - minX) * 0.75, minY + (maxY - minY) * 0.75),
        ]
        let farthestStoredDepth = projected.map(\.z).max()!
        let sampler = ARDepthSampler(minimumConfidence: .high, neighborhoodRadius: 0)
        var sampledPixels = Set<SIMD2<Int>>()
        for point in samplePoints {
            guard
                case .sample(let sample) = sampler.sample(
                    normalizedImagePoint: point,
                    in: frame, prefersSmoothedDepth: false), sample.source == .raw,
                sample.frameID == frame.pose.id,
                sample.coordinateFrameID == metadata.position.coordinateFrameID,
                sample.confidence == .high,
                sample.depthMeters > farthestStoredDepth + 0.10
            else { return false }
            sampledPixels.insert(sample.depthPixel)
        }
        // Several requests landing on one depth texel are one piece of evidence.
        return sampledPixels.count >= 3
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
        trackingSamples.removeAll()
        identityReviews.removeAll()
        acceptedNewObjects.removeAll()
        queuedIdentityConfirmations.removeAll()
        identityConfirmationCandidates = []
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
        var trackerConfidence: ConfidenceScore? = nil
        var associationMargin: Double = 0
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
            semanticLabel: existing.object.detectorSemanticLabel == nil
                ? incoming.object.semanticLabel : existing.object.semanticLabel,
            nodeID: existing.object.nodeID,
            position: incoming.object.position,
            bounds: incoming.object.bounds ?? existing.object.bounds,
            certainty: .confirmed,
            presence: .visible,
            confidence: incoming.object.confidence,
            firstSeenAt: min(existing.object.firstSeenAt, incoming.object.firstSeenAt),
            lastSeenAt: incoming.object.lastSeenAt,
            stateUpdatedAt: incoming.object.lastSeenAt,
            displayName: existing.object.displayName,
            temporalRevision: existing.object.temporalRevision,
            detectorSemanticLabel: existing.object.detectorSemanticLabel
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
