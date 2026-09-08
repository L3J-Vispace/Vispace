import RealityKit
import UIKit
import VispaceCore
import XCTest

@testable import Vispace

@MainActor
final class ARNavigationRibbonRenderingTests: XCTestCase {
    func testLongRouteUsesFourBatchedMeshes() throws {
        let points = try (0..<128).map { try Vec3(x: 0, y: 0, z: -Double($0) * 0.1) }
        let anchor = try XCTUnwrap(ARNavigationRibbonRendering.makeAnchor(for: makePath(points)))
        XCTAssertEqual(anchor.name, "vispace-navigation-route")
        XCTAssertEqual(Set(anchor.children.map(\.name)), [
            "vispace-navigation-ribbon", "vispace-navigation-edges",
            "vispace-navigation-chevrons", "vispace-navigation-destination",
        ])
        XCTAssertEqual(anchor.children.count, 4)
        XCTAssertTrue(anchor.children.allSatisfy { $0 is ModelEntity && $0.children.isEmpty })
    }

    func testRouteReplacementAndClearPreserveTheGroundedMarker() throws {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        let coordinator = CameraSurfaceView.Coordinator(sessionController: RibbonTestCameraSession())
        coordinator.updateWorldMarker(in: view, position: try Vec3(x: 1, y: 0.5, z: -2))
        let marker = try XCTUnwrap(view.scene.findEntity(named: "vispace-grounded-target"))
        let firstPath = try makePath([Vec3(x: 0, y: 0, z: 0), Vec3(x: 0, y: 0, z: -3)])
        coordinator.updateNavigationPath(in: view, path: firstPath)
        let first = try XCTUnwrap(view.scene.findEntity(named: "vispace-navigation-route"))
        XCTAssertEqual(view.scene.anchors.count, 2)
        coordinator.updateNavigationPath(in: view, path: firstPath)
        XCTAssertTrue(view.scene.findEntity(named: "vispace-navigation-route") === first)
        XCTAssertEqual(view.scene.anchors.count, 2)

        let replacement = try makePath([
            Vec3(x: 0, y: 0, z: 0), Vec3(x: 0, y: 0, z: -2), Vec3(x: 1, y: 0, z: -2),
        ])
        coordinator.updateNavigationPath(in: view, path: replacement)
        XCTAssertFalse(view.scene.findEntity(named: "vispace-navigation-route") === first)
        XCTAssertEqual(view.scene.anchors.count, 2)
        XCTAssertTrue(view.scene.findEntity(named: "vispace-grounded-target") === marker)
        coordinator.updateNavigationPath(in: view, path: nil)
        XCTAssertNil(view.scene.findEntity(named: "vispace-navigation-route"))
        XCTAssertEqual(view.scene.anchors.count, 1)
        XCTAssertTrue(view.scene.findEntity(named: "vispace-grounded-target") === marker)
        coordinator.updateNavigationPath(in: view, path: nil)
        XCTAssertEqual(view.scene.anchors.count, 1)
    }

    func testCustomClearanceConstrainsTheActualMeshes() throws {
        let points = try [Vec3(x: 0, y: 0, z: 0), Vec3(x: 0, y: 0, z: -4)]
        let narrow = try XCTUnwrap(ARNavigationRibbonRendering.makeAnchor(
            for: makePath(points, maximumHalfWidth: 0.07)))
        let standard = try XCTUnwrap(ARNavigationRibbonRendering.makeAnchor(for: makePath(points)))
        let narrowWidth = narrow.visualBounds(relativeTo: narrow).extents.x
        let standardWidth = standard.visualBounds(relativeTo: standard).extents.x
        XCTAssertGreaterThan(narrowWidth, 0)
        XCTAssertLessThanOrEqual(narrowWidth, 0.140_01)
        XCTAssertGreaterThan(standardWidth, narrowWidth)
    }

    /// Actual RealityKit rendering on a synthetic floor, never camera evidence.
    /// ARView.snapshot supplies pixels; UIKit adds the explicit demo label.
    func testCaptureProductionRibbonOnLightAndDarkSyntheticFloors() async throws {
        try await captureProductionRibbon()
    }

