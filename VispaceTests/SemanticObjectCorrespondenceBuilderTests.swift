import VispaceCore
import XCTest

@testable import Vispace

final class SemanticObjectCorrespondenceBuilderTests: XCTestCase {
    func testBuildsCorrespondencesOnlyForExactUniqueNormalizedLabels() throws {
        let fixture = Fixture()
        let objects = try [
            fixture.object(side: .source, index: 0, label: " Chair ", confidence: 0.91),
            fixture.object(side: .source, index: 1, label: "coffee   table", confidence: 0.86),
            fixture.object(side: .source, index: 2, label: "SOFA", confidence: 0.93),
            fixture.object(side: .target, index: 0, label: "chair", confidence: 0.88),
            fixture.object(side: .target, index: 1, label: " Coffee table ", confidence: 0.84),
            fixture.object(side: .target, index: 2, label: "sofa", confidence: 0.90),
        ]

        let result = try fixture.builder.build(
            source: fixture.source,
            target: fixture.target,
            from: objects
        )

        XCTAssertEqual(result.map(\.source.semanticLabel), ["chair", "coffee table", "sofa"])
        XCTAssertEqual(result.map(\.target.semanticLabel), ["chair", "coffee table", "sofa"])
        XCTAssertEqual(result.map(\.identityConfidence.value), [0.88, 0.84, 0.90])
        XCTAssertEqual(Set(result.map(\.source.coordinateFrameID)), [fixture.source.coordinateFrameID])
        XCTAssertEqual(Set(result.map(\.target.coordinateFrameID)), [fixture.target.coordinateFrameID])
    }

    func testDuplicateLabelsOnEitherSideAreExcludedInsteadOfGuessed() throws {
        let fixture = Fixture()
        var objects: [SpatialObjectMetadata] = []
        objects += try fixture.pairedObjects(labels: ["lamp", "sofa", "table"])
        objects += try [
            fixture.object(side: .source, index: 10, label: "chair"),
            fixture.object(side: .source, index: 11, label: " Chair "),
            fixture.object(side: .target, index: 10, label: "chair"),
            fixture.object(side: .source, index: 12, label: "plant"),
            fixture.object(side: .target, index: 12, label: "plant"),
            fixture.object(side: .target, index: 13, label: "PLANT"),
        ]

        let result = try fixture.builder.build(
            source: fixture.source,
            target: fixture.target,
            from: objects
        )

        XCTAssertEqual(result.map(\.source.semanticLabel), ["lamp", "sofa", "table"])
    }

    func testWeakRemovedAndProvisionalObjectsAreExcluded() throws {
        let fixture = Fixture()
        var objects = try fixture.pairedObjects(labels: ["lamp", "sofa", "table"])
        objects += try [
            fixture.object(
                side: .source,
                index: 20,
                label: "weak",
                confidence: 0.79
            ),
            fixture.object(side: .target, index: 20, label: "weak"),
            fixture.object(
                side: .source,
                index: 21,
                label: "removed",
                presence: .removed
            ),
            fixture.object(side: .target, index: 21, label: "removed"),
            fixture.object(
                side: .source,
                index: 22,
                label: "provisional",
                certainty: .provisional
            ),
            fixture.object(side: .target, index: 22, label: "provisional"),
        ]

        let result = try fixture.builder.build(
            source: fixture.source,
            target: fixture.target,
            from: objects
        )

        XCTAssertEqual(result.map(\.source.semanticLabel), ["lamp", "sofa", "table"])
    }

    func testObjectsFromWrongMapOrFrameCannotAffectEndpointCardinality() throws {
        let fixture = Fixture()
        var objects = try fixture.pairedObjects(labels: ["lamp", "sofa", "table"])
        objects += try [
            fixture.object(
                side: .source,
                index: 30,
                label: "lamp",
                mapID: Fixture.mapID(90)
            ),
            fixture.object(
                side: .source,
                index: 31,
                label: "sofa",
                frameID: Fixture.frameID(90)
            ),
            fixture.object(
                side: .target,
                index: 32,
                label: "table",
                mapID: Fixture.mapID(91)
            ),
            fixture.object(
                side: .target,
                index: 33,
                label: "lamp",
                frameID: Fixture.frameID(91)
            ),
        ]

        let result = try fixture.builder.build(
            source: fixture.source,
            target: fixture.target,
            from: objects
        )

        XCTAssertEqual(result.map(\.source.semanticLabel), ["lamp", "sofa", "table"])
        XCTAssertTrue(result.allSatisfy { $0.source.coordinateFrameID == fixture.source.coordinateFrameID })
        XCTAssertTrue(result.allSatisfy { $0.target.coordinateFrameID == fixture.target.coordinateFrameID })
    }

