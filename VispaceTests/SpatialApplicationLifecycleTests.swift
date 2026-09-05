import XCTest

@testable import Vispace

@MainActor
final class SpatialApplicationLifecycleTests: XCTestCase {
    private enum Failure: Error { case storage, deletion }

    func testPlaceMaintenanceUsesTheWriterBarrierWithoutDeletingOtherPlaces() async throws {
        var calls: [String] = []
        let lifecycle = SpatialApplicationLifecycle(
            prepareStorage: { calls.append("prepare") }, start: { calls.append("start") },
            stop: { calls.append("stop:\($0)") }, quiesce: { calls.append("joined") },
            deleteStore: { calls.append("deleteAll") }
        )
        lifecycle.setActive(true)
        let result = try await lifecycle.performStorageMaintenance {
            calls.append("selectedPlace")
            return "selected"
        }
        XCTAssertEqual(result, "selected")
        XCTAssertEqual(calls, ["prepare", "start", "stop:false", "joined", "selectedPlace", "prepare", "start"])
    }

    func testRepeatedSceneTransitionsStartAndCheckpointOnlyOnce() {
        var calls: [String] = []
        let lifecycle = SpatialApplicationLifecycle(
            prepareStorage: { calls.append("prepare") }, start: { calls.append("start") },
            stop: { calls.append("stop:\($0)") }, quiesce: {}, deleteStore: {}
        )
        lifecycle.setActive(true)
        lifecycle.setActive(true)
        lifecycle.setActive(false)
        lifecycle.setActive(false)
        XCTAssertEqual(calls, ["prepare", "start", "stop:true"])
        XCTAssertEqual(lifecycle.state, .inactive)
    }

    func testStorageFailureBlocksCaptureAndCanRetryWithoutCameraPermission() {
        var fail = true
        var starts = 0
        let lifecycle = SpatialApplicationLifecycle(
            prepareStorage: { if fail { throw Failure.storage } }, start: { starts += 1 },
            stop: { _ in }, quiesce: {}, deleteStore: {}
        )
        lifecycle.setActive(true)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(lifecycle.state, .storageUnavailable)
        fail = false
        lifecycle.retry()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(lifecycle.state, .active)
    }

    func testDeletionJoinsWritersBeforeRemovalAndReappliesPolicyBeforeRestart() async throws {
        var calls: [String] = []
        let lifecycle = SpatialApplicationLifecycle(
            prepareStorage: { calls.append("prepare") }, start: { calls.append("start") },
            stop: { calls.append("stop:\($0)") }, quiesce: { calls.append("joined") },
            deleteStore: { calls.append("delete") }
        )
        lifecycle.setActive(true)
        try await lifecycle.deleteSpatialData()
        XCTAssertEqual(calls, ["prepare", "start", "stop:false", "joined", "delete", "prepare", "start"])
        XCTAssertEqual(lifecycle.state, .active)
    }

    func testBackgroundDuringDeletionPreventsRestartAndDuplicateDeletion() async throws {
        var started = 0
        var deleted = 0
        var release: CheckedContinuation<Void, Never>?
        let lifecycle = SpatialApplicationLifecycle(
            prepareStorage: {}, start: { started += 1 }, stop: { _ in },
            quiesce: { await withCheckedContinuation { release = $0 } },
            deleteStore: { deleted += 1 }
        )
        lifecycle.setActive(true)
        let deletion = Task { try await lifecycle.deleteSpatialData() }
        while release == nil { await Task.yield() }
        XCTAssertEqual(lifecycle.state, .deleting)
        do {
            try await lifecycle.deleteSpatialData()
            XCTFail("Duplicate deletion must not enter the barrier")
        } catch { XCTAssertTrue(error is SpatialApplicationLifecycle.LifecycleError) }
        lifecycle.setActive(false)
        release?.resume()
        try await deletion.value
        XCTAssertEqual(started, 1)
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(lifecycle.state, .inactive)
    }

    func testFailureRestartsOnlyWhenActiveAndDoesNotReportSuccess() async {
        var starts = 0
        let lifecycle = SpatialApplicationLifecycle(
            prepareStorage: {}, start: { starts += 1 }, stop: { _ in }, quiesce: {},
            deleteStore: { throw Failure.deletion }
        )
        lifecycle.setActive(true)
        do {
            try await lifecycle.deleteSpatialData()
            XCTFail("Expected deletion failure")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(lifecycle.state, .active)
    }
}
