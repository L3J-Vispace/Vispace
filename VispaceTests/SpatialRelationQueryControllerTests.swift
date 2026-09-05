import Foundation
import VispaceCore
import XCTest

@testable import Vispace

@MainActor
final class SpatialRelationQueryControllerTests: XCTestCase {
    func testConfirmedCurrentMapAndFramePublishOnlyGroundedRelation() async throws {
        let map = mapID(1)
        let frame = frameID(1)
        let table = try record(
            id: objectID(1),
            mapID: map,
            frameID: frame,
            label: "table",
            aliases: ["테이블"]
        )
        let cup = try record(
            id: objectID(2),
            mapID: map,
            frameID: frame,
            label: "cup",
            aliases: ["컵"]
        )
        let foreignMapBook = try record(
            id: objectID(3),
            mapID: mapID(2),
            frameID: frame,
            label: "book",
            aliases: ["책"]
        )
        let foreignFrameVase = try record(
            id: objectID(4),
            mapID: map,
            frameID: frameID(2),
            label: "vase",
            aliases: ["화병"]
        )
        var graph = SceneGraph()
        try graph.upsert(relation(subject: cup, predicate: .on, object: table))
        try graph.upsert(relation(subject: foreignMapBook, predicate: .on, object: table))
        try graph.upsert(relation(subject: foreignFrameVase, predicate: .on, object: table))
        let identityBox = RelationIdentityBox(identity(mapID: map, frameID: frame))
        let controller = controller(
            identityBox: identityBox,
            snapshot: snapshot(
                mapID: map,
                frameID: frame,
                records: [table, cup, foreignMapBook, foreignFrameVase],
                graph: graph
            )
        )

        controller.submit("테이블 위에 뭐가 있어?", now: 20)
        try await waitForIdle(controller)

        let presentation = try XCTUnwrap(controller.latestPresentation)
        XCTAssertEqual(presentation.result.status, .answered)
        XCTAssertEqual(presentation.result.matches.map(\.subject.objectID), [cup.metadata.object.id])
        XCTAssertTrue(presentation.message.contains("확인된 물체"))
        XCTAssertTrue(presentation.message.contains("cup"))
        XCTAssertEqual(controller.metrics.resultsPublished, 1)
    }

    func testUnconfirmedOrMaplessCaptureNeverLoadsGraph() async throws {
        let probe = RelationSnapshotProviderProbe()
        let identityBox = RelationIdentityBox(
            identity(mapID: mapID(10), frameID: frameID(10), status: .relocalizing)
        )
        let controller = SpatialRelationQueryController(
            snapshotProvider: { mapID in
                await probe.record(mapID)
                return nil
            },
            currentIdentityProvider: { identityBox.value }
        )

        controller.submit("테이블 위에 뭐가 있어?", now: 20)

        try await Task.sleep(for: .milliseconds(20))
        guard case .unavailable(let relocalizingMessage) = controller.state else {
            return XCTFail("Relocalizing capture must be unavailable.")
        }
        XCTAssertTrue(relocalizingMessage.contains("카메라 위치"))
        let firstRequestCount = await probe.requestCount
        XCTAssertEqual(firstRequestCount, 0)
        XCTAssertEqual(controller.metrics.requestsStarted, 0)

        identityBox.value = identity(mapID: nil, frameID: frameID(10))
        controller.submit("테이블 위에 뭐가 있어?", now: 21)

        try await Task.sleep(for: .milliseconds(20))
        guard case .unavailable(let maplessMessage) = controller.state else {
            return XCTFail("Mapless capture must be unavailable.")
        }
        XCTAssertTrue(maplessMessage.contains("안정화"))
        let secondRequestCount = await probe.requestCount
        XCTAssertEqual(secondRequestCount, 0)
        XCTAssertEqual(controller.metrics.unavailableResultsPublished, 2)
    }

