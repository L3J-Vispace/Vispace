import Combine
import Foundation
import VispaceCore

public enum PlaceRecognitionControllerState: Equatable, Sendable {
    case inactive
    case waitingForCompleteSurface
    case fingerprinting
    case known(mapID: MapID, confidence: ConfidenceScore)
    case overlapping(mapID: MapID, confidence: ConfidenceScore)
    case newPlaceAwaitingCheckpoint(confidence: ConfidenceScore)
    case ambiguous(candidateMapIDs: [MapID], reason: PlaceAssociationDecisionReason)
    case failed(message: String)
}

public struct PlaceRecognitionMetrics: Equatable, Sendable {
    public var snapshotsReceived: UInt64 = 0
    public var snapshotsCoalesced: UInt64 = 0
    public var fingerprintsPersisted: UInt64 = 0
    public var associationObservationsPersisted: UInt64 = 0
    public var staleResultsRejected: UInt64 = 0
    public var logicalMergesCommitted: UInt64 = 0

    public init() {}
}

public enum LogicalMapMergeCommitError: Error, Equatable, Sendable {
    case identicalMaps
    case identityTransformRequired
    case crossFrameAlignmentRequired
    case alignmentContextMismatch
}

public enum PlaceRecognitionControllerError: Error, Equatable, Sendable {
    case invalidAlignmentResolutionContext
}

/// A merge receipt grounded in the exact reducer observation and, for
/// cross-frame maps, the estimator artifact that produced its transform.
public struct LogicalMapMergeCommit: Hashable, Sendable {
    public let associationStateID: PlaceAssociationStateID
    public let decidingObservationID: ObservationID
    public let sourceMapID: MapID
    public let sourceCoordinateFrameID: CoordinateFrameID
    public let targetMapID: MapID
    public let targetCoordinateFrameID: CoordinateFrameID
    public let sourceToTarget: Transform3D
    public let validatedAlignment: CoordinateFrameAlignmentResult?

    public init(
        associationStateID: PlaceAssociationStateID,
        decidingObservationID: ObservationID,
        sourceMapID: MapID,
        sourceCoordinateFrameID: CoordinateFrameID,
        targetMapID: MapID,
        targetCoordinateFrameID: CoordinateFrameID,
        sourceToTarget: Transform3D,
        validatedAlignment: CoordinateFrameAlignmentResult?
    ) throws {
        guard sourceMapID != targetMapID else {
            throw LogicalMapMergeCommitError.identicalMaps
        }
        if sourceCoordinateFrameID == targetCoordinateFrameID {
            guard sourceToTarget == .identity, validatedAlignment == nil else {
                throw LogicalMapMergeCommitError.identityTransformRequired
            }
        } else {
            guard let validatedAlignment else {
                throw LogicalMapMergeCommitError.crossFrameAlignmentRequired
            }
            guard validatedAlignment.sourceCoordinateFrameID == sourceCoordinateFrameID,
                validatedAlignment.targetCoordinateFrameID == targetCoordinateFrameID,
                validatedAlignment.sourceToTarget == sourceToTarget
            else {
                throw LogicalMapMergeCommitError.alignmentContextMismatch
            }
        }
        self.associationStateID = associationStateID
        self.decidingObservationID = decidingObservationID
        self.sourceMapID = sourceMapID
        self.sourceCoordinateFrameID = sourceCoordinateFrameID
        self.targetMapID = targetMapID
        self.targetCoordinateFrameID = targetCoordinateFrameID
        self.sourceToTarget = sourceToTarget
        self.validatedAlignment = validatedAlignment
    }
}

/// Phase 2 app coordinator. It consumes only coalesced, complete surface state,
/// builds privacy-preserving aggregate fingerprints, and applies the
/// deterministic place-association reducer before requesting any map mutation.
@MainActor
public final class PlaceRecognitionController: ObservableObject {
    public typealias SurfaceStreamProvider =
        @MainActor @Sendable () -> AsyncStream<ARSurfaceStateSnapshot>
    public typealias ObjectMetadataProvider = @Sendable () async throws -> [SpatialObjectMetadata]
    public typealias CatalogProvider = @Sendable () async throws -> PlaceMemoryCatalogSnapshot
    public typealias VerifiedAlignmentCatalogProvider =
        @Sendable () async throws -> CoordinateAlignmentCatalogSnapshot
    public typealias VisualHistogramProvider =
        @Sendable (ARSurfaceStateSnapshot) async throws -> NormalizedPlaceHistogram?
    public typealias FingerprintWriter = @Sendable (PlaceFingerprintRecord) async throws -> Void
    public typealias AssociationWriter =
        @Sendable (
            PlaceAssociationStateRecord
        ) async throws -> Void
    public typealias CoordinateCompatibilityProvider =
        @Sendable (
            ARSurfaceStateSnapshot,
            PlaceFingerprintRecord,
            [SpatialObjectMetadata]
        ) async throws -> PlaceCoordinateAlignmentResolution
    public typealias LogicalMergeWriter = @Sendable (LogicalMapMergeCommit) async throws -> Void
    public typealias MutationAcknowledger = @Sendable (PlaceAssociationStateID, UInt64) async throws -> Void
    public typealias CheckpointRequester = @MainActor @Sendable () -> Void
    public typealias ExistingMapAssociator =
        @MainActor @Sendable (
            MapID,
            CoordinateFrameID
        ) -> Bool

    @Published public private(set) var state: PlaceRecognitionControllerState = .inactive
    @Published public private(set) var latestFingerprint: PlaceFingerprint?
    @Published public private(set) var latestDecision: PlaceAssociationDecision?
    @Published public private(set) var metrics = PlaceRecognitionMetrics()

    var isProcessingForTesting: Bool {
        processingTask != nil
    }

    #if DEBUG
    /// Call after the intended snapshot has been received. Join its actual
    /// processing and any already-coalesced successor without imposing a
    /// per-observation disk/scheduler latency requirement on correctness tests.
    func waitForProcessingCompletionForTesting() async {
        while let current = processingTask {
            await current.value
        }
    }
    #endif

