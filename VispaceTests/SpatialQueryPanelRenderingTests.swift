import SwiftUI
import UIKit
import VispaceCore
import XCTest
import simd

@testable import Vispace

@MainActor
final class SpatialQueryPanelRenderingTests: XCTestCase {
    /// Captures the production panel with in-memory controller inputs. These
    /// images support manual layout review; the backdrop and route failure are
    /// synthetic. This unit-target capture is not a tap or accessibility audit:
    /// SwiftUI virtual controls are not exposed by public UIKit container APIs
    /// here. Those interactions require a separate XCUITest accessibility tree.
    func testCaptureNavigationPanelOnPortraitLightDarkAndLargestAccessibilityText() async throws {
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
                    XCTAssertEqual(fixture.query.canNavigateToSelectedObject, !retry)
                    XCTAssertEqual(fixture.query.canRefreshSelectedNavigation, retry)
                    XCTAssertEqual(fixture.navigation.state, retry ? .noPath : .inactive)
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

                    XCTAssertNotNil(screenshot.cgImage)
                    XCTAssertGreaterThan(screenshot.size.height, screenshot.size.width)
                    // Gray backdrop and the demo label contain no cyan. Require
                    // visible production navigation-button pixels, so an empty
                    // host/background capture cannot pass as a rendered panel.
                    XCTAssertGreaterThan(try cyanButtonPixelCount(in: screenshot), 100,
                                         "Missing visible navigation button in \(name)")
                    await fixture.navigation.deactivateAndWaitForPendingWork()
                    await fixture.query.invalidateAndWaitForPendingWork()
                }
            }
        }
    }

    private func cyanButtonPixelCount(in image: UIImage) throws -> Int {
        let source = try XCTUnwrap(image.cgImage)
        let width = 128, height = 256
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            let pixels = buffer.bindMemory(to: UInt8.self)
            var count = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
                if green > red + 35 && blue > red + 35 && abs(green - blue) < 60 { count += 1 }
            }
            return count
        }
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
