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
        let placeArchiveService = SpatialPlaceArchiveService(repository: repository)
        let mapSelection = SpatialMapSelection()
        let sessionController = ARSessionController.live(
            repository: repository, preferredMapProvider: { await mapSelection.mapID }
        )
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
            let now = Date().timeIntervalSince1970
            // Preserve observation dates after clock correction. The graph
            // service uses actual current time to retire future-dated evidence.
            let objects = try await repository.metadataSnapshot().objects
            _ = try await sceneGraphService.ingest(
                changed: metadata,
                allObjects: objects,
                at: now
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
                    retention: .retireCompletedAttempts
                )
            },
            mutationAcknowledger: { id, revision in
                try await placeMemoryRepository.acknowledgeAssociationMutation(id: id, revision: revision)
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
            },
            renameProvider: { expected, displayName in
                try await repository.renameObject(expected: expected, displayName: displayName)
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
            poseStreamProvider: { sessionController.poses },
            sourceMetadataProvider: { objectID, mapID in
                try await repository.metadataSnapshot().objects.first {
                    $0.object.id == objectID && $0.mapID == mapID
                }
            }
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
        let navigationDepthHistory = ARRecentNavigationDepthHistory(
            frameStreamProvider: { sessionController.frames }
        )
        let navigationController = IndoorNavigationController(
            surfaceStreamProvider: { sessionController.surfaces },
            poseStreamProvider: { sessionController.poses },
            currentIdentityProvider: {
                sessionController.captureIdentity
            },
            evidenceProvider: { snapshot, identity in
                let depthFrame = await sessionController.latestDepthFrame
                let depthHistory = await navigationDepthHistory.frames(
                    matching: identity, evaluatedAt: depthFrame?.pose.timestamp ?? .nan
                )
                let objects = try await repository.metadataSnapshot().objects
                let evidenceWork = Task.detached(priority: .userInitiated) {
                    navigationEvidenceBuilder.adapt(
                        snapshot,
                        currentIdentity: identity,
                        currentDepthFrame: depthFrame,
                        recentDepthFrames: depthHistory,
                        dynamicObjects: objects
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
                navigationDepthHistory.activate()
                placementStreamBridge.activate()
                navigationController.activate()
            },
            stop: { saveCheckpoint in
                queryController.invalidateForCaptureTransition()
                relationQueryController.invalidateForCaptureTransition()
                placementStreamBridge.deactivate()
                navigationController.deactivate()
                navigationDepthHistory.deactivate()
                guidanceController.deactivate()
                placeRecognitionController.deactivate()
                perceptionController.deactivate()
                sessionController.setFrameSnapshotsEnabled(false)
                sessionController.setSurfaceSnapshotsEnabled(false)
                if saveCheckpoint { sessionController.enterBackground() }
                sessionController.deactivate()
            },
            quiesce: {
                await guidanceController.deactivateAndWaitForPendingWork()
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
                await mapSelection.select(nil)
                await temporalMemoryService.reset()
                try await Task.detached(priority: .utility) {
                    try SpatialDataStoreMaintenance.deleteAll(at: spatialCaptureDirectory)
                }.value
                perceptionController.resetPersistenceStatus()
                sessionController.resetPersistenceStatus()
            }
        )
        let dataManagementController = SpatialDataManagementController(
            overviewProvider: {
                let document = try await repository.metadataSnapshot()
                let places = Dictionary(grouping: document.maps, by: \.mapID).map { mapID, maps in
                    SpatialStoredPlace(
                        id: mapID, updatedAt: maps.map(\.updatedAt).max() ?? 0,
                        objectCount: document.objects.filter { $0.mapID == mapID }.count
                    )
                }.sorted { $0.updatedAt > $1.updatedAt }
                return try await Task.detached(priority: .utility) {
                    let used = try SpatialStorageDirectory.totalBytes(at: spatialCaptureDirectory)
                    let attributes = try FileManager.default.attributesOfFileSystem(forPath: spatialCaptureDirectory.path)
                    let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                    return SpatialStorageOverview(usedBytes: used, availableBytes: available, places: places)
                }.value
            },
            deletePlaceAction: { mapID in
                try await lifecycle.performStorageMaintenance {
                    await mapSelection.select(nil)
                    await temporalMemoryService.reset()
                    try await temporalJournalRepository.deleteMap(mapID: mapID)
                    try await sceneGraphRepository.deleteMap(mapID: mapID)
                    try await coordinateAlignmentRepository.deleteMap(mapID: mapID)
                    try await placeMemoryRepository.deleteMap(mapID: mapID)
                    // Keep the owning map discoverable until cleanup succeeds,
                    // so an interrupted deletion remains retryable in settings.
                    try await repository.deleteMap(mapID: mapID)
                    perceptionController.resetPersistenceStatus()
                    sessionController.resetPersistenceStatus()
                }
            },
            selectPlaceAction: { mapID in
                // Verify availability before interrupting the current capture.
                guard try await repository.loadLatestValidCheckpoint(mapID: mapID) != nil else {
                    throw SpatialDataStoreMaintenanceError.placeUnavailable
                }
                try await lifecycle.performStorageMaintenance {
                    await temporalMemoryService.reset()
                    await mapSelection.select(mapID)
                }
            },
            exportPlaceAction: { mapID in
                try await lifecycle.performStorageMaintenance {
                    try await placeArchiveService.exportPlace(mapID: mapID)
                }
            },
            importPlaceAction: { selectedFile, recoveryKey in
                try await lifecycle.performStorageMaintenance {
                    let mapID = try await placeArchiveService.importPlace(
                        from: selectedFile, recoveryKey: recoveryKey
                    )
                    await temporalMemoryService.reset()
                    await mapSelection.select(mapID)
                    perceptionController.resetPersistenceStatus()
                    sessionController.resetPersistenceStatus()
                    return mapID
                }
            }
        ) {
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
        guidanceController.onTargetInvalidated = { [weak queryController] in
            queryController?.invalidateForCaptureTransition()
        }
        queryController.onObjectRenamed = {
            [weak relationQueryController, weak guidanceController,
                weak navigationController, weak placementController] in
            relationQueryController?.invalidateForCaptureTransition()
            guidanceController?.clear()
            navigationController?.clearRoute()
            placementController?.cancelCurrentEvaluation()
        }
        var lastIdentity = sessionController.captureIdentity
        sessionController.onCaptureIdentityChange = {
            [weak queryController, weak relationQueryController, weak guidanceController,
                weak navigationController, weak placementController] identity in
            guard identity != lastIdentity else { return }
            lastIdentity = identity
            queryController?.invalidateForCaptureTransition()
            relationQueryController?.invalidateForCaptureTransition()
            guidanceController?.clear()
            navigationController?.clearRoute()
            placementController?.cancelCurrentEvaluation()
        }
    }
}

private actor SpatialMapSelection {
    private(set) var mapID: MapID?
    func select(_ mapID: MapID?) { self.mapID = mapID }
}