    var pendingProcessingTaskCountForTesting: Int {
        processingTasks.count
    }

    var pendingCheckpointRetryTaskCountForTesting: Int {
        checkpointRetryTasks.count
    }

    private let surfaceStreamProvider: SurfaceStreamProvider
    private let refreshStreamOnActivation: Bool
    private let objectMetadataProvider: ObjectMetadataProvider
    private let catalogProvider: CatalogProvider
    private let visualHistogramProvider: VisualHistogramProvider
    private let verifiedAlignmentCatalogProvider: VerifiedAlignmentCatalogProvider
    private let fingerprintWriter: FingerprintWriter
    private let associationWriter: AssociationWriter
    private let mutationAcknowledger: MutationAcknowledger
    private let coordinateCompatibilityProvider: CoordinateCompatibilityProvider
    private let checkpointRequester: CheckpointRequester
    private let existingMapAssociator: ExistingMapAssociator
    private let logicalMergeWriter: LogicalMergeWriter
    private let checkpointRetryInterval: Duration
    private let minimumAssociationObservationInterval: TimeInterval
    private let builder: ARPlaceFingerprintBuilder
    private let comparator: PlaceFingerprintComparator
    private let associationPolicy: PlaceAssociationPolicy

    private var monitorTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var currentProcessingTaskID: UUID?
    private var processingTasks: [UUID: Task<Void, Never>] = [:]
    private var checkpointRetryTask: Task<Void, Never>?
    private var currentCheckpointRetryTaskID: UUID?
    private var checkpointRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingSnapshot: ARSurfaceStateSnapshot?
    private var isActive = false
    private var lifecycleGeneration: UInt64 = 0
    private var lastAcceptedRevision: SurfaceRevisionKey?
    private var latestSurfaceIdentity: SurfaceIdentityKey?
    private var latestOfferedRevision: SurfaceRevisionKey?
    private var activeAttempt: AssociationAttempt?
    private var settledUnmappedFrameID: CoordinateFrameID?
    private var awaitingCheckpointFrameID: CoordinateFrameID?
    private var settledMergePairs = Set<LogicalMapPair>()

    public convenience init(
        surfaces: AsyncStream<ARSurfaceStateSnapshot>,
        builder: ARPlaceFingerprintBuilder = ARPlaceFingerprintBuilder(),
        comparator: PlaceFingerprintComparator = PlaceFingerprintComparator(),
        associationPolicy: PlaceAssociationPolicy = .default,
        objectMetadataProvider: @escaping ObjectMetadataProvider,
        catalogProvider: @escaping CatalogProvider,
        visualHistogramProvider: @escaping VisualHistogramProvider = { _ in nil },
        verifiedAlignmentCatalogProvider: @escaping VerifiedAlignmentCatalogProvider = { try .init() },
        fingerprintWriter: @escaping FingerprintWriter,
        associationWriter: @escaping AssociationWriter,
        mutationAcknowledger: @escaping MutationAcknowledger = { _, _ in },
        coordinateCompatibilityProvider: @escaping CoordinateCompatibilityProvider = {
            snapshot, candidate, _ in
            try PlaceCoordinateAlignmentResolution(
                sourceMapID: snapshot.mapID,
                targetMapID: candidate.mapID,
                sourceCoordinateFrameID: snapshot.coordinateFrameID,
                targetCoordinateFrameID: candidate.coordinateFrameID,
                evidence: .unresolved,
                validatedAlignment: nil
            )
        },
        existingMapAssociator: @escaping ExistingMapAssociator = { _, _ in false },
        logicalMergeWriter: @escaping LogicalMergeWriter = { _ in },
        checkpointRetryInterval: Duration = .milliseconds(5_500),
        minimumAssociationObservationInterval: TimeInterval = 0.5,
        checkpointRequester: @escaping CheckpointRequester
    ) {
        self.init(
            surfaceStreamProvider: { surfaces },
            refreshStreamOnActivation: false,
            builder: builder,
            comparator: comparator,
            associationPolicy: associationPolicy,
            objectMetadataProvider: objectMetadataProvider,
            catalogProvider: catalogProvider,
            visualHistogramProvider: visualHistogramProvider,
            verifiedAlignmentCatalogProvider: verifiedAlignmentCatalogProvider,
            fingerprintWriter: fingerprintWriter,
            associationWriter: associationWriter,
            mutationAcknowledger: mutationAcknowledger,
            coordinateCompatibilityProvider: coordinateCompatibilityProvider,
            existingMapAssociator: existingMapAssociator,
            logicalMergeWriter: logicalMergeWriter,
            checkpointRetryInterval: checkpointRetryInterval,
            minimumAssociationObservationInterval: minimumAssociationObservationInterval,
            checkpointRequester: checkpointRequester
        )
    }

