import Foundation
import VispaceCore
import XCTest

@testable import Vispace

@MainActor
final class SpatialObjectQueryControllerTests: XCTestCase {
    func testExpiredNavigationCanExplicitlyRefreshTheSameObjectAndCurrentAlignment() async throws {
        let sourceMap = mapID(1_170), sourceFrame = frameID(1_170)
        let map = mapID(1_171), frame = frameID(1_171)
        let current = identity(mapID: map, frameID: frame)
        let original = try metadata(id: objectID(1_170), mapID: sourceMap, frameID: sourceFrame,
            label: "keyboard", position: vec(1, 0, -2), lastSeenAt: 90)
        let firstAlignment = try alignmentRecord(sourceMapID: sourceMap, sourceFrameID: sourceFrame,
            targetMapID: map, targetFrameID: frame, transform: .translation(vec(2, 0, 1)))
        let provider = SuspendedQuerySnapshotProvider()
        let controller = SpatialObjectQueryController(
            snapshotProvider: { try await provider.load(currentMapID: $0) },
            currentIdentityProvider: { current }, uptimeProvider: { 10 })
        let firstSnapshot = snapshot(records: [record(original)], alignments: [firstAlignment])
        controller.submit("키보드 어디있어", now: 100)
        try await waitForRequestCount(provider, 1)
        await provider.resume(requestIndex: 0, with: firstSnapshot)
        try await waitForIdle(controller)
        let searchTarget = try XCTUnwrap(controller.latestGroundedTarget)
        XCTAssertFalse(controller.canRefreshSelectedNavigation)
        XCTAssertFalse(controller.refreshSelectedNavigation(searchTarget, now: 101))
        XCTAssertTrue(controller.navigateToSelectedObject(searchTarget, now: 101))
        try await waitForRequestCount(provider, 2)
        await provider.resume(requestIndex: 1, with: firstSnapshot)
        try await waitForIdle(controller)
        let expired = try XCTUnwrap(controller.latestGroundedTarget)

        XCTAssertFalse(controller.canNavigateToSelectedObject)
        XCTAssertTrue(controller.canRefreshSelectedNavigation)
        XCTAssertTrue(controller.refreshSelectedNavigation(expired, now: 132))
        XCTAssertNil(controller.latestGroundedTarget)
        XCTAssertFalse(controller.canRefreshSelectedNavigation)
        XCTAssertFalse(controller.refreshSelectedNavigation(expired, now: 132))
        try await waitForRequestCount(provider, 3)
        let refreshed = try metadata(id: original.object.id, mapID: sourceMap, frameID: sourceFrame,
            label: "keyboard", position: original.position.value, lastSeenAt: 131)
        let other = try metadata(id: objectID(1_172), mapID: sourceMap, frameID: sourceFrame,
            label: "keyboard", position: vec(4, 0, -2), lastSeenAt: 131)
        let currentAlignment = try alignmentRecord(sourceMapID: sourceMap, sourceFrameID: sourceFrame,
            targetMapID: map, targetFrameID: frame, transform: .translation(vec(5, 0, 1)))
        await provider.resume(requestIndex: 2, with: snapshot(records: [record(other), record(refreshed)],
            alignments: [currentAlignment]))
        try await waitForIdle(controller)
        let renewed = try XCTUnwrap(controller.latestGroundedTarget)
        XCTAssertEqual(renewed.objectID, original.object.id)
        XCTAssertEqual(renewed.sourceMapID, sourceMap)
        XCTAssertEqual(renewed.sourcePosition, refreshed.position)
        XCTAssertEqual(renewed.position.x, 6, accuracy: 0.000_001)
        XCTAssertEqual(renewed.intent, .navigate)
        XCTAssertEqual(renewed.resolvedAt, 132)
        XCTAssertFalse(controller.refreshSelectedNavigation(expired, now: 133))
        XCTAssertEqual(controller.metrics.requestsStarted, 3)
    }

    func testNavigationRefreshRejectsCaptureChangesBeforeAndDuringRead() async throws {
        let map = mapID(1_180), frame = frameID(1_180)
        let current = identity(mapID: map, frameID: frame)
        let identityBox = QueryIdentityBox(current)
        let stored = try metadata(id: objectID(1_180), mapID: map, frameID: frame, label: "keyboard")
        let records = snapshot(records: [record(stored)])
        let provider = SuspendedQuerySnapshotProvider()
        let controller = SpatialObjectQueryController(
            snapshotProvider: { try await provider.load(currentMapID: $0) },
            currentIdentityProvider: { identityBox.value }, uptimeProvider: { 10 })
        controller.submit("키보드까지 안내해줘", now: 100)
        try await waitForRequestCount(provider, 1)
        await provider.resume(requestIndex: 0, with: records)
        try await waitForIdle(controller)
        let target = try XCTUnwrap(controller.latestGroundedTarget)
        XCTAssertEqual(target.intent, .navigate)
        XCTAssertTrue(controller.canRefreshSelectedNavigation)
        identityBox.value = identity(mapID: map, frameID: frameID(1_181))
        XCTAssertFalse(controller.canRefreshSelectedNavigation)
        XCTAssertFalse(controller.refreshSelectedNavigation(target, now: 131))
        XCTAssertEqual(controller.metrics.requestsStarted, 1)

        identityBox.value = current
        XCTAssertFalse(controller.refreshSelectedNavigation(target, now: .nan))
        XCTAssertFalse(controller.refreshSelectedNavigation(target, now: 99))
        XCTAssertTrue(controller.refreshSelectedNavigation(target, now: 131))
        try await waitForRequestCount(provider, 2)
        identityBox.value = identity(mapID: map, frameID: frameID(1_181))
        await provider.resume(requestIndex: 1, with: records)
        try await waitForIdle(controller)
        XCTAssertNil(controller.latestGroundedTarget)
        XCTAssertFalse(controller.canRefreshSelectedNavigation)
        XCTAssertEqual(controller.state, .idle)
    }

    func testNavigationRefreshUsesReadCompletionTimeWithoutAcceptingFutureObservations() async throws {
        let map = mapID(1_150), frame = frameID(1_150)
        let current = identity(mapID: map, frameID: frame)
        let original = try metadata(id: objectID(1_150), mapID: map, frameID: frame,
            label: "keyboard", position: vec(1, 0, -2), lastSeenAt: 90)
        for observedAt in [102.0, 104.0] {
            let provider = SuspendedQuerySnapshotProvider()
            let clock = QueryUptimeBox(10)
            let controller = SpatialObjectQueryController(
                snapshotProvider: { try await provider.load(currentMapID: $0) },
                currentIdentityProvider: { current }, uptimeProvider: { clock.value })
            controller.submit("키보드 어디있어", now: 100)
            try await waitForRequestCount(provider, 1)
            await provider.resume(requestIndex: 0, with: snapshot(records: [record(original)]))
            try await waitForIdle(controller)
            let target = try XCTUnwrap(controller.latestGroundedTarget)

            XCTAssertTrue(controller.navigateToSelectedObject(target, now: 101))
            try await waitForRequestCount(provider, 2)
            // The same location is observed during the suspended navigation
            // refresh. The read finishes at wall time 103, two seconds later.
            let refreshed = try metadata(id: original.object.id, mapID: map, frameID: frame,
                label: "keyboard", position: original.position.value, lastSeenAt: observedAt)
            clock.value = 12
            await provider.resume(requestIndex: 1, with: snapshot(records: [record(refreshed)]))
            try await waitForIdle(controller)

            XCTAssertEqual(controller.latestPresentation?.result.candidates.first?.record.metadata, refreshed)
            if observedAt == 102 {
                let destination = try XCTUnwrap(controller.latestGroundedTarget)
                XCTAssertEqual(destination.intent, .navigate)
                XCTAssertEqual(destination.sourcePosition, refreshed.position)
                XCTAssertEqual(destination.resolvedAt, 101, "The read must not renew the handoff lease")
            } else {
                XCTAssertNil(controller.latestGroundedTarget)
                XCTAssertEqual(controller.latestPresentation?.result.status, .lowConfidence)
                XCTAssertTrue(controller.latestPresentation?.result.issues.contains(.observationTimeInFuture) == true)
            }
        }
    }

    func testNavigationRefreshRejectsInvalidOrReversedEvaluationClock() async throws {
        let map = mapID(1_160), frame = frameID(1_160)
        let current = identity(mapID: map, frameID: frame)
        let stored = try metadata(id: objectID(1_160), mapID: map, frameID: frame, label: "keyboard")
        for completedUptime in [Double.nan, .infinity, 9] {
            let provider = SuspendedQuerySnapshotProvider()
            let clock = QueryUptimeBox(10)
            let controller = SpatialObjectQueryController(
                snapshotProvider: { try await provider.load(currentMapID: $0) },
                currentIdentityProvider: { current }, uptimeProvider: { clock.value })
            let records = snapshot(records: [record(stored)])
            controller.submit("키보드 어디있어", now: 100)
            try await waitForRequestCount(provider, 1)
            await provider.resume(requestIndex: 0, with: records)
            try await waitForIdle(controller)
            let target = try XCTUnwrap(controller.latestGroundedTarget)
            XCTAssertTrue(controller.navigateToSelectedObject(target, now: 101))
            try await waitForRequestCount(provider, 2)
            clock.value = completedUptime
            await provider.resume(requestIndex: 1, with: records)
            try await waitForIdle(controller)
            XCTAssertNil(controller.latestGroundedTarget)
            XCTAssertFalse(controller.canNavigateToSelectedObject)
            guard case .failed = controller.state else {
                return XCTFail("An unusable clock must not authorize navigation")
            }
        }
    }

