import XCTest

@testable import VispaceCore

final class SpatialRelationQueryTests: XCTestCase {
    func testCompoundRelationDoesNotSilentlyDiscardThirdGroundedEntity() throws {
        let table = try makeRecord(label: "table", aliases: ["테이블"])
        let cup = try makeRecord(label: "cup", aliases: ["컵"])
        let chair = try makeRecord(label: "chair", aliases: ["의자"])
        var graph = SceneGraph()
        try graph.upsert(relation(subject: cup, predicate: .on, object: table))

        for query in ["is the cup on the table and chair?", "컵이 테이블 위에 있고 의자 근처야?"] {
            let result = try engine.query(query, records: [table, cup, chair], graph: graph, at: 20)
            XCTAssertEqual(result.status, .ambiguous)
            XCTAssertEqual(result.issues, [.multipleSemanticTargets])
            XCTAssertTrue(result.matches.isEmpty)
            XCTAssertNil(result.isAffirmative)
            XCTAssertNil(result.referenceObject)
        }
    }

    func testListsConfirmedObjectsOnReferenceInKorean() throws {
        let table = try makeRecord(label: "dining table", aliases: ["테이블", "탁자"])
        let cup = try makeRecord(label: "cup", aliases: ["컵"])
        var graph = SceneGraph()
        try graph.upsert(relation(subject: cup, predicate: .on, object: table))

        let result = try engine.query(
            "테이블 위에 뭐가 있어?",
            records: [table, cup],
            graph: graph,
            at: 20
        )

        XCTAssertEqual(result.status, .answered)
        XCTAssertEqual(result.mode, .listRelatedObjects)
        XCTAssertEqual(result.predicate, .on)
        XCTAssertEqual(result.referenceObject?.objectID, table.metadata.object.id)
        XCTAssertEqual(result.matches.map(\.subject.objectID), [cup.metadata.object.id])
        XCTAssertNil(result.isAffirmative)
    }

    func testVerifiesTwoObjectRelationWithoutInventingMissingEdge() throws {
        let sofa = try makeRecord(label: "sofa", aliases: ["소파"])
        let door = try makeRecord(label: "door", aliases: ["문"])
        var graph = SceneGraph()

        let absent = try engine.query(
            "소파가 문을 막고 있어?",
            records: [sofa, door],
            graph: graph,
            at: 20
        )
        XCTAssertEqual(absent.status, .noConfirmedRelation)
        XCTAssertEqual(absent.isAffirmative, false)

        try graph.upsert(relation(subject: sofa, predicate: .blocking, object: door))
        let present = try engine.query(
            "소파가 문을 막고 있어?",
            records: [sofa, door],
            graph: graph,
            at: 20
        )
        XCTAssertEqual(present.status, .answered)
        XCTAssertEqual(present.isAffirmative, true)
        XCTAssertEqual(present.matches.count, 1)
    }

    func testSymmetricNearRelationCanBeStoredInReverseDirection() throws {
        let chair = try makeRecord(label: "chair")
        let table = try makeRecord(label: "table")
        var graph = SceneGraph()
        try graph.upsert(relation(subject: table, predicate: .near, object: chair))

        let result = try engine.query(
            "is the chair near the table?",
            records: [chair, table],
            graph: graph,
            at: 20
        )

        XCTAssertEqual(result.status, .answered)
        XCTAssertEqual(result.isAffirmative, true)
    }

    func testExpiredAndProvisionalRelationsAreNotAnswers() throws {
        let book = try makeRecord(label: "book")
        let desk = try makeRecord(label: "desk")
        let key = RelationKey(
            subject: .object(book.metadata.object.id),
            predicate: .on,
            object: .object(desk.metadata.object.id)
        )
        let expired = try SpatialRelation(
            key: key,
            confidence: ConfidenceScore(clamping: 0.95),
            certainty: .confirmed,
            validFrom: 5,
            validUntil: 10
        )
        let provisional = try SpatialRelation(
            key: key,
            confidence: ConfidenceScore(clamping: 0.7),
            certainty: .provisional,
            validFrom: 11
        )
        var graph = SceneGraph()
        try graph.upsert(expired)
        graph.remove(key)
        try graph.upsert(provisional)

        let result = try engine.query(
            "what is on the desk",
            records: [book, desk],
            graph: graph,
            at: 20
        )
        XCTAssertEqual(result.status, .noConfirmedRelation)
        XCTAssertTrue(result.matches.isEmpty)
    }

    func testDuplicateReferenceInstancesStayAmbiguous() throws {
        let tableA = try makeRecord(label: "table")
        let tableB = try makeRecord(label: "table", x: 2)
        let cup = try makeRecord(label: "cup")
        var graph = SceneGraph()
        try graph.upsert(relation(subject: cup, predicate: .on, object: tableA))

        let result = try engine.query(
            "what is on the table",
            records: [tableA, tableB, cup],
            graph: graph,
            at: 20
        )

        XCTAssertEqual(result.status, .ambiguous)
        XCTAssertEqual(result.issues, [.multipleTargetInstances])
        XCTAssertTrue(result.matches.isEmpty)
    }