    public convenience init(
        surfaceStreamProvider: @escaping SurfaceStreamProvider,
        builder: ARPlaceFingerprintBuilder = ARPlaceFingerprintBuilder(),
        comparator: PlaceFingerprintComparator = PlaceFingerprintComparator(),
        associationPolicy: PlaceAssociationPolicy = .default,
        objectMetadataProvider: @escaping ObjectMetadataProvider,
        catalogProvider: @escaping CatalogProvider,
        visualHistogramProvider: @escaping VisualHistogramProvider = { _ in nil },
        verifiedAlignmentCatalogProvider: @escaping VerifiedAlignmentCatalogProvider = { try .init() },
        fingerprintWriter: @escaping FingerprintWriter,
        associationWriter: @escaping AssociationWriter,
        mutationAcknowledger: @escaping MutationAcknowledger = { _, _ in },
        coordinateCompatibilityProvider: @escaping CoordinateCompatibilityProvider = {
            snapshot, candidate, _ in
            try PlaceCoordinateAlignmentResolution(
                sourceMapID: snapshot.mapID,
                targetMapID: candidate.mapID,
                sourceCoordinateFrameID: snapshot.coordinateFrameID,
                targetCoordinateFrameID: candidate.coordinateFrameID,
                evidence: .unresolved,
                validatedAlignment: nil
            )
        },
        existingMapAssociator: @escaping ExistingMapAssociator = { _, _ in false },
        logicalMergeWriter: @escaping LogicalMergeWriter = { _ in },
        checkpointRetryInterval: Duration = .milliseconds(5_500),
        minimumAssociationObservationInterval: TimeInterval = 0.5,
        checkpointRequester: @escaping CheckpointRequester
    ) {
        self.init(
            surfaceStreamProvider: surfaceStreamProvider,
            refreshStreamOnActivation: true,
            builder: builder,
            comparator: comparator,
            associationPolicy: associationPolicy,
            objectMetadataProvider: objectMetadataProvider,
            catalogProvider: catalogProvider,
            visualHistogramProvider: visualHistogramProvider,
            verifiedAlignmentCatalogProvider: verifiedAlignmentCatalogProvider,
            fingerprintWriter: fingerprintWriter,
            associationWriter: associationWriter,
            mutationAcknowledger: mutationAcknowledger,
            coordinateCompatibilityProvider: coordinateCompatibilityProvider,
            existingMapAssociator: existingMapAssociator,
            logicalMergeWriter: logicalMergeWriter,
            checkpointRetryInterval: checkpointRetryInterval,
            minimumAssociationObservationInterval: minimumAssociationObservationInterval,
            checkpointRequester: checkpointRequester
        )
    }

    private init(
        surfaceStreamProvider: @escaping SurfaceStreamProvider,
        refreshStreamOnActivation: Bool,
        builder: ARPlaceFingerprintBuilder,
        comparator: PlaceFingerprintComparator,
        associationPolicy: PlaceAssociationPolicy,
        objectMetadataProvider: @escaping ObjectMetadataProvider,
        catalogProvider: @escaping CatalogProvider,
        visualHistogramProvider: @escaping VisualHistogramProvider = { _ in nil },
        verifiedAlignmentCatalogProvider: @escaping VerifiedAlignmentCatalogProvider,
        fingerprintWriter: @escaping FingerprintWriter,
        associationWriter: @escaping AssociationWriter,
        mutationAcknowledger: @escaping MutationAcknowledger = { _, _ in },
        coordinateCompatibilityProvider: @escaping CoordinateCompatibilityProvider,
        existingMapAssociator: @escaping ExistingMapAssociator,
        logicalMergeWriter: @escaping LogicalMergeWriter,
        checkpointRetryInterval: Duration,
        minimumAssociationObservationInterval: TimeInterval,
        checkpointRequester: @escaping CheckpointRequester
    ) {
        self.surfaceStreamProvider = surfaceStreamProvider
        self.refreshStreamOnActivation = refreshStreamOnActivation
        self.builder = builder
        self.comparator = comparator
        self.associationPolicy = associationPolicy
        self.objectMetadataProvider = objectMetadataProvider
        self.catalogProvider = catalogProvider
        self.visualHistogramProvider = visualHistogramProvider
        self.verifiedAlignmentCatalogProvider = verifiedAlignmentCatalogProvider
        self.fingerprintWriter = fingerprintWriter
        self.associationWriter = associationWriter
        self.mutationAcknowledger = mutationAcknowledger
        self.coordinateCompatibilityProvider = coordinateCompatibilityProvider
        self.existingMapAssociator = existingMapAssociator
        self.logicalMergeWriter = logicalMergeWriter
        self.checkpointRetryInterval = checkpointRetryInterval
        self.minimumAssociationObservationInterval = max(
            0,
            minimumAssociationObservationInterval
        )
        self.checkpointRequester = checkpointRequester
    }

    public func activate() {
        guard !isActive else {
            return
        }
        lifecycleGeneration &+= 1
        isActive = true
        state = .waitingForCompleteSurface
        startMonitoringIfNeeded()
    }

    public func deactivate() {
        isActive = false
        if refreshStreamOnActivation {
            monitorTask?.cancel()
            monitorTask = nil
        }
        lifecycleGeneration &+= 1
        cancelProcessingTasks()
        cancelCheckpointRetryTasks()
        pendingSnapshot = nil
        activeAttempt = nil
        lastAcceptedRevision = nil
        latestSurfaceIdentity = nil
        latestOfferedRevision = nil
        settledUnmappedFrameID = nil
        awaitingCheckpointFrameID = nil
        state = .inactive
    }

    /// Used before deleting the local catalog so fingerprint or association
    /// writes that were already in flight have fully observed cancellation.
    public func deactivateAndWaitForPendingWork() async {
        let pendingProcessing = Array(processingTasks.values)
        let pendingRetries = Array(checkpointRetryTasks.values)
        // Direct streams keep one monitor across normal reactivation. A
        // provider-backed stream owns a replaceable subscription whose old
        // monitor must be cancelled and joined before deletion completes.
        let pendingMonitor = refreshStreamOnActivation ? monitorTask : nil
        deactivate()
        for task in pendingProcessing {
            await task.value
        }
        for task in pendingRetries {
            await task.value
        }
        await pendingMonitor?.value
    }

    /// Call after a drained deletion attempt, which may remove durable
    /// alignments before failing. Read-only maintenance keeps the cache.
    func invalidateStoredAssociationCache(for mapID: MapID? = nil) {
        if let mapID {
            settledMergePairs = settledMergePairs.filter { $0.first != mapID && $0.second != mapID }
        } else {
            settledMergePairs.removeAll()
        }
    }

    private func startMonitoringIfNeeded() {
        guard monitorTask == nil else {
            return
        }
        let stream = surfaceStreamProvider()
        monitorTask = Task { @MainActor [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled, let self else {
                    return
                }
                if self.isActive {
                    self.offer(snapshot)
                }
            }
        }
    }