    func testNavigationActionPreservesExplicitCandidateAndRefreshesGrounding() async throws {
        let map = mapID(1_100), frame = frameID(1_100)
        let records = try (0..<3).map { index in
            record(try metadata(id: objectID(1_100 + index), mapID: map, frameID: frame,
                label: "keyboard", position: vec(Double(index), 0, -2)), aliases: ["키보드"])
        }
        let controller = controller(identityBox: QueryIdentityBox(identity(mapID: map, frameID: frame)),
            records: records)
        controller.submit("키보드 어디있어", now: 100)
        try await waitForIdle(controller)
        XCTAssertFalse(controller.canNavigateToSelectedObject)
        controller.selectCandidate(objectID: records[1].metadata.object.id, mapID: map, now: 101)
        try await waitForIdle(controller)
        let selected = try XCTUnwrap(controller.latestGroundedTarget)
        XCTAssertTrue(controller.canNavigateToSelectedObject)
        XCTAssertEqual(selected.intent, .searchObject)

        XCTAssertTrue(controller.navigateToSelectedObject(selected, now: 102))
        XCTAssertNil(controller.latestGroundedTarget)
        XCTAssertFalse(controller.canNavigateToSelectedObject)
        try await waitForIdle(controller)

        let destination = try XCTUnwrap(controller.latestGroundedTarget)
        XCTAssertEqual(destination.intent, .navigate)
        XCTAssertEqual(destination.objectID, records[1].metadata.object.id)
        XCTAssertEqual(destination.sourceMapID, selected.sourceMapID)
        XCTAssertEqual(destination.sourcePosition, selected.sourcePosition)
        XCTAssertEqual(destination.currentFramePosition, selected.currentFramePosition)
        XCTAssertEqual(destination.resolvedAt, 102)
        XCTAssertFalse(controller.canNavigateToSelectedObject)
        XCTAssertFalse(controller.navigateToSelectedObject(destination, now: 103))
    }

    func testNavigationActionRejectsObsoleteButtonAndChangedCaptureIdentity() async throws {
        let map = mapID(1_110), frame = frameID(1_110)
        let identityBox = QueryIdentityBox(identity(mapID: map, frameID: frame))
        let keyboard = try metadata(id: objectID(1_110), mapID: map, frameID: frame, label: "keyboard")
        let mouse = try metadata(id: objectID(1_111), mapID: map, frameID: frame, label: "mouse")
        let controller = controller(identityBox: identityBox,
            records: [record(keyboard, aliases: ["키보드"]), record(mouse, aliases: ["마우스"])])
        controller.submit("키보드 어디있어", now: 100)
        try await waitForIdle(controller)
        let obsolete = try XCTUnwrap(controller.latestGroundedTarget)
        controller.submit("마우스 어디있어", now: 101)
        try await waitForIdle(controller)
        let current = try XCTUnwrap(controller.latestGroundedTarget)
        let requests = controller.metrics.requestsStarted
        XCTAssertFalse(controller.navigateToSelectedObject(obsolete, now: 102))
        XCTAssertEqual(controller.latestGroundedTarget, current)
        XCTAssertFalse(controller.navigateToSelectedObject(current, now: .nan))
        XCTAssertFalse(controller.navigateToSelectedObject(current, now: 99))

        identityBox.value = identity(mapID: map, frameID: frameID(1_112))
        XCTAssertFalse(controller.canNavigateToSelectedObject)
        XCTAssertFalse(controller.navigateToSelectedObject(current, now: 102))
        controller.cancelCurrentQuery()
        XCTAssertFalse(controller.canNavigateToSelectedObject)
        XCTAssertFalse(controller.navigateToSelectedObject(current, now: 102))
        XCTAssertEqual(controller.metrics.requestsStarted, requests)
    }

    func testNavigationActionRechecksSelectedPositionConfidenceAndRemovalWithoutFallback() async throws {
        let map = mapID(1_120), frame = frameID(1_120)
        let current = identity(mapID: map, frameID: frame)
        let original = try metadata(id: objectID(1_120), mapID: map, frameID: frame,
            label: "keyboard", position: vec(1, 0, -2))
        let other = try metadata(id: objectID(1_121), mapID: map, frameID: frame,
            label: "keyboard", position: vec(2, 0, -2))
        for change in 0..<3 {
            let provider = SuspendedQuerySnapshotProvider()
            let controller = SpatialObjectQueryController(
                snapshotProvider: { map in try await provider.load(currentMapID: map) },
                currentIdentityProvider: { current })
            controller.submit("키보드 어디있어", now: 100)
            try await waitForRequestCount(provider, 1)
            await provider.resume(requestIndex: 0,
                with: snapshot(records: [record(original, aliases: ["키보드"])]))
            try await waitForIdle(controller)
            let target = try XCTUnwrap(controller.latestGroundedTarget)
            XCTAssertTrue(controller.navigateToSelectedObject(target, now: 101))
            try await waitForRequestCount(provider, 2)
            let changed = try metadata(id: original.object.id, mapID: map, frameID: frame,
                label: "keyboard", position: change == 0 ? vec(5, 0, -2) : original.position.value,
                presence: change == 2 ? .removed : .visible,
                confidence: change == 1 ? confidence(0.1) : original.object.confidence)
            await provider.resume(requestIndex: 1, with: snapshot(records: [
                record(changed, aliases: ["키보드"]), record(other, aliases: ["키보드"])
            ]))
            try await waitForIdle(controller)
            XCTAssertNil(controller.latestGroundedTarget)
            XCTAssertFalse(controller.canNavigateToSelectedObject)
            if change == 1 {
                XCTAssertEqual(controller.latestPresentation?.result.status, .lowConfidence)
            } else if case .failed = controller.state {} else {
                XCTFail("Changed or removed destination requires another user selection")
            }
        }
    }

    func testNavigationActionRechecksAlignmentBeforePublishingAnotherMapTarget() async throws {
        let sourceMap = mapID(1_130), sourceFrame = frameID(1_130)
        let currentMap = mapID(1_131), currentFrame = frameID(1_131)
        let current = identity(mapID: currentMap, frameID: currentFrame)
        let stored = try metadata(id: objectID(1_130), mapID: sourceMap,
            frameID: sourceFrame, label: "keyboard", position: vec(1, 0, -2))
        let alignment = try alignmentRecord(sourceMapID: sourceMap, sourceFrameID: sourceFrame,
            targetMapID: currentMap, targetFrameID: currentFrame,
            transform: .translation(vec(2, 0, 1)))
        let provider = SuspendedQuerySnapshotProvider()
        let controller = SpatialObjectQueryController(
            snapshotProvider: { map in try await provider.load(currentMapID: map) },
            currentIdentityProvider: { current })
        controller.submit("키보드 어디있어", now: 100)
        try await waitForRequestCount(provider, 1)
        await provider.resume(requestIndex: 0,
            with: snapshot(records: [record(stored, aliases: ["키보드"])], alignments: [alignment]))
        try await waitForIdle(controller)
        let target = try XCTUnwrap(controller.latestGroundedTarget)
        XCTAssertTrue(controller.navigateToSelectedObject(target, now: 101))
        try await waitForRequestCount(provider, 2)
        await provider.resume(requestIndex: 1,
            with: snapshot(records: [record(stored, aliases: ["키보드"])]))
        try await waitForIdle(controller)
        XCTAssertEqual(controller.latestPresentation?.guidanceAvailability, .coordinateAlignmentUnavailable)
        XCTAssertNil(controller.latestGroundedTarget)
        XCTAssertFalse(controller.canNavigateToSelectedObject)
    }

    func testNavigationActionCannotPublishAcrossCaptureTransition() async throws {
        let map = mapID(1_140), frame = frameID(1_140)
        let identityBox = QueryIdentityBox(identity(mapID: map, frameID: frame))
        let stored = try metadata(id: objectID(1_140), mapID: map, frameID: frame, label: "keyboard")
        let provider = SuspendedQuerySnapshotProvider()
        let controller = SpatialObjectQueryController(
            snapshotProvider: { map in try await provider.load(currentMapID: map) },
            currentIdentityProvider: { identityBox.value })
        let records = snapshot(records: [record(stored, aliases: ["키보드"])])
        controller.submit("키보드 어디있어", now: 100)
        try await waitForRequestCount(provider, 1)
        await provider.resume(requestIndex: 0, with: records)
        try await waitForIdle(controller)
        let target = try XCTUnwrap(controller.latestGroundedTarget)
        XCTAssertTrue(controller.navigateToSelectedObject(target, now: 101))
        try await waitForRequestCount(provider, 2)
        identityBox.value = identity(mapID: map, frameID: frameID(1_141))
        await provider.resume(requestIndex: 1, with: records)
        try await waitForIdle(controller)
        XCTAssertNil(controller.latestPresentation)
        XCTAssertNil(controller.latestGroundedTarget)
        XCTAssertFalse(controller.canNavigateToSelectedObject)
    }

