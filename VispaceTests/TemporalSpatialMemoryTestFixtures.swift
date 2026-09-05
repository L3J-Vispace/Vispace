import Foundation
import VispaceCore
import simd

@testable import Vispace

func temporalTestUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
}

func temporalTestMapID(_ value: Int) -> MapID {
    MapID(rawValue: temporalTestUUID(100_000 + value))
}

func temporalTestFrameID(_ value: Int) -> CoordinateFrameID {
    CoordinateFrameID(rawValue: temporalTestUUID(200_000 + value))
}

func temporalTestObjectID(_ value: Int) -> ObjectID {
    ObjectID(rawValue: temporalTestUUID(300_000 + value))
}

func temporalTestDeltaID(_ value: Int) -> SpatialDeltaID {
    SpatialDeltaID(rawValue: temporalTestUUID(400_000 + value))
}

func temporalTestScore(_ value: Double) -> ConfidenceScore {
    ConfidenceScore(clamping: value)
}

func temporalTestVector() -> ConfidenceVector {
    ConfidenceVector(
        semantic: temporalTestScore(0.95),
        geometry: temporalTestScore(0.95),
        tracking: temporalTestScore(0.95),
        place: temporalTestScore(0.95),
        identity: temporalTestScore(0.95),
        objectState: temporalTestScore(0.95),
        relation: temporalTestScore(0.95)
    )
}

func temporalTestPosition(_ x: Double = 0) -> Vec3 {
    try! Vec3(x: x, y: 0, z: -2)
}

func temporalTestPolicy() -> TemporalSpatialMemoryPolicy {
    try! TemporalSpatialMemoryPolicy(
        minimumMissesForNotVisible: 2,
        minimumMissesForLastSeen: 3,
        minimumMissesForRemoval: 4,
        notVisibleGraceInterval: 1,
        lastSeenGraceInterval: 2,
        removalGraceInterval: 3,
        minimumMovementObservationInterval: 0.2,
        maximumRetainedDeltaCount: 8,
        maximumRememberedUpdateCount: 8
    )
}

func temporalTestMapMetadata(
    mapID: MapID,
    coordinateFrameID: CoordinateFrameID,
    number: Int = 1
) -> SpatialMapMetadata {
    try! SpatialMapMetadata(
        mapID: mapID,
        coordinateFrameID: coordinateFrameID,
        latestSegmentID: CaptureSegmentID(rawValue: temporalTestUUID(500_000 + number)),
        worldMapBlobID: temporalTestUUID(600_000 + number),
        createdAt: 1,
        updatedAt: 2
    )
}

func temporalTestMetadata(
    mapID: MapID,
    coordinateFrameID: CoordinateFrameID,
    objectID: ObjectID,
    at timestamp: TimeInterval,
    position: Vec3 = temporalTestPosition()
) -> SpatialObjectMetadata {
    let object = try! SpatialObject(
        id: objectID,
        semanticLabel: "의자",
        position: position,
        certainty: .confirmed,
        presence: .visible,
        confidence: temporalTestVector(),
        firstSeenAt: max(0, timestamp - 0.4),
        lastSeenAt: timestamp
    )
    let framed = try! FramedPosition(
        coordinateFrameID: coordinateFrameID,
        value: position,
        observedAt: timestamp,
        trackingQuality: .normal,
        uncertainty: .highConfidenceDepth
    )
    return try! SpatialObjectMetadata(mapID: mapID, object: object, position: framed)
}

func temporalTestPromotionEvidence(
    mapID: MapID,
    coordinateFrameID: CoordinateFrameID,
    at timestamp: TimeInterval,
    position: Vec3 = temporalTestPosition()
) -> ObjectReidentificationPromotionEvidence {
    let segmentID = CaptureSegmentID()
    let observations = [timestamp - 0.4, timestamp - 0.2, timestamp].map { time in
        try! ObjectPromotionObservation(
            observationID: ObservationID(),
            frameID: FrameID(),
            semanticLabel: "의자",
            coordinateFrameID: coordinateFrameID,
            captureSegmentID: segmentID,
            mapID: mapID,
            boundingBox: try! NormalizedBoundingBox2D(
                x: 0.4,
                y: 0.4,
                width: 0.2,
                height: 0.2
            ),
            position: try! FramedPosition(
                coordinateFrameID: coordinateFrameID,
                value: position,
                observedAt: time,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            ),
            semanticConfidence: temporalTestScore(0.95),
            geometryConfidence: temporalTestScore(0.95)
        )
    }
    return try! ObjectReidentificationPromotionEvidence(observations: observations)
}