    func testConfirmedCaptureRequestsOnlyItsCurrentMapID() async throws {
        let expectedMap = mapID(11)
        let probe = RelationSnapshotProviderProbe()
        let identityBox = RelationIdentityBox(
            identity(mapID: expectedMap, frameID: frameID(11))
        )
        let controller = SpatialRelationQueryController(
            snapshotProvider: { mapID in
                await probe.record(mapID)
                return nil
            },
            currentIdentityProvider: { identityBox.value }
        )

        controller.submit("테이블 위에 뭐가 있어?", now: 20)
        try await waitForIdle(controller)

        let requestedMapIDs = await probe.requestedMapIDs
        XCTAssertEqual(requestedMapIDs, [expectedMap])
        guard case .unavailable = controller.state else {
            return XCTFail("Missing current-map graph must remain unavailable.")
        }
    }

    func testProvisionalAndExpiredRelationsAreNeverPublished() async throws {
        let map = mapID(20)
        let frame = frameID(20)
        let table = try record(
            id: objectID(20),
            mapID: map,
            frameID: frame,
            label: "table",
            aliases: ["테이블"]
        )
        let cup = try record(
            id: objectID(21),
            mapID: map,
            frameID: frame,
            label: "cup"
        )
        let book = try record(
            id: objectID(22),
            mapID: map,
            frameID: frame,
            label: "book"
        )
        var graph = SceneGraph()
        try graph.upsert(
            relation(
                subject: cup,
                predicate: .on,
                object: table,
                certainty: .confirmed,
                validUntil: 10
            )
        )
        try graph.upsert(
            relation(
                subject: book,
                predicate: .on,
                object: table,
                confidence: 0.7,
                certainty: .provisional,
                validFrom: 11
            )
        )
        let identityBox = RelationIdentityBox(identity(mapID: map, frameID: frame))
        let controller = controller(
            identityBox: identityBox,
            snapshot: snapshot(
                mapID: map,
                frameID: frame,
                records: [table, cup, book],
                graph: graph
            )
        )

        controller.submit("테이블 위에 뭐가 있어?", now: 20)
        try await waitForIdle(controller)

        let presentation = try XCTUnwrap(controller.latestPresentation)
        XCTAssertEqual(presentation.result.status, .noConfirmedRelation)
        XCTAssertTrue(presentation.result.matches.isEmpty)
        XCTAssertEqual(presentation.result.issues, [.noConfirmedRelation])
        XCTAssertTrue(presentation.message.contains("확정된 기록"))
        XCTAssertTrue(presentation.message.contains("확인하지 못했어요"))
    }

    func testRelationOlderThanEitherEndpointStateIsNeverPublished() async throws {
        let map = mapID(25)
        let frame = frameID(25)
        let table = try record(
            id: objectID(25),
            mapID: map,
            frameID: frame,
            label: "table",
            aliases: ["테이블"],
            stateUpdatedAt: 10
        )
        let refreshedCup = try record(
            id: objectID(26),
            mapID: map,
            frameID: frame,
            label: "cup",
            aliases: ["컵"],
            stateUpdatedAt: 30
        )
        var graph = SceneGraph()
        try graph.upsert(
            relation(
                subject: refreshedCup,
                predicate: .on,
                object: table,
                validFrom: 20
            )
        )
        let identityBox = RelationIdentityBox(identity(mapID: map, frameID: frame))
        let controller = controller(
            identityBox: identityBox,
            snapshot: snapshot(
                mapID: map,
                frameID: frame,
                records: [table, refreshedCup],
                graph: graph
            )
        )

        controller.submit("컵이 테이블 위에 있어?", now: 40)
        try await waitForIdle(controller)

        let presentation = try XCTUnwrap(controller.latestPresentation)
        XCTAssertEqual(presentation.result.status, .noConfirmedRelation)
        XCTAssertEqual(presentation.result.isAffirmative, false)
        XCTAssertTrue(presentation.result.matches.isEmpty)
    }

