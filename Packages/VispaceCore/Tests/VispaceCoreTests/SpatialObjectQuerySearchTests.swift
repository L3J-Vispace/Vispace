import XCTest

@testable import VispaceCore

final class SpatialObjectQuerySearchTests: XCTestCase {
    func testFutureObservationAndStateDatesCannotGroundOrGainJustSeenRecency() throws {
        let engine = DeterministicSpatialObjectSearchEngine()
        for observedAt in [90.0, 110.0] {
            let source = try makeMetadata(id: objectID(50_099), mapID: currentMapID,
                frameID: currentFrameID, label: "chair", lastSeenAt: observedAt,
                uncertainty: .highConfidenceDepth)
            var object = source.object
            object.stateUpdatedAt = 110
            let metadata = try SpatialObjectMetadata(mapID: source.mapID, object: object, position: source.position)
            let context = try SpatialObjectSearchContext(currentMapID: currentMapID, now: 100)
            let result = engine.search(utterance: "chair", records: [record(metadata)], context: context)
            XCTAssertEqual(result.status, .lowConfidence)
            XCTAssertTrue(result.issues.contains(.observationTimeInFuture))
            XCTAssertNil(result.groundedPosition)
            XCTAssertEqual(result.candidates.first?.record.metadata, metadata)
            XCTAssertEqual(result.candidates.first?.secondsSinceLastSeen, 100 - observedAt)
            let chosen = engine.select(record: record(metadata), route: result.route, context: context)
            XCTAssertEqual(chosen.status, .lowConfidence)
            XCTAssertNil(chosen.selectedCandidate)
        }
    }

    private let currentMapID = MapID(rawValue: testUUID(50_001))
    private let otherMapID = MapID(rawValue: testUUID(50_002))
    private let currentFrameID = CoordinateFrameID(rawValue: testUUID(50_003))
    private let otherFrameID = CoordinateFrameID(rawValue: testUUID(50_004))
    private let currentFloorID = SpatialNodeID(rawValue: testUUID(50_005))
    private let otherFloorID = SpatialNodeID(rawValue: testUUID(50_006))

    func testKoreanFindRequestReturnsOnlyPersistedFramedPosition() throws {
        let metadata = try makeMetadata(
            id: objectID(50_101),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "노트북",
            position: try Vec3(x: 1.25, y: 0.8, z: -2.5),
            uncertainty: .highConfidenceDepth
        )
        let result = DeterministicSpatialObjectSearchEngine().search(
            utterance: "내 노트북이 어디 있어?",
            records: [record(metadata, floor: currentFloorID)],
            context: try context()
        )

        XCTAssertEqual(result.route.kind, .searchObject)
        XCTAssertFalse(result.requiresLLM)
        XCTAssertEqual(result.status, .found)
        XCTAssertEqual(result.matchedSemanticLabels, ["노트북"])
        XCTAssertEqual(result.selectedCandidate?.record.metadata, metadata)
        XCTAssertEqual(result.groundedPosition, metadata.position)
        XCTAssertEqual(result.groundedPosition?.value, metadata.object.position)
    }

    func testEnglishFindRequestAndAliasGroundToCanonicalStoredLabel() throws {
        let metadata = try makeMetadata(
            id: objectID(50_102),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "laptop",
            uncertainty: .highConfidenceDepth
        )
        let stored = StoredSpatialObjectRecord(
            metadata: metadata,
            memoryTier: .localMap,
            semanticAliases: ["노트북", "  노트북  ", ""]
        )
        let english = DeterministicSpatialObjectSearchEngine().search(
            utterance: "Where is my LAPTOP?",
            records: [stored],
            context: try context()
        )
        let korean = DeterministicSpatialObjectSearchEngine().search(
            utterance: "노트북을 찾아줘",
            records: [stored],
            context: try context()
        )

        XCTAssertEqual(stored.semanticAliases, ["노트북"])
        XCTAssertEqual(english.status, .found)
        XCTAssertEqual(korean.status, .found)
        XCTAssertEqual(korean.matchedSemanticLabels, ["laptop"])
        XCTAssertEqual(korean.groundedPosition, metadata.position)
    }

