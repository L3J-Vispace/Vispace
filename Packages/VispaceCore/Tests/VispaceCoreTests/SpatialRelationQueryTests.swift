import XCTest

@testable import VispaceCore

final class SpatialRelationQueryTests: XCTestCase {
    func testSingleKnownSubjectDoesNotReverseDirectionalQuestion() throws {
        let cup = try makeRecord(label: "cup", aliases: ["컵"])
        let smallBox = try makeRecord(label: "box", aliases: ["상자"])
        var graph = SceneGraph()
        for predicate in [SpatialRelationPredicate.on, .under, .inside, .blocking, .accessibleFrom] {
            try graph.upsert(relation(subject: smallBox, predicate: predicate, object: cup))
        }
        let records = [cup, smallBox]
        for question in [
            "what is the cup on?", "what is the cup under?", "what is the cup inside?",
            "컵은 무엇 위에 있어?", "컵은 무엇 아래에 있어?", "컵은 무엇 안에 있어?",
            "cup is on the shelf", "컵이 선반 위에 있어?",
            "what is the cup blocking?", "컵이 무엇을 막고 있어?",
            "cup accessible from what?", "어디에서 컵으로 갈 수 있어?",
        ] {
            let answer = try engine.query(question, records: records, graph: graph, at: 20)
            XCTAssertEqual(answer.status, .unsupported, question)
            XCTAssertTrue(answer.matches.isEmpty, question)
            XCTAssertNil(engine.targetScope(for: question, records: records), question)
            XCTAssertNil(engine.geometryScope(for: question, records: records), question)
        }
        for question in ["컵 위에 뭐가 있어?", "what is on the cup?", "컵을 무엇이 막고 있어?",
                         "what is blocking the cup?", "컵에서 어디로 갈 수 있어?", "what is accessible from cup?"] {
            let answer = try engine.query(question, records: records, graph: graph, at: 20)
            XCTAssertEqual(answer.status, .answered, question)
            XCTAssertEqual(answer.matches.map(\.subject.objectID), [smallBox.metadata.object.id], question)
            XCTAssertNotNil(engine.targetScope(for: question, records: records), question)
        }
    }

    func testSingleReferenceCompoundRelationsNeverSelectOnlyOnePredicate() throws {
        let cup = try makeRecord(label: "cup", aliases: ["컵"])
        let table = try makeRecord(label: "table", aliases: ["책상"])
        var graph = SceneGraph()
        try graph.upsert(relation(subject: cup, predicate: .under, object: table))
        try graph.upsert(relation(subject: cup, predicate: .near, object: table))
        let records = [cup, table]
        for question in [
            "책상 위에 또는 아래에 뭐가 있어?", "책상 근처에 또는 안에 뭐가 있어?",
            "what is on or under the table?", "what is inside or near the table?",
        ] {
            let answer = try engine.query(question, records: records, graph: graph, at: 20)
            XCTAssertEqual(answer.status, .unsupported, question)
            XCTAssertTrue(answer.matches.isEmpty, question)
            XCTAssertNil(answer.isAffirmative, question)
            XCTAssertNil(engine.targetScope(for: question, records: records), question)
            XCTAssertNil(engine.geometryScope(for: question, records: records), question)
        }
        let simple = try engine.query("책상 아래에 뭐가 있어?", records: records, graph: graph, at: 20)
        XCTAssertEqual(simple.status, .answered)
        XCTAssertEqual(simple.matches.map(\.subject.objectID), [cup.metadata.object.id])
    }

    func testNewlyRoutedPhrasesRetainGroundedPredicatesAndNameSpans() throws {
        let cup = try makeRecord(label: "cup", aliases: ["컵", "주변 컵"])
        let table = try makeRecord(label: "table", aliases: ["책상"])
        for (predicate, questions) in [
            (SpatialRelationPredicate.near, ["책상 근처에 뭐가 있어?", "책상 주변에 뭐가 있어?"]),
            (.intersects, ["컵과 책상이 겹쳐?"]),
            (.accessibleFrom, ["책상에서 컵으로 갈 수 있어?"]),
            (.on, ["책상 위에 주변 컵이 있어?"]),
        ] {
            var graph = SceneGraph()
            try graph.upsert(relation(subject: cup, predicate: predicate, object: table))
            for question in questions {
                XCTAssertEqual(SpatialCommandParser().parse(question), .relationQuery(question))
                let answer = try engine.query(question, records: [cup, table], graph: graph, at: 20)
                XCTAssertEqual(answer.status, .answered, question)
                XCTAssertEqual(answer.predicate, predicate, question)
                XCTAssertEqual(answer.matches.first?.subject.objectID, cup.metadata.object.id, question)
            }
        }
        let nameOnly = try engine.query("주변 컵 책상", records: [cup, table], graph: SceneGraph(), at: 20)
        XCTAssertEqual(nameOnly.status, .unsupported)
        XCTAssertTrue(nameOnly.matches.isEmpty)
    }

