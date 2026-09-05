import Combine
import Foundation
import VispaceCore

public struct SpatialRelationQuerySnapshot: Sendable {
    public let mapID: MapID
    public let coordinateFrameID: CoordinateFrameID
    public let records: [StoredSpatialObjectRecord]
    public let graph: SceneGraph

    public init(
        mapID: MapID,
        coordinateFrameID: CoordinateFrameID,
        records: [StoredSpatialObjectRecord],
        graph: SceneGraph
    ) {
        self.mapID = mapID
        self.coordinateFrameID = coordinateFrameID
        self.records = records
        self.graph = graph
    }
}

public struct SpatialRelationQueryPresentation: Hashable, Sendable {
    public let result: SpatialRelationQueryResult
    public let message: String

    public init(result: SpatialRelationQueryResult, message: String) {
        self.result = result
        self.message = String(message.prefix(512))
    }
}

public enum SpatialRelationQueryControllerState: Equatable, Sendable {
    case idle
    case searching(requestID: UInt64)
    case result(SpatialRelationQueryPresentation)
    case unavailable(message: String)
    case failed(message: String)
}

public struct SpatialRelationQueryControllerMetrics: Equatable, Sendable {
    public var requestsStarted: UInt64 = 0
    public var requestsCancelled: UInt64 = 0
    public var staleResultsRejected: UInt64 = 0
    public var resultsPublished: UInt64 = 0
    public var unavailableResultsPublished: UInt64 = 0
    public var failuresPublished: UInt64 = 0

    public init() {}
}

/// Reads only the confirmed scene graph owned by the current, confirmed AR
/// coordinate frame. Language selects an existing relation; it never creates
/// an edge or coordinate.
@MainActor
public final class SpatialRelationQueryController: ObservableObject {
    public static let maximumQueryLength = 256

    public typealias SnapshotProvider =
        @Sendable (
            _ currentMapID: MapID
        ) async throws -> SpatialRelationQuerySnapshot?
    public typealias CurrentIdentityProvider = @MainActor @Sendable () -> ARCaptureIdentity

    @Published public private(set) var state: SpatialRelationQueryControllerState = .idle
    @Published public private(set) var latestPresentation: SpatialRelationQueryPresentation?
    @Published public private(set) var metrics = SpatialRelationQueryControllerMetrics()

    var isProcessingForTesting: Bool {
        queryTask != nil
    }

    private let snapshotProvider: SnapshotProvider
    private let currentIdentityProvider: CurrentIdentityProvider
    private let engine: DeterministicSpatialRelationQueryEngine

    private var queryTask: Task<Void, Never>?
    private var trackedQueryTasks: [UUID: Task<Void, Never>] = [:]
    private var latestRequestID: UInt64 = 0

    public init(
        objectRepository: SpatialObjectQueryRepository,
        sceneGraphRepository: SceneGraphRepository,
        currentIdentityProvider: @escaping CurrentIdentityProvider,
        engine: DeterministicSpatialRelationQueryEngine =
            DeterministicSpatialRelationQueryEngine()
    ) {
        snapshotProvider = { mapID in
            async let objectSnapshot = objectRepository.loadSnapshot(currentMapID: mapID)
            async let graphRecord = sceneGraphRepository.load(mapID: mapID)
            let (objects, record) = try await (objectSnapshot, graphRecord)
            guard let record else {
                return nil
            }
            return SpatialRelationQuerySnapshot(
                mapID: record.mapID,
                coordinateFrameID: record.coordinateFrameID,
                records: objects.records,
                graph: record.graph
            )
        }
        self.currentIdentityProvider = currentIdentityProvider
        self.engine = engine
    }

    public init(
        snapshotProvider: @escaping SnapshotProvider,
        currentIdentityProvider: @escaping CurrentIdentityProvider,
        engine: DeterministicSpatialRelationQueryEngine =
            DeterministicSpatialRelationQueryEngine()
    ) {
        self.snapshotProvider = snapshotProvider
        self.currentIdentityProvider = currentIdentityProvider
        self.engine = engine
    }

    deinit {
        for task in trackedQueryTasks.values {
            task.cancel()
        }
    }

    public func submit(
        _ utterance: String,
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
        guard identity.status == .confirmed, let mapID = identity.mapID else {
            queryTask = nil
            latestPresentation = nil
            state = .unavailable(
                message: "카메라 위치가 안정화된 뒤 공간 관계를 다시 물어봐 주세요."
            )
            metrics.unavailableResultsPublished &+= 1
            return
        }

        let query = Self.boundedQuery(utterance)
        metrics.requestsStarted &+= 1
        latestPresentation = nil
        state = .searching(requestID: requestID)

        let snapshotProvider = self.snapshotProvider
        let engine = self.engine
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.trackedQueryDidFinish(taskID) }
            do {
                let snapshot = try await snapshotProvider(mapID)
                try Task.checkCancellation()
                guard let self,
                    self.isCurrent(requestID: requestID, identity: identity)
                else {
                    self?.rejectStaleResult(requestID: requestID)
                    self?.finish(requestID: requestID)
                    return
                }
                guard let snapshot else {
                    self.publishUnavailable(
                        "아직 확정된 공간 관계가 없어요. 카메라로 주변 물체를 조금 더 보여 주세요."
                    )
                    self.finish(requestID: requestID)
                    return
                }
                guard snapshot.mapID == mapID,
                    snapshot.coordinateFrameID == identity.coordinateFrameID
                else {
                    self.publishUnavailable(
                        "저장된 공간과 현재 카메라 좌표를 확인하지 못해 관계를 답하지 않았어요."
                    )
                    self.finish(requestID: requestID)
                    return
                }

                let eligibleRecords = snapshot.records.filter {
                    $0.metadata.mapID == mapID
                        && $0.metadata.position.coordinateFrameID
                            == identity.coordinateFrameID
                }
                let graph = try Self.freshnessFencedGraph(
                    snapshot.graph,
                    records: eligibleRecords
                )
                let result = try await Task.detached(priority: .userInitiated) {
                    try engine.query(
                        query,
                        records: eligibleRecords,
                        graph: graph,
                        at: now
                    )
                }.value
                try Task.checkCancellation()
                guard self.isCurrent(requestID: requestID, identity: identity) else {
                    self.rejectStaleResult(requestID: requestID)
                    self.finish(requestID: requestID)
                    return
                }

                let presentation = SpatialRelationQueryPresentation(
                    result: result,
                    message: Self.koreanMessage(for: result)
                )
                self.latestPresentation = presentation
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
        if queryTask != nil {
            queryTask?.cancel()
            queryTask = nil
            latestRequestID &+= 1
            metrics.requestsCancelled &+= 1
        }
        if resetToIdle {
            state = .idle
            latestPresentation = nil
        }
    }