    func testBareKnownLabelIsUpgradedToDeterministicSearch() throws {
        let metadata = try makeMetadata(
            id: objectID(50_103),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "노트북",
            uncertainty: .highConfidenceDepth
        )
        let result = DeterministicSpatialObjectSearchEngine().search(
            utterance: " 노트북 ",
            records: [record(metadata)],
            context: try context()
        )

        XCTAssertEqual(result.route.kind, .searchObject)
        XCTAssertEqual(result.route.matchedSignals, ["exact-semantic-label"])
        XCTAssertFalse(result.requiresLLM)
        XCTAssertEqual(result.status, .found)
    }

    func testUnknownSemanticTargetIsExplicitlyNotFound() throws {
        let laptop = try makeMetadata(
            id: objectID(50_104),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "노트북"
        )
        let result = DeterministicSpatialObjectSearchEngine().search(
            utterance: "지갑 어디 있어?",
            records: [record(laptop)],
            context: try context()
        )

        XCTAssertEqual(result.status, .notFound)
        XCTAssertEqual(result.issues, [.noSemanticTarget])
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertNil(result.groundedPosition)
    }

    func testComplexPlacementRequestNeverLeaksSearchCoordinate() throws {
        let sofa = try makeMetadata(
            id: objectID(50_105),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "소파",
            uncertainty: .highConfidenceDepth
        )
        let result = DeterministicSpatialObjectSearchEngine().search(
            utterance: "소파를 여기에 놓으면 어떨까?",
            records: [record(sofa)],
            context: try context()
        )

        XCTAssertEqual(result.route.kind, .complexAsk)
        XCTAssertTrue(result.requiresLLM)
        XCTAssertEqual(result.status, .unsupportedIntent)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertNil(result.selectedCandidate)
        XCTAssertNil(result.groundedPosition)
    }

    func testRelationRequestIsUnsupportedWithoutInventingLocation() throws {
        let bag = try makeMetadata(
            id: objectID(50_106),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "가방"
        )
        let result = DeterministicSpatialObjectSearchEngine().search(
            utterance: "가방이 책상 아래 있어?",
            records: [record(bag)],
            context: try context()
        )

        XCTAssertEqual(result.route.kind, .relationQuery)
        XCTAssertFalse(result.requiresLLM)
        XCTAssertEqual(result.status, .unsupportedIntent)
        XCTAssertNil(result.groundedPosition)
    }

    func testMultipleSemanticTargetsAreExplicitlyAmbiguous() throws {
        let laptop = try makeMetadata(
            id: objectID(50_107),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "노트북",
            uncertainty: .highConfidenceDepth
        )
        let bag = try makeMetadata(
            id: objectID(50_108),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "가방",
            uncertainty: .highConfidenceDepth
        )
        let result = DeterministicSpatialObjectSearchEngine().search(
            utterance: "노트북이랑 가방 어디 있어?",
            records: [record(laptop), record(bag)],
            context: try context()
        )

        XCTAssertEqual(result.status, .ambiguous)
        XCTAssertEqual(result.matchedSemanticLabels, ["가방", "노트북"])
        XCTAssertEqual(result.issues, [.multipleSemanticTargets])
        XCTAssertNil(result.groundedPosition)
    }

    func testLongerSemanticLabelSuppressesContainedLabel() throws {
        let table = try makeMetadata(
            id: objectID(50_109),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "table",
            uncertainty: .highConfidenceDepth
        )
        let coffeeTable = try makeMetadata(
            id: objectID(50_110),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "coffee table",
            uncertainty: .highConfidenceDepth
        )
        let result = DeterministicSpatialObjectSearchEngine().search(
            utterance: "find the coffee table",
            records: [record(table), record(coffeeTable)],
            context: try context()
        )

        XCTAssertEqual(result.status, .found)
        XCTAssertEqual(result.matchedSemanticLabels, ["coffee table"])
        XCTAssertEqual(result.selectedCandidate?.record.metadata.object.id, objectID(50_110))
    }