    func testOutputIsDeterministicAndBoundedToSixtyFourCorrespondences() throws {
        let fixture = Fixture()
        var objects: [SpatialObjectMetadata] = []
        for index in 0..<70 {
            let label = String(format: "item-%03d", index)
            objects.append(try fixture.object(side: .source, index: index, label: label))
            objects.append(try fixture.object(side: .target, index: index, label: label))
        }

        let forward = try fixture.builder.build(
            source: fixture.source,
            target: fixture.target,
            from: objects
        )
        let reverse = try fixture.builder.build(
            source: fixture.source,
            target: fixture.target,
            from: Array(objects.reversed())
        )

        XCTAssertEqual(forward.count, SemanticObjectCorrespondenceBuilder.maximumCorrespondenceCount)
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.first?.source.semanticLabel, "item-000")
        XCTAssertEqual(forward.last?.source.semanticLabel, "item-063")
    }

    func testThrowsTypedInsufficientResultWhenFewerThanThreeLabelsSurvive() throws {
        let fixture = Fixture()
        let objects = try fixture.pairedObjects(labels: ["lamp", "sofa"])

        XCTAssertThrowsError(
            try fixture.builder.build(
                source: fixture.source,
                target: fixture.target,
                from: objects
            )
        ) { error in
            XCTAssertEqual(
                error as? SemanticObjectCorrespondenceBuilderError,
                .insufficientCorrespondences(minimum: 3, actual: 2)
            )
        }
    }
}

private struct Fixture {
    enum Side {
        case source
        case target
    }

    let source = SemanticObjectCorrespondenceEndpoint(
        mapID: Fixture.mapID(1),
        coordinateFrameID: Fixture.frameID(1)
    )
    let target = SemanticObjectCorrespondenceEndpoint(
        mapID: Fixture.mapID(2),
        coordinateFrameID: Fixture.frameID(2)
    )
    let builder = SemanticObjectCorrespondenceBuilder()

    func pairedObjects(labels: [String]) throws -> [SpatialObjectMetadata] {
        try labels.enumerated().flatMap { index, label in
            [
                try object(side: .source, index: index, label: label),
                try object(side: .target, index: index, label: label),
            ]
        }
    }

    func object(
        side: Side,
        index: Int,
        label: String,
        mapID: MapID? = nil,
        frameID: CoordinateFrameID? = nil,
        certainty: ObjectCertainty = .confirmed,
        presence: ObjectPresence = .visible,
        confidence: Double = 0.95
    ) throws -> SpatialObjectMetadata {
        let endpoint: SemanticObjectCorrespondenceEndpoint
        let offset: Double
        switch side {
        case .source:
            endpoint = source
            offset = 0
        case .target:
            endpoint = target
            offset = 10
        }
        let resolvedMapID = mapID ?? endpoint.mapID
        let resolvedFrameID = frameID ?? endpoint.coordinateFrameID
        let position = try Vec3(
            x: Double(index) + offset,
            y: Double(index % 3),
            z: Double(index * 2) - offset
        )
        let score = ConfidenceScore(clamping: confidence)
        let object = try SpatialObject(
            id: Fixture.objectID(side: side, index: index),
            semanticLabel: label,
            position: position,
            certainty: certainty,
            presence: presence,
            confidence: ConfidenceVector(
                semantic: score,
                geometry: score,
                tracking: .one,
                identity: score,
                objectState: score
            ),
            firstSeenAt: 1,
            lastSeenAt: 2
        )
        return try SpatialObjectMetadata(
            mapID: resolvedMapID,
            object: object,
            position: FramedPosition(
                coordinateFrameID: resolvedFrameID,
                value: position,
                observedAt: 2,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            )
        )
    }

    static func mapID(_ value: Int) -> MapID {
        MapID(rawValue: uuid(namespace: 1, value: value))
    }

    static func frameID(_ value: Int) -> CoordinateFrameID {
        CoordinateFrameID(rawValue: uuid(namespace: 2, value: value))
    }

    static func objectID(side: Side, index: Int) -> ObjectID {
        let namespace: Int
        switch side {
        case .source:
            namespace = 3
        case .target:
            namespace = 4
        }
        return ObjectID(rawValue: uuid(namespace: namespace, value: index))
    }

    private static func uuid(namespace: Int, value: Int) -> UUID {
        UUID(
            uuid: (
                0, 0, 0, 0,
                0, 0,
                0, UInt8(namespace),
                0, 0,
                0, 0, 0,
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF)
            ))
    }
}