func temporalTestNewObservation(
    mapID: MapID,
    coordinateFrameID: CoordinateFrameID,
    objectID: ObjectID,
    at timestamp: TimeInterval,
    position: Vec3 = temporalTestPosition()
) -> TemporalSpatialObservation {
    try! TemporalSpatialObservation(
        metadata: temporalTestMetadata(
            mapID: mapID,
            coordinateFrameID: coordinateFrameID,
            objectID: objectID,
            at: timestamp,
            position: position
        ),
        promotionEvidence: temporalTestPromotionEvidence(
            mapID: mapID,
            coordinateFrameID: coordinateFrameID,
            at: timestamp,
            position: position
        ),
        identityDecision: .genuinelyNew
    )
}

func temporalTestPose(
    mapID: MapID?,
    coordinateFrameID: CoordinateFrameID,
    capturedAt: TimeInterval,
    sessionTimestamp: TimeInterval,
    sequence: UInt64,
    trackingState: ARTrackingStateSnapshot = .normal,
    worldMappingStatus: ARWorldMappingStatusSnapshot = .mapped,
    coordinateFrameStatus: ARCaptureIdentity.Status = .confirmed
) -> ARPoseSnapshot {
    ARPoseSnapshot(
        id: ARFrameID(rawValue: temporalTestUUID(700_000 + Int(sequence))),
        sessionToken: ARSessionFrameToken(
            sessionRunGeneration: 1,
            attachmentEpoch: 1
        ),
        coordinateFrameID: coordinateFrameID,
        segmentID: CaptureSegmentID(rawValue: temporalTestUUID(800_000)),
        mapID: mapID,
        coordinateFrameStatus: coordinateFrameStatus,
        capturedAt: capturedAt,
        timestamp: sessionTimestamp,
        cameraTransform: Matrix4x4Snapshot(matrix_identity_float4x4),
        trackingState: trackingState,
        worldMappingStatus: worldMappingStatus
    )
}

func temporalTestProvenance(
    update: TemporalSpatialUpdate,
    sequence: UInt64
) -> TemporalSpatialPoseProvenance {
    try! TemporalSpatialPoseProvenance(
        frameID: FrameID(rawValue: temporalTestUUID(900_000 + Int(sequence))),
        sessionRunGeneration: 1,
        attachmentEpoch: 1,
        captureSegmentID: CaptureSegmentID(rawValue: temporalTestUUID(910_000)),
        mapID: update.mapID,
        coordinateFrameID: update.coordinateFrameID,
        capturedAt: update.timestamp,
        sessionTimestamp: Double(sequence),
        cameraTransform: .identity,
        trackingQuality: .normal,
        mappingQuality: .mapped
    )
}

struct TemporalTestJournalMaterial {
    let previous: TemporalSpatialMemorySnapshot
    let resulting: TemporalSpatialMemorySnapshot
    let entry: TemporalSpatialMemoryJournalEntry
}

func temporalTestJournalMaterial(
    coordinator: inout TemporalSpatialMemoryCoordinator,
    sequence: UInt64,
    timestamp: TimeInterval,
    idNumber: Int
) throws -> TemporalTestJournalMaterial {
    let previous = coordinator.snapshot
    let update = try TemporalSpatialUpdate(
        id: temporalTestDeltaID(idNumber),
        baseRevision: previous.revision,
        sequence: sequence,
        timestamp: timestamp,
        mapID: previous.mapID,
        coordinateFrameID: previous.coordinateFrameID,
        observations: [],
        expectedVisibleObjectIDs: []
    )
    guard case .applied(let delta) = try coordinator.apply(update) else {
        throw TemporalTestFixtureError.expectedAppliedDelta
    }
    return TemporalTestJournalMaterial(
        previous: previous,
        resulting: coordinator.snapshot,
        entry: try TemporalSpatialMemoryJournalEntry(
            provenance: temporalTestProvenance(update: update, sequence: sequence),
            update: update,
            delta: delta
        )
    )
}

enum TemporalTestFixtureError: Error {
    case expectedAppliedDelta
}