    func testRelationAtLeastAsFreshAsBothEndpointsRemainsQueryable() async throws {
        let map = mapID(26)
        let frame = frameID(26)
        let table = try record(
            id: objectID(27),
            mapID: map,
            frameID: frame,
            label: "table",
            aliases: ["테이블"],
            stateUpdatedAt: 10
        )
        let refreshedCup = try record(
            id: objectID(28),
            mapID: map,
            frameID: frame,
            label: "cup",
            aliases: ["컵"],
            stateUpdatedAt: 30
        )
        var graph = SceneGraph()
        try graph.upsert(
            relation(
                subject: refreshedCup,
                predicate: .on,
                object: table,
                validFrom: 30
            )
        )
        let identityBox = RelationIdentityBox(identity(mapID: map, frameID: frame))
        let controller = controller(
            identityBox: identityBox,
            snapshot: snapshot(
                mapID: map,
                frameID: frame,
                records: [table, refreshedCup],
                graph: graph
            )
        )

        controller.submit("컵이 테이블 위에 있어?", now: 40)
        try await waitForIdle(controller)

        let presentation = try XCTUnwrap(controller.latestPresentation)
        XCTAssertEqual(presentation.result.status, .answered)
        XCTAssertEqual(presentation.result.isAffirmative, true)
        XCTAssertEqual(presentation.result.matches.first?.validFrom, 30)
    }

    func testMissingGraphPublishesHonestKoreanUnavailableState() async throws {
        let map = mapID(30)
        let frame = frameID(30)
        let identityBox = RelationIdentityBox(identity(mapID: map, frameID: frame))
        let controller = SpatialRelationQueryController(
            snapshotProvider: { _ in nil },
            currentIdentityProvider: { identityBox.value }
        )

        controller.submit("테이블 위에 뭐가 있어?", now: 20)
        try await waitForIdle(controller)

        guard case .unavailable(let message) = controller.state else {
            return XCTFail("Missing graph must be reported as unavailable.")
        }
        XCTAssertTrue(message.contains("확정된 공간 관계가 없어요"))
        XCTAssertNil(controller.latestPresentation)
        XCTAssertEqual(controller.metrics.unavailableResultsPublished, 1)
    }

    func testGraphFrameMismatchPublishesHonestKoreanUnavailableState() async throws {
        let map = mapID(40)
        let frame = frameID(40)
        let identityBox = RelationIdentityBox(identity(mapID: map, frameID: frame))
        let controller = controller(
            identityBox: identityBox,
            snapshot: snapshot(
                mapID: map,
                frameID: frameID(41),
                records: [],
                graph: SceneGraph()
            )
        )

        controller.submit("테이블 위에 뭐가 있어?", now: 20)
        try await waitForIdle(controller)

        guard case .unavailable(let message) = controller.state else {
            return XCTFail("A foreign coordinate frame must be unavailable.")
        }
        XCTAssertTrue(message.contains("현재 카메라 좌표"))
        XCTAssertTrue(message.contains("답하지 않았어요"))
        XCTAssertNil(controller.latestPresentation)
    }

    func testGraphMapMismatchPublishesHonestKoreanUnavailableState() async throws {
        let currentMap = mapID(42)
        let frame = frameID(42)
        let identityBox = RelationIdentityBox(identity(mapID: currentMap, frameID: frame))
        let controller = controller(
            identityBox: identityBox,
            snapshot: snapshot(
                mapID: mapID(43),
                frameID: frame,
                records: [],
                graph: SceneGraph()
            )
        )

        controller.submit("테이블 위에 뭐가 있어?", now: 20)
        try await waitForIdle(controller)

        guard case .unavailable(let message) = controller.state else {
            return XCTFail("A foreign map graph must be unavailable.")
        }
        XCTAssertTrue(message.contains("저장된 공간"))
        XCTAssertTrue(message.contains("답하지 않았어요"))
        XCTAssertNil(controller.latestPresentation)
    }

    func testCurrentMapRecordWithForeignFrameCannotGroundAnAnswer() async throws {
        let map = mapID(50)
        let frame = frameID(50)
        let foreignFrame = frameID(51)
        let table = try record(
            id: objectID(50),
            mapID: map,
            frameID: foreignFrame,
            label: "table",
            aliases: ["테이블"]
        )
        let cup = try record(
            id: objectID(51),
            mapID: map,
            frameID: foreignFrame,
            label: "cup"
        )
        var graph = SceneGraph()
        try graph.upsert(relation(subject: cup, predicate: .on, object: table))
        let identityBox = RelationIdentityBox(identity(mapID: map, frameID: frame))
        let controller = controller(
            identityBox: identityBox,
            snapshot: snapshot(mapID: map, frameID: frame, records: [table, cup], graph: graph)
        )

        controller.submit("테이블 위에 뭐가 있어?", now: 20)
        try await waitForIdle(controller)

        let presentation = try XCTUnwrap(controller.latestPresentation)
        XCTAssertEqual(presentation.result.status, .notGrounded)
        XCTAssertTrue(presentation.result.matches.isEmpty)
        XCTAssertTrue(presentation.message.contains("물체 이름을 찾지 못했어요"))
    }