    func testClassificationCorrectionKeepsSelectedIDAndNameAndRefreshesSearch() async throws {
        let map = mapID(993), frame = frameID(993)
        let current = identity(mapID: map, frameID: frame)
        let objects = try (0..<2).map { index in
            try metadata(
                id: objectID(993 + index), mapID: map, frameID: frame,
                label: "chair", position: vec(Double(index), 0, -2))
        }
        let store = QueryAnnotationTestStore(objects: objects)
        _ = try await store.rename(objects[0], name: "창가 가구")
        let controller = SpatialObjectQueryController(
            snapshotProvider: { _ in try await store.snapshot() },
            currentIdentityProvider: { current },
            classificationCorrectionProvider: { expected, label in
                try await store.correct(expected, label: label)
            })
        var invalidations = 0
        controller.onObjectRenamed = { invalidations += 1 }
        controller.submit("창가 가구 찾아줘", now: 100)
        try await waitForIdle(controller)
        XCTAssertTrue(controller.canCorrectClassification)
        controller.correctSelectedClassification("table", now: 101)
        try await waitForIdle(controller)
        let corrected = try XCTUnwrap(
            controller.latestPresentation?.result.selectedCandidate?.record.metadata)
        XCTAssertEqual(corrected.object.id, objects[0].object.id)
        XCTAssertEqual(corrected.object.displayName, "창가 가구")
        XCTAssertEqual(corrected.object.semanticLabel, "table")
        XCTAssertEqual(corrected.position, objects[0].position)
        XCTAssertEqual(invalidations, 1)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records[1].metadata, objects[1])
        controller.submit("table 찾아줘", now: 102)
        try await waitForIdle(controller)
        XCTAssertEqual(
            controller.latestPresentation?.result.selectedCandidate?.record.metadata.object.id,
            objects[0].object.id)
    }

    func testClassificationDraftCannotApplyToADifferentSelectedObject() async throws {
        let map = mapID(995), frame = frameID(995)
        let current = identity(mapID: map, frameID: frame)
        let a = try metadata(id: objectID(995), mapID: map, frameID: frame, label: "chair")
        let b = try metadata(id: objectID(996), mapID: map, frameID: frame, label: "table")
        let store = QueryAnnotationTestStore(objects: [a, b])
        let controller = SpatialObjectQueryController(
            snapshotProvider: { _ in try await store.snapshot() },
            currentIdentityProvider: { current },
            classificationCorrectionProvider: { expected, label in
                try await store.correct(expected, label: label)
            })
        controller.submit("chair 찾아줘", now: 100)
        try await waitForIdle(controller)
        let reviewed = try XCTUnwrap(controller.latestPresentation?.result.selectedCandidate?.record.metadata)
        controller.submit("table 찾아줘", now: 101)
        try await waitForIdle(controller)
        controller.correctSelectedClassification("cup", expected: reviewed, now: 102)
        try await waitForIdle(controller)
        let unchanged = try await store.snapshot()
        XCTAssertEqual(unchanged.records.map(\.metadata), [a, b])
        if case .failed = controller.state {} else { XCTFail("Changed selection requires another review") }
    }

    func testManualRegistrationCannotBeReclassifiedOrLoseItsOnlyName() async throws {
        let map = mapID(997), frame = frameID(997)
        let current = identity(mapID: map, frameID: frame)
        let initial = try metadata(id: objectID(997), mapID: map, frameID: frame,
            label: UserObjectRegistrationAccumulator.semanticLabel, presence: .lastSeen)
        let store = QueryAnnotationTestStore(objects: [initial])
        let manual = try await store.rename(initial, name: "내 스피커")
        let subject = SpatialObjectQueryController(
            snapshotProvider: { _ in try await store.snapshot() },
            currentIdentityProvider: { current },
            renameProvider: { expected, name in try await store.rename(expected, name: name) },
            classificationCorrectionProvider: { expected, label in try await store.correct(expected, label: label) })
        subject.submit("내 스피커 찾아줘", now: 100)
        try await waitForIdle(subject)
        let requests = subject.metrics.requestsStarted
        subject.correctSelectedClassification("speaker", now: 101)
        subject.renameSelectedObject(nil, now: 101)
        subject.renameSelectedObject("  ", now: 101)
        try await waitForIdle(subject)
        let persisted = try await store.snapshot()
        XCTAssertEqual(persisted.records.map(\.metadata), [manual])
        XCTAssertEqual(subject.latestPresentation?.result.selectedCandidate?.record.metadata, manual)
        XCTAssertEqual(subject.metrics.requestsStarted, requests)
        let calls = await store.mutationCounts()
        XCTAssertEqual(calls.corrections, 0)
        XCTAssertEqual(calls.renames, 1) // Only the initial test fixture name.
    }

    func testFutureStateTimeKeepsOriginalDateButCannotPublishGuidance() async throws {
        let map = mapID(970), frame = frameID(970)
        let original = try metadata(id: objectID(970), mapID: map, frameID: frame, label: "chair")
        var object = original.object
        object.stateUpdatedAt = 1_000
        let future = try SpatialObjectMetadata(mapID: map, object: object, position: original.position)
        let controller = self.controller(identityBox: QueryIdentityBox(identity(mapID: map, frameID: frame)),
            records: [record(future, aliases: ["의자"])])
        controller.submit("의자 찾아줘", now: 100)
        try await waitForIdle(controller)
        XCTAssertNil(controller.latestGroundedTarget)
        XCTAssertEqual(controller.latestPresentation?.result.status, .lowConfidence)
        XCTAssertEqual(controller.latestPresentation?.result.candidates.first?.record.metadata, future)
        XCTAssertTrue(controller.latestPresentation?.message.contains("기록 시각") == true)
    }

    func testExplicitChoiceAmongThreeCandidatesPublishesOnlyChosenCurrentRecord() async throws {
        let map = mapID(980), frame = frameID(980)
        let current = identity(mapID: map, frameID: frame)
        let records = try (0..<3).map { index in
            record(try metadata(id: objectID(980 + index), mapID: map, frameID: frame,
                label: "chair", position: vec(Double(index), 0, -2)), aliases: ["의자"])
        }
        let controller = self.controller(identityBox: QueryIdentityBox(current), records: records)
        controller.submit("의자 찾아줘", now: 100)
        try await waitForIdle(controller)
        XCTAssertEqual(controller.latestPresentation?.result.status, .ambiguous)
        XCTAssertEqual(controller.latestPresentation?.result.candidates.count, 3)
        XCTAssertNil(controller.latestGroundedTarget)
        controller.selectCandidate(objectID: records[1].metadata.object.id, mapID: map, now: 101)
        try await waitForIdle(controller)
        XCTAssertEqual(controller.latestGroundedTarget?.objectID, records[1].metadata.object.id)
        XCTAssertEqual(controller.latestGroundedTarget?.currentFramePosition, records[1].metadata.position)
    }

    func testLastSeenChoiceCanSelectUnchangedRemovedObjectAmongThreeCandidates() async throws {
        let map = mapID(971), frame = frameID(971)
        let current = identity(mapID: map, frameID: frame)
        let records = try (0..<3).map { index in
            record(try metadata(id: objectID(971 + index), mapID: map, frameID: frame,
                label: "chair", position: vec(Double(index), 0, -2), presence: .removed), aliases: ["의자"])
        }
        let controller = self.controller(identityBox: QueryIdentityBox(current), records: records)
        controller.submit("의자 마지막 위치", now: 100)
        try await waitForIdle(controller)
        XCTAssertEqual(controller.latestPresentation?.result.status, .ambiguous)
        controller.selectCandidate(objectID: records[1].metadata.object.id, mapID: map, now: 101)
        try await waitForIdle(controller)
        XCTAssertEqual(controller.latestGroundedTarget?.objectID, records[1].metadata.object.id)
        XCTAssertEqual(controller.latestGroundedTarget?.intent, .lastSeen)
        XCTAssertEqual(controller.latestPresentation?.result.selectedCandidate?.record.metadata.object.presence, .removed)
    }

    func testCandidateSelectionRechecksMovedAndLowConfidenceRecords() async throws {
        let map = mapID(985), frame = frameID(985)
        let current = identity(mapID: map, frameID: frame)
        let objects = try (0..<3).map { index in
            try metadata(id: objectID(985 + index), mapID: map, frameID: frame,
                label: "chair", position: vec(Double(index), 0, -2))
        }
        for change in 0..<2 {
            let provider = SuspendedQuerySnapshotProvider()
            let controller = SpatialObjectQueryController(snapshotProvider: { map in
                try await provider.load(currentMapID: map)
            }, currentIdentityProvider: { current })
            controller.submit("의자 찾아줘", now: 100)
            try await waitForRequestCount(provider, 1)
            await provider.resume(requestIndex: 0, with: snapshot(records: objects.map { record($0, aliases: ["의자"]) }))
            try await waitForIdle(controller)
            controller.selectCandidate(objectID: objects[1].object.id, mapID: map, now: 101)
            try await waitForRequestCount(provider, 2)
            let changed = try metadata(id: objects[1].object.id, mapID: map, frameID: frame,
                label: "chair", position: change == 0 ? vec(5, 0, -2) : objects[1].position.value,
                confidence: change == 1 ? ConfidenceVector() : objects[1].object.confidence)
            await provider.resume(requestIndex: 1, with: snapshot(records: [record(changed, aliases: ["의자"])]))
            try await waitForIdle(controller)
            XCTAssertNil(controller.latestGroundedTarget)
            if change == 1 { XCTAssertEqual(controller.latestPresentation?.result.status, .lowConfidence) }
            else if case .failed = controller.state {} else { XCTFail("Moved candidate must require another review") }
        }
    }

    func testCaptureTransitionWhileSelectingCannotPublishOldFrame() async throws {
        let map = mapID(989), frame = frameID(989)
        let identityBox = QueryIdentityBox(identity(mapID: map, frameID: frame))
        let objects = try (0..<3).map { index in
            record(try metadata(id: objectID(989 + index), mapID: map, frameID: frame, label: "chair"), aliases: ["의자"])
        }
        let provider = SuspendedQuerySnapshotProvider()
        let controller = SpatialObjectQueryController(snapshotProvider: { map in
            try await provider.load(currentMapID: map)
        }, currentIdentityProvider: { identityBox.value })
        controller.submit("의자 찾아줘", now: 100)
        try await waitForRequestCount(provider, 1)
        await provider.resume(requestIndex: 0, with: snapshot(records: objects))
        try await waitForIdle(controller)
        controller.selectCandidate(objectID: objects[1].metadata.object.id, mapID: map, now: 101)
        try await waitForRequestCount(provider, 2)
        identityBox.value = identity(mapID: map, frameID: frameID(999))
        await provider.resume(requestIndex: 1, with: snapshot(records: objects))
        try await waitForIdle(controller)
        XCTAssertNil(controller.latestGroundedTarget)
        XCTAssertNil(controller.latestPresentation)
    }

    func testRenamingSelectedCandidateRevalidatesAndSearchesItsAlias() async throws {
        let map = mapID(975), frame = frameID(975)
        let current = identity(mapID: map, frameID: frame)
        let objects = try (0..<3).map { index in
            try metadata(id: objectID(975 + index), mapID: map, frameID: frame,
                label: "chair", position: vec(Double(index), 0, -2))
        }
        let store = QueryAnnotationTestStore(objects: objects)
        let controller = SpatialObjectQueryController(snapshotProvider: { _ in try await store.snapshot() },
            currentIdentityProvider: { current }, renameProvider: { expected, name in
                try await store.rename(expected, name: name)
            })
        var invalidations = 0
        controller.onObjectRenamed = { invalidations += 1 }
        controller.submit("chair", now: 100)
        try await waitForIdle(controller)
        controller.selectCandidate(objectID: objects[1].object.id, mapID: map, now: 101)
        try await waitForIdle(controller)
        controller.renameSelectedObject("창가 의자", now: 102)
        XCTAssertNil(controller.latestGroundedTarget)
        try await waitForIdle(controller)
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(controller.latestPresentation?.result.selectedCandidate?.record.metadata.object.displayName, "창가 의자")
        XCTAssertEqual(controller.latestGroundedTarget?.objectID, objects[1].object.id)
        controller.submit("창가 의자 찾아줘", now: 103)
        try await waitForIdle(controller)
        XCTAssertEqual(controller.latestGroundedTarget?.objectID, objects[1].object.id)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records[0].metadata, objects[0])
        XCTAssertEqual(snapshot.records[2].metadata, objects[2])
        XCTAssertEqual(snapshot.records[1].metadata.position, objects[1].position)
    }

    func testSearchFindsAnObjectBeyondTheFormer512RecordLimit() async throws {
        let map = mapID(990)
        let frame = frameID(990)
        let current = identity(mapID: map, frameID: frame)
        var objects = try (0..<520).map { index in
            try metadata(id: objectID(index), mapID: map, frameID: frame, label: "chair", lastSeenAt: 100)
        }
        let target = try metadata(id: objectID(600), mapID: map, frameID: frame, label: "laptop", lastSeenAt: 99)
        objects.append(target)
        let allObjects = objects
        let repository = SpatialObjectQueryRepository(
            metadataProvider: { SpatialMetadataDocument(objects: allObjects) },
            alignmentCatalogProvider: { try CoordinateAlignmentCatalogSnapshot() }
        )
        let controller = SpatialObjectQueryController(repository: repository, currentIdentityProvider: { current })
        controller.submit("노트북 어디 있어", now: 101)
        let deadline = Date().addingTimeInterval(5)
        while controller.isProcessingForTesting, Date() < deadline { await Task.yield() }
        XCTAssertFalse(controller.isProcessingForTesting)
        XCTAssertEqual(controller.latestPresentation?.result.selectedCandidate?.record.metadata.object.id, target.object.id)
    }
    func testAliasCatalogIsSymmetricSanitizedAndBounded() {
        let defaults = SpatialObjectAliasCatalog.koreanEnglishDefaults
        XCTAssertTrue(defaults.aliases(for: " laptop ").contains("노트북"))
        XCTAssertTrue(defaults.aliases(for: "노트북").contains("laptop"))

        var entries: [String: [String]] = [:]
        for index in 0..<(SpatialObjectAliasCatalog.maximumCanonicalLabelCount + 20) {
            entries[String(format: "label-%03d", index)] =
                (0..<20).map {
                    "alias-\(index)-\($0)"
                } + ["", String(repeating: "x", count: 100)]
        }
        let bounded = SpatialObjectAliasCatalog(entries: entries)

        XCTAssertEqual(
            bounded.canonicalLabelCount,
            SpatialObjectAliasCatalog.maximumCanonicalLabelCount
        )
        XCTAssertEqual(
            bounded.aliases(for: "label-000").count,
            SpatialObjectAliasCatalog.maximumAliasesPerLabel
        )
        XCTAssertTrue(bounded.aliases(for: "label-999").isEmpty)
    }

    func testRepositoryAliasCatalogCoversEveryModelClassAndLegacySynonym() {
        let aliases = SpatialObjectAliasCatalog.koreanEnglishDefaults
        for entry in ObjectSemanticCatalog.default.entries {
            for term in entry.searchTerms {
                if term != entry.koreanName {
                    XCTAssertTrue(aliases.aliases(for: term).contains(entry.koreanName), term)
                }
                if term != entry.canonicalLabel {
                    XCTAssertTrue(aliases.aliases(for: term).contains(entry.canonicalLabel), term)
                }
            }
        }
        XCTAssertTrue(aliases.aliases(for: "tvmonitor").contains("모니터"))
        XCTAssertTrue(aliases.aliases(for: "diningtable").contains("식탁"))
        XCTAssertTrue(aliases.aliases(for: "pottedplant").contains("화분"))
    }

    func testScreenshotQueryExplainsUnseenObjectWithoutLanguageFailureOrGuidance() async throws {
        let box = QueryIdentityBox(identity(mapID: mapID(78), frameID: frameID(78)))
        let subject = controller(identityBox: box, records: [])
        subject.submit("키보드 어디있어?", now: 100)
        try await waitForIdle(subject)
        let presentation = try XCTUnwrap(subject.latestPresentation)
        XCTAssertEqual(presentation.result.issues, [.objectNotYetObserved])
        XCTAssertTrue(presentation.message.contains("키보드"))
        XCTAssertTrue(presentation.message.contains("아직 저장된 위치가 없"))
        XCTAssertFalse(presentation.message.contains("이해하지 못"))
        XCTAssertNil(subject.latestGroundedTarget)
        XCTAssertFalse(presentation.canStartARGuidance)
    }

    func testUnsupportedClassExplainsManualRegistrationWithoutInventingLocation() async throws {
        let box = QueryIdentityBox(identity(mapID: mapID(79), frameID: frameID(79)))
        let subject = controller(identityBox: box, records: [])
        subject.submit("스피커어디있어?", now: 100)
        try await waitForIdle(subject)
        let presentation = try XCTUnwrap(subject.latestPresentation)
        XCTAssertEqual(presentation.result.issues, [.automaticDetectionUnsupported])
        XCTAssertTrue(presentation.message.contains("자동 인식 모델이 지원하지 않는"))
        XCTAssertTrue(presentation.message.contains("직접 지정"))
        XCTAssertTrue(presentation.result.candidates.isEmpty)
        XCTAssertNil(subject.latestGroundedTarget)
    }

    func testRepositoryAndControllerFindActualLegacyMonitorLabelInKorean() async throws {
        let map = mapID(80)
        let frame = frameID(80)
        let stored = try metadata(id: objectID(80), mapID: map, frameID: frame, label: "tvmonitor")
        let repository = SpatialObjectQueryRepository(
            metadataProvider: { SpatialMetadataDocument(objects: [stored]) },
            alignmentCatalogProvider: { try CoordinateAlignmentCatalogSnapshot() })
        let current = identity(mapID: map, frameID: frame)
        let subject = SpatialObjectQueryController(repository: repository, currentIdentityProvider: { current })
        subject.submit("모니터어디있어?", now: 100)
        try await waitForIdle(subject)
        XCTAssertEqual(subject.latestPresentation?.result.status, .found)
        XCTAssertEqual(subject.latestGroundedTarget?.objectID, stored.object.id)
        XCTAssertTrue(subject.latestPresentation?.message.contains("모니터") == true)
    }

    func testRepositoryMapsCurrentVisibleLocalAndHistoricalObjectsToMemoryTiers() async throws {
        let currentMap = mapID(1)
        let currentFrame = frameID(1)
        let otherMap = mapID(2)
        let otherFrame = frameID(2)
        let visible = try metadata(
            id: objectID(1),
            mapID: currentMap,
            frameID: currentFrame,
            label: "laptop",
            presence: .visible,
            lastSeenAt: 30
        )
        let hidden = try metadata(
            id: objectID(2),
            mapID: currentMap,
            frameID: currentFrame,
            label: "chair",
            presence: .lastSeen,
            lastSeenAt: 20
        )
        let historical = try metadata(
            id: objectID(3),
            mapID: otherMap,
            frameID: otherFrame,
            label: "wallet",
            presence: .lastSeen,
            lastSeenAt: 10
        )
        let repository = SpatialObjectQueryRepository(
            metadataProvider: {
                SpatialMetadataDocument(objects: [historical, hidden, visible])
            },
            alignmentCatalogProvider: {
                try CoordinateAlignmentCatalogSnapshot()
            }
        )

        let snapshot = try await repository.loadSnapshot(currentMapID: currentMap)

        XCTAssertEqual(
            snapshot.records.map(\.metadata.object.id),
            [
                visible.object.id, hidden.object.id, historical.object.id,
            ])
        XCTAssertEqual(
            snapshot.records.map(\.memoryTier),
            [
                .realtime, .localMap, .longTerm,
            ])
        XCTAssertTrue(snapshot.records[0].semanticAliases.contains("노트북"))
    }

    func testRepositoryNeverTruncatesHistoricalRecordsBeforeSearch() async throws {
        let currentMap = mapID(10)
        let currentFrame = frameID(10)
        let other = try metadata(
            id: objectID(10),
            mapID: mapID(11),
            frameID: frameID(11),
            label: "other",
            lastSeenAt: 100
        )
        let current = try metadata(
            id: objectID(11),
            mapID: currentMap,
            frameID: currentFrame,
            label: "current",
            lastSeenAt: 1
        )
        let repository = SpatialObjectQueryRepository(
            metadataProvider: {
                SpatialMetadataDocument(objects: [other, current])
            },
            alignmentCatalogProvider: {
                try CoordinateAlignmentCatalogSnapshot()
            }
        )

        let snapshot = try await repository.loadSnapshot(currentMapID: currentMap)

        XCTAssertEqual(snapshot.records.map(\.metadata.object.id), [current.object.id, other.object.id])
    }

    func testExactCurrentFrameReturnsPersistedPositionWithoutAlignment() throws {
        let map = mapID(20)
        let frame = frameID(20)
        let stored = try metadata(
            id: objectID(20),
            mapID: map,
            frameID: frame,
            label: "chair",
            position: vec(1.5, 0.4, -2)
        )
        let identity = identity(mapID: map, frameID: frame)

        let resolved = ValidatedCurrentFramePositionResolver().resolve(
            stored,
            into: identity,
            using: try CoordinateAlignmentCatalogSnapshot()
        )

        XCTAssertEqual(resolved?.source, stored.position)
        XCTAssertEqual(resolved?.currentFramePosition, stored.position)
        XCTAssertNil(resolved?.alignmentConfidence)
        XCTAssertEqual(resolved?.mapPath, [map])
    }

    func testUnconfirmedCaptureNeverReturnsARGuidanceCoordinate() throws {
        let stored = try metadata(
            id: objectID(21),
            mapID: mapID(21),
            frameID: frameID(21),
            label: "chair"
        )
        let current = ARCaptureIdentity(
            coordinateFrameID: stored.position.coordinateFrameID,
            segmentID: CaptureSegmentID(),
            mapID: stored.mapID,
            status: .relocalizing
        )

        XCTAssertNil(
            ValidatedCurrentFramePositionResolver().resolve(
                stored,
                into: current,
                using: try CoordinateAlignmentCatalogSnapshot()
            )
        )
    }

    func testDirectValidatedAlignmentTransformsStoredCoordinateIntoCurrentFrame() throws {
        let sourceMap = mapID(30)
        let targetMap = mapID(31)
        let sourceFrame = frameID(30)
        let targetFrame = frameID(31)
        let translation = vec(3, 0.5, -2)
        let stored = try metadata(
            id: objectID(30),
            mapID: sourceMap,
            frameID: sourceFrame,
            label: "laptop",
            position: vec(1, 1, 1)
        )
        let record = try alignmentRecord(
            sourceMapID: sourceMap,
            sourceFrameID: sourceFrame,
            targetMapID: targetMap,
            targetFrameID: targetFrame,
            transform: .translation(translation)
        )

        let resolved = ValidatedCurrentFramePositionResolver().resolve(
            stored,
            into: identity(mapID: targetMap, frameID: targetFrame),
            using: try CoordinateAlignmentCatalogSnapshot(alignments: [record])
        )

        XCTAssertEqual(resolved?.mapPath, [sourceMap, targetMap])
        XCTAssertLessThan(
            try XCTUnwrap(resolved).currentFramePosition.value.distance(
                to: vec(4, 1.5, -1)
            ),
            1e-9
        )
        XCTAssertEqual(resolved?.currentFramePosition.coordinateFrameID, targetFrame)
        XCTAssertGreaterThan(
            try XCTUnwrap(resolved?.alignmentConfidence).value,
            0.999_999
        )
    }

    func testReverseValidatedAlignmentUsesRigidInverse() throws {
        let lowMap = mapID(40)
        let highMap = mapID(41)
        let lowFrame = frameID(40)
        let highFrame = frameID(41)
        let transform = rigidTransform(
            yaw: .pi / 2,
            translation: vec(5, 1, -3)
        )
        let record = try alignmentRecord(
            sourceMapID: lowMap,
            sourceFrameID: lowFrame,
            targetMapID: highMap,
            targetFrameID: highFrame,
            transform: transform
        )
        let originalLowPosition = vec(2, 0.5, -1)
        let storedHighPosition = try transform.transformed(originalLowPosition)
        let stored = try metadata(
            id: objectID(40),
            mapID: highMap,
            frameID: highFrame,
            label: "chair",
            position: storedHighPosition
        )

        let resolved = ValidatedCurrentFramePositionResolver().resolve(
            stored,
            into: identity(mapID: lowMap, frameID: lowFrame),
            using: try CoordinateAlignmentCatalogSnapshot(alignments: [record])
        )

        XCTAssertLessThan(
            try XCTUnwrap(resolved).position.distance(to: originalLowPosition),
            1e-9
        )
    }

    func testValidatedMultiHopPathComposesTransformsInCorrectOrder() throws {
        let mapA = mapID(50)
        let mapB = mapID(51)
        let mapC = mapID(52)
        let frameA = frameID(50)
        let frameB = frameID(51)
        let frameC = frameID(52)
        let aToB = Transform3D.translation(vec(2, 0, 0))
        let bToC = rigidTransform(yaw: .pi / 2, translation: vec(0, 1, -4))
        let stored = try metadata(
            id: objectID(50),
            mapID: mapA,
            frameID: frameA,
            label: "wallet",
            position: vec(1, 2, 3)
        )
        let records = [
            try alignmentRecord(
                sourceMapID: mapA,
                sourceFrameID: frameA,
                targetMapID: mapB,
                targetFrameID: frameB,
                transform: aToB
            ),
            try alignmentRecord(
                sourceMapID: mapB,
                sourceFrameID: frameB,
                targetMapID: mapC,
                targetFrameID: frameC,
                transform: bToC
            ),
        ]
        let expected = try (bToC * aToB).transformed(stored.position.value)

        let resolved = ValidatedCurrentFramePositionResolver().resolve(
            stored,
            into: identity(mapID: mapC, frameID: frameC),
            using: try CoordinateAlignmentCatalogSnapshot(alignments: records)
        )

        XCTAssertEqual(resolved?.mapPath, [mapA, mapB, mapC])
        XCTAssertLessThan(try XCTUnwrap(resolved).position.distance(to: expected), 1e-9)
    }

    func testMissingOrFrameMismatchedAlignmentReturnsNoCoordinate() throws {
        let sourceMap = mapID(60)
        let targetMap = mapID(61)
        let sourceFrame = frameID(60)
        let targetFrame = frameID(61)
        let stored = try metadata(
            id: objectID(60),
            mapID: sourceMap,
            frameID: sourceFrame,
            label: "laptop"
        )
        let record = try alignmentRecord(
            sourceMapID: sourceMap,
            sourceFrameID: sourceFrame,
            targetMapID: targetMap,
            targetFrameID: targetFrame,
            transform: .translation(vec(1, 0, 0))
        )
        let resolver = ValidatedCurrentFramePositionResolver()

        XCTAssertNil(
            resolver.resolve(
                stored,
                into: identity(mapID: targetMap, frameID: targetFrame),
                using: try CoordinateAlignmentCatalogSnapshot()
            )
        )
        XCTAssertNil(
            resolver.resolve(
                stored,
                into: identity(mapID: targetMap, frameID: frameID(999)),
                using: try CoordinateAlignmentCatalogSnapshot(alignments: [record])
            )
        )
    }

    func testControllerPublishesGroundedTargetForKoreanFindIntent() async throws {
        let currentMap = mapID(70)
        let currentFrame = frameID(70)
        let laptop = try metadata(
            id: objectID(70),
            mapID: currentMap,
            frameID: currentFrame,
            label: "laptop",
            position: vec(1.2, 0.7, -2)
        )
        let identityBox = QueryIdentityBox(
            identity(mapID: currentMap, frameID: currentFrame)
        )
        let controller = controller(
            identityBox: identityBox,
            records: [record(laptop, aliases: ["노트북"])]
        )

        controller.submit("내 노트북을 찾아줘", now: 100)
        try await waitForIdle(controller)

        let presentation = try XCTUnwrap(controller.latestPresentation)
        let target = try XCTUnwrap(controller.latestGroundedTarget)
        XCTAssertEqual(presentation.result.status, .found)
        XCTAssertEqual(presentation.result.route.kind, .searchObject)
        XCTAssertEqual(presentation.guidanceAvailability, .ready)
        XCTAssertTrue(presentation.canStartARGuidance)
        XCTAssertTrue(presentation.message.contains("AR 안내"))
        XCTAssertEqual(target.semanticLabel, "laptop")
        XCTAssertEqual(target.objectID, laptop.object.id)
        XCTAssertEqual(target.sourceMapID, currentMap)
        XCTAssertEqual(target.currentMapID, currentMap)
        XCTAssertEqual(target.position, laptop.position.value)
        XCTAssertEqual(target.currentCoordinateFrameID, currentFrame)
    }

    func testControllerFindsHistoricalRecordButWithholdsUnalignedCoordinate() async throws {
        let historical = try metadata(
            id: objectID(80),
            mapID: mapID(80),
            frameID: frameID(80),
            label: "wallet",
            presence: .lastSeen
        )
        let identityBox = QueryIdentityBox(
            identity(mapID: mapID(81), frameID: frameID(81))
        )
        let controller = controller(
            identityBox: identityBox,
            records: [record(historical, aliases: ["지갑"])]
        )

        controller.submit("지갑이 어디 있어?", now: 100)
        try await waitForIdle(controller)

        let presentation = try XCTUnwrap(controller.latestPresentation)
        XCTAssertEqual(presentation.result.status, .found)
        XCTAssertEqual(
            presentation.guidanceAvailability,
            .coordinateAlignmentUnavailable
        )
        XCTAssertNil(presentation.currentFramePosition)
        XCTAssertNil(controller.latestGroundedTarget)
        XCTAssertTrue(presentation.message.contains("좌표 연결"))
    }

    func testControllerPublishesTransformedTargetForValidatedOtherMap() async throws {
        let sourceMap = mapID(90)
        let currentMap = mapID(91)
        let sourceFrame = frameID(90)
        let currentFrame = frameID(91)
        let stored = try metadata(
            id: objectID(90),
            mapID: sourceMap,
            frameID: sourceFrame,
            label: "chair",
            position: vec(1, 0, 2)
        )
        let alignment = try alignmentRecord(
            sourceMapID: sourceMap,
            sourceFrameID: sourceFrame,
            targetMapID: currentMap,
            targetFrameID: currentFrame,
            transform: .translation(vec(4, 0.5, -1))
        )
        let identityBox = QueryIdentityBox(
            identity(mapID: currentMap, frameID: currentFrame)
        )
        let controller = controller(
            identityBox: identityBox,
            records: [record(stored, aliases: ["의자"])],
            alignments: [alignment]
        )

        controller.submit("의자까지 안내해줘", now: 100)
        try await waitForIdle(controller)

        let target = try XCTUnwrap(controller.latestGroundedTarget)
        XCTAssertEqual(target.intent, .navigate)
        XCTAssertEqual(target.sourceCoordinateFrameID, sourceFrame)
        XCTAssertEqual(target.currentCoordinateFrameID, currentFrame)
        XCTAssertLessThan(target.position.distance(to: vec(5, 0.5, 1)), 1e-9)
        XCTAssertGreaterThan(
            try XCTUnwrap(target.alignmentConfidence).value,
            0.999_999
        )
    }

    func testLastSeenIntentIncludesRemovedObjectButNeverInventsCoordinate() async throws {
        let stored = try metadata(
            id: objectID(100),
            mapID: mapID(100),
            frameID: frameID(100),
            label: "wallet",
            presence: .removed
        )
        let identityBox = QueryIdentityBox(
            identity(mapID: mapID(101), frameID: frameID(101))
        )
        let controller = controller(
            identityBox: identityBox,
            records: [record(stored, aliases: ["지갑"])]
        )

        controller.submit("지갑을 마지막으로 어디에서 봤어?", now: 100)
        try await waitForIdle(controller)

        let presentation = try XCTUnwrap(controller.latestPresentation)
        XCTAssertEqual(presentation.result.route.kind, .lastSeen)
        XCTAssertEqual(presentation.result.status, .found)
        XCTAssertEqual(presentation.result.candidates.first?.record.metadata, stored)
        XCTAssertNil(controller.latestGroundedTarget)
    }

    func testLowConfidenceAmbiguousAndUnsupportedResultsNeverExposeTarget() async throws {
        let map = mapID(110)
        let frame = frameID(110)
        let weak = try metadata(
            id: objectID(110),
            mapID: map,
            frameID: frame,
            label: "remote",
            confidence: confidence(0.3)
        )
        let identityBox = QueryIdentityBox(identity(mapID: map, frameID: frame))
        let lowController = controller(
            identityBox: identityBox,
            records: [record(weak, aliases: ["리모컨"])]
        )

        lowController.submit("리모컨 찾아줘", now: 100)
        try await waitForIdle(lowController)
        XCTAssertEqual(lowController.latestPresentation?.result.status, .lowConfidence)
        XCTAssertNil(lowController.latestGroundedTarget)

        let first = try metadata(
            id: objectID(111),
            mapID: map,
            frameID: frame,
            label: "chair",
            position: vec(1, 0, 0)
        )
        let second = try metadata(
            id: objectID(112),
            mapID: map,
            frameID: frame,
            label: "chair",
            position: vec(2, 0, 0)
        )
        let ambiguousController = controller(
            identityBox: identityBox,
            records: [record(first, aliases: ["의자"]), record(second, aliases: ["의자"])]
        )
        ambiguousController.submit("의자 어디 있어?", now: 100)
        try await waitForIdle(ambiguousController)
        XCTAssertEqual(
            ambiguousController.latestPresentation?.result.status,
            .ambiguous
        )
        XCTAssertNil(ambiguousController.latestGroundedTarget)

        let unsupportedController = controller(
            identityBox: identityBox,
            records: [record(first, aliases: ["의자"])]
        )
        unsupportedController.submit("의자를 여기에 놓으면 어때?", now: 100)
        try await waitForIdle(unsupportedController)
        XCTAssertEqual(
            unsupportedController.latestPresentation?.result.status,
            .unsupportedIntent
        )
        XCTAssertNil(unsupportedController.latestGroundedTarget)
    }

    func testConfiguredSearchResultLimitIsRespected() async throws {
        let map = mapID(120)
        let frame = frameID(120)
        let records = try (0..<5).map { index in
            record(
                try metadata(
                    id: objectID(120 + index),
                    mapID: map,
                    frameID: frame,
                    label: "bottle",
                    position: vec(Double(index), 0, 0)
                ),
                aliases: ["물병"]
            )
        }
        let policy = try SpatialObjectSearchPolicy(maximumResultCount: 2)
        let identityBox = QueryIdentityBox(identity(mapID: map, frameID: frame))
        let controller = controller(
            identityBox: identityBox,
            records: records,
            searchEngine: DeterministicSpatialObjectSearchEngine(policy: policy)
        )

        controller.submit("물병 찾아줘", now: 100)
        try await waitForIdle(controller)

        XCTAssertEqual(controller.latestPresentation?.result.candidates.count, 2)
        XCTAssertEqual(controller.latestPresentation?.result.status, .ambiguous)
        XCTAssertNil(controller.latestGroundedTarget)
    }

    func testNewerRequestWinsWhenProvidersCompleteOutOfOrder() async throws {
        let map = mapID(130)
        let frame = frameID(130)
        let chair = try metadata(
            id: objectID(130),
            mapID: map,
            frameID: frame,
            label: "chair"
        )
        let laptop = try metadata(
            id: objectID(131),
            mapID: map,
            frameID: frame,
            label: "laptop"
        )
        let provider = SuspendedQuerySnapshotProvider()
        let identityBox = QueryIdentityBox(identity(mapID: map, frameID: frame))
        let controller = SpatialObjectQueryController(
            snapshotProvider: { mapID in
                try await provider.load(currentMapID: mapID)
            },
            currentIdentityProvider: { identityBox.value }
        )

        controller.submit("의자 찾아줘", now: 100)
        try await waitForRequestCount(provider, 1)
        controller.submit("노트북 찾아줘", now: 101)
        try await waitForRequestCount(provider, 2)

        await provider.resume(
            requestIndex: 1,
            with: snapshot(records: [
                record(chair, aliases: ["의자"]),
                record(laptop, aliases: ["노트북"]),
            ])
        )
        try await waitForIdle(controller)
        XCTAssertEqual(controller.latestGroundedTarget?.objectID, laptop.object.id)

        await provider.resume(
            requestIndex: 0,
            with: snapshot(records: [record(chair, aliases: ["의자"])])
        )
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(controller.latestGroundedTarget?.objectID, laptop.object.id)
        XCTAssertEqual(controller.metrics.requestsCancelled, 1)
        XCTAssertGreaterThanOrEqual(controller.metrics.staleResultsRejected, 1)
    }

    func testObservationRefreshCoalescesAndRetriesOnlyTheSubmittedQuery() async throws {
        let map = mapID(132)
        let frame = frameID(132)
        let keyboard = try metadata(id: objectID(132), mapID: map, frameID: frame, label: "keyboard")
        let provider = SuspendedQuerySnapshotProvider()
        let box = QueryIdentityBox(identity(mapID: map, frameID: frame))
        let subject = SpatialObjectQueryController(
            snapshotProvider: { try await provider.load(currentMapID: $0) },
            currentIdentityProvider: { box.value })
        subject.submit("키보드 어디있어?", now: 100)
        try await waitForRequestCount(provider, 1)
        subject.refreshUnresolvedQueryAfterObservation(now: 101)
        subject.refreshUnresolvedQueryAfterObservation(now: 102)
        subject.refreshUnresolvedQueryAfterObservation(now: 103)
        await provider.resume(requestIndex: 0, with: snapshot(records: []))
        try await waitForRequestCount(provider, 2)
        await provider.resume(requestIndex: 1, with: snapshot(records: [record(keyboard)]))
        try await waitForIdle(subject)
        XCTAssertEqual(subject.latestGroundedTarget?.objectID, keyboard.object.id)
        XCTAssertEqual(subject.metrics.requestsStarted, 2)
        subject.refreshUnresolvedQueryAfterObservation(now: 104)
        XCTAssertEqual(subject.metrics.requestsStarted, 2)
    }

    func testNewExplicitQueryClearsPendingObservationRefresh() async throws {
        let provider = SuspendedQuerySnapshotProvider()
        let box = QueryIdentityBox(identity(mapID: mapID(133), frameID: frameID(133)))
        let subject = SpatialObjectQueryController(
            snapshotProvider: { try await provider.load(currentMapID: $0) },
            currentIdentityProvider: { box.value })
        subject.submit("키보드 찾아줘", now: 100)
        try await waitForRequestCount(provider, 1)
        subject.refreshUnresolvedQueryAfterObservation(now: 101)
        subject.submit("마우스 찾아줘", now: 102)
        try await waitForRequestCount(provider, 2)
        await provider.resume(requestIndex: 0, with: snapshot(records: []))
        await provider.resume(requestIndex: 1, with: snapshot(records: []))
        try await waitForIdle(subject)
        XCTAssertEqual(subject.metrics.requestsStarted, 2)
        XCTAssertEqual(subject.latestPresentation?.result.matchedSemanticLabels, ["mouse"])
    }

    func testCancelledOrUnsupportedQueryDoesNotRefreshAfterObservation() async throws {
        let provider = SuspendedQuerySnapshotProvider()
        let box = QueryIdentityBox(identity(mapID: mapID(134), frameID: frameID(134)))
        let subject = SpatialObjectQueryController(
            snapshotProvider: { try await provider.load(currentMapID: $0) },
            currentIdentityProvider: { box.value })
        subject.submit("키보드 찾아줘", now: 100)
        try await waitForRequestCount(provider, 1)
        subject.refreshUnresolvedQueryAfterObservation(now: 101)
        subject.invalidateForCaptureTransition()
        await provider.resume(requestIndex: 0, with: snapshot(records: []))
        await subject.invalidateAndWaitForPendingWork()
        subject.refreshUnresolvedQueryAfterObservation(now: 102)
        XCTAssertEqual(subject.metrics.requestsStarted, 1)
        XCTAssertNil(subject.latestPresentation)

        subject.submit("스피커 찾아줘", now: 103)
        try await waitForRequestCount(provider, 2)
        subject.refreshUnresolvedQueryAfterObservation(now: 104)
        await provider.resume(requestIndex: 1, with: snapshot(records: []))
        try await waitForIdle(subject)
        XCTAssertEqual(subject.latestPresentation?.result.issues, [.automaticDetectionUnsupported])
        XCTAssertEqual(subject.metrics.requestsStarted, 2)
    }

    func testExplicitCandidateSelectionCannotBeReplacedByObservationRefresh() async throws {
        let map = mapID(135)
        let frame = frameID(135)
        let objects = try (0..<2).map {
            record(try metadata(id: objectID(135 + $0), mapID: map, frameID: frame, label: "chair"))
        }
        let subject = controller(identityBox: QueryIdentityBox(identity(mapID: map, frameID: frame)), records: objects)
        subject.submit("의자 찾아줘", now: 100)
        try await waitForIdle(subject)
        XCTAssertEqual(subject.latestPresentation?.result.status, .ambiguous)
        subject.selectCandidate(objectID: objects[1].metadata.object.id, mapID: map, now: 101)
        subject.refreshUnresolvedQueryAfterObservation(now: 102)
        try await waitForIdle(subject)
        XCTAssertEqual(subject.latestGroundedTarget?.objectID, objects[1].metadata.object.id)
        XCTAssertEqual(subject.metrics.requestsStarted, 2)
    }

    func testCancellationAndCaptureIdentityChangeRejectLateResults() async throws {
        let map = mapID(140)
        let frame = frameID(140)
        let laptop = try metadata(
            id: objectID(140),
            mapID: map,
            frameID: frame,
            label: "laptop"
        )
        let provider = SuspendedQuerySnapshotProvider()
        let identityBox = QueryIdentityBox(identity(mapID: map, frameID: frame))
        let controller = SpatialObjectQueryController(
            snapshotProvider: { mapID in
                try await provider.load(currentMapID: mapID)
            },
            currentIdentityProvider: { identityBox.value }
        )

        controller.submit("노트북 찾아줘", now: 100)
        try await waitForRequestCount(provider, 1)
        controller.cancelCurrentQuery()
        await provider.resume(
            requestIndex: 0,
            with: snapshot(records: [record(laptop, aliases: ["노트북"])])
        )
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.latestGroundedTarget)

        controller.submit("노트북 찾아줘", now: 101)
        try await waitForRequestCount(provider, 2)
        identityBox.value = identity(mapID: mapID(141), frameID: frameID(141))
        await provider.resume(
            requestIndex: 1,
            with: snapshot(records: [record(laptop, aliases: ["노트북"])])
        )
        try await waitForIdle(controller)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.latestPresentation)
        XCTAssertNil(controller.latestGroundedTarget)
    }

    func testInvalidateAndWaitAlsoWaitsForReplacedSnapshotRead() async throws {
        let map = mapID(145)
        let frame = frameID(145)
        let laptop = try metadata(
            id: objectID(145),
            mapID: map,
            frameID: frame,
            label: "laptop"
        )
        let provider = SuspendedQuerySnapshotProvider()
        let completion = QueryDeletionBarrierCompletion()
        let identityBox = QueryIdentityBox(identity(mapID: map, frameID: frame))
        let controller = SpatialObjectQueryController(
            snapshotProvider: { mapID in
                try await provider.load(currentMapID: mapID)
            },
            currentIdentityProvider: { identityBox.value }
        )

        controller.submit("노트북 찾아줘", now: 100)
        try await waitForRequestCount(provider, 1)
        controller.submit("노트북 찾아줘", now: 101)
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
        XCTAssertNil(controller.latestGroundedTarget)

        // Finishing the visible request must not hide the cancelled, older read.
        await provider.resume(
            requestIndex: 1,
            with: snapshot(records: [record(laptop, aliases: ["노트북"])])
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
            requestIndex: 0,
            with: snapshot(records: [record(laptop, aliases: ["노트북"])])
        )
        await barrierTask.value

        let finishedAfterProviderReleased = await completion.isFinished
        XCTAssertTrue(finishedAfterProviderReleased)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.latestPresentation)
        XCTAssertNil(controller.latestGroundedTarget)
        XCTAssertEqual(controller.metrics.resultsPublished, 0)
        XCTAssertEqual(controller.metrics.requestsCancelled, 2)
        XCTAssertEqual(controller.metrics.staleResultsRejected, 2)
    }

    func testRepositoryFailurePublishesSafeKoreanError() async throws {
        enum TestError: Error { case unavailable }
        let identityBox = QueryIdentityBox(identity(mapID: mapID(150), frameID: frameID(150)))
        let controller = SpatialObjectQueryController(
            snapshotProvider: { _ in throw TestError.unavailable },
            currentIdentityProvider: { identityBox.value }
        )

        controller.submit("노트북 찾아줘", now: 100)
        try await waitForIdle(controller)

        guard case .failed(let message) = controller.state else {
            return XCTFail("Expected a safe failure state.")
        }
        XCTAssertTrue(message.contains("공간 정보"))
        XCTAssertFalse(message.contains("unavailable"))
        XCTAssertNil(controller.latestGroundedTarget)
        XCTAssertEqual(controller.metrics.failuresPublished, 1)
    }

    private func controller(
        identityBox: QueryIdentityBox,
        records: [StoredSpatialObjectRecord],
        alignments: [CoordinateAlignmentRecord] = [],
        searchEngine: DeterministicSpatialObjectSearchEngine =
            DeterministicSpatialObjectSearchEngine()
    ) -> SpatialObjectQueryController {
        let value = snapshot(records: records, alignments: alignments)
        return SpatialObjectQueryController(
            snapshotProvider: { _ in value },
            currentIdentityProvider: { identityBox.value },
            searchEngine: searchEngine
        )
    }

    private func snapshot(
        records: [StoredSpatialObjectRecord],
        alignments: [CoordinateAlignmentRecord] = []
    ) -> SpatialObjectQueryRepositorySnapshot {
        SpatialObjectQueryRepositorySnapshot(
            records: records,
            alignmentCatalog: try! CoordinateAlignmentCatalogSnapshot(
                alignments: alignments
            )
        )
    }

    private func record(
        _ metadata: SpatialObjectMetadata,
        tier: MemoryTier = .longTerm,
        aliases: [String] = []
    ) -> StoredSpatialObjectRecord {
        StoredSpatialObjectRecord(
            metadata: metadata,
            memoryTier: tier,
            semanticAliases: aliases
        )
    }

    private func metadata(
        id: ObjectID,
        mapID: MapID,
        frameID: CoordinateFrameID,
        label: String,
        position: Vec3 = .zero,
        certainty: ObjectCertainty = .confirmed,
        presence: ObjectPresence = .visible,
        confidence: ConfidenceVector = ConfidenceVector(
            semantic: .one,
            geometry: .one,
            tracking: .one,
            identity: .one,
            objectState: .one
        ),
        lastSeenAt: TimeInterval = 10
    ) throws -> SpatialObjectMetadata {
        let object = try SpatialObject(
            id: id,
            semanticLabel: label,
            position: position,
            certainty: certainty,
            presence: presence,
            confidence: confidence,
            firstSeenAt: min(1, lastSeenAt),
            lastSeenAt: lastSeenAt
        )
        return try SpatialObjectMetadata(
            mapID: mapID,
            object: object,
            position: FramedPosition(
                coordinateFrameID: frameID,
                value: position,
                observedAt: lastSeenAt,
                trackingQuality: .normal,
                uncertainty: .highConfidenceDepth
            )
        )
    }

    private func alignmentRecord(
        sourceMapID: MapID,
        sourceFrameID: CoordinateFrameID,
        targetMapID: MapID,
        targetFrameID: CoordinateFrameID,
        transform: Transform3D
    ) throws -> CoordinateAlignmentRecord {
        let sourcePoints = [
            vec(0, 0, 0),
            vec(2, 0.2, 0.1),
            vec(0.2, 0.9, 1.7),
            vec(-1.1, 0.5, -0.8),
        ]
        let correspondences = try sourcePoints.enumerated().map { index, source in
            try CoordinateFrameAlignmentCorrespondence(
                source: CoordinateFrameAlignmentSourcePoint(
                    objectID: objectID(10_000 + index),
                    coordinateFrameID: sourceFrameID,
                    semanticLabel: "landmark-\(index)",
                    position: source
                ),
                target: CoordinateFrameAlignmentTargetPoint(
                    objectID: objectID(20_000 + index),
                    coordinateFrameID: targetFrameID,
                    semanticLabel: "landmark-\(index)",
                    position: try transform.transformed(source)
                ),
                identityConfidence: .one
            )
        }
        let result = try CoordinateFrameAlignmentEstimator().estimate(
            correspondences: correspondences
        )
        return try CoordinateAlignmentRecord(
            sourceMapID: sourceMapID,
            sourceCoordinateFrameID: sourceFrameID,
            targetMapID: targetMapID,
            targetCoordinateFrameID: targetFrameID,
            result: result,
            createdAt: 1,
            updatedAt: 1
        )
    }

    private func identity(
        mapID: MapID?,
        frameID: CoordinateFrameID,
        status: ARCaptureIdentity.Status = .confirmed
    ) -> ARCaptureIdentity {
        ARCaptureIdentity(
            coordinateFrameID: frameID,
            segmentID: CaptureSegmentID(rawValue: testUUID(900_000)),
            mapID: mapID,
            status: status
        )
    }

    private func rigidTransform(yaw: Double, translation: Vec3) -> Transform3D {
        let cosine = cos(yaw)
        let sine = sin(yaw)
        return try! Transform3D(rowMajorElements: [
            cosine, 0, sine, translation.x,
            0, 1, 0, translation.y,
            -sine, 0, cosine, translation.z,
            0, 0, 0, 1,
        ])
    }

    private func confidence(_ value: Double) -> ConfidenceVector {
        let score = ConfidenceScore(clamping: value)
        return ConfidenceVector(
            semantic: score,
            geometry: score,
            tracking: score,
            identity: score,
            objectState: score
        )
    }

    private func waitForIdle(
        _ controller: SpatialObjectQueryController
    ) async throws {
        for _ in 0..<200 where controller.isProcessingForTesting {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isProcessingForTesting)
    }

    private func waitForRequestCount(
        _ provider: SuspendedQuerySnapshotProvider,
        _ expectedCount: Int
    ) async throws {
        for _ in 0..<200 {
            if await provider.requestCount == expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Provider did not receive \(expectedCount) requests before timeout.")
    }

    private func mapID(_ value: Int) -> MapID {
        MapID(rawValue: testUUID(value))
    }

    private func frameID(_ value: Int) -> CoordinateFrameID {
        CoordinateFrameID(rawValue: testUUID(100_000 + value))
    }

    private func objectID(_ value: Int) -> ObjectID {
        ObjectID(rawValue: testUUID(200_000 + value))
    }

    private func vec(_ x: Double, _ y: Double, _ z: Double) -> Vec3 {
        try! Vec3(x: x, y: y, z: z)
    }

    private func testUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }
}

