import SwiftUI
import UIKit
import VispaceCore
import XCTest
import simd

@testable import Vispace

@MainActor
final class SpatialQueryPanelRenderingTests: XCTestCase {
    /// Captures the production panel with in-memory controller inputs. These
    /// images prove UI layout only; the backdrop and route failure are synthetic.
    func testNavigationActionsOnPortraitLightDarkAndLargestAccessibilityText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let priorKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        defer {
            window.isHidden = true
            window.rootViewController = nil
            priorKeyWindow?.makeKey()
        }
        XCTAssertGreaterThan(scene.coordinateSpace.bounds.height, scene.coordinateSpace.bounds.width)

        for retry in [false, true] {
            for dark in [false, true] {
                for largeText in [false, true] {
                    let fixture = try await makeFixture(retry: retry)
                    let panel = SpatialQueryPanel(
                        perceptionController: fixture.perception, queryController: fixture.query,
                        relationQueryController: fixture.relation, placementController: fixture.placement,
                        navigationController: fixture.navigation, onManageData: {},
                        distanceDescription: { _ in "2 m" })
                    let root = ZStack(alignment: .top) {
                        Color(white: dark ? 0.15 : 0.8).ignoresSafeArea()
                        Text("합성 UI 검증 · 실제 카메라 장면 아님")
                            .font(.caption).foregroundStyle(dark ? .white : .black)
                            .padding(.top, 12)
                        panel
                    }
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.dynamicTypeSize, largeText ? .accessibility5 : .large)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                    let host = UIHostingController(rootView: root)
                    window.overrideUserInterfaceStyle = dark ? .dark : .light
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    try await Task.sleep(for: .milliseconds(300))
                    window.layoutIfNeeded()

                    let name = "query-panel-\(retry ? "retry" : "selected")-\(dark ? "dark" : "light")-\(largeText ? "AXXXL" : "standard")"
                    let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let attachment = XCTAttachment(image: screenshot)
                    attachment.name = name
                    attachment.lifetime = .keepAlways
                    add(attachment)

                    // SwiftUI controls are virtual accessibility elements, not
                    // UIButton subviews. Inspect only public UIKit container APIs.
                    let elements = accessibilityElements(in: window)
                    let primaryID = retry ? "vispace.navigation.retry" : "vispace.query.navigate"
                    let primary = elements.first { identifier(of: $0) == primaryID }
                    let dismiss = elements.first { identifier(of: $0) == "vispace.query.dismiss" }
                    if let result = elements.first(where: { identifier(of: $0) == "vispace.query.result" }) {
                        let frame = window.convert(result.accessibilityFrame, from: nil)
                        XCTAssertTrue(window.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                                      "Result message must fit on screen at this text size: \(frame)")
                    }
                    let diagnostic = elements.compactMap { item -> String? in
                        guard let id = identifier(of: item) else { return nil }
                        return "\(id): \(item.accessibilityFrame)"
                    }.joined(separator: "\n")
                    let tree = XCTAttachment(string: diagnostic)
                    tree.name = "\(name)-accessibility-frames"
                    tree.lifetime = .keepAlways
                    add(tree)

                    if let primary, let dismiss {
                        assertReachableButton(primary, in: window, name: primaryID)
                        assertReachableButton(dismiss, in: window, name: "dismiss")
                        let requests = fixture.query.metrics.requestsStarted
                        let selectedID = fixture.query.latestGroundedTarget?.objectID
                        XCTAssertTrue(primary.accessibilityActivate(), "The native navigation action must be callable")
                        try await waitUntil {
                            fixture.query.metrics.requestsStarted > requests && !fixture.query.isProcessingForTesting
                        }
                        XCTAssertEqual(fixture.query.latestGroundedTarget?.intent, .navigate)
                        XCTAssertEqual(fixture.query.latestGroundedTarget?.objectID, selectedID)
                        try await Task.sleep(for: .milliseconds(100))
                        window.layoutIfNeeded()
                        let updatedDismiss = try XCTUnwrap(accessibilityElements(in: window).first {
                            identifier(of: $0) == "vispace.query.dismiss"
                        })
                        XCTAssertTrue(updatedDismiss.accessibilityActivate(), "Dismiss must expose its native action")
                        try await waitUntil { fixture.query.state == .idle }
                        XCTAssertNil(fixture.navigation.latestPresentation)
                        XCTAssertNil(fixture.navigation.renderablePath)
                    } else {
                        XCTFail("Public accessibility tree did not expose the navigation and dismiss buttons in \(name). Inspect the saved capture; do not count this as an interaction pass.")
                    }
                    await fixture.navigation.deactivateAndWaitForPendingWork()
                    await fixture.query.invalidateAndWaitForPendingWork()
                }
            }
        }
    }

    private func assertReachableButton(_ element: NSObject, in window: UIWindow, name: String) {
        let frame = window.convert(element.accessibilityFrame, from: nil)
        XCTAssertTrue(element.accessibilityTraits.contains(.button), name)
        XCTAssertGreaterThanOrEqual(frame.width, 44, name)
        XCTAssertGreaterThanOrEqual(frame.height, 44, name)
        XCTAssertTrue(window.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                      "\(name) must stay inside the portrait viewport: \(frame)")
        XCTAssertFalse(frame.isEmpty, name)
    }

    private func identifier(of element: NSObject) -> String? {
        (element as? UIAccessibilityIdentification)?.accessibilityIdentifier
    }

    private func accessibilityElements(in root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ element: NSObject, depth: Int) {
            guard depth < 40, visited.insert(ObjectIdentifier(element)).inserted else { return }
            result.append(element)
            for child in element.accessibilityElements ?? [] {
                if let object = child as? NSObject { visit(object, depth: depth + 1) }
            }
            let count = element.accessibilityElementCount()
            if count > 0 && count < 1_000 {
                for index in 0..<count {
                    if let object = element.accessibilityElement(at: index) as? NSObject {
                        visit(object, depth: depth + 1)
                    }
                }
            }
            if let view = element as? UIView {
                for child in view.subviews { visit(child, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return result
    }

    private func makeFixture(retry: Bool) async throws -> PanelFixture {
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let now = Date().timeIntervalSince1970
        let position = try Vec3(x: 1, y: 0, z: -2)
        let object = try SpatialObject(semanticLabel: "keyboard", position: position,
            certainty: .confirmed, presence: .visible,
            confidence: ConfidenceVector(semantic: .one, geometry: .one, tracking: .one,
                identity: .one, objectState: .one), firstSeenAt: now - 120, lastSeenAt: now - 60,
            displayName: "창가 책상 옆 개인용 기계식 키보드")
        let metadata = try SpatialObjectMetadata(mapID: XCTUnwrap(identity.mapID), object: object,
            position: FramedPosition(coordinateFrameID: identity.coordinateFrameID, value: position,
                observedAt: now - 60, trackingQuality: .normal, uncertainty: .highConfidenceDepth))
        let snapshot = SpatialObjectQueryRepositorySnapshot(
            records: [StoredSpatialObjectRecord(metadata: metadata, memoryTier: .realtime)],
            alignmentCatalog: try CoordinateAlignmentCatalogSnapshot())
        let query = SpatialObjectQueryController(snapshotProvider: { _ in snapshot },
            currentIdentityProvider: { identity })
        query.submit(retry ? "키보드까지 안내해줘" : "키보드 어디있어", now: now)
        try await waitUntil { !query.isProcessingForTesting }
        XCTAssertNotNil(query.latestGroundedTarget)
        let surfaceStream = AsyncStream<ARSurfaceStateSnapshot>.makeStream()
        let poseStream = AsyncStream<ARPoseSnapshot>.makeStream()
        let navigation = IndoorNavigationController(surfaces: surfaceStream.stream, poses: poseStream.stream,
            currentIdentityProvider: { identity },
            evidenceProvider: { _, _ in .insufficientEvidence(.coverageAttestationUnavailable) },
            sourceMetadataProvider: { _, _ in metadata })
        if retry {
            navigation.activate()
            surfaceStream.continuation.yield(ARSurfaceStateSnapshot(
                coordinateFrameID: identity.coordinateFrameID, segmentID: identity.segmentID,
                mapID: identity.mapID, coordinateFrameStatus: .confirmed, revision: 1, timestamp: 10,
                planes: [:], meshes: [:], unresolvedFailures: [], isCurrentSessionData: true))
            poseStream.continuation.yield(ARPoseSnapshot(id: ARFrameID(),
                sessionToken: ARSessionFrameToken(sessionRunGeneration: 1, attachmentEpoch: 1),
                coordinateFrameID: identity.coordinateFrameID, segmentID: identity.segmentID,
                mapID: identity.mapID, coordinateFrameStatus: .confirmed, capturedAt: now, timestamp: 10,
                cameraTransform: Matrix4x4Snapshot(matrix_identity_float4x4),
                trackingState: .normal, worldMappingStatus: .mapped))
            navigation.navigate(to: try XCTUnwrap(query.latestGroundedTarget))
            try await waitUntil { navigation.state == .noPath }
        }
        surfaceStream.continuation.finish()
        poseStream.continuation.finish()
        let perception = SpatialPerceptionController(frames: AsyncStream { $0.finish() },
            detectorResolution: ObjectDetectorResolution(detector: NoOpObjectDetector(), availability: .available),
            confirmedIdentityProvider: { _ in identity }, metadataWriter: { _ in })
        return PanelFixture(perception: perception, query: query,
            relation: SpatialRelationQueryController(snapshotProvider: { _ in nil },
                currentIdentityProvider: { identity }),
            placement: FurniturePlacementController(candidatePositionProvider: { _ in nil },
                objectMetadataProvider: { [] }, capabilitiesProvider: { nil }), navigation: navigation)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PanelCaptureFailure.stateDidNotSettle
    }
}

private enum PanelCaptureFailure: Error { case stateDidNotSettle }

@MainActor
private struct PanelFixture {
    let perception: SpatialPerceptionController
    let query: SpatialObjectQueryController
    let relation: SpatialRelationQueryController
    let placement: FurniturePlacementController
    let navigation: IndoorNavigationController
}