    func testCurrentMapOutranksHigherConfidenceOtherMap() throws {
        let current = try makeMetadata(
            id: objectID(50_111),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "printer",
            confidence: vector(
                semantic: 0.65,
                geometry: 0.65,
                tracking: 0.65,
                identity: 0.65,
                objectState: 0.65
            ),
            lastSeenAt: 50,
            uncertainty: .highConfidenceDepth
        )
        let other = try makeMetadata(
            id: objectID(50_112),
            mapID: otherMapID,
            frameID: otherFrameID,
            label: "printer",
            confidence: vector(
                semantic: 0.99,
                geometry: 0.99,
                tracking: 0.99,
                identity: 0.99,
                objectState: 0.99
            ),
            lastSeenAt: 100,
            uncertainty: .highConfidenceDepth
        )
        let result = DeterministicSpatialObjectSearchEngine().search(
            utterance: "find printer",
            records: [record(other), record(current)],
            context: try context()
        )

        XCTAssertEqual(result.status, .found)
        XCTAssertEqual(
            result.candidates.map(\.record.metadata.object.id),
            [
                objectID(50_111), objectID(50_112),
            ])
        XCTAssertEqual(result.selectedCandidate?.matchesCurrentMap, true)
        XCTAssertEqual(result.groundedPosition, current.position)
    }

    func testCurrentFloorOutranksHigherConfidenceOtherFloor() throws {
        let currentFloor = try makeMetadata(
            id: objectID(50_113),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "chair",
            confidence: vector(
                semantic: 0.65,
                geometry: 0.65,
                tracking: 0.65,
                identity: 0.65,
                objectState: 0.65
            ),
            uncertainty: .highConfidenceDepth
        )
        let otherFloor = try makeMetadata(
            id: objectID(50_114),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "chair",
            confidence: vector(
                semantic: 0.98,
                geometry: 0.98,
                tracking: 0.98,
                identity: 0.98,
                objectState: 0.98
            ),
            uncertainty: .highConfidenceDepth
        )
        let result = DeterministicSpatialObjectSearchEngine().search(
            utterance: "where is chair",
            records: [
                record(otherFloor, floor: otherFloorID),
                record(currentFloor, floor: currentFloorID),
            ],
            context: try context()
        )

        XCTAssertEqual(result.status, .found)
        XCTAssertEqual(result.selectedCandidate?.record.metadata.object.id, objectID(50_113))
        XCTAssertEqual(result.selectedCandidate?.matchesCurrentFloor, true)
    }

    func testConfidencePrecedesRecencyAndLargeGapSelectsCandidate() throws {
        let strongerOlder = try makeMetadata(
            id: objectID(50_115),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "keys",
            confidence: vector(
                semantic: 0.92,
                geometry: 0.92,
                tracking: 0.92,
                identity: 0.92,
                objectState: 0.92
            ),
            lastSeenAt: 10,
            uncertainty: .highConfidenceDepth
        )
        let weakerRecent = try makeMetadata(
            id: objectID(50_116),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "keys",
            confidence: vector(
                semantic: 0.7,
                geometry: 0.7,
                tracking: 0.7,
                identity: 0.7,
                objectState: 0.7
            ),
            lastSeenAt: 100,
            uncertainty: .highConfidenceDepth
        )
        let result = DeterministicSpatialObjectSearchEngine().search(
            utterance: "find keys",
            records: [record(weakerRecent), record(strongerOlder)],
            context: try context()
        )

        XCTAssertEqual(result.status, .found)
        XCTAssertEqual(result.candidates.first?.record.metadata.object.id, objectID(50_115))
    }

    func testRecencyOrdersEquivalentCandidatesButDoesNotHideAmbiguity() throws {
        let older = try makeMetadata(
            id: objectID(50_117),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "bottle",
            lastSeenAt: 20,
            uncertainty: .highConfidenceDepth
        )
        let recent = try makeMetadata(
            id: objectID(50_118),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "bottle",
            lastSeenAt: 90,
            uncertainty: .highConfidenceDepth
        )
        let result = DeterministicSpatialObjectSearchEngine().search(
            utterance: "where is bottle",
            records: [record(older), record(recent)],
            context: try context()
        )

        XCTAssertEqual(result.status, .ambiguous)
        XCTAssertEqual(result.issues, [.multiplePlausibleObjects])
        XCTAssertEqual(
            result.candidates.map(\.record.metadata.object.id),
            [
                objectID(50_118), objectID(50_117),
            ])
        XCTAssertNil(result.groundedPosition)
    }

