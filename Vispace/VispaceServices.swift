import Combine
import Foundation
import VispaceCore

/// The live dependency graph is assembled once; views do not create stores or
/// coordinate asynchronous writers. Tests can exercise feature/lifecycle seams.
@MainActor
final class VispaceServices: ObservableObject {
    let sessionController: ARSessionController
    let perceptionController: SpatialPerceptionController
    let placeRecognitionController: PlaceRecognitionController
    let queryController: SpatialObjectQueryController
    let relationQueryController: SpatialRelationQueryController
    let guidanceController: ARGuidanceController
    let placementController: FurniturePlacementController
    let navigationController: IndoorNavigationController
    let dataManagementController: SpatialDataManagementController
    let lifecycle: SpatialApplicationLifecycle
    let placementStreamBridge: ARFurniturePlacementStreamBridge

    init() {
        let spatialCaptureDirectory = VispaceStoragePaths.spatialCaptureDirectory()
        let repository = WorldMapCheckpointRepository(
            directoryURL: spatialCaptureDirectory
        )
        let sessionController = ARSessionController.live(repository: repository)
        let placeMemoryRepository = PlaceMemoryRepository(
            directoryURL: spatialCaptureDirectory
        )
        let coordinateAlignmentRepository = CoordinateAlignmentRepository(
            directoryURL: spatialCaptureDirectory
        )
        let coordinateAlignmentResolver = PlaceCoordinateAlignmentResolver()
        let queryRepository = SpatialObjectQueryRepository(
            worldMapRepository: repository,
            coordinateAlignmentRepository: coordinateAlignmentRepository
        )
        let sceneGraphRepository = SceneGraphRepository(
            directoryURL: spatialCaptureDirectory
        )
        let sceneGraphService = SpatialSceneGraphService(
            repository: sceneGraphRepository
        )
        let durableMetadataWriter: @Sendable (SpatialObjectMetadata) async throws -> Void = {
            metadata in
            try await repository.upsertObjectMetadata(metadata)
            let objects = try await repository.metadataSnapshot().objects
            _ = try await sceneGraphService.ingest(
                changed: metadata,
                allObjects: objects,
                at: max(
                    Date().timeIntervalSince1970,
                    metadata.object.stateUpdatedAt
                )
            )
        }
        let temporalJournalRepository = TemporalSpatialMemoryJournalRepository(
            directoryURL: spatialCaptureDirectory
        )
        let temporalMemoryService = TemporalSpatialMemoryService(
            journalRepository: temporalJournalRepository,
            metadataProvider: {
                try await repository.metadataSnapshot()
            },
            metadataWriter: durableMetadataWriter
        )
        let detectorResolution: ObjectDetectorResolution
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(
                "-VispaceSimulateDetectorUnavailable"
            ) {
                detectorResolution = ObjectDetectorResolution(
                    detector: NoOpObjectDetector(reason: "Simulated unavailable detector."),
                    availability: .unavailable(reason: "Simulated unavailable detector.")
                )
            } else {
                detectorResolution = ObjectDetectorFactory.bundledModel(
                    named: "YOLOv3TinyInt8LUT"
                )
            }
        #else
            detectorResolution = ObjectDetectorFactory.bundledModel(
                named: "YOLOv3TinyInt8LUT"
            )
        #endif
        let perceptionController = SpatialPerceptionController(
            frameStreamProvider: { sessionController.frames },
            detectorResolution: detectorResolution,
            confirmedIdentityProvider: { frame in
                sessionController.confirmedCaptureIdentity(for: frame)
            },
            metadataProvider: {
                try await repository.metadataSnapshot().objects
            },
            metadataWriter: durableMetadataWriter,
            temporalMemoryProcessor: { batch, pose in
                try await temporalMemoryService.process(batch, pose: pose)
            }
        )
        let placeRecognitionController = PlaceRecognitionController(
            surfaceStreamProvider: { sessionController.surfaces },
            objectMetadataProvider: {
                try await repository.metadataSnapshot().objects
            },
            catalogProvider: {
                try await placeMemoryRepository.catalogSnapshot()
            },
            fingerprintWriter: { record in
                try await placeMemoryRepository.upsertFingerprint(record)
            },
            associationWriter: { record in
                try await placeMemoryRepository.upsertAssociationState(
                    record,
                    retention: .retireOlderDeferredAttempts
                )
            },
            coordinateCompatibilityProvider: { snapshot, candidate, objects in
                coordinateAlignmentResolver.resolve(
                    current: snapshot,
                    candidate: candidate,
                    objects: objects
                )
            },
            existingMapAssociator: { mapID, coordinateFrameID in
                sessionController.associateCurrentCapture(
                    with: mapID,
                    coordinateFrameID: coordinateFrameID
                )
            },
            logicalMergeWriter: { commit in
                guard let alignment = commit.validatedAlignment else {
                    // Same-coordinate-frame aliases are already durably
                    // represented by the replayable association decision.
                    return
                }
                let now = max(0, Date().timeIntervalSince1970)
                let record = try CoordinateAlignmentRecord(
                    sourceMapID: commit.sourceMapID,
                    sourceCoordinateFrameID: commit.sourceCoordinateFrameID,
                    targetMapID: commit.targetMapID,
                    targetCoordinateFrameID: commit.targetCoordinateFrameID,
                    result: alignment,
                    createdAt: now,
                    updatedAt: now
                )
                _ = try await coordinateAlignmentRepository.commitIfAbsent(record)
            },
            checkpointRequester: {
                sessionController.requestWorldMapCheckpoint()
            }
        )
        let queryController = SpatialObjectQueryController(
            repository: queryRepository,
            currentIdentityProvider: {
                sessionController.captureIdentity
            }
        )
        let relationQueryController = SpatialRelationQueryController(
            objectRepository: queryRepository,
            sceneGraphRepository: sceneGraphRepository,
            currentIdentityProvider: {
                sessionController.captureIdentity
            }
        )
        let guidanceController = ARGuidanceController(
            poseStreamProvider: { sessionController.poses }
        )
        let placementController = FurniturePlacementController(
            candidatePositionProvider: { _ in
                sessionController.verifiedPlacementPositionAtScreenCenter()
            },
            objectMetadataProvider: {
                try await repository.metadataSnapshot().objects
            },
            capabilitiesProvider: {
                sessionController.capabilities
            }
        )
        let placementStreamBridge = ARFurniturePlacementStreamBridge(
            poseStreamProvider: { sessionController.poses },
            surfaceStreamProvider: { sessionController.surfaces },
            controller: placementController
        )
        let navigationEvidenceBuilder = ARVerifiedNavigationEvidenceBuilder()
        let navigationController = IndoorNavigationController(
            surfaceStreamProvider: { sessionController.surfaces },
            poseStreamProvider: { sessionController.poses },
            currentIdentityProvider: {
                sessionController.captureIdentity
            },
            evidenceProvider: { snapshot, identity in
                let evidenceWork = Task.detached(priority: .userInitiated) {
                    navigationEvidenceBuilder.adapt(
                        snapshot,
                        currentIdentity: identity
                    )
                }
                return await withTaskCancellationHandler {
                    await evidenceWork.value
                } onCancel: {
                    evidenceWork.cancel()
                }
            },
            startPositionProvider: { stalePose, identity in
                guard
                    let evidence =
                        await sessionController
                        .currentVerifiedCameraFloorPoseEvidence(matching: identity)
                else {
                    return ARPoseIndoorNavigationAdapter().adapt(
                        stalePose,
                        currentIdentity: identity
                    )
                }
                return ARPoseIndoorNavigationAdapter().adapt(
                    evidence.pose,
                    currentIdentity: identity,
                    verifiedFloorPosition: evidence.floorPosition
                )
            },
            sourceMetadataProvider: { objectID, sourceMapID in
                try await repository.metadataSnapshot().objects.first {
                    $0.object.id == objectID && $0.mapID == sourceMapID
                }
            },
            surfaceStabilityDelay: .milliseconds(250),
            evaluationTimestampProvider: { sessionController.navigationEvaluationTimestamp }
        )
        let lifecycle = SpatialApplicationLifecycle(
            prepareStorage: {
                try SpatialStorageDirectory.prepare(at: spatialCaptureDirectory)
            },
            start: {
                sessionController.setFrameSnapshotsEnabled(perceptionController.isDetectorAvailable)
                sessionController.setSurfaceSnapshotsEnabled(true)
                sessionController.activate()
                perceptionController.activate()
                placeRecognitionController.activate()
                guidanceController.activate()
                placementStreamBridge.activate()
                navigationController.activate()
            },
            stop: { saveCheckpoint in
                queryController.invalidateForCaptureTransition()
                relationQueryController.invalidateForCaptureTransition()
                placementStreamBridge.deactivate()
                navigationController.deactivate()
                guidanceController.deactivate()
                placeRecognitionController.deactivate()
                perceptionController.deactivate()
                sessionController.setFrameSnapshotsEnabled(false)
                sessionController.setSurfaceSnapshotsEnabled(false)
                if saveCheckpoint { sessionController.enterBackground() }
                sessionController.deactivate()
            },
            quiesce: {
                await queryController.invalidateAndWaitForPendingWork()
                await relationQueryController.invalidateAndWaitForPendingWork()
                await placementController.cancelCurrentEvaluationAndWait()
                await navigationController.deactivateAndWaitForPendingWork()
                sessionController.setFrameSnapshotsEnabled(false)
                sessionController.setSurfaceSnapshotsEnabled(false)
                await sessionController.prepareForSpatialDataDeletion()
                await perceptionController.deactivateAndWaitForPendingWork()
                await placeRecognitionController.deactivateAndWaitForPendingWork()
            },
            deleteStore: {
                try await Task.detached(priority: .utility) {
                    try SpatialDataStoreMaintenance.deleteAll(at: spatialCaptureDirectory)
                }.value
            }
        )
        let dataManagementController = SpatialDataManagementController {
            try await lifecycle.deleteSpatialData()
        }
        self.sessionController = sessionController
        self.perceptionController = perceptionController
        self.placeRecognitionController = placeRecognitionController
        self.queryController = queryController
        self.relationQueryController = relationQueryController
        self.guidanceController = guidanceController
        self.placementController = placementController
        self.navigationController = navigationController
        self.dataManagementController = dataManagementController
        self.lifecycle = lifecycle
        self.placementStreamBridge = placementStreamBridge
    }
}