    func testKoreanMessagesCoverAnsweredAmbiguousNotGroundedAndUnsupported() async throws {
        let map = mapID(60)
        let frame = frameID(60)
        let table = try record(
            id: objectID(60),
            mapID: map,
            frameID: frame,
            label: "table",
            aliases: ["테이블"]
        )
        let cup = try record(
            id: objectID(61),
            mapID: map,
            frameID: frame,
            label: "cup",
            aliases: ["컵"]
        )
        var graph = SceneGraph()
        try graph.upsert(relation(subject: cup, predicate: .on, object: table))
        let identityBox = RelationIdentityBox(identity(mapID: map, frameID: frame))
        let answered = controller(
            identityBox: identityBox,
            snapshot: snapshot(mapID: map, frameID: frame, records: [table, cup], graph: graph)
        )

        answered.submit("컵이 테이블 위에 있어?", now: 20)
        try await waitForIdle(answered)
        XCTAssertEqual(answered.latestPresentation?.result.status, .answered)
        XCTAssertTrue(answered.latestPresentation?.message.contains("확정된 기록상") == true)

        let secondTable = try record(
            id: objectID(62),
            mapID: map,
            frameID: frame,
            label: "table",
            aliases: ["테이블"]
        )
        let ambiguous = controller(
            identityBox: identityBox,
            snapshot: snapshot(
                mapID: map,
                frameID: frame,
                records: [table, secondTable, cup],
                graph: graph
            )
        )
        ambiguous.submit("테이블 위에 뭐가 있어?", now: 20)
        try await waitForIdle(ambiguous)
        XCTAssertEqual(ambiguous.latestPresentation?.result.status, .ambiguous)
        XCTAssertTrue(ambiguous.latestPresentation?.message.contains("여러 개") == true)

        let missing = controller(
            identityBox: identityBox,
            snapshot: snapshot(
                mapID: map,
                frameID: frame,
                records: [table],
                graph: SceneGraph()
            )
        )
        missing.submit("선반 위에 뭐가 있어?", now: 20)
        try await waitForIdle(missing)
        XCTAssertEqual(missing.latestPresentation?.result.status, .notGrounded)
        XCTAssertTrue(missing.latestPresentation?.message.contains("물체 이름") == true)

        let unsupported = controller(
            identityBox: identityBox,
            snapshot: snapshot(
                mapID: map,
                frameID: frame,
                records: [table],
                graph: SceneGraph()
            )
        )
        unsupported.submit("테이블 왼쪽에는 뭐가 있어?", now: 20)
        try await waitForIdle(unsupported)
        XCTAssertEqual(unsupported.latestPresentation?.result.status, .unsupported)
        XCTAssertTrue(unsupported.latestPresentation?.message.contains("현재는 위·아래") == true)
    }