private actor QueryAnnotationTestStore {
    var objects: [SpatialObjectMetadata]
    private var correctionCalls = 0
    private var renameCalls = 0
    init(objects: [SpatialObjectMetadata]) { self.objects = objects }
    func mutationCounts() -> (corrections: Int, renames: Int) { (correctionCalls, renameCalls) }
    func snapshot() throws -> SpatialObjectQueryRepositorySnapshot {
        SpatialObjectQueryRepositorySnapshot(records: objects.map {
            StoredSpatialObjectRecord(metadata: $0, memoryTier: .localMap)
        }, alignmentCatalog: try CoordinateAlignmentCatalogSnapshot())
    }
    func correct(_ expected: SpatialObjectMetadata, label: String) throws -> SpatialObjectMetadata {
        correctionCalls += 1
        let index = objects.firstIndex { $0.object.id == expected.object.id && $0.mapID == expected.mapID }!
        guard objects[index] == expected else { throw SpatialObjectError.invalidTimestamp }
        var object = objects[index].object
        object.semanticLabel = label
        object.stateUpdatedAt = max(object.stateUpdatedAt, 101)
        let corrected = try SpatialObjectMetadata(
            mapID: expected.mapID, object: object, position: expected.position)
        objects[index] = corrected
        return corrected
    }
    func rename(_ expected: SpatialObjectMetadata, name: String?) throws -> SpatialObjectMetadata {
        renameCalls += 1
        let index = objects.firstIndex { $0.object.id == expected.object.id && $0.mapID == expected.mapID }!
        var object = objects[index].object
        try object.setDisplayName(name)
        let renamed = try SpatialObjectMetadata(mapID: expected.mapID, object: object, position: objects[index].position)
        objects[index] = renamed
        return renamed
    }
}

@MainActor
private final class QueryUptimeBox {
    var value: TimeInterval

    init(_ value: TimeInterval) {
        self.value = value
    }
}

@MainActor
private final class QueryIdentityBox {
    var value: ARCaptureIdentity

    init(_ value: ARCaptureIdentity) {
        self.value = value
    }
}

private actor SuspendedQuerySnapshotProvider {
    private var continuations: [CheckedContinuation<SpatialObjectQueryRepositorySnapshot, Error>] = []

    var requestCount: Int {
        continuations.count
    }

    func load(currentMapID: MapID?) async throws -> SpatialObjectQueryRepositorySnapshot {
        _ = currentMapID
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(
        requestIndex: Int,
        with snapshot: SpatialObjectQueryRepositorySnapshot
    ) {
        continuations[requestIndex].resume(returning: snapshot)
    }
}

private actor QueryDeletionBarrierCompletion {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}
