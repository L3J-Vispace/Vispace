import Combine
import Foundation
import VispaceCore

/// The live dependency graph is assembled once; views do not create stores or
/// coordinate asynchronous writers. Tests can exercise feature/lifecycle seams.
@MainActor
final class VispaceServices: ObservableObject {
    let sessionController: ARSessionController
    let perceptionController: SpatialPerceptionController
    let registrationController: UserObjectRegistrationController
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
        let placeVisualEvidence = ARPlaceVisualEvidenceProvider(directoryURL: spatialCaptureDirectory)
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
        let objectMutationFence = SpatialObjectMutationFence()
        let durableMetadataWriter: @Sendable (SpatialObjectMetadata) async throws -> Void = {
            metadata in
            objectMutationFence.begin()
            defer { objectMutationFence.end() }
            let document = try await repository.upsertObjectMetadataBatch([metadata])
            try Task.checkCancellation()
            let now = Date().timeIntervalSince1970
            // Preserve observation dates after clock correction. The graph
            // service uses actual current time to retire future-dated evidence.
            _ = try await sceneGraphService.ingest(
                changed: metadata,
                allObjects: document.objects,
                at: now
            )
        }
        let durableMetadataBatchWriter: TemporalSpatialMemoryService.MetadataBatchWriter = { metadata in
            objectMutationFence.begin()
            defer { objectMutationFence.end() }
            let document = try await repository.upsertObjectMetadataBatch(metadata)
            try Task.checkCancellation()
            guard let first = metadata.first else { return }
            // Recovery provides one complete map/frame snapshot. Reconcile from
            // the committed document, including any name updated before the batch.
            try await sceneGraphService.rebuild(
                mapID: first.mapID, coordinateFrameID: first.position.coordinateFrameID,
                allObjects: document.objects, at: Date().timeIntervalSince1970
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
            metadataWriter: durableMetadataWriter,
            metadataBatchWriter: durableMetadataBatchWriter,
            poseValidator: sessionController.makeTemporalPoseValidator()
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
                    named: "YOLOv3Int8LUT"
                )
            }
        #else
            detectorResolution = ObjectDetectorFactory.bundledModel(
                named: "YOLOv3Int8LUT"
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
            },
            observationSink: { frame, detections in
                let objects = try await repository.metadataSnapshot().objects
                try await placeVisualEvidence.ingest(frame: frame, detections: detections, objects: objects)
            }
        )
        let registrationController = UserObjectRegistrationController(
            frameStreamProvider: { sessionController.frames },
            confirmedIdentityProvider: { sessionController.confirmedCaptureIdentity(for: $0) },
            metadataWriter: durableMetadataWriter
        )
        let placeRecognitionController = PlaceRecognitionController(
            surfaceStreamProvider: { sessionController.surfaces },
            objectMetadataProvider: {
                try await repository.metadataSnapshot().objects
            },
            catalogProvider: {
                try await placeMemoryRepository.catalogSnapshot()
            },
            visualHistogramProvider: { await placeVisualEvidence.visualHistogram(matching: $0) },
            verifiedAlignmentCatalogProvider: { try await coordinateAlignmentRepository.catalogSnapshot() },
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
                let alignments = try await coordinateAlignmentRepository.catalogSnapshot()
                let resolution = try await placeVisualEvidence.resolve(
                    current: snapshot,
                    candidate: candidate,
                    objects: objects,
                    verifiedAlignments: alignments
                )
                guard try await coordinateAlignmentRepository.catalogSnapshot() == alignments else {
                    return try PlaceCoordinateAlignmentResolution(
                        sourceMapID: snapshot.mapID, targetMapID: candidate.mapID,
                        sourceCoordinateFrameID: snapshot.coordinateFrameID,
                        targetCoordinateFrameID: candidate.coordinateFrameID,
                        evidence: .unresolved, validatedAlignment: nil)
                }
                return resolution
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
                if expected.object.semanticLabel == UserObjectRegistrationAccumulator.semanticLabel,
                    displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    throw SpatialObjectError.invalidDisplayName
                }
                objectMutationFence.begin()
                defer { objectMutationFence.end() }
                return try await repository.renameObject(expected: expected, displayName: displayName)
            },
            classificationCorrectionProvider: { expected, label in
                guard expected.object.semanticLabel != UserObjectRegistrationAccumulator.semanticLabel else {
                    throw TemporalSpatialMemoryError.staleClassificationCorrection(expected.object.id)
                }
                guard let frame = await sessionController.latestDepthFrame,
                    frame.pose.mapID == expected.mapID,
                    frame.pose.coordinateFrameID == expected.position.coordinateFrameID
                else {
                    throw SpatialSceneGraphServiceError.mapCoordinateFrameMismatch
                }
                guard
                    let current = try await repository.metadataSnapshot().objects.first(where: {
                        $0.mapID == expected.mapID && $0.object.id == expected.object.id
                    }), current.position.coordinateFrameID == expected.position.coordinateFrameID,
                    current.object.semanticLabel == expected.object.semanticLabel,
                    current.object.displayName == expected.object.displayName,
                    current.object.detectorSemanticLabel == expected.object.detectorSemanticLabel,
                    current.object.certainty == expected.object.certainty,
                    current.object.presence != .removed,
                    current.object.firstSeenAt == expected.object.firstSeenAt
                else {
                    throw SpatialSceneGraphServiceError.outOfOrderObservation
                }
                _ = try await temporalMemoryService.correctClassification(
                    objectID: current.object.id,
                    semanticLabel: label, expectedTemporalRevision: current.object.temporalRevision,
                    pose: frame.pose)
                guard
                    let corrected = try await repository.metadataSnapshot().objects.first(where: {
                        $0.mapID == expected.mapID && $0.object.id == expected.object.id
                    })
                else { throw SpatialSceneGraphServiceError.missingChangedObject }
                return corrected
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
        let navigationEvidenceProvider: IndoorNavigationController.EvidenceProvider = { snapshot, identity in
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
        }
        let navigationController = IndoorNavigationController(
            surfaceStreamProvider: { sessionController.surfaces },
            poseStreamProvider: { sessionController.poses },
            currentIdentityProvider: {
                sessionController.captureIdentity
            },
            evidenceProvider: navigationEvidenceProvider,
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
        relationQueryController.observationProvider = { scope, records, identity, wallTime in
            guard let mapID = identity.mapID, let sourceVersion = objectMutationFence.stableVersion else {
                return SceneGraph()
            }
            let latestObjects = try await repository.metadataSnapshot().objects
            guard
                SpatialObjectMutationFence.representsSameSnapshot(
                    records: records, currentObjects: latestObjects,
                    mapID: mapID, coordinateFrameID: identity.coordinateFrameID),
                objectMutationFence.stableVersion == sourceVersion
            else { return SceneGraph() }
            let capture = await MainActor.run {
                (
                    sessionController.latestSurfaceSnapshot,
                    sessionController.navigationEvaluationTimestamp
                )
            }
            guard let snapshot = capture.0, let evaluatedAt = capture.1,
                let floor = await sessionController.currentVerifiedCameraFloorPoseEvidence(
                    matching: identity),
                case .ready(let evidence) = try await navigationEvidenceProvider(snapshot, identity)
            else {
                try await sceneGraphService.replaceObservedRelations(
                    mapID: mapID,
                    coordinateFrameID: identity.coordinateFrameID, graph: SceneGraph(), at: wallTime)
                return SceneGraph()
            }
            let graph = try await Task.detached(priority: .userInitiated) {
                try ObservedNavigationRelationDeriver().derive(
                    scope: scope,
                    objects: records.map(\.metadata), evidence: evidence, cameraStart: floor.floorPosition,
                    segmentID: identity.segmentID, evaluatedAt: evaluatedAt, wallTime: wallTime,
                    objectRevisionEpoch: sourceVersion)
            }.value
            try Task.checkCancellation()
            let isCurrent = await MainActor.run {
                sessionController.captureIdentity == identity
                    && sessionController.latestSurfaceSnapshot?.revision == snapshot.revision
                    && sessionController.navigationEvaluationTimestamp.map {
                        $0 >= evaluatedAt && $0 - evaluatedAt <= 0.5
                    } == true
            }
            guard isCurrent, objectMutationFence.stableVersion == sourceVersion else { return SceneGraph() }
            try await sceneGraphService.replaceObservedRelations(
                mapID: mapID,
                coordinateFrameID: identity.coordinateFrameID, graph: graph, at: Date().timeIntervalSince1970)
            guard objectMutationFence.stableVersion == sourceVersion else { return SceneGraph() }
            return graph
        }
        relationQueryController.observationValidator = { source in
            guard let current = sessionController.latestSurfaceSnapshot,
                let now = sessionController.navigationEvaluationTimestamp
            else { return false }
            return current.mapID == source.mapID && current.coordinateFrameID == source.coordinateFrameID
                && current.segmentID == source.segmentID && current.revision == source.surfaceRevision
                && source.objectRevisionEpoch != nil
                && objectMutationFence.stableVersion == source.objectRevisionEpoch
                && now >= source.observedAt && now - source.observedAt <= 0.75
        }
        let lifecycle = SpatialApplicationLifecycle(
            prepareStorage: {
                try SpatialStorageDirectory.prepare(at: spatialCaptureDirectory)
            },
            start: {
                sessionController.setFrameSnapshotsEnabled(true)
                sessionController.setSurfaceSnapshotsEnabled(true)
                sessionController.activate()
                perceptionController.activate()
                registrationController.activate()
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
                registrationController.deactivate()
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
                await registrationController.cancelAndWait()
                await placeVisualEvidence.reset()
                await placeRecognitionController.deactivateAndWaitForPendingWork()
            },
            deleteStore: {
                await mapSelection.select(nil)
                await temporalMemoryService.reset()
                defer { placeRecognitionController.invalidateStoredAssociationCache() }
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
                    defer { placeRecognitionController.invalidateStoredAssociationCache(for: mapID) }
                    try await coordinateAlignmentRepository.deleteMap(mapID: mapID)
                    try await placeMemoryRepository.deleteMap(mapID: mapID)
                    try await placeVisualEvidence.deleteMap(mapID)
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
        self.registrationController = registrationController
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
                weak navigationController, weak placementController,
                weak registrationController] identity in
            guard identity != lastIdentity else { return }
            lastIdentity = identity
            registrationController?.cancel()
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