    private func offer(_ snapshot: ARSurfaceStateSnapshot) {
        metrics.snapshotsReceived &+= 1
        let identity = SurfaceIdentityKey(snapshot)
        if let latestSurfaceIdentity, latestSurfaceIdentity != identity {
            lifecycleGeneration &+= 1
            cancelProcessingTasks()
            cancelCheckpointRetryTasks()
            pendingSnapshot = nil
            activeAttempt = nil
            lastAcceptedRevision = nil
            latestOfferedRevision = nil
            settledUnmappedFrameID = nil
            awaitingCheckpointFrameID = nil
        }
        latestSurfaceIdentity = identity
        guard snapshot.isComplete else {
            lifecycleGeneration &+= 1
            cancelProcessingTasks()
            cancelCheckpointRetryTasks()
            pendingSnapshot = nil
            latestOfferedRevision = nil
            state = .waitingForCompleteSurface
            return
        }
        let revision = SurfaceRevisionKey(snapshot)
        latestOfferedRevision = revision
        if let lastAcceptedRevision,
            lastAcceptedRevision == revision
        {
            return
        }
        if snapshot.mapID == nil,
            settledUnmappedFrameID == snapshot.coordinateFrameID
        {
            return
        }
        if snapshot.mapID == nil,
            awaitingCheckpointFrameID == snapshot.coordinateFrameID
        {
            return
        }

        if processingTask != nil {
            pendingSnapshot = snapshot
            metrics.snapshotsCoalesced &+= 1
            return
        }
        startProcessing(snapshot)
    }

