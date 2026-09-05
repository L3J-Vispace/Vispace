import Combine
import Foundation
import VispaceCore

public enum SpatialObjectQueryGuidanceAvailability: String, Hashable, Sendable {
    case ready
    case captureNotConfirmed
    case coordinateAlignmentUnavailable
    case searchNotGrounded
}

public struct SpatialObjectQueryPresentation: Hashable, Sendable {
    public let result: SpatialObjectSearchResult
    public let resolvedPosition: ResolvedCurrentFramePosition?
    public let guidanceAvailability: SpatialObjectQueryGuidanceAvailability
    public let message: String

    public var currentFramePosition: FramedPosition? {
        resolvedPosition?.currentFramePosition
    }

    public var canStartARGuidance: Bool {
        result.status == .found
            && guidanceAvailability == .ready
            && currentFramePosition != nil
    }

    public init(
        result: SpatialObjectSearchResult,
        resolvedPosition: ResolvedCurrentFramePosition?,
        guidanceAvailability: SpatialObjectQueryGuidanceAvailability,
        message: String
    ) {
        self.result = result
        self.resolvedPosition = resolvedPosition
        self.guidanceAvailability = guidanceAvailability
        self.message = message
    }
}

/// Minimal, fully grounded handoff consumed by AR marker/arrow/navigation UI.
/// `position` is always expressed in `currentCoordinateFrameID`; this value is
/// never created for ambiguous, low-confidence, or unaligned search results.
public struct GroundedSpatialObjectQueryTarget: Hashable, Sendable {
    public let semanticLabel: String
    public let objectID: ObjectID
    public let sourceMapID: MapID
    public let currentMapID: MapID?
    public let currentSegmentID: CaptureSegmentID
    public let sourcePosition: FramedPosition
    public let currentFramePosition: FramedPosition
    public let intent: SpatialIntentKind
    public let effectiveConfidence: ConfidenceScore
    public let confidenceGrade: ConfidenceGrade
    public let alignmentConfidence: ConfidenceScore?
    public let resolvedAt: TimeInterval

    public var position: Vec3 {
        currentFramePosition.value
    }

    public var sourceCoordinateFrameID: CoordinateFrameID {
        sourcePosition.coordinateFrameID
    }

    public var currentCoordinateFrameID: CoordinateFrameID {
        currentFramePosition.coordinateFrameID
    }

    public var representsLastSeenLocation: Bool {
        intent == .lastSeen
    }

    public init(
        semanticLabel: String,
        objectID: ObjectID,
        sourceMapID: MapID,
        currentMapID: MapID?,
        currentSegmentID: CaptureSegmentID,
        sourcePosition: FramedPosition,
        currentFramePosition: FramedPosition,
        intent: SpatialIntentKind,
        effectiveConfidence: ConfidenceScore,
        confidenceGrade: ConfidenceGrade,
        alignmentConfidence: ConfidenceScore?,
        resolvedAt: TimeInterval
    ) {
        self.semanticLabel = String(semanticLabel.prefix(64))
        self.objectID = objectID
        self.sourceMapID = sourceMapID
        self.currentMapID = currentMapID
        self.currentSegmentID = currentSegmentID
        self.sourcePosition = sourcePosition
        self.currentFramePosition = currentFramePosition
        self.intent = intent
        self.effectiveConfidence = effectiveConfidence
        self.confidenceGrade = confidenceGrade
        self.alignmentConfidence = alignmentConfidence
        self.resolvedAt = resolvedAt
    }
}

public enum SpatialObjectQueryControllerState: Equatable, Sendable {
    case idle
    case searching(requestID: UInt64)
    case result(SpatialObjectQueryPresentation)
    case failed(message: String)
}

public struct SpatialObjectQueryControllerMetrics: Equatable, Sendable {
    public var requestsStarted: UInt64 = 0
    public var requestsCancelled: UInt64 = 0
    public var staleResultsRejected: UInt64 = 0
    public var resultsPublished: UInt64 = 0
    public var failuresPublished: UInt64 = 0

    public init() {}
}