    func testRemovedAndProvisionalObjectsCannotGroundQuestion() throws {
        let removedTable = try makeRecord(label: "table", presence: .removed)
        let provisionalCup = try makeRecord(label: "cup", certainty: .provisional)
        let result = try engine.query(
            "what is on the table",
            records: [removedTable, provisionalCup],
            graph: SceneGraph(),
            at: 20
        )

        XCTAssertEqual(result.status, .notGrounded)
        XCTAssertEqual(result.issues, [.noSemanticTarget])
    }

    func testUnsupportedOrMissingTargetReturnsStructuredIssue() throws {
        let table = try makeRecord(label: "table")
        let unsupported = try engine.query(
            "where is the table",
            records: [table],
            graph: SceneGraph(),
            at: 20
        )
        XCTAssertEqual(unsupported.status, .unsupported)

        let missing = try engine.query(
            "what is on the shelf",
            records: [table],
            graph: SceneGraph(),
            at: 20
        )
        XCTAssertEqual(missing.status, .notGrounded)
    }

    func testResultsAreConfidenceThenRecencyThenIDOrderedAndBounded() throws {
        let table = try makeRecord(label: "table")
        let cup = try makeRecord(label: "cup")
        let book = try makeRecord(label: "book")
        var graph = SceneGraph()
        try graph.upsert(
            relation(
                subject: cup,
                predicate: .on,
                object: table,
                confidence: 0.9,
                validFrom: 9
            )
        )
        try graph.upsert(
            relation(
                subject: book,
                predicate: .on,
                object: table,
                confidence: 0.95,
                validFrom: 8
            )
        )
        let limitedEngine = DeterministicSpatialRelationQueryEngine(
            policy: try SpatialRelationQueryPolicy(maximumResultCount: 1)
        )

        let result = try limitedEngine.query(
            "what is on the table",
            records: [table, cup, book],
            graph: graph,
            at: 20
        )

        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches.first?.subject.objectID, book.metadata.object.id)
    }

    func testInvalidTimeAndPolicyFailValidation() throws {
        XCTAssertThrowsError(
            try engine.query("what is on table", records: [], graph: SceneGraph(), at: .nan)
        ) {
            XCTAssertEqual($0 as? SpatialRelationQueryError, .invalidCurrentTime)
        }
        XCTAssertThrowsError(try SpatialRelationQueryPolicy(maximumResultCount: 0)) {
            XCTAssertEqual($0 as? SpatialRelationQueryError, .invalidResultLimit)
        }
        XCTAssertThrowsError(
            try SpatialRelationQueryPolicy(
                maximumResultCount: SpatialRelationQueryPolicy.maximumAllowedResultCount + 1
            )
        )
    }

    private let engine = DeterministicSpatialRelationQueryEngine()

    private func relation(
        subject: StoredSpatialObjectRecord,
        predicate: SpatialRelationPredicate,
        object: StoredSpatialObjectRecord,
        confidence: Double = 0.95,
        validFrom: TimeInterval = 10
    ) throws -> SpatialRelation {
        try SpatialRelation(
            key: RelationKey(
                subject: .object(subject.metadata.object.id),
                predicate: predicate,
                object: .object(object.metadata.object.id)
            ),
            confidence: ConfidenceScore(validating: confidence),
            certainty: .confirmed,
            validFrom: validFrom
        )
    }

    private func makeRecord(
        label: String,
        aliases: [String] = [],
        x: Double = 0,
        presence: ObjectPresence = .visible,
        certainty: ObjectCertainty = .confirmed
    ) throws -> StoredSpatialObjectRecord {
        let position = try Vec3(x: x, y: 0, z: 0)
        let confidence = ConfidenceScore(clamping: certainty == .confirmed ? 0.95 : 0.6)
        let object = try SpatialObject(
            semanticLabel: label,
            position: position,
            bounds: try AABB(
                min: Vec3(x: x - 0.1, y: 0, z: -0.1),
                max: Vec3(x: x + 0.1, y: 0.2, z: 0.1)
            ),
            certainty: certainty,
            presence: presence,
            confidence: ConfidenceVector(
                semantic: confidence,
                geometry: confidence,
                tracking: confidence,
                place: confidence,
                identity: confidence,
                objectState: confidence,
                relation: confidence
            ),
            firstSeenAt: 1,
            lastSeenAt: 10,
            stateUpdatedAt: 10
        )
        let metadata = try SpatialObjectMetadata(
            mapID: MapID(),
            object: object,
            position: FramedPosition(
                coordinateFrameID: CoordinateFrameID(),
                value: position,
                observedAt: 10,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            )
        )
        return StoredSpatialObjectRecord(
            metadata: metadata,
            memoryTier: .longTerm,
            semanticAliases: aliases
        )
    }
}