    private func startProcessing(_ snapshot: ARSurfaceStateSnapshot) {
        let generation = lifecycleGeneration
        let taskID = UUID()
        lastAcceptedRevision = SurfaceRevisionKey(snapshot)
        state = .fingerprinting
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.finishProcessing(
                    generation: generation,
                    taskID: taskID
                )
            }
            do {
                let objects = try await self.objectMetadataProvider()
                try Task.checkCancellation()
                guard self.isCurrent(snapshot, generation: generation) else {
                    self.metrics.staleResultsRejected &+= 1
                    return
                }

                let visualHistogram = try await self.visualHistogramProvider(snapshot)
                try Task.checkCancellation()
                guard self.isCurrent(snapshot, generation: generation) else {
                    self.metrics.staleResultsRejected &+= 1
                    return
                }
                let builder = self.builder
                let fingerprint = try await Task.detached(priority: .utility) {
                    try builder.makeFingerprint(
                        from: snapshot, objects: objects, visualHistogram: visualHistogram)
                }.value
                try Task.checkCancellation()
                guard self.isCurrent(snapshot, generation: generation) else {
                    self.metrics.staleResultsRejected &+= 1
                    return
                }

                let catalog = try await self.catalogProvider()
                try Task.checkCancellation()
                guard self.isCurrent(snapshot, generation: generation) else {
                    self.metrics.staleResultsRejected &+= 1
                    return
                }

                self.latestFingerprint = fingerprint
                if let mapID = snapshot.mapID {
                    try await self.persistKnownFingerprint(
                        fingerprint,
                        mapID: mapID,
                        coordinateFrameID: snapshot.coordinateFrameID,
                        catalog: catalog
                    )
                    guard self.isCurrent(snapshot, generation: generation) else {
                        self.metrics.staleResultsRejected &+= 1
                        return
                    }
                    try await self.associateMappedFingerprint(
                        fingerprint,
                        snapshot: snapshot,
                        objects: objects,
                        catalog: catalog,
                        generation: generation
                    )
                } else {
                    try await self.associateUnmappedFingerprint(
                        fingerprint,
                        snapshot: snapshot,
                        objects: objects,
                        catalog: catalog,
                        generation: generation
                    )
                }
            } catch is CancellationError {
                // Lifecycle cancellation is expected.
            } catch {
                if generation == self.lifecycleGeneration, self.isActive {
                    self.state = .failed(message: String(describing: error))
                }
            }
        }
        processingTask = task
        currentProcessingTaskID = taskID
        processingTasks[taskID] = task
    }

    private func persistKnownFingerprint(
        _ fingerprint: PlaceFingerprint,
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        catalog: PlaceMemoryCatalogSnapshot
    ) async throws {
        let existing = catalog.fingerprints.first { $0.mapID == mapID }
        let shouldPersist =
            existing.map {
                fingerprint != $0.fingerprint
                    && FingerprintCoverage(fingerprint) > FingerprintCoverage($0.fingerprint)
            } ?? true
        if shouldPersist {
            let now = durableTimestamp(after: existing?.updatedAt)
            let record = try PlaceFingerprintRecord(
                mapID: mapID,
                coordinateFrameID: coordinateFrameID,
                fingerprint: fingerprint,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
            try await fingerprintWriter(record)
            try Task.checkCancellation()
            metrics.fingerprintsPersisted &+= 1
        }
        // A mapped snapshot is published only after checkpoint/association
        // completion. Recover acknowledgements from durable proposals as well
        // as the live attempt so an app restart cannot permanently pin them.
        for attempt in catalog.associationStates where
            attempt.context.sourceCoordinateFrameID == coordinateFrameID
                && catalog.acknowledgedMutationRevisions[attempt.id] != attempt.revision {
            let completed: Bool
            switch attempt.latestDecision.mutation {
            case .createNewMap: completed = attempt.context.sourceMapID == nil
            case .associateExisting(let targetMapID): completed = targetMapID == mapID
            case .mergeMaps, .deferDecision: completed = false
            }
            if completed {
                try await mutationAcknowledger(attempt.id, attempt.revision)
                try Task.checkCancellation()
            }
        }
        settledUnmappedFrameID = nil
        awaitingCheckpointFrameID = nil
        cancelCheckpointRetryTasks()
        latestDecision = PlaceAssociationDecision(
            outcome: .known,
            mutation: .associateExisting(targetMapID: mapID),
            selectedMapID: mapID,
            candidateMapIDs: [mapID],
            confidence: .one,
            grade: .high,
            reason: .recognizedKnownPlace
        )
        state = .known(mapID: mapID, confidence: .one)
    }

    private func associateUnmappedFingerprint(
        _ fingerprint: PlaceFingerprint,
        snapshot: ARSurfaceStateSnapshot,
        objects: [SpatialObjectMetadata],
        catalog: PlaceMemoryCatalogSnapshot,
        generation: UInt64
    ) async throws {
        let context = PlaceAssociationContext(
            sourceMapID: nil,
            sourceCoordinateFrameID: snapshot.coordinateFrameID
        )
        var attempt = try restoredOrNewAttempt(for: context, catalog: catalog)
        if attempt.observations.count >= PlaceAssociationStateRecord.maximumObservationHistory {
            attempt = newAttempt(for: context, catalog: catalog, after: attempt.updatedAt)
        }

        guard
            attempt.accepts(
                surfaceRevision: snapshot.revision,
                timestamp: snapshot.timestamp,
                minimumInterval: minimumAssociationObservationInterval
            )
        else {
            return
        }

        let candidates = try await scoredCandidates(
            for: fingerprint,
            snapshot: snapshot,
            objects: objects,
            catalog: catalog,
            excluding: nil,
            generation: generation
        )

        let sequence = try nextSequence(after: attempt.reducer.snapshot.latestSequence)
        let observation = PlaceAssociationObservation(
            id: ObservationID(),
            baseRevision: attempt.reducer.snapshot.revision,
            sequence: sequence,
            candidates: candidates.map(\.evidence)
        )
        var nextReducer = attempt.reducer
        let application = try nextReducer.apply(observation)
        let decision: PlaceAssociationDecision
        switch application {
        case .applied(_, let value), .alreadyApplied(_, let value):
            decision = value
        }
        let updatedAt = durableTimestamp(after: attempt.updatedAt)
        let nextObservations = attempt.observations + [observation]
        let record = try PlaceAssociationStateRecord(
            id: attempt.id,
            context: context,
            observations: nextObservations,
            createdAt: attempt.createdAt,
            updatedAt: updatedAt
        )
        try await associationWriter(record)
        try Task.checkCancellation()
        guard isCurrent(snapshot, generation: generation) else {
            metrics.staleResultsRejected &+= 1
            return
        }

        attempt.reducer = nextReducer
        attempt.observations = nextObservations
        attempt.updatedAt = updatedAt
        attempt.recordSurface(revision: snapshot.revision, timestamp: snapshot.timestamp)
        activeAttempt = attempt
        latestDecision = decision
        metrics.associationObservationsPersisted &+= 1
        publish(decision, snapshot: snapshot, catalog: catalog)
    }

    private func associateMappedFingerprint(
        _ fingerprint: PlaceFingerprint,
        snapshot: ARSurfaceStateSnapshot,
        objects: [SpatialObjectMetadata],
        catalog: PlaceMemoryCatalogSnapshot,
        generation: UInt64
    ) async throws {
        guard let sourceMapID = snapshot.mapID else {
            return
        }
        let scored = try await scoredCandidates(
            for: fingerprint,
            snapshot: snapshot,
            objects: objects,
            catalog: catalog,
            excluding: sourceMapID,
            generation: generation
        )
        let candidates = scored.filter {
            !settledMergePairs.contains(LogicalMapPair(sourceMapID, $0.evidence.mapID))
        }
        guard !candidates.isEmpty else {
            if activeAttempt?.context.sourceMapID == sourceMapID {
                activeAttempt = nil
            }
            return
        }

        let context = PlaceAssociationContext(
            sourceMapID: sourceMapID,
            sourceCoordinateFrameID: snapshot.coordinateFrameID
        )
        var attempt = try restoredOrNewAttempt(for: context, catalog: catalog)
        if attempt.observations.count >= PlaceAssociationStateRecord.maximumObservationHistory {
            attempt = newAttempt(for: context, catalog: catalog, after: attempt.updatedAt)
        }
        guard
            attempt.accepts(
                surfaceRevision: snapshot.revision,
                timestamp: snapshot.timestamp,
                minimumInterval: minimumAssociationObservationInterval
            )
        else {
            return
        }

        let sequence = try nextSequence(after: attempt.reducer.snapshot.latestSequence)
        let observation = PlaceAssociationObservation(
            id: ObservationID(),
            baseRevision: attempt.reducer.snapshot.revision,
            sequence: sequence,
            candidates: candidates.map(\.evidence)
        )
        var nextReducer = attempt.reducer
        let application = try nextReducer.apply(observation)
        let decision: PlaceAssociationDecision
        switch application {
        case .applied(_, let value), .alreadyApplied(_, let value):
            decision = value
        }
        let updatedAt = durableTimestamp(after: attempt.updatedAt)
        let nextObservations = attempt.observations + [observation]
        let stateRecord = try PlaceAssociationStateRecord(
            id: attempt.id,
            context: context,
            observations: nextObservations,
            createdAt: attempt.createdAt,
            updatedAt: updatedAt
        )
        guard isCurrent(snapshot, generation: generation) else {
            metrics.staleResultsRejected &+= 1
            return
        }
        try await associationWriter(stateRecord)
        try Task.checkCancellation()
        guard isCurrent(snapshot, generation: generation) else {
            metrics.staleResultsRejected &+= 1
            return
        }

        attempt.reducer = nextReducer
        attempt.observations = nextObservations
        attempt.updatedAt = updatedAt
        attempt.recordSurface(revision: snapshot.revision, timestamp: snapshot.timestamp)
        activeAttempt = attempt
        latestDecision = decision
        metrics.associationObservationsPersisted &+= 1

        guard
            case .mergeMaps(
                let decidedSourceMapID,
                let targetMapID,
                let sourceToTarget
            ) = decision.mutation,
            decidedSourceMapID == sourceMapID,
            let selected = candidates.first(where: { $0.evidence.mapID == targetMapID })
        else {
            state = .known(mapID: sourceMapID, confidence: .one)
            return
        }

        let pair = LogicalMapPair(sourceMapID, targetMapID)
        guard !settledMergePairs.contains(pair) else {
            state = .known(mapID: sourceMapID, confidence: .one)
            return
        }
        let validatedAlignment: CoordinateFrameAlignmentResult?
        if snapshot.coordinateFrameID == selected.evidence.coordinateFrameID {
            guard sourceToTarget == .identity else {
                state = .known(mapID: sourceMapID, confidence: .one)
                return
            }
            validatedAlignment = nil
        } else {
            guard let latestAlignment = selected.validatedAlignment,
                latestAlignment.sourceCoordinateFrameID == snapshot.coordinateFrameID,
                latestAlignment.targetCoordinateFrameID
                    == selected.evidence.coordinateFrameID,
                latestAlignment.sourceToTarget == sourceToTarget
            else {
                // A compatibility latched from an older observation is not a
                // sufficient merge receipt. Wait for fresh validated evidence.
                state = .known(mapID: sourceMapID, confidence: .one)
                return
            }
            validatedAlignment = latestAlignment
        }

        let commit = try LogicalMapMergeCommit(
            associationStateID: attempt.id,
            decidingObservationID: observation.id,
            sourceMapID: sourceMapID,
            sourceCoordinateFrameID: snapshot.coordinateFrameID,
            targetMapID: targetMapID,
            targetCoordinateFrameID: selected.evidence.coordinateFrameID,
            sourceToTarget: sourceToTarget,
            validatedAlignment: validatedAlignment
        )
        guard isCurrent(snapshot, generation: generation) else {
            metrics.staleResultsRejected &+= 1
            return
        }
        try await logicalMergeWriter(commit)
        try Task.checkCancellation()
        try await mutationAcknowledger(stateRecord.id, stateRecord.revision)
        try Task.checkCancellation()
        settledMergePairs.insert(pair)
        metrics.logicalMergesCommitted &+= 1
        state = .known(mapID: sourceMapID, confidence: .one)
    }

    private func scoredCandidates(
        for fingerprint: PlaceFingerprint,
        snapshot: ARSurfaceStateSnapshot,
        objects: [SpatialObjectMetadata],
        catalog: PlaceMemoryCatalogSnapshot,
        excluding excludedMapID: MapID?,
        generation: UInt64
    ) async throws -> [ScoredCandidate] {
        let verifiedAlignments = try await verifiedAlignmentCatalogProvider()
        try Task.checkCancellation()
        guard isCurrent(snapshot, generation: generation) else { throw CancellationError() }
        let groups = VerifiedPlaceMapGroups(catalog: verifiedAlignments, objects: objects)
        var candidates: [ScoredCandidate] = []
        candidates.reserveCapacity(catalog.fingerprints.count)
        for record in catalog.fingerprints where record.mapID != excludedMapID {
            let comparison = try comparator.compare(fingerprint, record.fingerprint)
            let compatibility: PlaceCoordinateCompatibilityEvidence
            let validatedAlignment: CoordinateFrameAlignmentResult?
            if record.coordinateFrameID == snapshot.coordinateFrameID {
                compatibility = .aligned(sourceToCandidate: .identity, confidence: .one)
                validatedAlignment = nil
            } else {
                let resolution = try await coordinateCompatibilityProvider(
                    snapshot,
                    record,
                    objects
                )
                try Task.checkCancellation()
                guard isCurrent(snapshot, generation: generation) else {
                    metrics.staleResultsRejected &+= 1
                    throw CancellationError()
                }
                guard resolution.sourceMapID == snapshot.mapID,
                    resolution.targetMapID == record.mapID,
                    resolution.sourceCoordinateFrameID == snapshot.coordinateFrameID,
                    resolution.targetCoordinateFrameID == record.coordinateFrameID
                else {
                    throw PlaceRecognitionControllerError.invalidAlignmentResolutionContext
                }
                compatibility = resolution.evidence
                validatedAlignment = resolution.validatedAlignment
            }
            let poseEvidence: PlaceFingerprintSimilarity
            switch compatibility {
            case .aligned(_, let confidence):
                poseEvidence = .available(confidence)
            case .unresolved, .incompatible:
                poseEvidence = .unavailable
            }
            let placeEvidence = comparison.placeEvidence(
                poseConsistency: poseEvidence
            )
            let score = PlaceRecognizer().classify(placeEvidence).aggregateScore
            candidates.append(
                ScoredCandidate(
                    evidence: PlaceMapCandidateEvidence(
                        mapID: record.mapID,
                        coordinateFrameID: record.coordinateFrameID,
                        placeEvidence: placeEvidence,
                        coordinateCompatibility: compatibility
                    ),
                    score: score,
                    validatedAlignment: validatedAlignment
                )
            )
        }
        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.evidence.mapID < rhs.evidence.mapID
        }
        let latestAlignments = try await verifiedAlignmentCatalogProvider()
        try Task.checkCancellation()
        guard latestAlignments == verifiedAlignments, isCurrent(snapshot, generation: generation) else {
            throw CancellationError()
        }
        var representatives: [MapID: ScoredCandidate] = [:]
        for candidate in candidates {
            let group = groups.representative(
                mapID: candidate.evidence.mapID,
                frameID: candidate.evidence.coordinateFrameID)
            if let existing = representatives[group] {
                if case .aligned = existing.evidence.coordinateCompatibility { continue }
                guard case .aligned = candidate.evidence.coordinateCompatibility else { continue }
            }
            representatives[group] = candidate
        }
        let ranked = representatives.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.evidence.mapID < $1.evidence.mapID
        }
        return Array(ranked.prefix(associationPolicy.maximumTrackedCandidates))
    }

    private func restoredOrNewAttempt(
        for context: PlaceAssociationContext,
        catalog: PlaceMemoryCatalogSnapshot
    ) throws -> AssociationAttempt {
        let saved = catalog.associationStates
            .filter({ $0.context == context })
            .max(by: { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt < rhs.updatedAt
                }
                return lhs.id < rhs.id
            })
        if let activeAttempt, activeAttempt.context == context {
            let isRetired = !catalog.associationStates.contains(where: { $0.id == activeAttempt.id })
                && catalog.retiredAssociationCreatedAtThrough.map { activeAttempt.createdAt <= $0 } == true
            if !isRetired {
                // A superseded surface can finish its durable write without
                // publishing UI state or advancing this cache. Replay a newer
                // durable revision/attempt before appending more observations.
                // Keep matching (or newer) live state so an older catalog read
                // cannot regress its revision or surface/time throttle.
                if let saved {
                    if saved.id == activeAttempt.id,
                        saved.revision <= activeAttempt.reducer.snapshot.revision {
                        return activeAttempt
                    }
                    if saved.id != activeAttempt.id, saved.createdAt <= activeAttempt.createdAt {
                        return activeAttempt
                    }
                } else {
                    return activeAttempt
                }
            }
        }
        if let saved {
            return AssociationAttempt(
                id: saved.id,
                context: saved.context,
                reducer: try PlaceMapAssociationReducer.replay(
                    context: saved.context,
                    policy: associationPolicy,
                    observations: saved.observations
                ),
                observations: saved.observations,
                createdAt: saved.createdAt,
                updatedAt: saved.updatedAt
            )
        }
        return newAttempt(for: context, catalog: catalog)
    }

    private func newAttempt(
        for context: PlaceAssociationContext,
        catalog: PlaceMemoryCatalogSnapshot,
        after previous: TimeInterval? = nil
    ) -> AssociationAttempt {
        // Creation order remains durable even when the device clock moves
        // backward. Retired attempt IDs must never be admitted as new work.
        let latest = catalog.associationStates.map(\.updatedAt).max()
        let floor = [previous, latest, catalog.retiredAssociationCreatedAtThrough]
            .compactMap { $0 }.max()
        return AssociationAttempt(context: context, now: durableTimestamp(after: floor))
    }

    private func publish(
        _ decision: PlaceAssociationDecision,
        snapshot: ARSurfaceStateSnapshot,
        catalog: PlaceMemoryCatalogSnapshot
    ) {
        switch decision.outcome {
        case .known:
            guard let mapID = decision.selectedMapID else {
                state = .ambiguous(
                    candidateMapIDs: decision.candidateMapIDs,
                    reason: .coordinateCompatibilityUnresolved
                )
                return
            }
            resolveRecognizedUnmappedPlace(
                mapID: mapID,
                snapshot: snapshot,
                catalog: catalog
            )
            state = .known(mapID: mapID, confidence: decision.confidence)
        case .overlapping:
            guard let mapID = decision.selectedMapID else {
                state = .ambiguous(
                    candidateMapIDs: decision.candidateMapIDs,
                    reason: .coordinateCompatibilityUnresolved
                )
                return
            }
            resolveRecognizedUnmappedPlace(
                mapID: mapID,
                snapshot: snapshot,
                catalog: catalog
            )
            state = .overlapping(mapID: mapID, confidence: decision.confidence)
        case .new:
            state = .newPlaceAwaitingCheckpoint(confidence: decision.confidence)
            beginWaitingForCheckpoint(snapshot)
        case .ambiguous:
            state = .ambiguous(
                candidateMapIDs: decision.candidateMapIDs,
                reason: decision.reason
            )
        }
    }

    private func resolveRecognizedUnmappedPlace(
        mapID: MapID,
        snapshot: ARSurfaceStateSnapshot,
        catalog: PlaceMemoryCatalogSnapshot
    ) {
        let targetFrameID = catalog.fingerprints.first {
            $0.mapID == mapID
        }?.coordinateFrameID
        if let targetFrameID,
            targetFrameID == snapshot.coordinateFrameID,
            existingMapAssociator(mapID, targetFrameID)
        {
            settledUnmappedFrameID = snapshot.coordinateFrameID
            awaitingCheckpointFrameID = nil
            cancelCheckpointRetryTasks()
        } else {
            beginWaitingForCheckpoint(snapshot)
        }
    }

    private func beginWaitingForCheckpoint(_ snapshot: ARSurfaceStateSnapshot) {
        if awaitingCheckpointFrameID == snapshot.coordinateFrameID,
            checkpointRetryTask != nil
        {
            return
        }
        awaitingCheckpointFrameID = snapshot.coordinateFrameID
        checkpointRequester()
        let frameID = snapshot.coordinateFrameID
        let generation = lifecycleGeneration
        let interval = checkpointRetryInterval
        cancelCheckpointRetryTasks()
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            defer {
                self?.finishCheckpointRetry(taskID: taskID)
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self,
                    self.isActive,
                    self.lifecycleGeneration == generation,
                    self.awaitingCheckpointFrameID == frameID
                else {
                    return
                }
                self.checkpointRequester()
            }
        }
        checkpointRetryTask = task
        currentCheckpointRetryTaskID = taskID
        checkpointRetryTasks[taskID] = task
    }

    private func finishProcessing(generation: UInt64, taskID: UUID) {
        processingTasks.removeValue(forKey: taskID)
        guard currentProcessingTaskID == taskID else {
            return
        }
        processingTask = nil
        currentProcessingTaskID = nil
        guard generation == lifecycleGeneration else {
            return
        }
        guard let pendingSnapshot else {
            return
        }
        self.pendingSnapshot = nil
        startProcessing(pendingSnapshot)
    }

    private func finishCheckpointRetry(taskID: UUID) {
        checkpointRetryTasks.removeValue(forKey: taskID)
        guard currentCheckpointRetryTaskID == taskID else {
            return
        }
        checkpointRetryTask = nil
        currentCheckpointRetryTaskID = nil
    }

    private func cancelProcessingTasks() {
        for task in processingTasks.values {
            task.cancel()
        }
        // Keep cancelled generations joinable until their writer returns;
        // clearing the current slot must not forget a pending disk write.
        processingTask = nil
        currentProcessingTaskID = nil
    }

    private func cancelCheckpointRetryTasks() {
        for task in checkpointRetryTasks.values {
            task.cancel()
        }
        // The task's defer removes only its own registry entry after unwinding.
        checkpointRetryTask = nil
        currentCheckpointRetryTaskID = nil
    }

    private func isCurrent(
        _ snapshot: ARSurfaceStateSnapshot,
        generation: UInt64
    ) -> Bool {
        generation == lifecycleGeneration
            && isActive
            && snapshot.isComplete
            && latestSurfaceIdentity == SurfaceIdentityKey(snapshot)
            && latestOfferedRevision == SurfaceRevisionKey(snapshot)
    }

    private func durableTimestamp(after previous: TimeInterval? = nil) -> TimeInterval {
        let now = max(0, Date().timeIntervalSince1970)
        guard let previous else {
            return now
        }
        return max(now, previous.nextUp)
    }

    private func nextSequence(after previous: UInt64?) throws -> UInt64 {
        guard let previous else {
            return 1
        }
        let (next, overflow) = previous.addingReportingOverflow(1)
        guard !overflow else {
            throw PlaceMapAssociationError.observationCounterOverflow
        }
        return next
    }

    deinit {
        monitorTask?.cancel()
        for task in processingTasks.values {
            task.cancel()
        }
        for task in checkpointRetryTasks.values {
            task.cancel()
        }
    }
}