    func testEquivalentKoreanOrdersKeepRolesIncludingNegativeQuestions() throws {
        let cup = try makeRecord(label: "cup", aliases: ["컵"])
        let table = try makeRecord(label: "table", aliases: ["테이블"])
        for (predicate, phrase) in [(SpatialRelationPredicate.on, "위에"), (.under, "아래"), (.inside, "안에")] {
            var graph = SceneGraph()
            try graph.upsert(relation(subject: cup, predicate: predicate, object: table))
            for question in [
                "컵이 테이블 \(phrase) 있어?", "테이블 \(phrase) 컵이 있어?",
                "컵은 테이블 \(phrase) 없지?", "테이블 \(phrase) 컵이 있지 않아?",
            ] {
                let result = try engine.query(question, records: [cup, table], graph: graph, at: 20)
                XCTAssertEqual(result.status, .answered, question)
                XCTAssertEqual(result.referenceObject?.objectID, table.metadata.object.id, question)
                XCTAssertEqual(result.matches.first?.subject.objectID, cup.metadata.object.id, question)
            }
            let reversed = try engine.query(
                "컵 \(phrase) 테이블이 있어?", records: [cup, table], graph: graph, at: 20)
            XCTAssertEqual(reversed.status, .noConfirmedRelation)
            XCTAssertNil(reversed.isAffirmative)
        }
    }

    func testRoleResolutionPreservesSameClassAliasesAndExplicitSelection() throws {
        let upper = try makeRecord(label: "box", aliases: ["작은 상자"])
        let lower = try makeRecord(label: "box", aliases: ["큰 상자"])
        let otherLower = try makeRecord(label: "box", aliases: ["큰 상자"], x: 2)
        var graph = SceneGraph()
        try graph.upsert(relation(subject: upper, predicate: .on, object: lower))
        let records = [upper, lower, otherLower]
        for question in ["작은 상자가 큰 상자 위에 있어?", "큰 상자 위에 작은 상자가 없어?"] {
            let ambiguous = try engine.query(question, records: records, graph: graph, at: 20)
            XCTAssertEqual(ambiguous.status, .ambiguous)
            let selected = try engine.query(
                question, records: records, graph: graph, at: 20,
                selections: ["큰 상자": lower.metadata.object.id])
            XCTAssertEqual(selected.matches.first?.subject.objectID, upper.metadata.object.id)
            XCTAssertEqual(selected.referenceObject?.objectID, lower.metadata.object.id)
            let stale = try engine.query(
                question, records: [upper, otherLower], graph: graph, at: 20,
                selections: ["큰 상자": lower.metadata.object.id])
            XCTAssertEqual(stale.status, .ambiguous)
            XCTAssertTrue(stale.matches.isEmpty)
        }
    }

    func testKoreanBlockingParticlesDetermineRolesInEitherOrder() throws {
        let sofa = try makeRecord(label: "sofa", aliases: ["소파"])
        let door = try makeRecord(label: "door", aliases: ["문"])
        var graph = SceneGraph()
        try graph.upsert(relation(subject: sofa, predicate: .blocking, object: door))
        for question in ["소파가 문을 막고 있어?", "문을 소파가 막고 있어?", "문을 소파가 막고 있지 않아?"] {
            let result = try engine.query(question, records: [sofa, door], graph: graph, at: 20)
            XCTAssertEqual(result.status, .answered, question)
            XCTAssertEqual(result.referenceObject?.objectID, door.metadata.object.id, question)
        }
    }

    func testEnglishPreposedReferenceKeepsRelationDirection() throws {
        let cup = try makeRecord(label: "cup")
        let table = try makeRecord(label: "table")
        var graph = SceneGraph()
        try graph.upsert(relation(subject: cup, predicate: .on, object: table))
        for question in [
            "is the cup on the table?", "on the table is the cup?", "isn't the cup on top of the table?",
        ] {
            let result = try engine.query(question, records: [cup, table], graph: graph, at: 20)
            XCTAssertEqual(result.status, .answered, question)
            XCTAssertEqual(result.referenceObject?.objectID, table.metadata.object.id, question)
        }
    }

    func testAccessibleFromUsesOriginParticleAndEnglishPreposition() throws {
        let chair = try makeRecord(label: "chair", aliases: ["의자"])
        let table = try makeRecord(label: "table", aliases: ["테이블"])
        var graph = SceneGraph()
        try graph.upsert(relation(subject: table, predicate: .accessibleFrom, object: chair))
        for question in ["의자에서 테이블로 갈 수 있어?", "테이블로 의자에서 갈 수 있어?", "table accessible from chair"] {
            let result = try engine.query(question, records: [chair, table], graph: graph, at: 20)
            XCTAssertEqual(result.status, .answered, question)
            XCTAssertEqual(result.referenceObject?.objectID, chair.metadata.object.id, question)
            XCTAssertEqual(result.matches.first?.subject.objectID, table.metadata.object.id, question)
        }
    }

