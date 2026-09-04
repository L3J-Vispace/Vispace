import XCTest

@testable import Vispace

final class LatestValueChannelTests: XCTestCase {
    func testChannelKeepsOnlyNewestUnconsumedValue() async {
        let channel = LatestValueChannel<Int>()

        XCTAssertEqual(channel.send(1), .enqueued)
        XCTAssertEqual(channel.send(2), .replacedOlderValue)

        var iterator = channel.stream.makeAsyncIterator()
        let value = await iterator.next()
        XCTAssertEqual(value, 2)
    }

    func testFinishedChannelRejectsNewValues() {
        let channel = LatestValueChannel<Int>()
        channel.finish()

        XCTAssertEqual(channel.send(1), .terminated)
    }

    func testCadenceGateRejectsInvalidAndRapidTimestamps() {
        let gate = SnapshotCadenceGate(maximumFramesPerSecond: 2)

        XCTAssertFalse(gate.admits(timestamp: .nan))
        XCTAssertTrue(gate.admits(timestamp: 10))
        XCTAssertFalse(gate.admits(timestamp: 10.49))
        XCTAssertTrue(gate.admits(timestamp: 10.5))
        XCTAssertTrue(gate.admits(timestamp: 1))

        gate.reset()
        XCTAssertTrue(gate.admits(timestamp: 1.1))
    }
}
