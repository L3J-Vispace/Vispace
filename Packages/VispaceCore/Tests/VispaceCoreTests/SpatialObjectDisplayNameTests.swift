import Foundation
import XCTest

@testable import VispaceCore

final class SpatialObjectDisplayNameTests: XCTestCase {
    func testLegacyObjectDecodesWithoutNameAndRenamePreservesFacts() throws {
        let original = makeObject(id: objectID(88_001), label: "chair")
        let legacyData = try JSONEncoder().encode(original)
        XCTAssertFalse(String(decoding: legacyData, as: UTF8.self).contains("displayName"))
        var renamed = try JSONDecoder().decode(SpatialObject.self, from: legacyData)
        XCTAssertNil(renamed.displayName)
        try renamed.setDisplayName("  창가 의자  ")
        XCTAssertEqual(renamed.semanticLabel, "chair")
        XCTAssertEqual(renamed.displayLabel, "창가 의자")
        XCTAssertEqual(renamed.lastSeenAt, original.lastSeenAt)
        XCTAssertEqual(renamed.stateUpdatedAt, original.stateUpdatedAt)
        XCTAssertEqual(try JSONDecoder().decode(SpatialObject.self, from: JSONEncoder().encode(renamed)), renamed)
        try renamed.setDisplayName("")
        XCTAssertEqual(renamed, original)
    }

    func testNameValidationRejectsControlCharactersAndOversize() throws {
        var object = makeObject(id: objectID(88_002))
        for name in ["의자\n창가", String(repeating: "가", count: 65), "!!!"] {
            XCTAssertThrowsError(try object.setDisplayName(name))
        }
        XCTAssertNil(object.displayName)
    }

    func testDistinctPersonalNameSelectsOnlyItsObjectButClassSearchKeepsThreeCandidates() throws {
        let map = MapID()
        let frame = CoordinateFrameID()
        var objects = (0..<3).map { makeObject(id: objectID(88_010 + $0), label: "chair") }
        try objects[1].setDisplayName("창가 의자")
        let records = try objects.map { object in
            StoredSpatialObjectRecord(metadata: try SpatialObjectMetadata(mapID: map, object: object,
                position: FramedPosition(coordinateFrameID: frame, value: object.position,
                    observedAt: object.lastSeenAt, trackingQuality: .normal, uncertainty: .highConfidenceDepth)),
                memoryTier: .localMap, semanticAliases: ["의자"])
        }
        let engine = DeterministicSpatialObjectSearchEngine()
        let context = try SpatialObjectSearchContext(currentMapID: map, now: 10)
        let named = engine.search(utterance: "창가 의자 찾아줘", records: records, context: context)
        XCTAssertEqual(named.status, .found)
        XCTAssertEqual(named.selectedCandidate?.record.metadata.object.id, objects[1].id)
        XCTAssertEqual(named.matchedSemanticLabels, ["chair"])
        let general = engine.search(utterance: "의자 찾아줘", records: records, context: context)
        XCTAssertEqual(general.status, .ambiguous)
        XCTAssertEqual(general.candidates.count, 3)
    }
}