private struct SurfaceIdentityKey: Equatable, Sendable {
    let coordinateFrameID: CoordinateFrameID
    let segmentID: CaptureSegmentID
    let mapID: MapID?
    let status: ARCaptureIdentity.Status

    init(_ snapshot: ARSurfaceStateSnapshot) {
        coordinateFrameID = snapshot.coordinateFrameID
        segmentID = snapshot.segmentID
        mapID = snapshot.mapID
        status = snapshot.coordinateFrameStatus
    }
}

private struct SurfaceRevisionKey: Equatable, Sendable {
    let identity: SurfaceIdentityKey
    let revision: UInt64

    init(_ snapshot: ARSurfaceStateSnapshot) {
        identity = SurfaceIdentityKey(snapshot)
        revision = snapshot.revision
    }
}

/// A lexicographic evidence measure used only to prevent a partial revisit
/// from replacing a richer durable place fingerprint. It does not claim that
/// a larger room or a denser histogram is a better place match.
private struct FingerprintCoverage: Comparable, Sendable {
    let availableModalityCount: Int
    let observedObjectCount: Int
    let populatedBinCount: Int
    let coarseExtentVolume: Double

    init(_ fingerprint: PlaceFingerprint) {
        let histograms = [
            fingerprint.visualHistogram,
            fingerprint.geometryHistogram,
            fingerprint.structureHistogram,
            fingerprint.objectLayoutHistogram,
            fingerprint.spatialOccupancyHistogram,
        ]
        availableModalityCount = histograms.compactMap { $0 }.count
        observedObjectCount = fingerprint.observedObjectCount ?? 0
        populatedBinCount = histograms.compactMap { $0 }.reduce(0) { count, histogram in
            count + histogram.values.filter { $0 > 0 }.count
        }
        if let extent = fingerprint.coarseExtent {
            coarseExtentVolume =
                extent.widthMeters
                * extent.heightMeters
                * extent.depthMeters
        } else {
            coarseExtentVolume = 0
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.availableModalityCount != rhs.availableModalityCount {
            return lhs.availableModalityCount < rhs.availableModalityCount
        }
        if lhs.observedObjectCount != rhs.observedObjectCount {
            return lhs.observedObjectCount < rhs.observedObjectCount
        }
        if lhs.populatedBinCount != rhs.populatedBinCount {
            return lhs.populatedBinCount < rhs.populatedBinCount
        }
        return lhs.coarseExtentVolume < rhs.coarseExtentVolume
    }
}

private struct ScoredCandidate: Sendable {
    let evidence: PlaceMapCandidateEvidence
    let score: ConfidenceScore
    let validatedAlignment: CoordinateFrameAlignmentResult?
}

private struct LogicalMapPair: Hashable, Sendable {
    let first: MapID
    let second: MapID