    func testLowConfidenceCandidateIsExplicitAndCannotDriveGuidance() throws {
        let weak = try makeMetadata(
            id: objectID(50_119),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "remote",
            confidence: vector(
                semantic: 0.4,
                geometry: 0.95,
                tracking: 0.95,
                identity: 0.95,
                objectState: 0.95
            ),
            uncertainty: .highConfidenceDepth
        )
        let result = DeterministicSpatialObjectSearchEngine().search(
            utterance: "find remote",
            records: [record(weak)],
            context: try context()
        )

        XCTAssertEqual(result.status, .lowConfidence)
        XCTAssertEqual(result.issues, [.groundedPositionLowConfidence])
        XCTAssertEqual(result.candidates.first?.confidenceGrade, .low)
        XCTAssertNil(result.selectedCandidate)
        XCTAssertNil(result.groundedPosition)
    }

    func testPositionProvenanceCapsUnknownAtMediumAndUnavailableAtLow() throws {
        let unknown = try makeMetadata(
            id: objectID(50_120),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "camera",
            confidence: vector(
                semantic: 0.99,
                geometry: 0.99,
                tracking: 0.99,
                identity: 0.99,
                objectState: 0.99
            ),
            trackingQuality: .normal,
            uncertainty: .unknown
        )
        let unavailable = try makeMetadata(
            id: objectID(50_121),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "speaker",
            confidence: vector(
                semantic: 0.99,
                geometry: 0.99,
                tracking: 0.99,
                identity: 0.99,
                objectState: 0.99
            ),
            trackingQuality: .unavailable,
            uncertainty: .highConfidenceDepth
        )

        let unknownResult = DeterministicSpatialObjectSearchEngine().search(
            utterance: "find camera",
            records: [record(unknown)],
            context: try context()
        )
        let unavailableResult = DeterministicSpatialObjectSearchEngine().search(
            utterance: "find speaker",
            records: [record(unavailable)],
            context: try context()
        )

        XCTAssertEqual(unknownResult.status, .found)
        XCTAssertEqual(unknownResult.candidates.first?.confidenceGrade, .medium)
        XCTAssertEqual(unavailableResult.status, .lowConfidence)
        XCTAssertEqual(unavailableResult.candidates.first?.confidenceGrade, .low)
    }

    func testProvisionalAndRemovedObjectsAreExcludedByDefault() throws {
        let provisional = try makeMetadata(
            id: objectID(50_122),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "wallet",
            certainty: .provisional
        )
        let removed = try makeMetadata(
            id: objectID(50_123),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "wallet",
            presence: .removed
        )
        let engine = DeterministicSpatialObjectSearchEngine()
        let hidden = engine.search(
            utterance: "find wallet",
            records: [record(provisional), record(removed)],
            context: try context()
        )
        let historical = engine.search(
            utterance: "where was wallet last seen",
            records: [record(removed)],
            context: try context(includeRemoved: true)
        )

        XCTAssertEqual(hidden.status, .notFound)
        XCTAssertEqual(hidden.issues, [.noEligibleStoredObject])
        XCTAssertEqual(historical.route.kind, .lastSeen)
        XCTAssertNotEqual(historical.status, .notFound)
        XCTAssertEqual(historical.candidates.first?.record.metadata.object.presence, .removed)
    }

