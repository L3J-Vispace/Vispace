import Combine
import Foundation
import VispaceCore

public struct FurniturePlacementPresentation: Equatable, Sendable {
    public let kind: FurnitureKind
    public let disposition: FurniturePlacementDisposition
    public let candidatePosition: FramedPosition?
    public let candidate: FurniturePlacementCandidate?
    public let evaluation: FurniturePlacementEvaluation?
    public let evidenceSummary: ARFurniturePlacementEvidenceSummary?
    public let issue: ARFurniturePlacementEvidenceIssue?
    public let message: String

    public init(
        kind: FurnitureKind,
        disposition: FurniturePlacementDisposition,
        candidatePosition: FramedPosition?,
        candidate: FurniturePlacementCandidate?,
        evaluation: FurniturePlacementEvaluation?,
        evidenceSummary: ARFurniturePlacementEvidenceSummary?,
        issue: ARFurniturePlacementEvidenceIssue?,
        message: String
    ) {
        self.kind = kind
        self.disposition = disposition
        self.candidatePosition = candidatePosition
        self.candidate = candidate
        self.evaluation = evaluation
        self.evidenceSummary = evidenceSummary
        self.issue = issue
        self.message = message
    }
}

/// Renderable only when the core evaluator returned `.feasible` from a
/// caller-provided, frame-validated candidate coordinate.
public struct RecommendedFurniturePlacement: Equatable, Sendable {
    public let kind: FurnitureKind
    public let position: FramedPosition
    public let yawRadians: Double
    public let dimensions: FurnitureDimensions
    public let confidence: ConfidenceGrade
    public let confidenceScore: ConfidenceScore

    public init(
        kind: FurnitureKind,
        position: FramedPosition,
        yawRadians: Double,
        dimensions: FurnitureDimensions,
        confidence: ConfidenceGrade,
        confidenceScore: ConfidenceScore
    ) {
        self.kind = kind
        self.position = position
        self.yawRadians = yawRadians
        self.dimensions = dimensions
        self.confidence = confidence
        self.confidenceScore = confidenceScore
    }
}

public enum FurniturePlacementControllerState: Equatable, Sendable {
    case idle
    case evaluating(requestID: UInt64, kind: FurnitureKind)
    case result(FurniturePlacementPresentation)
}

public struct FurniturePlacementControllerMetrics: Equatable, Sendable {
    public var posesAccepted: UInt64 = 0
    public var posesRejectedAsOutOfOrder: UInt64 = 0
    public var surfacesAccepted: UInt64 = 0
    public var surfacesRejectedAsOutOfOrder: UInt64 = 0
    public var requestsStarted: UInt64 = 0
    public var requestsCancelled: UInt64 = 0
    public var staleResultsRejected: UInt64 = 0
    public var recommendationsPublished: UInt64 = 0
    public var rejectionsPublished: UInt64 = 0
    public var insufficientEvidencePublished: UInt64 = 0

    public init() {}
}

/// Phase 4 app coordinator. Pose and surface snapshots are fed by the app's
/// single AR stream owner, avoiding a second iterator on `AsyncStream`. The
/// screen-center raycast remains an injected provider and is the only source
/// of the candidate coordinate.
@MainActor
public final class FurniturePlacementController: ObservableObject {
    public typealias CandidatePositionProvider =
        @MainActor @Sendable (
            _ referencePose: ARPoseSnapshot
        ) async throws -> FramedPosition?
    public typealias ObjectMetadataProvider =
        @Sendable () async throws ->
        [SpatialObjectMetadata]
    public typealias CapabilitiesProvider =
        @MainActor @Sendable () ->
        ARCaptureCapabilities?

    @Published public private(set) var state: FurniturePlacementControllerState = .idle
    @Published public private(set) var latestPose: ARPoseSnapshot?
    @Published public private(set) var latestSurface: ARSurfaceStateSnapshot?
    @Published public private(set) var latestPresentation: FurniturePlacementPresentation?
    @Published public private(set) var latestRecommendedPlacement: RecommendedFurniturePlacement?
    @Published public private(set) var metrics = FurniturePlacementControllerMetrics()

