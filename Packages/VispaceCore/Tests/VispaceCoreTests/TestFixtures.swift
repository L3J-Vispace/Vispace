import Foundation

@testable import VispaceCore

func testUUID(_ value: Int) -> UUID {
    let suffix = String(format: "%012d", value)
    return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
}

func objectID(_ value: Int) -> ObjectID {
    ObjectID(rawValue: testUUID(value))
}

func nodeID(_ value: Int) -> SpatialNodeID {
    SpatialNodeID(rawValue: testUUID(value))
}

func frameID(_ value: Int) -> FrameID {
    FrameID(rawValue: testUUID(value))
}

func deltaID(_ value: Int) -> SpatialDeltaID {
    SpatialDeltaID(rawValue: testUUID(value))
}

func score(_ value: Double) -> ConfidenceScore {
    try! ConfidenceScore(validating: value)
}

func vector(
    semantic: Double = 0.9,
    geometry: Double = 0.9,
    tracking: Double = 0.9,
    place: Double = 0.9,
    identity: Double = 0.9,
    objectState: Double = 0.9,
    relation: Double = 0.9
) -> ConfidenceVector {
    ConfidenceVector(
        semantic: score(semantic),
        geometry: score(geometry),
        tracking: score(tracking),
        place: score(place),
        identity: score(identity),
        objectState: score(objectState),
        relation: score(relation)
    )
}

func vec(_ x: Double, _ y: Double = 0, _ z: Double = 0) -> Vec3 {
    try! Vec3(x: x, y: y, z: z)
}

func box(
    minX: Double,
    minY: Double,
    minZ: Double,
    maxX: Double,
    maxY: Double,
    maxZ: Double
) -> AABB {
    try! AABB(
        min: vec(minX, minY, minZ),
        max: vec(maxX, maxY, maxZ)
    )
}

func makeObject(
    id: ObjectID,
    label: String = "노트북",
    position: Vec3 = .zero,
    certainty: ObjectCertainty = .confirmed,
    presence: ObjectPresence = .visible,
    confidence: ConfidenceVector = vector(),
    firstSeenAt: TimeInterval = 1,
    lastSeenAt: TimeInterval = 2
) -> SpatialObject {
    try! SpatialObject(
        id: id,
        semanticLabel: label,
        position: position,
        certainty: certainty,
        presence: presence,
        confidence: confidence,
        firstSeenAt: firstSeenAt,
        lastSeenAt: lastSeenAt
    )
}