    func testNewerRequestWinsWhenProvidersCompleteOutOfOrder() async throws {
        let map = mapID(70)
        let frame = frameID(70)
        let table = try record(
            id: objectID(70),
            mapID: map,
            frameID: frame,
            label: "table",
            aliases: ["테이블"]
        )
        let cup = try record(
            id: objectID(71),
            mapID: map,
            frameID: frame,
            label: "cup",
            aliases: ["컵"]
        )
        let door = try record(
            id: objectID(72),
            mapID: map,
            frameID: frame,
            label: "door",
            aliases: ["문"]
        )
        let chair = try record(
            id: objectID(73),
            mapID: map,
            frameID: frame,
            label: "chair",
            aliases: ["의자"]
        )
        var graph = SceneGraph()
        try graph.upsert(relation(subject: cup, predicate: .on, object: table))
        try graph.upsert(relation(subject: chair, predicate: .near, object: door))
        let value = snapshot(
            mapID: map,
            frameID: frame,
            records: [table, cup, door, chair],
            graph: graph
        )
        let provider = SuspendedRelationSnapshotProvider()
        let identityBox = RelationIdentityBox(identity(mapID: map, frameID: frame))
        let controller = SpatialRelationQueryController(
            snapshotProvider: { mapID in
                try await provider.load(mapID: mapID)
            },
            currentIdentityProvider: { identityBox.value }
        )

        controller.submit("테이블 위에 뭐가 있어?", now: 20)
        try await waitForRequestCount(provider, 1)
        controller.submit("문 근처 뭐가 있어?", now: 21)
        try await waitForRequestCount(provider, 2)

        await provider.resume(index: 1, with: value)
        try await waitForIdle(controller)
        XCTAssertEqual(
            controller.latestPresentation?.result.referenceObject?.objectID, door.metadata.object.id)
        XCTAssertEqual(
            controller.latestPresentation?.result.matches.first?.subject.objectID, chair.metadata.object.id)

        await provider.resume(index: 0, with: value)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(
            controller.latestPresentation?.result.referenceObject?.objectID, door.metadata.object.id)
        XCTAssertEqual(controller.metrics.requestsCancelled, 1)
        XCTAssertGreaterThanOrEqual(controller.metrics.staleResultsRejected, 1)
    }

