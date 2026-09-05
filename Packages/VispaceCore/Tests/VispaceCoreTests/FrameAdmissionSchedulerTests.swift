import XCTest

@testable import VispaceCore

final class FrameAdmissionSchedulerTests: XCTestCase {
    func testNewArrivalSupersedesCadenceDelayedPendingFrame() throws {
        var scheduler = FrameAdmissionScheduler(
            policy: try FrameAdmissionPolicy(minimumStartInterval: 0.5, maximumFrameAge: 2)
        )
        let first = try FrameDescriptor(sequenceNumber: 1, timestamp: 1)
        let pending = try FrameDescriptor(sequenceNumber: 2, timestamp: 1.1)
        let newest = try FrameDescriptor(sequenceNumber: 3, timestamp: 1.5)
        _ = scheduler.offer(first, now: 1)
        _ = try scheduler.complete(first.id, now: 1.05)
        _ = scheduler.offer(pending, now: 1.1)
        XCTAssertEqual(scheduler.offer(newest, now: 1.5), .started(newest))
        XCTAssertNil(scheduler.pendingLatest)
        XCTAssertNil(try scheduler.complete(newest.id, now: 2))
        XCTAssertNil(scheduler.poll(now: 2.1))
        XCTAssertEqual(scheduler.statistics.startedCount, 2)
        XCTAssertEqual(scheduler.statistics.supersededDropCount, 1)
    }

    func testSingleFlightKeepsOnlyLatestPendingFrame() throws {
        var scheduler = FrameAdmissionScheduler()
        let first = try FrameDescriptor(id: frameID(1), sequenceNumber: 1, timestamp: 1.00)
        let second = try FrameDescriptor(id: frameID(2), sequenceNumber: 2, timestamp: 1.01)
        let third = try FrameDescriptor(id: frameID(3), sequenceNumber: 3, timestamp: 1.02)

        XCTAssertEqual(scheduler.offer(first, now: 1.00), .started(first))
        XCTAssertEqual(scheduler.offer(second, now: 1.01), .queued(second, dropped: nil))
        XCTAssertEqual(
            scheduler.offer(third, now: 1.02),
            .queued(
                third,
                dropped: DroppedFrame(frame: second, reason: .superseded)
            )
        )
        XCTAssertEqual(scheduler.pendingLatest, third)
        XCTAssertEqual(try scheduler.complete(first.id, now: 1.03), third)
        XCTAssertEqual(scheduler.inFlight, third)
        XCTAssertNil(scheduler.pendingLatest)
        XCTAssertEqual(scheduler.statistics.startedCount, 2)
        XCTAssertEqual(scheduler.statistics.supersededDropCount, 1)
    }

    func testUnexpectedCompletionDoesNotCorruptState() throws {
        var scheduler = FrameAdmissionScheduler()
        let first = try FrameDescriptor(id: frameID(1), sequenceNumber: 1, timestamp: 1)
        _ = scheduler.offer(first, now: 1)

        XCTAssertThrowsError(try scheduler.complete(frameID(99), now: 1.1)) { error in
            XCTAssertEqual(
                error as? FrameAdmissionError,
                .unexpectedCompletion(expected: first.id, actual: frameID(99))
            )
        }
        XCTAssertEqual(scheduler.inFlight, first)
    }

    func testStaleAndOutOfOrderFramesAreDropped() throws {
        var scheduler = FrameAdmissionScheduler(
            policy: try FrameAdmissionPolicy(minimumStartInterval: 0, maximumFrameAge: 0.2)
        )
        let stale = try FrameDescriptor(id: frameID(1), sequenceNumber: 1, timestamp: 1)
        XCTAssertEqual(
            scheduler.offer(stale, now: 1.21),
            .dropped(DroppedFrame(frame: stale, reason: .stale))
        )

        let current = try FrameDescriptor(id: frameID(3), sequenceNumber: 3, timestamp: 2)
        XCTAssertEqual(scheduler.offer(current, now: 2), .started(current))
        let lateSequence = try FrameDescriptor(id: frameID(2), sequenceNumber: 2, timestamp: 2.01)
        XCTAssertEqual(
            scheduler.offer(lateSequence, now: 2.01),
            .dropped(DroppedFrame(frame: lateSequence, reason: .outOfOrder))
        )
        XCTAssertEqual(scheduler.statistics.staleDropCount, 1)
        XCTAssertEqual(scheduler.statistics.outOfOrderDropCount, 1)
    }

    func testCadenceDelayedFrameStartsOnPoll() throws {
        var scheduler = FrameAdmissionScheduler(
            policy: try FrameAdmissionPolicy(minimumStartInterval: 0.5, maximumFrameAge: 1)
        )
        let first = try FrameDescriptor(id: frameID(1), sequenceNumber: 1, timestamp: 1)
        let second = try FrameDescriptor(id: frameID(2), sequenceNumber: 2, timestamp: 1.1)
        _ = scheduler.offer(first, now: 1)
        XCTAssertNil(try scheduler.complete(first.id, now: 1.1))
        XCTAssertEqual(scheduler.offer(second, now: 1.1), .queued(second, dropped: nil))
        XCTAssertNil(scheduler.poll(now: 1.49))
        XCTAssertEqual(scheduler.poll(now: 1.5), second)
    }

    func testPendingFrameThatAgesOutIsNotStarted() throws {
        var scheduler = FrameAdmissionScheduler(
            policy: try FrameAdmissionPolicy(minimumStartInterval: 1, maximumFrameAge: 0.2)
        )
        let first = try FrameDescriptor(id: frameID(1), sequenceNumber: 1, timestamp: 1)
        let pending = try FrameDescriptor(id: frameID(2), sequenceNumber: 2, timestamp: 1.1)
        _ = scheduler.offer(first, now: 1)
        _ = scheduler.offer(pending, now: 1.1)
        XCTAssertNil(try scheduler.complete(first.id, now: 1.5))
        XCTAssertNil(scheduler.pendingLatest)
        XCTAssertEqual(scheduler.statistics.staleDropCount, 1)
    }

    func testCodableCannotRestoreInvalidFrameOrPolicy() {
        let idJSON = #"{"rawValue":"00000000-0000-0000-0000-000000000001"}"#
        let invalidFrame = Data(
            #"{"id":\#(idJSON),"sequenceNumber":1,"timestamp":-1}"#.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(FrameDescriptor.self, from: invalidFrame)
        )

        let invalidPolicy = Data(
            #"{"minimumStartInterval":-1,"maximumFrameAge":0.25}"#.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(FrameAdmissionPolicy.self, from: invalidPolicy)
        )
    }
}