    func testDuplicateDurableObjectAcrossTiersIsDeduplicatedAfterRanking() throws {
        let durableID = objectID(50_124)
        let current = try makeMetadata(
            id: durableID,
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "glasses",
            position: try Vec3(x: 1, y: 0, z: 0),
            uncertainty: .highConfidenceDepth
        )
        let historical = try makeMetadata(
            id: durableID,
            mapID: otherMapID,
            frameID: otherFrameID,
            label: "glasses",
            position: try Vec3(x: 99, y: 99, z: 99),
            lastSeenAt: 50,
            uncertainty: .highConfidenceDepth
        )
        let result = DeterministicSpatialObjectSearchEngine().search(
            utterance: "find glasses",
            records: [
                record(historical, tier: .longTerm),
                record(current, tier: .localMap),
            ],
            context: try context()
        )

        XCTAssertEqual(result.status, .found)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.groundedPosition, current.position)
        XCTAssertNotEqual(result.groundedPosition?.value, historical.position.value)
    }

    func testNavigateAndLastSeenRemainDeterministicObjectLookups() throws {
        let printer = try makeMetadata(
            id: objectID(50_125),
            mapID: currentMapID,
            frameID: currentFrameID,
            label: "프린터",
            presence: .lastSeen,
            uncertainty: .highConfidenceDepth
        )
        let engine = DeterministicSpatialObjectSearchEngine()
        let navigate = engine.search(
            utterance: "프린터까지 가는 경로 안내해줘",
            records: [record(printer)],
            context: try context()
        )
        let lastSeen = engine.search(
            utterance: "프린터 마지막 위치가 어디야?",
            records: [record(printer)],
            context: try context()
        )

        XCTAssertEqual(navigate.route.kind, .navigate)
        XCTAssertEqual(navigate.status, .found)
        XCTAssertEqual(lastSeen.route.kind, .lastSeen)
        XCTAssertEqual(lastSeen.status, .found)
        XCTAssertFalse(navigate.requiresLLM)
        XCTAssertFalse(lastSeen.requiresLLM)
    }

    func testPolicyAndContextRejectInvalidBounds() {
        XCTAssertThrowsError(try SpatialObjectSearchContext(now: .nan)) { error in
            XCTAssertEqual(error as? SpatialObjectSearchError, .invalidCurrentTime)
        }
        XCTAssertThrowsError(try SpatialObjectSearchPolicy(maximumResultCount: 0)) { error in
            XCTAssertEqual(error as? SpatialObjectSearchError, .invalidResultLimit)
        }
        XCTAssertThrowsError(
            try SpatialObjectSearchPolicy(
                maximumResultCount: SpatialObjectSearchPolicy.maximumAllowedResultCount + 1
            )
        ) { error in
            XCTAssertEqual(error as? SpatialObjectSearchError, .invalidResultLimit)
        }
        XCTAssertThrowsError(
            try SpatialObjectSearchPolicy(ambiguityConfidenceDelta: .infinity)
        ) { error in
            XCTAssertEqual(error as? SpatialObjectSearchError, .invalidAmbiguityThreshold)
        }
    }

    private func context(includeRemoved: Bool = false) throws -> SpatialObjectSearchContext {
        try SpatialObjectSearchContext(
            currentMapID: currentMapID,
            currentFloorNodeID: currentFloorID,
            now: 200,
            includeRemoved: includeRemoved
        )
    }

    private func record(
        _ metadata: SpatialObjectMetadata,
        tier: MemoryTier = .localMap,
        floor: SpatialNodeID? = nil
    ) -> StoredSpatialObjectRecord {
        StoredSpatialObjectRecord(
            metadata: metadata,
            memoryTier: tier,
            floorNodeID: floor
        )
    }

    private func makeMetadata(
        id: ObjectID,
        mapID: MapID,
        frameID: CoordinateFrameID,
        label: String,
        position: Vec3 = .zero,
        certainty: ObjectCertainty = .confirmed,
        presence: ObjectPresence = .visible,
        confidence: ConfidenceVector = vector(),
        lastSeenAt: TimeInterval = 100,
        trackingQuality: SpatialTrackingQuality = .normal,
        uncertainty: SpatialPositionUncertainty = .unknown
    ) throws -> SpatialObjectMetadata {
        let object = try SpatialObject(
            id: id,
            semanticLabel: label,
            position: position,
            certainty: certainty,
            presence: presence,
            confidence: confidence,
            firstSeenAt: 1,
            lastSeenAt: lastSeenAt
        )
        let framedPosition = try FramedPosition(
            coordinateFrameID: frameID,
            value: position,
            observedAt: lastSeenAt,
            trackingQuality: trackingQuality,
            uncertainty: uncertainty
        )
        return try SpatialObjectMetadata(
            mapID: mapID,
            object: object,
            position: framedPosition
        )
    }
}