    var isProcessingForTesting: Bool {
        evaluationTask != nil
    }

    private let candidatePositionProvider: CandidatePositionProvider
    private let objectMetadataProvider: ObjectMetadataProvider
    private let capabilitiesProvider: CapabilitiesProvider
    private let evidenceBuilder: ARFurniturePlacementEvidenceBuilder
    private let evaluator: FurniturePlacementEvaluator

    private var evaluationTask: Task<Void, Never>?
    private var trackedEvaluationTasks: [UUID: Task<Void, Never>] = [:]
    private var latestRequestID: UInt64 = 0

    public init(
        candidatePositionProvider: @escaping CandidatePositionProvider,
        objectMetadataProvider: @escaping ObjectMetadataProvider,
        capabilitiesProvider: @escaping CapabilitiesProvider,
        evidenceBuilder: ARFurniturePlacementEvidenceBuilder =
            ARFurniturePlacementEvidenceBuilder(),
        evaluator: FurniturePlacementEvaluator = FurniturePlacementEvaluator()
    ) {
        self.candidatePositionProvider = candidatePositionProvider
        self.objectMetadataProvider = objectMetadataProvider
        self.capabilitiesProvider = capabilitiesProvider
        self.evidenceBuilder = evidenceBuilder
        self.evaluator = evaluator
    }

    deinit {
        for task in trackedEvaluationTasks.values {
            task.cancel()
        }
    }

    public func update(pose: ARPoseSnapshot) {
        if let current = latestPose {
            guard Self.isNewer(pose, than: current) else {
                metrics.posesRejectedAsOutOfOrder &+= 1
                return
            }
            let contextChanged = !Self.hasStableEvaluationContext(current, pose)
            latestPose = pose
            metrics.posesAccepted &+= 1
            if contextChanged {
                invalidateEvaluationContext()
            }
            return
        }
        latestPose = pose
        metrics.posesAccepted &+= 1
    }

    public func update(surface: ARSurfaceStateSnapshot) {
        if let current = latestSurface,
            Self.hasSameSurfaceIdentity(current, surface)
        {
            guard
                surface.revision > current.revision
                    || (surface.revision == current.revision
                        && surface.timestamp > current.timestamp)
            else {
                metrics.surfacesRejectedAsOutOfOrder &+= 1
                return
            }
        }
        let changed = latestSurface.map { $0 != surface } ?? false
        latestSurface = surface
        metrics.surfacesAccepted &+= 1
        if changed {
            invalidateEvaluationContext()
        }
    }

    public func clearSpatialContext() {
        latestPose = nil
        latestSurface = nil
        invalidateEvaluationContext()
    }