    init(_ lhs: MapID, _ rhs: MapID) {
        if lhs < rhs {
            first = lhs
            second = rhs
        } else {
            first = rhs
            second = lhs
        }
    }
}

private struct AssociationAttempt: Sendable {
    let id: PlaceAssociationStateID
    let context: PlaceAssociationContext
    var reducer: PlaceMapAssociationReducer
    var observations: [PlaceAssociationObservation]
    let createdAt: TimeInterval
    var updatedAt: TimeInterval
    var lastSurfaceRevision: UInt64?
    var lastSurfaceTimestamp: TimeInterval?

    init(context: PlaceAssociationContext, now: TimeInterval) {
        id = PlaceAssociationStateID()
        self.context = context
        reducer = PlaceMapAssociationReducer(context: context)
        observations = []
        createdAt = now
        updatedAt = now
        lastSurfaceRevision = nil
        lastSurfaceTimestamp = nil
    }

    init(
        id: PlaceAssociationStateID,
        context: PlaceAssociationContext,
        reducer: PlaceMapAssociationReducer,
        observations: [PlaceAssociationObservation],
        createdAt: TimeInterval,
        updatedAt: TimeInterval
    ) {
        self.id = id
        self.context = context
        self.reducer = reducer
        self.observations = observations
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        lastSurfaceRevision = nil
        lastSurfaceTimestamp = nil
    }

    func accepts(
        surfaceRevision: UInt64,
        timestamp: TimeInterval,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard lastSurfaceRevision != surfaceRevision else {
            return false
        }
        guard let lastSurfaceTimestamp else {
            return true
        }
        guard timestamp >= lastSurfaceTimestamp else {
            return false
        }
        return timestamp - lastSurfaceTimestamp >= minimumInterval
    }

    mutating func recordSurface(revision: UInt64, timestamp: TimeInterval) {
        lastSurfaceRevision = revision
        lastSurfaceTimestamp = timestamp
    }
}
