import Foundation
import XCTest

@testable import Vispace

final class SpatialDataManagementControllerTests: XCTestCase {
    func testMaintenanceDeletesOnlyDedicatedSpatialCaptureContents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vispace = root.appendingPathComponent("Vispace", isDirectory: true)
        let capture = vispace.appendingPathComponent("SpatialCapture", isDirectory: true)
        let sibling = vispace.appendingPathComponent("keep.txt")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: capture,
            withIntermediateDirectories: true
        )
        try Data("map".utf8).write(to: capture.appendingPathComponent("map.bin"))
        try Data("keep".utf8).write(to: sibling)

        try SpatialDataStoreMaintenance.deleteAll(at: capture)

        XCTAssertTrue(FileManager.default.fileExists(atPath: capture.path))
        try assertSpatialDirectoryPolicy(at: capture)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: capture.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testMaintenanceRejectsUnexpectedDirectory() {
        let unexpected = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpatialCapture", isDirectory: true)

        XCTAssertThrowsError(try SpatialDataStoreMaintenance.deleteAll(at: unexpected)) {
            XCTAssertEqual(
                $0 as? SpatialDataStoreMaintenanceError,
                .unexpectedDirectory
            )
        }
    }

    @MainActor
    func testControllerPublishesSuccessfulDeletion() async {
        let recorder = DeletionRecorder()
        let controller = SpatialDataManagementController {
            await recorder.record()
        }

        controller.deleteAllSpatialData()
        await waitUntil { controller.state == .deleted }

        let deletionCount = await recorder.count
        XCTAssertEqual(deletionCount, 1)
    }

    @MainActor
    func testControllerPublishesGenericFailureWithoutLeakingError() async {
        let controller = SpatialDataManagementController {
            throw SampleDeletionError.secretPath
        }

        controller.deleteAllSpatialData()
        await waitUntil {
            if case .failed = controller.state { return true }
            return false
        }

        guard case .failed(let message) = controller.state else {
            return XCTFail("Expected failed state")
        }
        XCTAssertFalse(message.contains("secretPath"))
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
    }
}

private actor DeletionRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private enum SampleDeletionError: Error {
    case secretPath
}