    public func evaluate(_ kind: FurnitureKind) {
        guard let pose = latestPose else {
            publishInsufficient(kind: kind, issue: .poseUnavailable)
            return
        }
        guard let surface = latestSurface else {
            publishInsufficient(kind: kind, issue: .surfaceUnavailable)
            return
        }
        guard let capabilities = capabilitiesProvider() else {
            publishInsufficient(kind: kind, issue: .capabilitiesUnavailable)
            return
        }

        if evaluationTask != nil {
            evaluationTask?.cancel()
            metrics.requestsCancelled &+= 1
        }
        latestRequestID &+= 1
        let requestID = latestRequestID
        let context = EvaluationContext(
            pose: pose,
            surface: surface,
            capabilities: capabilities
        )
        latestPresentation = nil
        latestRecommendedPlacement = nil
        metrics.requestsStarted &+= 1
        state = .evaluating(requestID: requestID, kind: kind)

        let candidateProvider = candidatePositionProvider
        let metadataProvider = objectMetadataProvider
        let builder = evidenceBuilder
        let evaluator = evaluator
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.trackedEvaluationDidFinish(taskID) }
            do {
                guard let candidatePosition = try await candidateProvider(pose) else {
                    guard let self,
                        self.isCurrent(requestID: requestID, context: context)
                    else {
                        self?.rejectStale(requestID: requestID)
                        return
                    }
                    self.publishInsufficient(
                        kind: kind,
                        issue: .candidateUnavailable,
                        requestID: requestID
                    )
                    return
                }
                try Task.checkCancellation()
                guard let self,
                    self.isCurrent(requestID: requestID, context: context)
                else {
                    self?.rejectStale(requestID: requestID)
                    return
                }

                let objects = try await metadataProvider()
                try Task.checkCancellation()
                guard self.isCurrent(requestID: requestID, context: context) else {
                    self.rejectStale(requestID: requestID)
                    return
                }

                let buildTask = Task.detached(priority: .userInitiated) {
                    builder.build(
                        kind: kind,
                        candidatePosition: candidatePosition,
                        surface: surface,
                        pose: pose,
                        capabilities: capabilities,
                        objects: objects
                    )
                }
                let buildOutcome = await withTaskCancellationHandler {
                    await buildTask.value
                } onCancel: {
                    buildTask.cancel()
                }
                try Task.checkCancellation()
                guard self.isCurrent(requestID: requestID, context: context) else {
                    self.rejectStale(requestID: requestID)
                    return
                }

                switch buildOutcome {
                case .insufficient(let issue):
                    self.publishInsufficient(
                        kind: kind,
                        issue: issue,
                        candidatePosition: candidatePosition,
                        requestID: requestID
                    )
                case .ready(let prepared):
                    let evaluationTask = Task.detached(priority: .userInitiated) {
                        evaluator.evaluate(
                            candidate: prepared.candidate,
                            evidence: prepared.evidence
                        )
                    }
                    let evaluation = await withTaskCancellationHandler {
                        await evaluationTask.value
                    } onCancel: {
                        evaluationTask.cancel()
                    }
                    try Task.checkCancellation()
                    guard self.isCurrent(requestID: requestID, context: context) else {
                        self.rejectStale(requestID: requestID)
                        return
                    }
                    self.publishEvaluation(
                        kind: kind,
                        prepared: prepared,
                        evaluation: evaluation,
                        requestID: requestID
                    )
                }
            } catch is CancellationError {
                self?.rejectStale(requestID: requestID)
            } catch {
                guard let self,
                    self.isCurrent(requestID: requestID, context: context)
                else {
                    self?.rejectStale(requestID: requestID)
                    return
                }
                self.publishInsufficient(
                    kind: kind,
                    issue: .objectMetadataUnavailable,
                    requestID: requestID
                )
            }
        }
        evaluationTask = task
        trackedEvaluationTasks[taskID] = task
    }

    public func cancelCurrentEvaluation(resetToIdle: Bool = true) {
        guard evaluationTask != nil else {
            if resetToIdle {
                state = .idle
                latestPresentation = nil
                latestRecommendedPlacement = nil
            }
            return
        }
        evaluationTask?.cancel()
        evaluationTask = nil
        latestRequestID &+= 1
        metrics.requestsCancelled &+= 1
        if resetToIdle {
            state = .idle
            latestPresentation = nil
            latestRecommendedPlacement = nil
        }
    }

    /// Cancels the request and waits for metadata loading and detached geometry
    /// evaluation to finish before app-owned spatial files are removed.
    public func cancelCurrentEvaluationAndWait(resetToIdle: Bool = true) async {
        let pendingEvaluations = Array(trackedEvaluationTasks.values)
        cancelCurrentEvaluation(resetToIdle: resetToIdle)
        for task in pendingEvaluations {
            task.cancel()
        }
        for task in pendingEvaluations {
            await task.value
        }
    }

    private func trackedEvaluationDidFinish(_ taskID: UUID) {
        trackedEvaluationTasks[taskID] = nil
    }

    private func invalidateEvaluationContext() {
        if evaluationTask != nil {
            evaluationTask?.cancel()
            evaluationTask = nil
            latestRequestID &+= 1
            metrics.requestsCancelled &+= 1
        }
        state = .idle
        latestPresentation = nil
        latestRecommendedPlacement = nil
    }

    private func isCurrent(
        requestID: UInt64,
        context: EvaluationContext
    ) -> Bool {
        requestID == latestRequestID
            && context.matches(
                pose: latestPose,
                surface: latestSurface,
                capabilities: capabilitiesProvider()
            )
    }

    private func rejectStale(requestID: UInt64) {
        metrics.staleResultsRejected &+= 1
        if requestID == latestRequestID {
            evaluationTask = nil
            state = .idle
            latestPresentation = nil
            latestRecommendedPlacement = nil
        }
    }

    private func publishInsufficient(
        kind: FurnitureKind,
        issue: ARFurniturePlacementEvidenceIssue,
        candidatePosition: FramedPosition? = nil,
        requestID: UInt64? = nil
    ) {
        let presentation = FurniturePlacementPresentation(
            kind: kind,
            disposition: .insufficientEvidence,
            candidatePosition: candidatePosition,
            candidate: nil,
            evaluation: nil,
            evidenceSummary: nil,
            issue: issue,
            message: Self.koreanMessage(for: issue, kind: kind)
        )
        state = .result(presentation)
        latestPresentation = presentation
        latestRecommendedPlacement = nil
        metrics.insufficientEvidencePublished &+= 1
        finish(requestID: requestID)
    }

    private func publishEvaluation(
        kind: FurnitureKind,
        prepared: ARFurniturePlacementPreparedInput,
        evaluation: FurniturePlacementEvaluation,
        requestID: UInt64
    ) {
        let issue: ARFurniturePlacementEvidenceIssue? =
            evaluation.disposition == .insufficientEvidence
                && !prepared.summary.lidarEvidenceComplete
            ? .lidarEvidenceIncomplete : nil
        let presentation = FurniturePlacementPresentation(
            kind: kind,
            disposition: evaluation.disposition,
            candidatePosition: prepared.sourcePosition,
            candidate: prepared.candidate,
            evaluation: evaluation,
            evidenceSummary: prepared.summary,
            issue: issue,
            message: Self.koreanMessage(
                for: evaluation,
                kind: kind,
                lidarIncomplete: issue == .lidarEvidenceIncomplete
            )
        )
        latestPresentation = presentation
        state = .result(presentation)

        switch evaluation.disposition {
        case .feasible:
            latestRecommendedPlacement = RecommendedFurniturePlacement(
                kind: kind,
                position: prepared.sourcePosition,
                yawRadians: prepared.candidate.yawRadians,
                dimensions: prepared.candidate.furniture,
                confidence: evaluation.confidence,
                confidenceScore: evaluation.confidenceScore
            )
            metrics.recommendationsPublished &+= 1
        case .rejected:
            latestRecommendedPlacement = nil
            metrics.rejectionsPublished &+= 1
        case .insufficientEvidence:
            latestRecommendedPlacement = nil
            metrics.insufficientEvidencePublished &+= 1
        }
        finish(requestID: requestID)
    }

    private func finish(requestID: UInt64?) {
        guard requestID == nil || requestID == latestRequestID else {
            return
        }
        evaluationTask = nil
    }

    private static func koreanMessage(
        for issue: ARFurniturePlacementEvidenceIssue,
        kind: FurnitureKind
    ) -> String {
        let name = koreanName(kind)
        switch issue {
        case .poseUnavailable, .surfaceUnavailable, .capabilitiesUnavailable:
            return "공간 정보가 아직 준비되지 않아 \(name) 배치를 추천하지 않았어요. 카메라로 주변을 조금 더 둘러봐 주세요."
        case .candidateUnavailable:
            return "화면 중앙에서 바닥 위치를 확인하지 못해 \(name) 배치를 추천하지 않았어요. 바닥을 비춰 주세요."
        case .worldTrackingUnavailable:
            return "이 기기에서는 안정적인 공간 추적을 확인할 수 없어 배치를 추천하지 않았어요."
        case .captureNotConfirmed, .trackingUnstable:
            return "카메라 추적이 안정되지 않아 \(name) 배치를 추천하지 않았어요. 잠시 멈춰 주변을 천천히 비춰 주세요."
        case .worldMappingIncomplete, .incompleteSurfaceSnapshot,
            .surfaceSnapshotStale:
            return "주변 공간 스캔이 충분하지 않아 \(name) 배치를 추천하지 않았어요. 바닥과 벽을 더 비춰 주세요."
        case .coordinateContextMismatch, .currentMapUnavailable,
            .candidateCoordinateMismatch:
            return "현재 공간과 후보 위치의 좌표가 일치하지 않아 안전하게 추천할 수 없어요. 공간을 다시 인식해 주세요."
        case .candidatePositionStale, .candidatePositionUncertain:
            return "화면 중앙 위치의 신뢰도가 부족해 \(name) 배치를 추천하지 않았어요. 바닥을 다시 지정해 주세요."
        case .surfaceCapacityExceeded, .objectCapacityExceeded,
            .invalidSurfaceGeometry:
            return "공간 형상을 안전하게 검증하지 못해 \(name) 배치를 추천하지 않았어요. 다시 스캔해 주세요."
        case .objectMetadataUnavailable:
            return "저장된 물체 정보를 확인하지 못해 \(name) 배치를 추천하지 않았어요. 잠시 후 다시 시도해 주세요."
        case .lidarEvidenceIncomplete:
            return "벽, 문, 통로까지 확인할 LiDAR 공간 정보가 부족해 \(name) 배치를 아직 추천하지 않았어요. 주변을 더 넓게 스캔해 주세요."
        }
    }

    private static func koreanMessage(
        for evaluation: FurniturePlacementEvaluation,
        kind: FurnitureKind,
        lidarIncomplete: Bool
    ) -> String {
        let name = koreanName(kind)
        switch evaluation.disposition {
        case .feasible:
            return "확인된 바닥, 벽, 문, 물체와 통로 기준으로 이 위치에 \(name)을 놓아도 좋아 보여요."
        case .insufficientEvidence:
            if lidarIncomplete {
                return koreanMessage(for: .lidarEvidenceIncomplete, kind: kind)
            }
            let codes = Set(evaluation.reasons.map(\.code))
            if codes.contains(.floorEvidenceMissing)
                || codes.contains(.floorSupportInsufficient)
                || codes.contains(.floorConfidenceTooLow)
            {
                return "바닥 지지 영역을 충분히 확인하지 못해 \(name) 배치를 추천하지 않았어요."
            }
            if codes.contains(.observationEvidenceMissing)
                || codes.contains(.observationCoverageInsufficient)
                || codes.contains(.observationConfidenceTooLow)
            {
                return "후보 주변의 빈 공간을 충분히 확인하지 못해 \(name) 배치를 추천하지 않았어요."
            }
            return "안전한 배치를 판단할 공간 정보가 부족해 \(name) 배치를 추천하지 않았어요."
        case .rejected:
            let codes = Set(evaluation.reasons.map(\.code))
            if codes.contains(.blocksDoorway) {
                return "문과 출입 공간을 막을 수 있어 이 위치의 \(name) 배치는 추천하지 않아요."
            }
            if codes.contains(.passageWidthTooNarrow) {
                return "사람이 지날 통로가 너무 좁아져 이 위치의 \(name) 배치는 추천하지 않아요."
            }
            if codes.contains(.collidesWithExistingObject)
                || codes.contains(.objectClearanceTooSmall)
            {
                return "기존 물체와 겹치거나 너무 가까워 이 위치의 \(name) 배치는 추천하지 않아요."
            }
            if codes.contains(.wallClearanceTooSmall) {
                return "벽과 필요한 여유 거리를 확보하지 못해 이 위치의 \(name) 배치는 추천하지 않아요."
            }
            if codes.contains(.floorSupportInsufficient) {
                return "가구 전체를 지지할 바닥이 부족해 이 위치의 \(name) 배치는 추천하지 않아요."
            }
            return "확인된 공간 제약과 충돌해 이 위치의 \(name) 배치는 추천하지 않아요."
        }
    }

    private static func koreanName(_ kind: FurnitureKind) -> String {
        switch kind {
        case .sofa: "소파"
        case .bed: "침대"
        case .desk: "책상"
        }
    }

    private static func isNewer(
        _ incoming: ARPoseSnapshot,
        than current: ARPoseSnapshot
    ) -> Bool {
        let incomingToken = incoming.sessionToken
        let currentToken = current.sessionToken
        if incomingToken.attachmentEpoch != currentToken.attachmentEpoch {
            return incomingToken.attachmentEpoch > currentToken.attachmentEpoch
        }
        if incomingToken.sessionRunGeneration != currentToken.sessionRunGeneration {
            return incomingToken.sessionRunGeneration > currentToken.sessionRunGeneration
        }
        return incoming.timestamp > current.timestamp
    }

    private static func hasStableEvaluationContext(
        _ lhs: ARPoseSnapshot,
        _ rhs: ARPoseSnapshot
    ) -> Bool {
        lhs.sessionToken == rhs.sessionToken
            && lhs.coordinateFrameID == rhs.coordinateFrameID
            && lhs.segmentID == rhs.segmentID
            && lhs.mapID == rhs.mapID
            && lhs.coordinateFrameStatus == rhs.coordinateFrameStatus
            && lhs.trackingState == rhs.trackingState
            && lhs.worldMappingStatus == rhs.worldMappingStatus
    }

    private static func hasSameSurfaceIdentity(
        _ lhs: ARSurfaceStateSnapshot,
        _ rhs: ARSurfaceStateSnapshot
    ) -> Bool {
        lhs.coordinateFrameID == rhs.coordinateFrameID
            && lhs.segmentID == rhs.segmentID
            && lhs.mapID == rhs.mapID
            && lhs.coordinateFrameStatus == rhs.coordinateFrameStatus
    }
}