    func testRelationWordsInsideNamesCannotOverrideActualPredicate() throws {
        let cup = try makeRecord(label: "cup", aliases: ["inside cup", "아래 컵"])
        let table = try makeRecord(label: "table", aliases: ["테이블"])
        var graph = SceneGraph()
        try graph.upsert(relation(subject: cup, predicate: .on, object: table))
        for question in ["is the inside cup on the table?", "테이블 위에 아래 컵이 있어?"] {
            let result = try engine.query(question, records: [cup, table], graph: graph, at: 20)
            XCTAssertEqual(result.status, .answered, question)
            XCTAssertEqual(result.predicate, .on, question)
            XCTAssertEqual(result.matches.first?.subject.objectID, cup.metadata.object.id, question)
            XCTAssertEqual(engine.targetScope(for: question, records: [cup, table])?.predicate, .on)
        }
        let nameOnly = try engine.query("inside cup table?", records: [cup, table], graph: graph, at: 20)
        XCTAssertEqual(nameOnly.status, .unsupported)
        XCTAssertTrue(nameOnly.matches.isEmpty)
    }

    func testUnresolvedOrConflictingDirectionalGrammarDoesNotGuessByMentionOrder() throws {
        let cup = try makeRecord(label: "cup", aliases: ["컵"])
        let table = try makeRecord(label: "table", aliases: ["테이블"])
        var graph = SceneGraph()
        try graph.upsert(relation(subject: cup, predicate: .on, object: table))
        for question in ["컵 테이블 그리고 위에 있어?", "컵 위에 테이블 아래 있어?", "cup table on?"] {
            let result = try engine.query(question, records: [cup, table], graph: graph, at: 20)
            XCTAssertEqual(result.status, .unsupported, question)
            XCTAssertTrue(result.matches.isEmpty, question)
            XCTAssertNil(result.isAffirmative, question)
            XCTAssertNil(engine.targetScope(for: question, records: [cup, table]), question)
        }
    }

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
        XCTAssertNil(absent.isAffirmative)

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

    func testNamesKeepIndividualObjectIDsForListAndVerification() throws {
        let tableA = try makeRecord(label: "table", aliases: ["책상A"])
        let tableB = try makeRecord(label: "table", aliases: ["책상B"], x: 2)
        let cup = try makeRecord(label: "cup", aliases: ["컵"])
        var graph = SceneGraph()
        try graph.upsert(relation(subject: cup, predicate: .on, object: tableA))
        let records = [tableA, tableB, cup]
        let first = try engine.query("책상A 위에 뭐 있어?", records: records, graph: graph, at: 20)
        XCTAssertEqual(first.referenceObject?.objectID, tableA.metadata.object.id)
        XCTAssertEqual(first.matches.map(\.subject.objectID), [cup.metadata.object.id])
        XCTAssertEqual(
            engine.geometryScope(for: "책상A 위에 뭐 있어?", records: records)?.objectIDs,
            [tableA.metadata.object.id])
        let second = try engine.query("책상B 위에 뭐 있어?", records: records, graph: graph, at: 20)
        XCTAssertEqual(second.referenceObject?.objectID, tableB.metadata.object.id)
        XCTAssertTrue(second.matches.isEmpty)
        let pair = try engine.query("책상A 근처 책상B", records: records, graph: graph, at: 20)
        XCTAssertEqual(pair.mode, .verifyRelation)
        XCTAssertEqual(pair.status, .noConfirmedRelation)
    }

    func testDuplicateNameSelectionRevalidatesCurrentCandidates() throws {
        let tableA = try makeRecord(label: "table", aliases: ["업무책상"])
        let tableB = try makeRecord(label: "table", aliases: ["업무책상"], x: 2)
        let cup = try makeRecord(label: "cup")
        var graph = SceneGraph()
        try graph.upsert(relation(subject: cup, predicate: .on, object: tableB))
        let records = [tableA, tableB, cup]
        let query = "업무책상 위에 뭐 있어?"
        let ambiguous = try engine.query(query, records: records, graph: graph, at: 20)
        XCTAssertEqual(ambiguous.status, .ambiguous)
        XCTAssertEqual(ambiguous.ambiguousTargets.first?.candidates.count, 2)
        let selected = try engine.query(
            query, records: records, graph: graph, at: 20,
            selections: ["업무책상": tableB.metadata.object.id])
        XCTAssertEqual(selected.referenceObject?.objectID, tableB.metadata.object.id)
        XCTAssertEqual(selected.matches.count, 1)
        let stale = try engine.query(
            query, records: [tableA, cup], graph: graph, at: 20,
            selections: ["업무책상": tableB.metadata.object.id])
        XCTAssertEqual(stale.status, .ambiguous)
        XCTAssertTrue(stale.matches.isEmpty)
        XCTAssertNil(
            engine.geometryScope(
                for: query, records: [tableA, cup],
                selections: ["업무책상": tableB.metadata.object.id]))
    }

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
