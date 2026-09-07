import VispaceCore
import XCTest
import simd

@testable import Vispace

@MainActor
final class IndoorNavigationControllerTests: XCTestCase {
    func testPublishedRibbonInheritsCustomWallClearance() async throws {
        let fixture = NavigationAppFixture()
        let harness = makeHarness(fixture: fixture, engine: IndoorARNavigationEngine(
            policy: try IndoorNavigationPolicy(agentRadius: 0.10)
        ))
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: try fixture.metadata(x: 2))
        await eventually { harness.controller.renderablePath != nil }
        let output = try XCTUnwrap(harness.controller.renderablePath)
        XCTAssertEqual(output.maximumHalfWidth, 0.10)
        let geometry = try XCTUnwrap(ARNavigationRibbonGeometry.make(
            waypoints: output.waypoints, maximumHalfWidth: output.maximumHalfWidth))
        XCTAssertTrue(geometry.surface.positions.allSatisfy { abs($0.z) <= 0.100_001 })
        await harness.controller.deactivateAndWaitForPendingWork()
    }

    func testFutureSourceStateCannotBecomeDirectOrGroundedNavigationDestination() throws {
        let fixture = NavigationAppFixture()
        let original = try fixture.metadata(x: 2)
        var object = original.object
        object.stateUpdatedAt = 100
        let source = try SpatialObjectMetadata(mapID: original.mapID, object: object, position: original.position)
        let adapter = ARIndoorNavigationTargetAdapter()
        guard case .invalid(.targetStale) = adapter.resolve(metadata: source,
            currentIdentity: fixture.identity, now: 10) else {
            return XCTFail("Future state evidence must not become a direct navigation target")
        }
        let target = GroundedSpatialObjectQueryTarget(semanticLabel: object.semanticLabel,
            objectID: object.id, sourceMapID: source.mapID, currentMapID: fixture.identity.mapID,
            currentSegmentID: fixture.identity.segmentID, sourcePosition: source.position,
            currentFramePosition: source.position, intent: .navigate,
            effectiveConfidence: .one, confidenceGrade: .high, alignmentConfidence: nil, resolvedAt: 10)
        guard case .invalid(.targetStale) = adapter.resolve(groundedTarget: target,
            sourceMetadata: source, currentIdentity: fixture.identity, now: 10) else {
            return XCTFail("A fresh query resolution cannot renew future observation evidence")
        }
    }

    func testPublishedPathExpiresWhenCaptureStreamsStop() async throws {
        let fixture = NavigationAppFixture()
        let harness = makeHarness(fixture: fixture, engine: IndoorARNavigationEngine(
            policy: try IndoorNavigationPolicy(maximumStartAge: 0.08, maximumEvidenceAge: 0.08)
        ))
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: try fixture.metadata(x: 2))
        await eventually { harness.controller.renderablePath != nil }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(harness.controller.renderablePath)
        XCTAssertGreaterThanOrEqual(harness.controller.metrics.routeInvalidations, 1)
        await harness.controller.deactivateAndWaitForPendingWork()
    }

    func testDoorLeaseRevokesPublishedCrossingBeforeFloorEvidenceExpires() async throws {
        let fixture = NavigationAppFixture()
        let original = try fixture.evidence(revision: 1)
        let door = try IndoorNavigationDoorEvidence(
            identifier: "short-door-lease",
            firstCell: IndoorNavigationCell(column: 0, row: 0),
            secondCell: IndoorNavigationCell(column: 1, row: 0), state: .open,
            confidence: .one, observedAt: 10, validUntil: 10.15)
        let evidence = try IndoorNavigationEvidence(
            mapID: original.mapID,
            coordinateFrameID: original.coordinateFrameID, revision: original.revision,
            observedAt: original.observedAt, gridOrigin: original.gridOrigin,
            cellSize: original.cellSize, floors: original.floors, mesh: original.mesh,
            doors: [door], walls: original.walls, obstacles: original.obstacles,
            completeness: original.completeness)
        let harness = makeHarness(fixture: fixture, evidence: evidence)
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: try fixture.metadata(x: 2))
        await eventually { harness.controller.renderablePath != nil }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(harness.controller.renderablePath)
        XCTAssertGreaterThanOrEqual(harness.controller.metrics.routeInvalidations, 1)
        await harness.controller.deactivateAndWaitForPendingWork()
    }

    func testWalkingInvalidatesPreviousOriginAndReevaluates() async throws {
        let fixture = NavigationAppFixture()
        let harness = makeHarness(fixture: fixture)
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: try fixture.metadata(x: 2))
        await eventually { harness.controller.renderablePath != nil }
        harness.poseContinuation.yield(fixture.pose(timestamp: 10.2, x: 0.5))
        await eventually { harness.controller.metrics.requestsStarted >= 2 }
        XCTAssertNil(harness.controller.renderablePath)
        XCTAssertGreaterThanOrEqual(harness.controller.metrics.routeInvalidations, 1)
        await harness.controller.deactivateAndWaitForPendingWork()
    }

    func testArrivalRemovesPathAndFinishesNavigation() async throws {
        let fixture = NavigationAppFixture()
        let harness = makeHarness(fixture: fixture)
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: try fixture.metadata(x: 2))
        await eventually { harness.controller.renderablePath != nil }
        harness.poseContinuation.yield(fixture.pose(timestamp: 10.1, x: 1.9))
        await eventually { harness.controller.state == .arrived }
        XCTAssertNil(harness.controller.renderablePath)
        XCTAssertTrue(harness.controller.latestPresentation?.message.contains("도착") == true)
        await harness.controller.deactivateAndWaitForPendingWork()
    }

    func testRawSurfaceAdapterNeverInventsFreeSpaceCoverage() throws {
        let fixture = NavigationAppFixture()
        let snapshot = fixture.surface(revision: 1)

        let result = ARSurfaceIndoorNavigationEvidenceAdapter().adapt(
            snapshot,
            currentIdentity: fixture.identity
        )

        guard case .insufficientEvidence(let issue) = result else {
            return XCTFail("Raw AR surface data must not become trusted free-space evidence")
        }
        XCTAssertEqual(issue, .freeSpaceCoverageUnavailable)
    }

    func testSurfaceAdapterRejectsIncompleteMismatchedAndStaleAttestations() throws {
        let fixture = NavigationAppFixture()
        let adapter = ARSurfaceIndoorNavigationEvidenceAdapter()
        let incomplete = fixture.surface(revision: 1, isCurrentSessionData: false)
        guard
            case .insufficientEvidence(let incompleteIssue) = adapter.adapt(
                incomplete,
                currentIdentity: fixture.identity,
                verifiedEvidence: try fixture.evidence(revision: 1)
            )
        else {
            return XCTFail("Expected incomplete snapshot rejection")
        }
        XCTAssertEqual(incompleteIssue, .surfaceSnapshotIncomplete)

        let snapshot = fixture.surface(revision: 2)
        guard
            case .insufficientEvidence(let revisionIssue) = adapter.adapt(
                snapshot,
                currentIdentity: fixture.identity,
                verifiedEvidence: try fixture.evidence(revision: 1)
            )
        else {
            return XCTFail("Expected revision mismatch rejection")
        }
        XCTAssertEqual(revisionIssue, .surfaceRevisionMismatch)

        let otherIdentity = ARCaptureIdentity(
            coordinateFrameID: CoordinateFrameID(),
            segmentID: fixture.identity.segmentID,
            mapID: fixture.identity.mapID,
            status: .confirmed
        )
        guard
            case .insufficientEvidence(let contextIssue) = adapter.adapt(
                snapshot,
                currentIdentity: otherIdentity,
                verifiedEvidence: try fixture.evidence(revision: 2)
            )
        else {
            return XCTFail("Expected coordinate mismatch rejection")
        }
        XCTAssertEqual(contextIssue, .coordinateContextMismatch)
    }

    func testSurfaceAdapterAcceptsOnlyExactCompleteVerifiedEvidence() throws {
        let fixture = NavigationAppFixture()
        let evidence = try fixture.evidence(revision: 7)
        let result = ARSurfaceIndoorNavigationEvidenceAdapter().adapt(
            fixture.surface(revision: 7),
            currentIdentity: fixture.identity,
            verifiedEvidence: evidence
        )

        guard case .ready(let adapted) = result else {
            return XCTFail("Expected exact attestation to be accepted")
        }
        XCTAssertEqual(adapted.revision, 7)
        XCTAssertEqual(adapted.mapID, fixture.identity.mapID)
        XCTAssertEqual(adapted.coordinateFrameID, fixture.identity.coordinateFrameID)
    }

    func testPoseAdapterRequiresSeparateFloorGroundingAndExactLivePose() throws {
        let fixture = NavigationAppFixture()
        let pose = fixture.pose(timestamp: 10)
        let adapter = ARPoseIndoorNavigationAdapter()
        guard
            case .insufficientEvidence(let missingIssue) = adapter.adapt(
                pose,
                currentIdentity: fixture.identity
            )
        else {
            return XCTFail("Pose alone must not invent a floor raycast")
        }
        XCTAssertEqual(missingIssue, .positionGroundingUnavailable)

        guard
            case .ready(let position) = adapter.adapt(
                pose,
                currentIdentity: fixture.identity,
                verifiedFloorPosition: try fixture.floorPosition(timestamp: 10)
            )
        else {
            return XCTFail("Expected verified floor position")
        }
        XCTAssertEqual(position.value, try Vec3(x: 0, y: 0, z: 0))

        let stale = try fixture.floorPosition(timestamp: 9)
        guard
            case .insufficientEvidence(let staleIssue) = adapter.adapt(
                pose,
                currentIdentity: fixture.identity,
                verifiedFloorPosition: stale
            )
        else {
            return XCTFail("Expected timestamp mismatch")
        }
        XCTAssertEqual(staleIssue, .positionTimestampMismatch)

        let displaced = try FramedPosition(
            coordinateFrameID: fixture.identity.coordinateFrameID,
            value: Vec3(x: 1, y: 0, z: 0),
            observedAt: 10,
            trackingQuality: .normal,
            uncertainty: .raycastEstimate
        )
        guard
            case .insufficientEvidence(let displacedIssue) = adapter.adapt(
                pose,
                currentIdentity: fixture.identity,
                verifiedFloorPosition: displaced
            )
        else {
            return XCTFail("Expected camera position mismatch")
        }
        XCTAssertEqual(displacedIssue, .positionDoesNotMatchCamera)
    }

    func testTargetAdapterAcceptsOnlyCurrentFrameMetadata() throws {
        let fixture = NavigationAppFixture()
        let adapter = ARIndoorNavigationTargetAdapter()
        let metadata = try fixture.metadata(x: 2)
        guard
            case .ready(let accepted) = adapter.resolve(
                metadata: metadata,
                currentIdentity: fixture.identity
            )
        else {
            return XCTFail("Expected current-frame metadata")
        }
        XCTAssertEqual(accepted, metadata)

        let wrongFrame = try fixture.metadata(x: 2, frameID: CoordinateFrameID())
        guard
            case .invalid(let issue) = adapter.resolve(
                metadata: wrongFrame,
                currentIdentity: fixture.identity
            )
        else {
            return XCTFail("Expected cross-frame metadata rejection")
        }
        XCTAssertEqual(issue, .coordinateContextMismatch)
    }

    func testGroundedSearchTargetIsBoundToOriginalMetadataAndCurrentFrame() throws {
        let fixture = NavigationAppFixture()
        let sourceMapID = MapID()
        let sourceFrameID = CoordinateFrameID()
        let source = try fixture.metadata(
            x: 20,
            mapID: sourceMapID,
            frameID: sourceFrameID,
            confidence: 0.95
        )
        let currentPosition = try FramedPosition(
            coordinateFrameID: fixture.identity.coordinateFrameID,
            value: Vec3(x: 2, y: 0, z: 0),
            observedAt: source.position.observedAt,
            trackingQuality: .normal,
            uncertainty: .highConfidenceDepth
        )
        let target = GroundedSpatialObjectQueryTarget(
            semanticLabel: source.object.semanticLabel,
            objectID: source.object.id,
            sourceMapID: sourceMapID,
            currentMapID: fixture.identity.mapID,
            currentSegmentID: fixture.identity.segmentID,
            sourcePosition: source.position,
            currentFramePosition: currentPosition,
            intent: .navigate,
            effectiveConfidence: ConfidenceScore(clamping: 0.7),
            confidenceGrade: .medium,
            alignmentConfidence: ConfidenceScore(clamping: 0.8),
            resolvedAt: 9
        )

        let result = ARIndoorNavigationTargetAdapter().resolve(
            groundedTarget: target,
            sourceMetadata: source,
            currentIdentity: fixture.identity,
            now: 10
        )
        guard case .ready(let resolved) = result else {
            return XCTFail("Expected verified grounded target")
        }
        XCTAssertEqual(resolved.mapID, fixture.identity.mapID)
        XCTAssertEqual(resolved.position, currentPosition)
        XCTAssertEqual(resolved.object.position, currentPosition.value)
        XCTAssertNil(resolved.object.bounds)
        XCTAssertNil(resolved.object.nodeID)
        XCTAssertEqual(resolved.object.confidence.geometry, ConfidenceScore(clamping: 0.7))

        let forgedTarget = GroundedSpatialObjectQueryTarget(
            semanticLabel: target.semanticLabel,
            objectID: ObjectID(),
            sourceMapID: target.sourceMapID,
            currentMapID: target.currentMapID,
            currentSegmentID: target.currentSegmentID,
            sourcePosition: target.sourcePosition,
            currentFramePosition: target.currentFramePosition,
            intent: target.intent,
            effectiveConfidence: target.effectiveConfidence,
            confidenceGrade: target.confidenceGrade,
            alignmentConfidence: target.alignmentConfidence,
            resolvedAt: target.resolvedAt
        )
        guard
            case .invalid(let issue) = ARIndoorNavigationTargetAdapter().resolve(
                groundedTarget: forgedTarget,
                sourceMetadata: source,
                currentIdentity: fixture.identity,
                now: 10
            )
        else {
            return XCTFail("Expected forged search handoff rejection")
        }
        XCTAssertEqual(issue, .searchTargetMismatch)

        let unprovenAlignment = GroundedSpatialObjectQueryTarget(
            semanticLabel: target.semanticLabel,
            objectID: target.objectID,
            sourceMapID: target.sourceMapID,
            currentMapID: target.currentMapID,
            currentSegmentID: target.currentSegmentID,
            sourcePosition: target.sourcePosition,
            currentFramePosition: target.currentFramePosition,
            intent: target.intent,
            effectiveConfidence: target.effectiveConfidence,
            confidenceGrade: target.confidenceGrade,
            alignmentConfidence: nil,
            resolvedAt: target.resolvedAt
        )
        guard
            case .invalid(let alignmentIssue) = ARIndoorNavigationTargetAdapter().resolve(
                groundedTarget: unprovenAlignment,
                sourceMetadata: source,
                currentIdentity: fixture.identity,
                now: 10
            )
        else {
            return XCTFail("Expected missing cross-frame alignment proof rejection")
        }
        XCTAssertEqual(alignmentIssue, .targetNotGrounded)
    }

    func testControllerPublishesOnlyAdjacentObservedPathSegments() async throws {
        let fixture = NavigationAppFixture()
        let harness = makeHarness(fixture: fixture)
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: try fixture.metadata(x: 2))

        await eventually { harness.controller.renderablePath != nil }
        let output = try XCTUnwrap(harness.controller.renderablePath)
        XCTAssertEqual(harness.controller.state, .navigating)
        XCTAssertEqual(output.surfaceRevision, 1)
        XCTAssertEqual(output.totalDistance, 2, accuracy: 1e-12)
        XCTAssertEqual(
            output.waypoints,
            [
                try Vec3(x: 0, y: 0, z: 0),
                try Vec3(x: 1, y: 0, z: 0),
                try Vec3(x: 2, y: 0, z: 0),
            ])
        XCTAssertEqual(output.segments.count, 2)
        XCTAssertEqual(output.segments[0].start, output.waypoints[0])
        XCTAssertEqual(output.segments[0].end, output.waypoints[1])
        XCTAssertEqual(output.segments[1].start, output.waypoints[1])
        XCTAssertEqual(output.segments[1].end, output.waypoints[2])
        XCTAssertFalse(
            output.segments.contains {
                $0.start == output.waypoints[0] && $0.end == output.waypoints[2]
            }
        )
        XCTAssertTrue(harness.controller.latestPresentation?.message.contains("2.0미터") == true)
    }

    func testLimitedTrackingImmediatelyRevokesPublishedPath() async throws {
        let fixture = NavigationAppFixture()
        let harness = makeHarness(fixture: fixture)
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: try fixture.metadata(x: 2))
        await eventually { harness.controller.renderablePath != nil }

        harness.poseContinuation.yield(
            fixture.pose(
                timestamp: 11,
                trackingState: .limited(.insufficientFeatures)
            )
        )

        await eventually { harness.controller.renderablePath == nil }
        XCTAssertEqual(harness.controller.state, .waitingForPose)
        XCTAssertEqual(harness.controller.metrics.routeInvalidations, 1)
    }

    func testCurrentCameraTimestampCanFollowGeometryAfterDebounce() async throws {
        let fixture = NavigationAppFixture()
        let harness = makeHarness(
            fixture: fixture,
            evidence: try fixture.evidence(revision: 1, timestamp: 100),
            surfaceStabilityDelay: .milliseconds(250),
            evaluationTimestampProvider: { 100.4 }
        )
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1, timestamp: 100))
        harness.poseContinuation.yield(fixture.pose(timestamp: 100.4))
        harness.controller.navigate(to: try fixture.metadata(x: 2))

        await eventually(timeoutIterations: 300) { harness.controller.renderablePath != nil }
        XCTAssertEqual(harness.controller.latestPresentation?.result?.status, .success)
        XCTAssertEqual(harness.controller.renderablePath?.surfaceRevision, 1)
    }

    func testEvaluationTimestampProviderRejectsStaleOrFutureSurface() async throws {
        for surfaceTimestamp in [94.9, 100.3] {
            let fixture = NavigationAppFixture()
            let harness = makeHarness(
                fixture: fixture,
                evidence: try fixture.evidence(revision: 1, timestamp: surfaceTimestamp),
                evaluationTimestampProvider: { 100 }
            )
            harness.controller.activate()
            harness.surfaceContinuation.yield(
                fixture.surface(revision: 1, timestamp: surfaceTimestamp)
            )
            harness.poseContinuation.yield(fixture.pose(timestamp: 100))
            harness.controller.navigate(to: try fixture.metadata(x: 2))

            await eventually { harness.controller.latestPresentation != nil }
            XCTAssertEqual(harness.controller.latestPresentation?.result?.reason, .evidenceStale)
            XCTAssertNil(harness.controller.renderablePath)
            await harness.controller.deactivateAndWaitForPendingWork()
        }
    }

    func testEvaluationTimestampProviderRejectsStaleOrFutureCameraPose() async throws {
        for poseTimestamp in [94.9, 100.3] {
            let fixture = NavigationAppFixture()
            let harness = makeHarness(
                fixture: fixture,
                evidence: try fixture.evidence(revision: 1, timestamp: 100),
                evaluationTimestampProvider: { 100 }
            )
            harness.controller.activate()
            harness.surfaceContinuation.yield(fixture.surface(revision: 1, timestamp: 100))
            harness.poseContinuation.yield(fixture.pose(timestamp: poseTimestamp))
            harness.controller.navigate(to: try fixture.metadata(x: 2))

            await eventually { harness.controller.latestPresentation != nil }
            XCTAssertEqual(harness.controller.latestPresentation?.result?.reason, .startPoseStale)
            XCTAssertNil(harness.controller.renderablePath)
            await harness.controller.deactivateAndWaitForPendingWork()
        }
    }

    func testMissingCurrentSessionClockDoesNotFallBackToOldSnapshotTime() async throws {
        let fixture = NavigationAppFixture()
        let harness = makeHarness(
            fixture: fixture,
            evaluationTimestampProvider: { nil }
        )
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: try fixture.metadata(x: 2))

        await eventually { harness.controller.latestPresentation != nil }
        XCTAssertEqual(harness.controller.latestPresentation?.result?.reason, .evidenceStale)
        XCTAssertNil(harness.controller.renderablePath)
    }

    func testUnusableWorldMappingImmediatelyRevokesPublishedPath() async throws {
        let fixture = NavigationAppFixture()
        let harness = makeHarness(fixture: fixture)
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: try fixture.metadata(x: 2))
        await eventually { harness.controller.renderablePath != nil }

        harness.poseContinuation.yield(
            fixture.pose(
                timestamp: 11,
                worldMappingStatus: .limited
            )
        )

        await eventually { harness.controller.renderablePath == nil }
        XCTAssertEqual(harness.controller.state, .waitingForPose)
        XCTAssertEqual(harness.controller.metrics.routeInvalidations, 1)
    }

    func testControllerResubscribesToFreshStreamsAfterReactivation() async throws {
        let fixture = NavigationAppFixture()
        let surfaceChannel = LatestValueChannel<ARSurfaceStateSnapshot>()
        let poseChannel = LatestValueChannel<ARPoseSnapshot>()
        let identity = MainActorIdentity(fixture.identity)
        let controller = IndoorNavigationController(
            surfaceStreamProvider: { surfaceChannel.stream },
            poseStreamProvider: { poseChannel.stream },
            currentIdentityProvider: { identity.value },
            evidenceProvider: { snapshot, currentIdentity in
                ARSurfaceIndoorNavigationEvidenceAdapter().adapt(
                    snapshot,
                    currentIdentity: currentIdentity,
                    verifiedEvidence: try fixture.evidence(
                        revision: snapshot.revision,
                        timestamp: snapshot.timestamp
                    )
                )
            },
            startPositionProvider: { pose, currentIdentity in
                ARPoseIndoorNavigationAdapter().adapt(
                    pose,
                    currentIdentity: currentIdentity,
                    verifiedFloorPosition: try fixture.floorPosition(timestamp: pose.timestamp)
                )
            },
            nowProvider: { 10 }
        )

        controller.activate()
        surfaceChannel.send(fixture.surface(revision: 1))
        poseChannel.send(fixture.pose(timestamp: 10))
        controller.navigate(to: try fixture.metadata(x: 2))
        await eventually { controller.renderablePath?.surfaceRevision == 1 }

        controller.deactivate()
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertNil(controller.renderablePath)

        controller.activate()
        surfaceChannel.send(fixture.surface(revision: 2, timestamp: 11))
        poseChannel.send(fixture.pose(timestamp: 11))
        await eventually { controller.renderablePath?.surfaceRevision == 2 }
    }

    func testDefaultAdaptersReportHonestKoreanInsufficientEvidence() async throws {
        let fixture = NavigationAppFixture()
        let (surfaceStream, surfaceContinuation) = AsyncStream<ARSurfaceStateSnapshot>.makeStream()
        let (poseStream, poseContinuation) = AsyncStream<ARPoseSnapshot>.makeStream()
        let identity = MainActorIdentity(fixture.identity)
        let controller = IndoorNavigationController(
            surfaces: surfaceStream,
            poses: poseStream,
            currentIdentityProvider: { identity.value }
        )
        controller.activate()
        surfaceContinuation.yield(fixture.surface(revision: 1))
        poseContinuation.yield(fixture.pose(timestamp: 10))
        controller.navigate(to: try fixture.metadata(x: 2))

        await eventually { controller.latestPresentation != nil }
        XCTAssertEqual(controller.state, .noPath)
        XCTAssertNil(controller.renderablePath)
        XCTAssertEqual(
            controller.latestPresentation?.evidenceIssue,
            .freeSpaceCoverageUnavailable
        )
        XCTAssertTrue(
            controller.latestPresentation?.message.contains("경로를 추정하지 않았어요") == true
        )
    }

    func testUnreachableRouteHasNoOutputAndKoreanNoPathMessage() async throws {
        let fixture = NavigationAppFixture()
        let blockedEvidence = try fixture.evidence(
            revision: 1,
            cells: [
                IndoorNavigationCell(column: 0, row: 0),
                IndoorNavigationCell(column: 2, row: 0),
            ]
        )
        let harness = makeHarness(fixture: fixture, evidence: blockedEvidence)
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: try fixture.metadata(x: 2))

        await eventually { harness.controller.latestPresentation != nil }
        XCTAssertEqual(harness.controller.latestPresentation?.result?.status, .unreachable)
        XCTAssertNil(harness.controller.renderablePath)
        XCTAssertTrue(
            harness.controller.latestPresentation?.message.contains("확인된 경로가 없어요") == true
        )
    }

    func testSurfaceRevisionImmediatelyRevokesThenRecomputesRoute() async throws {
        let fixture = NavigationAppFixture()
        let (surfaceStream, surfaceContinuation) = AsyncStream<ARSurfaceStateSnapshot>.makeStream()
        let (poseStream, poseContinuation) = AsyncStream<ARPoseSnapshot>.makeStream()
        let identity = MainActorIdentity(fixture.identity)
        let factory = fixture
        let controller = IndoorNavigationController(
            surfaces: surfaceStream,
            poses: poseStream,
            currentIdentityProvider: { identity.value },
            evidenceProvider: { snapshot, currentIdentity in
                if snapshot.revision == 2 {
                    try await Task.sleep(for: .milliseconds(80))
                }
                return ARSurfaceIndoorNavigationEvidenceAdapter().adapt(
                    snapshot,
                    currentIdentity: currentIdentity,
                    verifiedEvidence: try factory.evidence(revision: snapshot.revision)
                )
            },
            startPositionProvider: { pose, currentIdentity in
                ARPoseIndoorNavigationAdapter().adapt(
                    pose,
                    currentIdentity: currentIdentity,
                    verifiedFloorPosition: try factory.floorPosition(timestamp: pose.timestamp)
                )
            }
        )
        controller.activate()
        surfaceContinuation.yield(fixture.surface(revision: 1))
        poseContinuation.yield(fixture.pose(timestamp: 10))
        controller.navigate(to: try fixture.metadata(x: 2))
        await eventually { controller.renderablePath?.surfaceRevision == 1 }

        surfaceContinuation.yield(fixture.surface(revision: 2))
        await eventually { controller.state == .routing }
        XCTAssertNil(controller.renderablePath)
        XCTAssertGreaterThanOrEqual(controller.metrics.routeInvalidations, 1)

        await eventually(timeoutIterations: 300) {
            controller.renderablePath?.surfaceRevision == 2
        }
        XCTAssertEqual(controller.state, .navigating)
    }

    func testSurfaceStabilityDelayCoalescesRapidRevisionsIntoLatestRoute() async throws {
        let fixture = NavigationAppFixture()
        let (harness, recorder) = makeRecordingHarness(
            fixture: fixture,
            surfaceStabilityDelay: .milliseconds(80)
        )
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: try fixture.metadata(x: 2))
        await eventually(timeoutIterations: 300) {
            harness.controller.renderablePath?.surfaceRevision == 1
        }

        harness.surfaceContinuation.yield(fixture.surface(revision: 2, timestamp: 11))
        await eventually {
            harness.controller.isRoutingForTesting && harness.controller.renderablePath == nil
        }
        harness.surfaceContinuation.yield(fixture.surface(revision: 3, timestamp: 12))
        await eventually { harness.controller.metrics.requestsCancelled >= 1 }

        await eventually(timeoutIterations: 300) {
            harness.controller.renderablePath?.surfaceRevision == 3
        }
        let recordedRevisions = await recorder.recordedRevisions()
        XCTAssertEqual(recordedRevisions, [1, 3])
        XCTAssertEqual(harness.controller.metrics.requestsStarted, 2)
        XCTAssertEqual(harness.controller.metrics.routesPublished, 2)
        XCTAssertEqual(harness.controller.metrics.routeInvalidations, 1)
        XCTAssertEqual(harness.controller.renderablePath?.surfaceRevision, 3)
    }

    func testClearRouteCancelsDebouncedRequestBeforeRouteStarts() async throws {
        let fixture = NavigationAppFixture()
        let (harness, recorder) = makeRecordingHarness(
            fixture: fixture,
            surfaceStabilityDelay: .milliseconds(80)
        )
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: try fixture.metadata(x: 2))
        await eventually { harness.controller.isRoutingForTesting }

        harness.controller.clearRoute()
        try await Task.sleep(for: .milliseconds(120))

        let recordedRevisions = await recorder.recordedRevisions()
        XCTAssertEqual(recordedRevisions, [])
        XCTAssertEqual(harness.controller.metrics.requestsStarted, 0)
        XCTAssertEqual(harness.controller.metrics.requestsCancelled, 1)
        XCTAssertFalse(harness.controller.isRoutingForTesting)
        XCTAssertNil(harness.controller.renderablePath)
        XCTAssertNil(harness.controller.latestPresentation)
        XCTAssertEqual(harness.controller.state, .ready)
    }

    func testDeactivateCancelsDebouncedRequestBeforeRouteStarts() async throws {
        let fixture = NavigationAppFixture()
        let (harness, recorder) = makeRecordingHarness(
            fixture: fixture,
            surfaceStabilityDelay: .milliseconds(80)
        )
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: try fixture.metadata(x: 2))
        await eventually { harness.controller.isRoutingForTesting }

        harness.controller.deactivate()
        try await Task.sleep(for: .milliseconds(120))

        let recordedRevisions = await recorder.recordedRevisions()
        XCTAssertEqual(recordedRevisions, [])
        XCTAssertEqual(harness.controller.metrics.requestsStarted, 0)
        XCTAssertEqual(harness.controller.metrics.requestsCancelled, 1)
        XCTAssertFalse(harness.controller.isRoutingForTesting)
        XCTAssertNil(harness.controller.renderablePath)
        XCTAssertNil(harness.controller.latestPresentation)
        XCTAssertEqual(harness.controller.state, .inactive)
    }

    func testDeactivateAndWaitAlsoWaitsForReplacedEvidenceRead() async throws {
        let fixture = NavigationAppFixture()
        let (surfaceStream, surfaceContinuation) = AsyncStream<ARSurfaceStateSnapshot>.makeStream()
        let (poseStream, poseContinuation) = AsyncStream<ARPoseSnapshot>.makeStream()
        let identity = MainActorIdentity(fixture.identity)
        let evidenceProvider = SuspendedNavigationEvidenceProvider()
        let completion = NavigationDeletionBarrierCompletion()
        let controller = IndoorNavigationController(
            surfaces: surfaceStream,
            poses: poseStream,
            currentIdentityProvider: { identity.value },
            evidenceProvider: { snapshot, currentIdentity in
                try await evidenceProvider.load(
                    surface: snapshot,
                    identity: currentIdentity
                )
            },
            startPositionProvider: { pose, currentIdentity in
                ARPoseIndoorNavigationAdapter().adapt(
                    pose,
                    currentIdentity: currentIdentity,
                    verifiedFloorPosition: try fixture.floorPosition(timestamp: pose.timestamp)
                )
            }
        )
        controller.activate()
        surfaceContinuation.yield(fixture.surface(revision: 1))
        poseContinuation.yield(fixture.pose(timestamp: 10))
        controller.navigate(to: try fixture.metadata(x: 2))
        try await waitForEvidenceRequest(evidenceProvider, 1)
        controller.navigate(to: try fixture.metadata(x: 3))
        try await waitForEvidenceRequest(evidenceProvider, 2)

        let barrierTask = Task { @MainActor in
            await controller.deactivateAndWaitForPendingWork()
            await completion.markFinished()
        }
        await eventually { !controller.isRoutingForTesting }

        let finishedWhileProviderWasBlocked = await completion.isFinished
        XCTAssertFalse(finishedWhileProviderWasBlocked)
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertNil(controller.renderablePath)
        XCTAssertNil(controller.latestPresentation)

        let adaptation = ARSurfaceIndoorNavigationEvidenceAdapter().adapt(
            fixture.surface(revision: 1),
            currentIdentity: fixture.identity,
            verifiedEvidence: try fixture.evidence(revision: 1)
        )
        // The second route finishing cannot release deletion while the first still reads evidence.
        await evidenceProvider.resume(index: 1, with: adaptation)
        await eventually { controller.metrics.staleResultsRejected == 1 }
        XCTAssertEqual(controller.metrics.staleResultsRejected, 1)
        try await Task.sleep(for: .milliseconds(30))
        let finishedWhileReplacedReadWasBlocked = await completion.isFinished
        XCTAssertFalse(finishedWhileReplacedReadWasBlocked)

        await evidenceProvider.resume(index: 0, with: adaptation)
        await barrierTask.value

        let finishedAfterProviderReleased = await completion.isFinished
        XCTAssertTrue(finishedAfterProviderReleased)
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertNil(controller.renderablePath)
        XCTAssertNil(controller.latestPresentation)
        XCTAssertEqual(controller.metrics.routesPublished, 0)
        XCTAssertEqual(controller.metrics.requestsCancelled, 2)
        XCTAssertEqual(controller.metrics.staleResultsRejected, 2)
    }

    func testDefaultZeroStabilityDelayStartsRouteSynchronously() async throws {
        let fixture = NavigationAppFixture()
        let (harness, _) = makeRecordingHarness(fixture: fixture)
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        await eventually { harness.controller.state == .ready }

        harness.controller.navigate(to: try fixture.metadata(x: 2))

        XCTAssertEqual(harness.controller.metrics.requestsStarted, 1)
        await eventually { harness.controller.renderablePath?.surfaceRevision == 1 }
    }

    func testOutOfOrderSurfaceCannotRevokeNewerRoute() async throws {
        let fixture = NavigationAppFixture()
        let evidence = try fixture.evidence(revision: 2)
        let harness = makeHarness(fixture: fixture, evidence: evidence)
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 2))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: try fixture.metadata(x: 2))
        await eventually { harness.controller.renderablePath?.surfaceRevision == 2 }

        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        await settle()
        XCTAssertEqual(harness.controller.renderablePath?.surfaceRevision, 2)
        XCTAssertEqual(harness.controller.metrics.outOfOrderSurfacesRejected, 1)
    }

    func testOutOfOrderPoseCannotReplaceCurrentStartOrRevokeRoute() async throws {
        let fixture = NavigationAppFixture()
        let harness = makeHarness(fixture: fixture)
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: try fixture.metadata(x: 2))
        await eventually { harness.controller.renderablePath != nil }

        let published = harness.controller.renderablePath
        harness.poseContinuation.yield(fixture.pose(timestamp: 9))
        await settle()

        XCTAssertEqual(harness.controller.renderablePath, published)
        XCTAssertEqual(harness.controller.metrics.outOfOrderPosesRejected, 1)
    }

    func testCaptureTransitionCancelsLateRouteAndClearsAllOutput() async throws {
        let fixture = NavigationAppFixture()
        let (surfaceStream, surfaceContinuation) = AsyncStream<ARSurfaceStateSnapshot>.makeStream()
        let (poseStream, poseContinuation) = AsyncStream<ARPoseSnapshot>.makeStream()
        let identity = MainActorIdentity(fixture.identity)
        let factory = fixture
        let controller = IndoorNavigationController(
            surfaces: surfaceStream,
            poses: poseStream,
            currentIdentityProvider: { identity.value },
            evidenceProvider: { snapshot, currentIdentity in
                try await Task.sleep(for: .milliseconds(100))
                return ARSurfaceIndoorNavigationEvidenceAdapter().adapt(
                    snapshot,
                    currentIdentity: currentIdentity,
                    verifiedEvidence: try factory.evidence(revision: snapshot.revision)
                )
            },
            startPositionProvider: { pose, currentIdentity in
                ARPoseIndoorNavigationAdapter().adapt(
                    pose,
                    currentIdentity: currentIdentity,
                    verifiedFloorPosition: try factory.floorPosition(timestamp: pose.timestamp)
                )
            }
        )
        controller.activate()
        surfaceContinuation.yield(fixture.surface(revision: 1))
        poseContinuation.yield(fixture.pose(timestamp: 10))
        controller.navigate(to: try fixture.metadata(x: 2))
        await eventually { controller.isRoutingForTesting }

        let replacement = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        identity.value = replacement
        poseContinuation.yield(fixture.pose(timestamp: 11, identity: replacement))
        await eventually { controller.state == .waitingForSurface }
        try await Task.sleep(for: .milliseconds(140))

        XCTAssertNil(controller.renderablePath)
        XCTAssertNil(controller.latestPresentation)
        XCTAssertGreaterThanOrEqual(controller.metrics.requestsCancelled, 1)
    }

    func testNewRequestCannotBeClearedByCancelledOldOperation() async throws {
        let fixture = NavigationAppFixture()
        let (surfaceStream, surfaceContinuation) = AsyncStream<ARSurfaceStateSnapshot>.makeStream()
        let (poseStream, poseContinuation) = AsyncStream<ARPoseSnapshot>.makeStream()
        let identity = MainActorIdentity(fixture.identity)
        let factory = fixture
        let controller = IndoorNavigationController(
            surfaces: surfaceStream,
            poses: poseStream,
            currentIdentityProvider: { identity.value },
            evidenceProvider: { snapshot, currentIdentity in
                try await Task.sleep(for: .milliseconds(40))
                return ARSurfaceIndoorNavigationEvidenceAdapter().adapt(
                    snapshot,
                    currentIdentity: currentIdentity,
                    verifiedEvidence: try factory.evidence(revision: snapshot.revision)
                )
            },
            startPositionProvider: { pose, currentIdentity in
                ARPoseIndoorNavigationAdapter().adapt(
                    pose,
                    currentIdentity: currentIdentity,
                    verifiedFloorPosition: try factory.floorPosition(timestamp: pose.timestamp)
                )
            }
        )
        let old = try fixture.metadata(x: 2, objectID: ObjectID())
        let replacement = try fixture.metadata(x: 1, objectID: ObjectID())
        controller.activate()
        surfaceContinuation.yield(fixture.surface(revision: 1))
        poseContinuation.yield(fixture.pose(timestamp: 10))
        controller.navigate(to: old)
        await eventually { controller.isRoutingForTesting }
        controller.navigate(to: replacement)

        await eventually(timeoutIterations: 300) {
            controller.renderablePath?.destinationObjectID == replacement.object.id
        }
        XCTAssertEqual(controller.renderablePath?.waypoints.last, try Vec3(x: 1, y: 0, z: 0))
        XCTAssertGreaterThanOrEqual(controller.metrics.requestsCancelled, 1)
    }

    func testGroundedTargetLoadsOriginalMetadataBeforeRouting() async throws {
        let fixture = NavigationAppFixture()
        let sourceMapID = MapID()
        let sourceFrameID = CoordinateFrameID()
        let source = try fixture.metadata(
            x: 20,
            mapID: sourceMapID,
            frameID: sourceFrameID
        )
        let currentPosition = try FramedPosition(
            coordinateFrameID: fixture.identity.coordinateFrameID,
            value: Vec3(x: 2, y: 0, z: 0),
            observedAt: source.position.observedAt,
            trackingQuality: .normal,
            uncertainty: .highConfidenceDepth
        )
        let target = GroundedSpatialObjectQueryTarget(
            semanticLabel: source.object.semanticLabel,
            objectID: source.object.id,
            sourceMapID: sourceMapID,
            currentMapID: fixture.identity.mapID,
            currentSegmentID: fixture.identity.segmentID,
            sourcePosition: source.position,
            currentFramePosition: currentPosition,
            intent: .navigate,
            effectiveConfidence: ConfidenceScore(clamping: 0.9),
            confidenceGrade: .high,
            alignmentConfidence: ConfidenceScore(clamping: 0.9),
            resolvedAt: 9
        )
        let harness = makeHarness(
            fixture: fixture,
            evidence: try fixture.evidence(revision: 1),
            metadataProvider: { objectID, mapID in
                objectID == source.object.id && mapID == sourceMapID ? source : nil
            },
            now: 10
        )
        harness.controller.activate()
        harness.surfaceContinuation.yield(fixture.surface(revision: 1))
        harness.poseContinuation.yield(fixture.pose(timestamp: 10))
        harness.controller.navigate(to: target)

        await eventually { harness.controller.renderablePath != nil }
        XCTAssertEqual(harness.controller.renderablePath?.destinationObjectID, source.object.id)
        XCTAssertEqual(harness.controller.renderablePath?.waypoints.last, currentPosition.value)
    }

    private func makeHarness(
        fixture: NavigationAppFixture,
        engine: IndoorARNavigationEngine = IndoorARNavigationEngine(),
        evidence: IndoorNavigationEvidence? = nil,
        metadataProvider: IndoorNavigationController.SourceMetadataProvider? = nil,
        surfaceStabilityDelay: Duration = .zero,
        evaluationTimestampProvider: IndoorNavigationController.EvaluationTimestampProvider? = nil,
        now: TimeInterval = 10
    ) -> NavigationControllerHarness {
        let (surfaceStream, surfaceContinuation) = AsyncStream<ARSurfaceStateSnapshot>.makeStream()
        let (poseStream, poseContinuation) = AsyncStream<ARPoseSnapshot>.makeStream()
        let identity = MainActorIdentity(fixture.identity)
        let verifiedEvidence = evidence ?? (try! fixture.evidence(revision: 1))
        let controller = IndoorNavigationController(
            surfaces: surfaceStream,
            poses: poseStream,
            currentIdentityProvider: { identity.value },
            evidenceProvider: { snapshot, currentIdentity in
                ARSurfaceIndoorNavigationEvidenceAdapter().adapt(
                    snapshot,
                    currentIdentity: currentIdentity,
                    verifiedEvidence: verifiedEvidence
                )
            },
            startPositionProvider: { pose, currentIdentity in
                ARPoseIndoorNavigationAdapter().adapt(
                    pose,
                    currentIdentity: currentIdentity,
                    verifiedFloorPosition: try fixture.floorPosition(timestamp: pose.timestamp)
                )
            },
            sourceMetadataProvider: metadataProvider,
            engine: engine,
            surfaceStabilityDelay: surfaceStabilityDelay,
            evaluationTimestampProvider: evaluationTimestampProvider,
            nowProvider: { now }
        )
        return NavigationControllerHarness(
            controller: controller,
            surfaceContinuation: surfaceContinuation,
            poseContinuation: poseContinuation
        )
    }

    private func makeRecordingHarness(
        fixture: NavigationAppFixture,
        surfaceStabilityDelay: Duration = .zero
    ) -> (NavigationControllerHarness, NavigationRevisionRecorder) {
        let (surfaceStream, surfaceContinuation) = AsyncStream<ARSurfaceStateSnapshot>.makeStream()
        let (poseStream, poseContinuation) = AsyncStream<ARPoseSnapshot>.makeStream()
        let identity = MainActorIdentity(fixture.identity)
        let recorder = NavigationRevisionRecorder()
        let controller = IndoorNavigationController(
            surfaces: surfaceStream,
            poses: poseStream,
            currentIdentityProvider: { identity.value },
            evidenceProvider: { snapshot, currentIdentity in
                await recorder.record(snapshot.revision)
                return ARSurfaceIndoorNavigationEvidenceAdapter().adapt(
                    snapshot,
                    currentIdentity: currentIdentity,
                    verifiedEvidence: try fixture.evidence(
                        revision: snapshot.revision,
                        timestamp: snapshot.timestamp
                    )
                )
            },
            startPositionProvider: { pose, currentIdentity in
                ARPoseIndoorNavigationAdapter().adapt(
                    pose,
                    currentIdentity: currentIdentity,
                    verifiedFloorPosition: try fixture.floorPosition(timestamp: pose.timestamp)
                )
            },
            surfaceStabilityDelay: surfaceStabilityDelay,
            nowProvider: { 10 }
        )
        return (
            NavigationControllerHarness(
                controller: controller,
                surfaceContinuation: surfaceContinuation,
                poseContinuation: poseContinuation
            ),
            recorder
        )
    }

    private func eventually(
        timeoutIterations: Int = 150,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition did not become true")
    }

    private func waitForEvidenceRequest(
        _ provider: SuspendedNavigationEvidenceProvider,
        _ expected: Int
    ) async throws {
        for _ in 0..<250 {
            if await provider.requestCount == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Evidence provider did not receive \(expected) requests.")
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
private final class MainActorIdentity {
    var value: ARCaptureIdentity

    init(_ value: ARCaptureIdentity) {
        self.value = value
    }
}

private actor NavigationRevisionRecorder {
    private var revisions: [UInt64] = []

    func record(_ revision: UInt64) {
        revisions.append(revision)
    }

    func recordedRevisions() -> [UInt64] {
        revisions
    }
}

private actor SuspendedNavigationEvidenceProvider {
    private var continuations: [CheckedContinuation<ARIndoorNavigationEvidenceAdaptation, Error>] = []

    var requestCount: Int {
        continuations.count
    }

    func load(
        surface: ARSurfaceStateSnapshot,
        identity: ARCaptureIdentity
    ) async throws -> ARIndoorNavigationEvidenceAdaptation {
        _ = surface
        _ = identity
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(index: Int, with adaptation: ARIndoorNavigationEvidenceAdaptation) {
        continuations[index].resume(returning: adaptation)
    }
}

private actor NavigationDeletionBarrierCompletion {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}

private struct NavigationControllerHarness {
    let controller: IndoorNavigationController
    let surfaceContinuation: AsyncStream<ARSurfaceStateSnapshot>.Continuation
    let poseContinuation: AsyncStream<ARPoseSnapshot>.Continuation
}

private struct NavigationAppFixture: Sendable {
    let identity: ARCaptureIdentity

    init(identity: ARCaptureIdentity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)) {
        self.identity = identity
    }

    func surface(
        revision: UInt64,
        timestamp: TimeInterval = 10,
        isCurrentSessionData: Bool = true,
        identity: ARCaptureIdentity? = nil
    ) -> ARSurfaceStateSnapshot {
        let identity = identity ?? self.identity
        return ARSurfaceStateSnapshot(
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: identity.mapID,
            coordinateFrameStatus: identity.status,
            revision: revision,
            timestamp: timestamp,
            planes: [:],
            meshes: [:],
            unresolvedFailures: [],
            isCurrentSessionData: isCurrentSessionData
        )
    }

    func pose(
        timestamp: TimeInterval,
        identity: ARCaptureIdentity? = nil,
        x: Float = 0,
        z: Float = 0,
        sessionRunGeneration: UInt64 = 1,
        trackingState: ARTrackingStateSnapshot = .normal,
        worldMappingStatus: ARWorldMappingStatusSnapshot = .mapped
    ) -> ARPoseSnapshot {
        let identity = identity ?? self.identity
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(x, 1.5, z, 1)
        return ARPoseSnapshot(
            id: ARFrameID(),
            sessionToken: ARSessionFrameToken(
                sessionRunGeneration: sessionRunGeneration,
                attachmentEpoch: 1
            ),
            coordinateFrameID: identity.coordinateFrameID,
            segmentID: identity.segmentID,
            mapID: identity.mapID,
            coordinateFrameStatus: identity.status,
            capturedAt: 100,
            timestamp: timestamp,
            cameraTransform: Matrix4x4Snapshot(transform),
            trackingState: trackingState,
            worldMappingStatus: worldMappingStatus
        )
    }

    func floorPosition(timestamp: TimeInterval) throws -> FramedPosition {
        try FramedPosition(
            coordinateFrameID: identity.coordinateFrameID,
            value: Vec3(x: 0, y: 0, z: 0),
            observedAt: timestamp,
            trackingQuality: .normal,
            uncertainty: .raycastEstimate
        )
    }

    func evidence(
        revision: UInt64,
        timestamp: TimeInterval = 10,
        cells: [IndoorNavigationCell] = [
            IndoorNavigationCell(column: 0, row: 0),
            IndoorNavigationCell(column: 1, row: 0),
            IndoorNavigationCell(column: 2, row: 0),
        ]
    ) throws -> IndoorNavigationEvidence {
        try IndoorNavigationEvidence(
            mapID: identity.mapID!,
            coordinateFrameID: identity.coordinateFrameID,
            revision: revision,
            observedAt: timestamp,
            gridOrigin: Vec3(x: 0, y: 0, z: 0),
            cellSize: 1,
            floors: try cells.map {
                try IndoorNavigationFloorEvidence(
                    cell: $0,
                    zoneIdentifier: "room",
                    elevation: 0,
                    confidence: ConfidenceScore(clamping: 0.9)
                )
            },
            mesh: cells.map {
                IndoorNavigationMeshEvidence(
                    cell: $0,
                    occupancy: .free,
                    confidence: ConfidenceScore(clamping: 0.9)
                )
            },
            completeness: .complete
        )
    }

    func metadata(
        x: Double,
        mapID: MapID? = nil,
        frameID: CoordinateFrameID? = nil,
        objectID: ObjectID = ObjectID(),
        confidence: Double = 0.9
    ) throws -> SpatialObjectMetadata {
        let position = try Vec3(x: x, y: 0, z: 0)
        let object = try SpatialObject(
            id: objectID,
            semanticLabel: "sofa",
            position: position,
            certainty: .confirmed,
            presence: .lastSeen,
            confidence: ConfidenceVector(
                semantic: ConfidenceScore(clamping: confidence),
                geometry: ConfidenceScore(clamping: confidence),
                tracking: ConfidenceScore(clamping: confidence),
                place: ConfidenceScore(clamping: confidence),
                identity: ConfidenceScore(clamping: confidence),
                objectState: ConfidenceScore(clamping: confidence)
            ),
            firstSeenAt: 1,
            lastSeenAt: 9
        )
        let framed = try FramedPosition(
            coordinateFrameID: frameID ?? identity.coordinateFrameID,
            value: position,
            observedAt: 9,
            trackingQuality: .normal,
            uncertainty: .highConfidenceDepth
        )
        return try SpatialObjectMetadata(
            mapID: mapID ?? identity.mapID!,
            object: object,
            position: framed
        )
    }
}