private struct EvaluationContext: Equatable, Sendable {
    let sessionToken: ARSessionFrameToken
    let coordinateFrameID: CoordinateFrameID
    let segmentID: CaptureSegmentID
    let mapID: MapID?
    let coordinateFrameStatus: ARCaptureIdentity.Status
    let trackingState: ARTrackingStateSnapshot
    let worldMappingStatus: ARWorldMappingStatusSnapshot
    let surfaceRevision: UInt64
    let surfaceTimestamp: TimeInterval
    let surfaceIsCurrent: Bool
    let capabilities: ARCaptureCapabilities

    init(
        pose: ARPoseSnapshot,
        surface: ARSurfaceStateSnapshot,
        capabilities: ARCaptureCapabilities
    ) {
        sessionToken = pose.sessionToken
        coordinateFrameID = pose.coordinateFrameID
        segmentID = pose.segmentID
        mapID = pose.mapID
        coordinateFrameStatus = pose.coordinateFrameStatus
        trackingState = pose.trackingState
        worldMappingStatus = pose.worldMappingStatus
        surfaceRevision = surface.revision
        surfaceTimestamp = surface.timestamp
        surfaceIsCurrent = surface.isCurrentSessionData
        self.capabilities = capabilities
    }

    func matches(
        pose: ARPoseSnapshot?,
        surface: ARSurfaceStateSnapshot?,
        capabilities: ARCaptureCapabilities?
    ) -> Bool {
        guard let pose, let surface, let capabilities else {
            return false
        }
        return self
            == EvaluationContext(
                pose: pose,
                surface: surface,
                capabilities: capabilities
            )
    }
}