/// Phase 3 app coordinator. Deterministic intents are searched locally, and an
/// AR coordinate is published only after the selected persisted position is
/// proven to be in the live coordinate frame.
@MainActor
public final class SpatialObjectQueryController: ObservableObject {
    public static let maximumQueryLength = 256

    public typealias SnapshotProvider =
        @Sendable (
            _ currentMapID: MapID?
        ) async throws -> SpatialObjectQueryRepositorySnapshot
    public typealias CurrentIdentityProvider = @MainActor @Sendable () -> ARCaptureIdentity

    @Published public private(set) var state: SpatialObjectQueryControllerState = .idle
    @Published public private(set) var latestPresentation: SpatialObjectQueryPresentation?
    @Published public private(set) var latestGroundedTarget: GroundedSpatialObjectQueryTarget?
    @Published public private(set) var metrics = SpatialObjectQueryControllerMetrics()

    var isProcessingForTesting: Bool {
        queryTask != nil
    }

    private let snapshotProvider: SnapshotProvider
    private let currentIdentityProvider: CurrentIdentityProvider
    private let searchEngine: DeterministicSpatialObjectSearchEngine
    private let positionResolver: ValidatedCurrentFramePositionResolver

    private var queryTask: Task<Void, Never>?
    private var trackedQueryTasks: [UUID: Task<Void, Never>] = [:]
    private var latestRequestID: UInt64 = 0

    public init(
        repository: SpatialObjectQueryRepository,
        currentIdentityProvider: @escaping CurrentIdentityProvider,
        searchEngine: DeterministicSpatialObjectSearchEngine =
            DeterministicSpatialObjectSearchEngine(),
        positionResolver: ValidatedCurrentFramePositionResolver =
            ValidatedCurrentFramePositionResolver()
    ) {
        snapshotProvider = { currentMapID in
            try await repository.loadSnapshot(currentMapID: currentMapID)
        }
        self.currentIdentityProvider = currentIdentityProvider
        self.searchEngine = searchEngine
        self.positionResolver = positionResolver
    }

    public init(
        snapshotProvider: @escaping SnapshotProvider,
        currentIdentityProvider: @escaping CurrentIdentityProvider,
        searchEngine: DeterministicSpatialObjectSearchEngine =
            DeterministicSpatialObjectSearchEngine(),
        positionResolver: ValidatedCurrentFramePositionResolver =
            ValidatedCurrentFramePositionResolver()
    ) {
        self.snapshotProvider = snapshotProvider
        self.currentIdentityProvider = currentIdentityProvider
        self.searchEngine = searchEngine
        self.positionResolver = positionResolver
    }

    deinit {
        for task in trackedQueryTasks.values {
            task.cancel()
        }
    }