    public func invalidateForCaptureTransition() {
        cancelCurrentQuery()
    }

    /// Waits for both metadata and scene-graph reads to release their actor
    /// gates before the shared spatial-data directory is deleted.
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
        }
    }

    private func finish(requestID: UInt64) {
        guard requestID == latestRequestID else {
            return
        }
        queryTask = nil
    }

    private func publishUnavailable(_ message: String) {
        latestPresentation = nil
        state = .unavailable(message: message)
        metrics.unavailableResultsPublished &+= 1
    }

    private func publishFailure() {
        latestPresentation = nil
        state = .failed(
            message: "저장된 공간 관계를 불러오지 못했어요. 잠시 후 다시 시도해 주세요."
        )
        metrics.failuresPublished &+= 1
    }

    private static func boundedQuery(_ utterance: String) -> String {
        String(
            utterance.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maximumQueryLength)
        )
    }

    /// A metadata commit and its scene-graph projection are separate atomic
    /// writes. Do not let a relation produced from an older endpoint state
    /// cross that commit boundary into a query result.
    private static func freshnessFencedGraph(
        _ graph: SceneGraph,
        records: [StoredSpatialObjectRecord]
    ) throws -> SceneGraph {
        var stateUpdatedAtByObjectID: [ObjectID: TimeInterval] = [:]
        for record in records {
            let object = record.metadata.object
            stateUpdatedAtByObjectID[object.id] = max(
                stateUpdatedAtByObjectID[object.id] ?? 0,
                object.stateUpdatedAt
            )
        }
        var freshGraph = SceneGraph(confidencePolicy: graph.confidencePolicy)
        for relation in graph.relations(includeProvisional: true) {
            guard case .object(let subjectID) = relation.key.subject,
                case .object(let objectID) = relation.key.object,
                let subjectStateUpdatedAt = stateUpdatedAtByObjectID[subjectID],
                let objectStateUpdatedAt = stateUpdatedAtByObjectID[objectID],
                relation.validFrom >= subjectStateUpdatedAt,
                relation.validFrom >= objectStateUpdatedAt
            else {
                continue
            }
            try freshGraph.upsert(relation)
        }
        return freshGraph
    }

    private static func koreanMessage(
        for result: SpatialRelationQueryResult
    ) -> String {
        let predicate = koreanPredicate(result.predicate)
        switch result.status {
        case .answered:
            if result.mode == .verifyRelation,
                let match = result.matches.first
            {
                return
                    "확정된 기록상 ‘\(match.subject.semanticLabel)’은(는) ‘\(match.object.semanticLabel)’ \(predicate) 있어요."
            }
            let reference = result.referenceObject?.semanticLabel ?? "해당 물체"
            let related = relatedLabels(in: result)
            return "‘\(reference)’ \(predicate) 확인된 물체는 \(related)예요."
        case .noConfirmedRelation:
            return "현재 확정된 기록에서는 해당 \(predicate) 관계를 확인하지 못했어요."
        case .ambiguous:
            return "같은 종류의 물체가 여러 개라 관계를 하나로 확정할 수 없어요. 주변 특징을 더 보여 주세요."
        case .notGrounded:
            return "관계를 확인할 물체 이름을 찾지 못했어요. 물체 두 개와 관계를 함께 말해 주세요."
        case .unsupported:
            return "현재는 위·아래·안·근처·막힘·교차·연결·접근 관계를 확인할 수 있어요."
        }
    }

    private static func relatedLabels(
        in result: SpatialRelationQueryResult
    ) -> String {
        let referenceID = result.referenceObject?.objectID
        let labels = result.matches.map { match in
            match.subject.objectID == referenceID
                ? match.object.semanticLabel
                : match.subject.semanticLabel
        }
        let unique = Array(Set(labels)).sorted()
        return unique.map { "‘\($0)’" }.joined(separator: ", ")
    }

    private static func koreanPredicate(
        _ predicate: SpatialRelationPredicate?
    ) -> String {
        switch predicate {
        case .on:
            return "위에"
        case .under:
            return "아래에"
        case .inside:
            return "안에"
        case .near:
            return "근처에"
        case .blocking:
            return "앞을 막고"
        case .intersects:
            return "겹쳐"
        case .connectedTo:
            return "연결되어"
        case .accessibleFrom:
            return "접근 가능한 곳에"
        case .leftOf:
            return "왼쪽에"
        case .rightOf:
            return "오른쪽에"
        case nil:
            return "공간"
        }
    }
}