    func testExplicitCaptureTransitionCancelsLateResultAndClearsPresentation() async throws {
        let map = mapID(80)
        let frame = frameID(80)
        let table = try record(
            id: objectID(80),
            mapID: map,
            frameID: frame,
            label: "table",
            aliases: ["테이블"]
        )
        let provider = SuspendedRelationSnapshotProvider()
        let identityBox = RelationIdentityBox(identity(mapID: map, frameID: frame))
        let controller = SpatialRelationQueryController(
            snapshotProvider: { mapID in
                try await provider.load(mapID: mapID)
            },
            currentIdentityProvider: { identityBox.value }
        )

        controller.submit("테이블 위에 뭐가 있어?", now: 20)
        try await waitForRequestCount(provider, 1)
        controller.invalidateForCaptureTransition()
        await provider.resume(
            index: 0,
            with: snapshot(
                mapID: map,
                frameID: frame,
                records: [table],
                graph: SceneGraph()
            )
        )
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.latestPresentation)
        XCTAssertFalse(controller.isProcessingForTesting)
        XCTAssertEqual(controller.metrics.requestsCancelled, 1)
        XCTAssertGreaterThanOrEqual(controller.metrics.staleResultsRejected, 1)
    }

    func testInvalidateAndWaitAlsoWaitsForReplacedSnapshotRead() async throws {
        let map = mapID(85)
        let frame = frameID(85)
        let table = try record(
            id: objectID(85),
            mapID: map,
            frameID: frame,
            label: "table",
            aliases: ["테이블"]
        )
        let provider = SuspendedRelationSnapshotProvider()
        let completion = RelationDeletionBarrierCompletion()
        let identityBox = RelationIdentityBox(identity(mapID: map, frameID: frame))
        let controller = SpatialRelationQueryController(
            snapshotProvider: { mapID in
                try await provider.load(mapID: mapID)
            },
            currentIdentityProvider: { identityBox.value }
        )

        controller.submit("테이블 위에 뭐가 있어?", now: 20)
        try await waitForRequestCount(provider, 1)
        controller.submit("테이블 위에 뭐가 있어?", now: 21)
        try await waitForRequestCount(provider, 2)
        let barrierTask = Task { @MainActor in
            await controller.invalidateAndWaitForPendingWork()
            await completion.markFinished()
        }
        try await waitForIdle(controller)

        let finishedWhileProviderWasBlocked = await completion.isFinished
        XCTAssertFalse(finishedWhileProviderWasBlocked)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.latestPresentation)

        // The newest read can unwind while its replaced predecessor still owns a store read.
        await provider.resume(
            index: 1,
            with: snapshot(
                mapID: map,
                frameID: frame,
                records: [table],
                graph: SceneGraph()
            )
        )
        for _ in 0..<200 {
            if controller.metrics.staleResultsRejected == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.metrics.staleResultsRejected, 1)
        try await Task.sleep(for: .milliseconds(30))
        let finishedWhileReplacedReadWasBlocked = await completion.isFinished
        XCTAssertFalse(finishedWhileReplacedReadWasBlocked)

        await provider.resume(
            index: 0,
            with: snapshot(
                mapID: map,
                frameID: frame,
                records: [table],
                graph: SceneGraph()
            )
        )
        await barrierTask.value

        let finishedAfterProviderReleased = await completion.isFinished
        XCTAssertTrue(finishedAfterProviderReleased)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.latestPresentation)
        XCTAssertEqual(controller.metrics.resultsPublished, 0)
        XCTAssertEqual(controller.metrics.unavailableResultsPublished, 0)
        XCTAssertEqual(controller.metrics.requestsCancelled, 2)
        XCTAssertEqual(controller.metrics.staleResultsRejected, 2)
    }

    func testIdentityChangeRejectsLateResultEvenWithoutExplicitInvalidation() async throws {
        let map = mapID(90)
        let frame = frameID(90)
        let table = try record(
            id: objectID(90),
            mapID: map,
            frameID: frame,
            label: "table",
            aliases: ["테이블"]
        )
        let provider = SuspendedRelationSnapshotProvider()
        let identityBox = RelationIdentityBox(identity(mapID: map, frameID: frame))
        let controller = SpatialRelationQueryController(
            snapshotProvider: { mapID in
                try await provider.load(mapID: mapID)
            },
            currentIdentityProvider: { identityBox.value }
        )

        controller.submit("테이블 위에 뭐가 있어?", now: 20)
        try await waitForRequestCount(provider, 1)
        identityBox.value = identity(
            mapID: map,
            frameID: frame,
            segmentID: segmentID(91)
        )
        await provider.resume(
            index: 0,
            with: snapshot(
                mapID: map,
                frameID: frame,
                records: [table],
                graph: SceneGraph()
            )
        )
        try await waitForIdle(controller)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.latestPresentation)
        XCTAssertEqual(controller.metrics.staleResultsRejected, 1)
    }

    func testProviderFailureAndInvalidTimePublishSafeKoreanFailure() async throws {
        enum TestError: Error {
            case rawRepositoryFailure
        }
        let identityBox = RelationIdentityBox(
            identity(mapID: mapID(100), frameID: frameID(100))
        )
        let controller = SpatialRelationQueryController(
            snapshotProvider: { _ in throw TestError.rawRepositoryFailure },
            currentIdentityProvider: { identityBox.value }
        )

        controller.submit("테이블 위에 뭐가 있어?", now: 20)
        try await waitForIdle(controller)

        guard case .failed(let providerMessage) = controller.state else {
            return XCTFail("Provider error must publish a safe failure.")
        }
        XCTAssertTrue(providerMessage.contains("불러오지 못했어요"))
        XCTAssertFalse(providerMessage.contains("rawRepositoryFailure"))
        XCTAssertNil(controller.latestPresentation)

        controller.submit("테이블 위에 뭐가 있어?", now: .nan)

        guard case .failed(let timeMessage) = controller.state else {
            return XCTFail("Invalid time must publish a safe failure.")
        }
        XCTAssertTrue(timeMessage.contains("다시 시도"))
        XCTAssertNil(controller.latestPresentation)
        XCTAssertEqual(controller.metrics.failuresPublished, 2)
    }

    private func controller(
        identityBox: RelationIdentityBox,
        snapshot: SpatialRelationQuerySnapshot
    ) -> SpatialRelationQueryController {
        SpatialRelationQueryController(
            snapshotProvider: { _ in snapshot },
            currentIdentityProvider: { identityBox.value }
        )
    }

    private func snapshot(
        mapID: MapID,
        frameID: CoordinateFrameID,
        records: [StoredSpatialObjectRecord],
        graph: SceneGraph
    ) -> SpatialRelationQuerySnapshot {
        SpatialRelationQuerySnapshot(
            mapID: mapID,
            coordinateFrameID: frameID,
            records: records,
            graph: graph
        )
    }

    private func relation(
        subject: StoredSpatialObjectRecord,
        predicate: SpatialRelationPredicate,
        object: StoredSpatialObjectRecord,
        confidence: Double = 0.95,
        certainty: RelationCertainty = .confirmed,
        validFrom: TimeInterval = 10,
        validUntil: TimeInterval? = nil
    ) throws -> SpatialRelation {
        try SpatialRelation(
            key: RelationKey(
                subject: .object(subject.metadata.object.id),
                predicate: predicate,
                object: .object(object.metadata.object.id)
            ),
            confidence: ConfidenceScore(validating: confidence),
            certainty: certainty,
            validFrom: validFrom,
            validUntil: validUntil
        )
    }

    private func record(
        id: ObjectID,
        mapID: MapID,
        frameID: CoordinateFrameID,
        label: String,
        aliases: [String] = [],
        stateUpdatedAt: TimeInterval = 10
    ) throws -> StoredSpatialObjectRecord {
        let position = Vec3.zero
        let object = try SpatialObject(
            id: id,
            semanticLabel: label,
            position: position,
            bounds: nil,
            certainty: .confirmed,
            presence: .visible,
            confidence: ConfidenceVector(
                semantic: .one,
                geometry: .one,
                tracking: .one,
                place: .one,
                identity: .one,
                objectState: .one,
                relation: .one
            ),
            firstSeenAt: 1,
            lastSeenAt: stateUpdatedAt,
            stateUpdatedAt: stateUpdatedAt
        )
        let metadata = try SpatialObjectMetadata(
            mapID: mapID,
            object: object,
            position: FramedPosition(
                coordinateFrameID: frameID,
                value: position,
                observedAt: stateUpdatedAt,
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

    private func identity(
        mapID: MapID?,
        frameID: CoordinateFrameID,
        segmentID: CaptureSegmentID? = nil,
        status: ARCaptureIdentity.Status = .confirmed
    ) -> ARCaptureIdentity {
        ARCaptureIdentity(
            coordinateFrameID: frameID,
            segmentID: segmentID ?? self.segmentID(1),
            mapID: mapID,
            status: status
        )
    }

    private func waitForIdle(_ controller: SpatialRelationQueryController) async throws {
        for _ in 0..<250 where controller.isProcessingForTesting {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isProcessingForTesting)
    }

    private func waitForRequestCount(
        _ provider: SuspendedRelationSnapshotProvider,
        _ expected: Int
    ) async throws {
        for _ in 0..<250 {
            if await provider.requestCount == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Provider did not receive \(expected) requests.")
    }

    private func mapID(_ value: Int) -> MapID {
        MapID(rawValue: uuid(100_000 + value))
    }

    private func frameID(_ value: Int) -> CoordinateFrameID {
        CoordinateFrameID(rawValue: uuid(200_000 + value))
    }

    private func segmentID(_ value: Int) -> CaptureSegmentID {
        CaptureSegmentID(rawValue: uuid(300_000 + value))
    }

    private func objectID(_ value: Int) -> ObjectID {
        ObjectID(rawValue: uuid(400_000 + value))
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }
}

@MainActor
private final class RelationIdentityBox {
    var value: ARCaptureIdentity

    init(_ value: ARCaptureIdentity) {
        self.value = value
    }
}

private actor RelationSnapshotProviderProbe {
    private(set) var requestedMapIDs: [MapID] = []

    var requestCount: Int {
        requestedMapIDs.count
    }

    func record(_ mapID: MapID) {
        requestedMapIDs.append(mapID)
    }
}

private actor SuspendedRelationSnapshotProvider {
    private var continuations: [CheckedContinuation<SpatialRelationQuerySnapshot?, Error>] = []

    var requestCount: Int {
        continuations.count
    }

    func load(mapID: MapID) async throws -> SpatialRelationQuerySnapshot? {
        _ = mapID
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(index: Int, with snapshot: SpatialRelationQuerySnapshot?) {
        continuations[index].resume(returning: snapshot)
    }
}

private actor RelationDeletionBarrierCompletion {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}