    /// Replaces any in-flight request. The captured session identity is checked
    /// again after every suspension so an old frame cannot publish late.
    public func submit(
        _ utterance: String,
        currentFloorNodeID: SpatialNodeID? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        guard now.isFinite, now >= 0 else {
            cancelCurrentQuery(resetToIdle: false)
            publishFailure()
            return
        }

        if queryTask != nil {
            queryTask?.cancel()
            metrics.requestsCancelled &+= 1
        }
        latestRequestID &+= 1
        let requestID = latestRequestID
        let identity = currentIdentityProvider()
        let query = Self.boundedQuery(utterance)
        metrics.requestsStarted &+= 1
        latestPresentation = nil
        latestGroundedTarget = nil
        state = .searching(requestID: requestID)

        let snapshotProvider = self.snapshotProvider
        let engine = searchEngine
        let resolver = positionResolver
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.trackedQueryDidFinish(taskID) }
            do {
                let snapshot = try await snapshotProvider(identity.mapID)
                try Task.checkCancellation()
                guard let self,
                    self.isCurrent(requestID: requestID, identity: identity)
                else {
                    self?.rejectStaleResult(requestID: requestID)
                    self?.finish(requestID: requestID)
                    return
                }

                let context = try SpatialObjectSearchContext(
                    currentMapID: identity.mapID,
                    currentFloorNodeID: currentFloorNodeID,
                    now: now,
                    includeRemoved: DeterministicIntentRouter().route(query).kind == .lastSeen
                )
                let records = snapshot.records
                let result = await Task.detached(priority: .userInitiated) {
                    engine.search(
                        utterance: query,
                        records: records,
                        context: context
                    )
                }.value
                try Task.checkCancellation()
                guard self.isCurrent(requestID: requestID, identity: identity) else {
                    self.rejectStaleResult(requestID: requestID)
                    self.finish(requestID: requestID)
                    return
                }

                let resolvedPosition = result.selectedCandidate.flatMap { candidate in
                    resolver.resolve(
                        candidate.record.metadata,
                        into: identity,
                        using: snapshot.alignmentCatalog
                    )
                }
                let guidanceAvailability = Self.guidanceAvailability(
                    for: result,
                    identity: identity,
                    resolvedPosition: resolvedPosition
                )
                let presentation = SpatialObjectQueryPresentation(
                    result: result,
                    resolvedPosition: resolvedPosition,
                    guidanceAvailability: guidanceAvailability,
                    message: Self.koreanMessage(
                        for: result,
                        guidanceAvailability: guidanceAvailability
                    )
                )
                self.latestPresentation = presentation
                self.latestGroundedTarget = Self.groundedTarget(
                    from: result,
                    resolvedPosition: resolvedPosition,
                    currentIdentity: identity,
                    resolvedAt: now
                )
                self.state = .result(presentation)
                self.metrics.resultsPublished &+= 1
                self.finish(requestID: requestID)
            } catch is CancellationError {
                self?.rejectStaleResult(requestID: requestID)
                self?.finish(requestID: requestID)
            } catch {
                guard let self,
                    self.isCurrent(requestID: requestID, identity: identity)
                else {
                    self?.rejectStaleResult(requestID: requestID)
                    self?.finish(requestID: requestID)
                    return
                }
                self.publishFailure()
                self.finish(requestID: requestID)
            }
        }
        queryTask = task
        trackedQueryTasks[taskID] = task
    }

    public func cancelCurrentQuery(resetToIdle: Bool = true) {
        guard queryTask != nil else {
            if resetToIdle {
                state = .idle
                latestPresentation = nil
                latestGroundedTarget = nil
            }
            return
        }
        queryTask?.cancel()
        queryTask = nil
        latestRequestID &+= 1
        metrics.requestsCancelled &+= 1
        if resetToIdle {
            state = .idle
            latestPresentation = nil
            latestGroundedTarget = nil
        }
    }

    /// Call when ARSession changes coordinate-frame ownership. This guarantees
    /// that no result from the previous run remains eligible for guidance.
    public func invalidateForCaptureTransition() {
        cancelCurrentQuery()
    }

    /// Cancels the visible request and waits until any repository read and
    /// detached ranking work has fully unwound. Spatial-data deletion uses
    /// this barrier before removing the shared store directory.
    public func invalidateAndWaitForPendingWork() async {
        let pendingQueries = Array(trackedQueryTasks.values)
        cancelCurrentQuery()
        for task in pendingQueries {
            task.cancel()
        }
        for task in pendingQueries {
            await task.value
        }
    }

    private func trackedQueryDidFinish(_ taskID: UUID) {
        trackedQueryTasks[taskID] = nil
    }

    private func isCurrent(
        requestID: UInt64,
        identity: ARCaptureIdentity
    ) -> Bool {
        requestID == latestRequestID && currentIdentityProvider() == identity
    }

    private func rejectStaleResult(requestID: UInt64) {
        metrics.staleResultsRejected &+= 1
        if requestID == latestRequestID {
            state = .idle
            latestPresentation = nil
            latestGroundedTarget = nil
        }
    }

    private func finish(requestID: UInt64) {
        guard requestID == latestRequestID else {
            return
        }
        queryTask = nil
    }

    private func publishFailure() {
        latestPresentation = nil
        latestGroundedTarget = nil
        state = .failed(
            message: "저장된 공간 정보를 불러오지 못했어요. 잠시 후 다시 시도해 주세요."
        )
        metrics.failuresPublished &+= 1
    }

    private static func boundedQuery(_ utterance: String) -> String {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximumQueryLength))
    }

    private static func guidanceAvailability(
        for result: SpatialObjectSearchResult,
        identity: ARCaptureIdentity,
        resolvedPosition: ResolvedCurrentFramePosition?
    ) -> SpatialObjectQueryGuidanceAvailability {
        guard result.status == .found else {
            return .searchNotGrounded
        }
        guard identity.status == .confirmed else {
            return .captureNotConfirmed
        }
        guard resolvedPosition != nil else {
            return .coordinateAlignmentUnavailable
        }
        return .ready
    }

    private static func groundedTarget(
        from result: SpatialObjectSearchResult,
        resolvedPosition: ResolvedCurrentFramePosition?,
        currentIdentity: ARCaptureIdentity,
        resolvedAt: TimeInterval
    ) -> GroundedSpatialObjectQueryTarget? {
        guard result.status == .found,
            let candidate = result.selectedCandidate,
            let resolvedPosition
        else {
            return nil
        }
        let metadata = candidate.record.metadata
        return GroundedSpatialObjectQueryTarget(
            semanticLabel: metadata.object.semanticLabel,
            objectID: metadata.object.id,
            sourceMapID: metadata.mapID,
            currentMapID: currentIdentity.mapID,
            currentSegmentID: currentIdentity.segmentID,
            sourcePosition: resolvedPosition.source,
            currentFramePosition: resolvedPosition.currentFramePosition,
            intent: result.route.kind,
            effectiveConfidence: candidate.effectiveConfidence,
            confidenceGrade: candidate.confidenceGrade,
            alignmentConfidence: resolvedPosition.alignmentConfidence,
            resolvedAt: resolvedAt
        )
    }

    private static func koreanMessage(
        for result: SpatialObjectSearchResult,
        guidanceAvailability: SpatialObjectQueryGuidanceAvailability
    ) -> String {
        let rawLabel =
            result.matchedSemanticLabels.first
            ?? result.candidates.first?.record.metadata.object.semanticLabel
            ?? "물체"
        let label = String(rawLabel.prefix(64))

        switch result.status {
        case .found:
            switch guidanceAvailability {
            case .ready:
                switch result.route.kind {
                case .lastSeen:
                    return "‘\(label)’의 마지막 확인 위치를 찾았어요. AR 안내를 시작할 수 있어요."
                case .navigate:
                    return "‘\(label)’ 위치를 찾았어요. AR 방향 안내를 시작할 수 있어요."
                case .searchObject:
                    return "‘\(label)’ 위치를 찾았어요. AR 안내를 시작할 수 있어요."
                case .relationQuery, .complexAsk:
                    return "위치는 찾았지만 이 요청은 AR 안내로 확정할 수 없어요."
                }
            case .captureNotConfirmed:
                return "‘\(label)’ 기록은 찾았지만 카메라 위치가 아직 안정화되지 않아 AR 안내를 표시하지 않았어요."
            case .coordinateAlignmentUnavailable:
                return "‘\(label)’ 기록은 찾았지만 저장된 공간과 현재 공간의 좌표 연결을 확인할 수 없어 AR 안내를 표시하지 않았어요."
            case .searchNotGrounded:
                return "‘\(label)’ 기록은 찾았지만 안내 좌표를 확정하지 못했어요."
            }
        case .ambiguous:
            return "‘\(label)’ 후보가 여러 개라 하나의 위치로 확정할 수 없어요. 주변 특징을 더 보여 주세요."
        case .notFound:
            if result.issues.contains(.noSemanticTarget) {
                return "찾을 물체를 이해하지 못했어요. 물체 이름과 함께 다시 말해 주세요."
            }
            return "‘\(label)’의 저장된 위치를 찾지 못했어요. 카메라로 공간을 조금 더 둘러봐 주세요."
        case .lowConfidence:
            return "‘\(label)’ 기록은 있지만 위치 신뢰도가 낮아 AR 안내를 표시하지 않았어요."
        case .unsupportedIntent:
            return "이 요청은 물체 찾기, 마지막 확인 위치, 또는 길 안내 검색으로 확정할 수 없어요."
        }
    }
}