    func testCaptureRestoresAnExistingARCameraSurface() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let priorKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let cameraWindow = UIWindow(windowScene: scene)
        let host = UIViewController()
        let cameraView = ARView(frame: scene.coordinateSpace.bounds, cameraMode: .ar,
                                automaticallyConfigureSession: false)
        let existingAnchor = AnchorEntity(world: .zero)
        cameraView.scene.addAnchor(existingAnchor)
        host.view = cameraView
        cameraWindow.rootViewController = host
        cameraWindow.makeKeyAndVisible()
        defer {
            cameraWindow.isHidden = true
            cameraWindow.rootViewController = nil
            priorKeyWindow?.makeKey()
        }

        try await captureProductionRibbon()

        XCTAssertEqual(cameraView.cameraMode, .ar)
        XCTAssertTrue(cameraWindow.isKeyWindow)
        XCTAssertFalse(cameraWindow.isHidden)
        XCTAssertEqual(cameraView.scene.anchors.count, 1)
        XCTAssertTrue(cameraView.scene.anchors.first === existingAnchor)
    }

    private func captureProductionRibbon() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let priorKeyWindow = scene.windows.first(where: \.isKeyWindow)
        // A host .ar view makes a second .nonAR view render black on Simulator.
        // Isolate synthetic rendering without altering the host's scene content.
        let priorCameraViews = scene.windows.flatMap { cameraViews(in: $0) }.map {
            (view: $0, mode: $0.cameraMode)
        }
        priorCameraViews.forEach { $0.view.cameraMode = .nonAR }
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        let view = ARView(frame: scene.coordinateSpace.bounds, cameraMode: .nonAR,
                          automaticallyConfigureSession: false)
        // This unlit floor fixture does not use photographic effects or shadows.
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField,
                              .disableCameraGrain, .disableGroundingShadows]
        host.view = view
        window.rootViewController = host
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            priorCameraViews.forEach { $0.view.cameraMode = $0.mode }
            priorKeyWindow?.makeKey()
        }
        XCTAssertGreaterThan(window.bounds.height, window.bounds.width, "Capture on a portrait iPhone Simulator")

        let label = UILabel()
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.backgroundColor = .black
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])

        let cameraAnchor = AnchorEntity(world: .zero)
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 64
        camera.look(at: SIMD3<Float>(0, 0, -3.3), from: SIMD3<Float>(0, 2.2, 1.3), relativeTo: nil)
        cameraAnchor.addChild(camera)
        view.scene.addAnchor(cameraAnchor)
        let floorAnchor = AnchorEntity(world: SIMD3<Float>(0, -0.01, -4))
        let floor = ModelEntity(mesh: .generatePlane(width: 14, depth: 16),
                                materials: [UnlitMaterial(color: .darkGray)])
        floorAnchor.addChild(floor)
        view.scene.addAnchor(floorAnchor)
        let route = try makePath([
            Vec3(x: -0.55, y: 0, z: 0.25), Vec3(x: -0.55, y: 0, z: -2.5),
            Vec3(x: 1.15, y: 0, z: -2.5), Vec3(x: 1.15, y: 0, z: -5),
            Vec3(x: -0.35, y: 0, z: -5), Vec3(x: -0.35, y: 0, z: -6.1),
        ])
        view.scene.addAnchor(try XCTUnwrap(ARNavigationRibbonRendering.makeAnchor(for: route)))

        for (name, color, style) in [
            ("dark", UIColor(white: 0.13, alpha: 1), UIUserInterfaceStyle.dark),
            ("light", UIColor(white: 0.76, alpha: 1), UIUserInterfaceStyle.light),
        ] {
            window.overrideUserInterfaceStyle = style
            floor.model?.materials = [UnlitMaterial(color: color)]
            view.environment.background = .color(color)
            label.text = "합성 테스트 장면 · \(name == "dark" ? "어두운 바닥" : "밝은 바닥")\n실측 경로가 아닙니다"
            window.layoutIfNeeded()
            try await waitForSceneFrames(in: view)
            let pixels = try await snapshotPixels(of: view)
            let rendered = try XCTUnwrap(UIImage(data: pixels))
            XCTAssertGreaterThan(cyanPixelCount(in: rendered), 12,
                                 "The real renderer must produce visible cyan route pixels")
            let preview = UIImageView(image: rendered)
            preview.frame = view.bounds
            preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(preview, belowSubview: label)
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "navigation-ribbon-synthetic-\(name)-portrait"
            attachment.lifetime = .keepAlways
            add(attachment)
            preview.removeFromSuperview()
        }
    }

    private func cameraViews(in view: UIView) -> [ARView] {
        (view as? ARView).map { [$0] } ?? view.subviews.flatMap { cameraViews(in: $0) }
    }

    private func waitForSceneFrames(in view: ARView) async throws {
        let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        let continuation = channel.continuation
        let subscription = view.scene.subscribe(to: SceneEvents.Update.self) { _ in continuation.yield(()) }
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            continuation.finish()
        }
        defer { subscription.cancel(); timeout.cancel(); continuation.finish() }
        var frames = 0
        for await _ in channel.stream {
            frames += 1
            if frames >= 3 { return }
        }
        throw RibbonCaptureError.noRenderedFrames
    }

    private func snapshotPixels(of view: ARView) async throws -> Data {
        // Send Data through the callback boundary, not a non-Sendable UIImage.
        let channel = AsyncStream<Data?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let continuation = channel.continuation
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            continuation.finish()
        }
        defer { timeout.cancel(); continuation.finish() }
        view.snapshot(saveToHDR: false) { image in
            continuation.yield(image?.pngData())
            continuation.finish()
        }
        for await image in channel.stream {
            guard let image else { throw RibbonCaptureError.missingSnapshot }
            return image
        }
        throw RibbonCaptureError.missingSnapshot
    }

    private func cyanPixelCount(in image: UIImage) -> Int {
        guard let source = image.cgImage else { return 0 }
        let width = 160, height = 320
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return 0 }
            context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            let pixels = buffer.bindMemory(to: UInt8.self)
            var count = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let red = Int(pixels[index])
                let green = Int(pixels[index + 1])
                let blue = Int(pixels[index + 2])
                if green > red + 20 && blue > red + 20 { count += 1 }
            }
            return count
        }
    }

    private func makePath(_ points: [Vec3], maximumHalfWidth: Double = 0.20) throws -> ARIndoorNavigationPathOutput {
        let identity = ARCaptureIdentity(mapID: MapID(), status: .confirmed)
        let confidence = try ConfidenceScore(validating: 0.95)
        let distance = zip(points, points.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        let straight = points.first!.distance(to: points.last!)
        let ratio = straight > 1e-8 ? distance / straight : 1
        let quality: IndoorNavigationPathQuality = ratio <= 1.05 ? .direct
            : (ratio <= 1.50 ? .efficientDetour : .extendedDetour)
        let path = try IndoorNavigationPath(mapID: XCTUnwrap(identity.mapID),
            coordinateFrameID: identity.coordinateFrameID, destinationObjectID: ObjectID(),
            evidenceRevision: 1, waypoints: points.enumerated().map {
                IndoorNavigationWaypoint(cell: IndoorNavigationCell(column: $0.offset, row: 0),
                    position: $0.element, evidenceConfidence: confidence)
            }, totalDistance: distance, straightLineDistance: straight, quality: quality,
            confidenceScore: confidence, confidence: .high, exploredNodeCount: points.count)
        return try ARIndoorNavigationPathOutput(path: path, semanticLabel: "synthetic destination",
            identity: identity, surfaceRevision: 1, maximumHalfWidth: maximumHalfWidth)
    }
}

private enum RibbonCaptureError: Error { case noRenderedFrames, missingSnapshot }

@MainActor
private final class RibbonTestCameraSession: CameraSessionControlling {
    func attach(to view: ARView) {}
    func detach(from view: ARView) {}
    func activate() {}
    func deactivate() {}
    func enterBackground() {}
    func setDisplayGeometry(_ geometry: FrameDisplayGeometry) {}
}
