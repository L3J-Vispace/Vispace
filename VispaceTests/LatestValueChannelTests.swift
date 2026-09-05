@preconcurrency import ARKit
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

    func testEverySubscriberReceivesTheSameLatestValueIndependently() async {
        let channel = LatestValueChannel<Int>()
        let firstStream = channel.stream
        let secondStream = channel.stream
        var first = firstStream.makeAsyncIterator()
        var second = secondStream.makeAsyncIterator()

        XCTAssertEqual(channel.send(42), .enqueued)

        let firstValue = await first.next()
        let secondValue = await second.next()
        XCTAssertEqual(firstValue, 42)
        XCTAssertEqual(secondValue, 42)
    }

    func testLateSubscriberReceivesOnlyTheNewestBufferedValue() async {
        let channel = LatestValueChannel<Int>()
        XCTAssertEqual(channel.send(1), .enqueued)
        XCTAssertEqual(channel.send(2), .replacedOlderValue)

        var iterator = channel.stream.makeAsyncIterator()
        let value = await iterator.next()

        XCTAssertEqual(value, 2)
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

final class ARSessionDelegateProxyEventRoutingTests: XCTestCase {
    func testRunResetReplacesBufferedSurfaceWithFailClosedSnapshot() async {
        let identity = ARCaptureIdentity(status: .confirmed)
        let runContext = ARSessionRunContext(generation: 1, startedAt: 0)
        let proxy = ARSessionDelegateProxy(
            surfaceCaptureEnabled: true,
            imageOrientationProvider: { .right },
            captureIdentityProvider: { identity },
            sessionRunContextProvider: { runContext },
            displayGeometryProvider: { nil }
        )
        proxy.surfaceChannel.send(
            ARSurfaceStateSnapshot(
                coordinateFrameID: identity.coordinateFrameID,
                segmentID: identity.segmentID,
                mapID: identity.mapID,
                coordinateFrameStatus: .confirmed,
                revision: 10,
                timestamp: 1,
                planes: [:],
                meshes: [:],
                unresolvedFailures: [],
                isCurrentSessionData: true
            )
        )

        proxy.resetObservationGatesForNewRun()

        var iterator = proxy.surfaces.makeAsyncIterator()
        let invalid = await iterator.next()
        XCTAssertEqual(invalid?.revision, 0)
        XCTAssertFalse(invalid?.isCurrentSessionData ?? true)
        XCTAssertFalse(invalid?.isComplete ?? true)
    }

    func testDisablingSurfaceCaptureReplacesBufferedState() async {
        let identity = ARCaptureIdentity(status: .confirmed)
        let runContext = ARSessionRunContext(generation: 1, startedAt: 0)
        let proxy = ARSessionDelegateProxy(
            surfaceCaptureEnabled: true,
            imageOrientationProvider: { .right },
            captureIdentityProvider: { identity },
            sessionRunContextProvider: { runContext },
            displayGeometryProvider: { nil }
        )
        proxy.surfaceChannel.send(makeValidSurfaceState(identity: identity))

        proxy.surfaceCaptureEnabled = false

        var iterator = proxy.surfaces.makeAsyncIterator()
        let invalid = await iterator.next()
        XCTAssertFalse(invalid?.isCurrentSessionData ?? true)
        XCTAssertFalse(invalid?.isComplete ?? true)
    }

    @MainActor
    func testUninstallReplacesBufferedSurfaceState() async {
        let identity = ARCaptureIdentity(status: .confirmed)
        let runContext = ARSessionRunContext(generation: 1, startedAt: 0)
        let proxy = ARSessionDelegateProxy(
            surfaceCaptureEnabled: true,
            imageOrientationProvider: { .right },
            captureIdentityProvider: { identity },
            sessionRunContextProvider: { runContext },
            displayGeometryProvider: { nil }
        )
        let session = ARSession()
        proxy.install(
            on: session,
            delegateQueue: DispatchQueue(label: "test.surface-uninstall")
        )
        proxy.surfaceChannel.send(makeValidSurfaceState(identity: identity))

        proxy.uninstall(from: session)

        var iterator = proxy.surfaces.makeAsyncIterator()
        let invalid = await iterator.next()
        XCTAssertFalse(invalid?.isCurrentSessionData ?? true)
        XCTAssertFalse(invalid?.isComplete ?? true)
    }

    func testDiagnosticFloodCannotEvictControllerLifecycleEvent() async {
        let identity = ARCaptureIdentity(status: .confirmed)
        let runContext = ARSessionRunContext(generation: 1, startedAt: 0)
        let proxy = ARSessionDelegateProxy(
            imageOrientationProvider: { .right },
            captureIdentityProvider: { identity },
            sessionRunContextProvider: { runContext },
            displayGeometryProvider: { nil }
        )
        let events = proxy.beginControllerEvents()

        for index in 0..<100 {
            proxy.emit(.surfaceSnapshotFailed(message: "failure-\(index)"))
        }
        let context = ARSessionFrameContext(
            captureIdentity: identity,
            sessionRunGeneration: 1,
            frameTimestamp: 1
        )
        proxy.emit(.trackingStateChanged(.normal, context: context))

        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event, .trackingStateChanged(.normal, context: context))
        proxy.endControllerEvents()
    }

    @MainActor
    func testCallbackFromPreviouslyInstalledSessionIsDiscarded() async {
        let identity = ARCaptureIdentity(status: .confirmed)
        let runContext = ARSessionRunContext(generation: 9, startedAt: 1)
        let proxy = ARSessionDelegateProxy(
            imageOrientationProvider: { .right },
            captureIdentityProvider: { identity },
            sessionRunContextProvider: { runContext },
            displayGeometryProvider: { nil }
        )
        let oldSession = ARSession()
        let currentSession = ARSession()
        let delegateQueue = DispatchQueue(label: "test.arkit.delegate")
        proxy.install(on: oldSession, delegateQueue: delegateQueue)
        proxy.uninstall(from: oldSession)
        proxy.install(on: currentSession, delegateQueue: delegateQueue)
        let events = proxy.beginControllerEvents()

        XCTAssertFalse(proxy.sessionShouldAttemptRelocalization(oldSession))
        XCTAssertTrue(proxy.sessionShouldAttemptRelocalization(currentSession))

        proxy.sessionWasInterrupted(oldSession)
        proxy.sessionWasInterrupted(currentSession)

        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(
            event,
            .interrupted(context: runContext)
        )
        proxy.endControllerEvents()
        proxy.uninstall(from: currentSession)
    }

    private func makeValidSurfaceState(
        identity: ARCaptureIdentity
    ) -> ARSurfaceStateSnapshot {
        ARSurfaceStateSnapshot(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: identity.mapID,
            coordinateFrameStatus: .confirmed,
            revision: 10,
            timestamp: 1,
            planes: [:],
            meshes: [:],
            unresolvedFailures: [],
            isCurrentSessionData: true
        )
    }
}
