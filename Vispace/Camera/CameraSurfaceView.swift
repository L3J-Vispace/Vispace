import RealityKit
import SwiftUI
import VispaceCore
import simd

/// Placement yaw is measured from +X toward +Z. RealityKit's right-handed
/// rotation around +Y turns +X toward -Z, so rendering uses the opposite sign.
@MainActor
enum FurniturePlacementRendering {
    static func makePreview(dimensions: FurnitureDimensions, yawRadians: Double) -> ModelEntity {
        let preview = ModelEntity(
            mesh: .generateBox(
                width: Float(dimensions.width), height: Float(dimensions.height),
                depth: Float(dimensions.depth)
            ),
            materials: [SimpleMaterial(
                color: UIColor.systemGreen.withAlphaComponent(0.30), isMetallic: false
            )]
        )
        preview.name = "vispace-furniture-placement"
        preview.position.y = Float(dimensions.height / 2)
        preview.orientation = simd_quatf(angle: -Float(yawRadians), axis: SIMD3<Float>(0, 1, 0))
        return preview
    }
}

@MainActor
struct CameraSurfaceView: UIViewRepresentable {
    let sessionController: any CameraSessionControlling
    let exposesAccessibility: Bool
    let worldMarkerPosition: Vec3?
    let recommendedFurniturePlacement: RecommendedFurniturePlacement?
    let navigationPath: ARIndoorNavigationPathOutput?

    init(
        sessionController: any CameraSessionControlling,
        exposesAccessibility: Bool,
        worldMarkerPosition: Vec3? = nil,
        recommendedFurniturePlacement: RecommendedFurniturePlacement? = nil,
        navigationPath: ARIndoorNavigationPathOutput? = nil
    ) {
        self.sessionController = sessionController
        self.exposesAccessibility = exposesAccessibility
        self.worldMarkerPosition = worldMarkerPosition
        self.recommendedFurniturePlacement = recommendedFurniturePlacement
        self.navigationPath = navigationPath
    }

    @MainActor
    final class Coordinator {
        let sessionController: any CameraSessionControlling
        private var attachTask: Task<Void, Never>?
        private var markerAnchor: AnchorEntity?
        private var markerPosition: Vec3?
        private var furnitureAnchor: AnchorEntity?
        private var furniturePlacement: RecommendedFurniturePlacement?
        private var navigationAnchors: [AnchorEntity] = []
        private var renderedNavigationPath: ARIndoorNavigationPathOutput?

        init(sessionController: any CameraSessionControlling) {
            self.sessionController = sessionController
        }

        func attachAfterViewUpdate(to view: ARView) {
            attachTask?.cancel()
            attachTask = Task { @MainActor [weak self, weak view] in
                await Task.yield()
                guard !Task.isCancelled, let self, let view else {
                    return
                }
                self.sessionController.attach(to: view)
            }
        }

        func cancelPendingAttach() {
            attachTask?.cancel()
            attachTask = nil
        }

        func updateWorldMarker(in view: ARView, position: Vec3?) {
            guard markerPosition != position else {
                return
            }
            if let markerAnchor {
                view.scene.removeAnchor(markerAnchor)
            }
            markerAnchor = nil
            markerPosition = nil

            guard let position,
                Self.isRepresentableAsFloat(position)
            else {
                return
            }

            let anchor = AnchorEntity(
                world: SIMD3<Float>(
                    Float(position.x),
                    Float(position.y),
                    Float(position.z)
                )
            )
            let marker = ModelEntity(
                mesh: .generateSphere(radius: 0.055),
                materials: [
                    UnlitMaterial(color: UIColor.systemYellow)
                ]
            )
            marker.name = "vispace-grounded-target"
            anchor.addChild(marker)
            view.scene.addAnchor(anchor)
            markerAnchor = anchor
            markerPosition = position
        }

        func removeWorldMarker(from view: ARView) {
            if let markerAnchor {
                view.scene.removeAnchor(markerAnchor)
            }
            markerAnchor = nil
            markerPosition = nil
        }

        func updateFurniturePlacement(
            in view: ARView,
            placement: RecommendedFurniturePlacement?
        ) {
            guard furniturePlacement != placement else {
                return
            }
            if let furnitureAnchor {
                view.scene.removeAnchor(furnitureAnchor)
            }
            furnitureAnchor = nil
            furniturePlacement = nil

            guard let placement,
                Self.isRepresentableAsFloat(placement.position.value),
                Self.isRepresentableAsFloat(placement.dimensions.width),
                Self.isRepresentableAsFloat(placement.dimensions.depth),
                Self.isRepresentableAsFloat(placement.dimensions.height),
                Self.isRepresentableAsFloat(placement.yawRadians)
            else {
                return
            }

            let position = placement.position.value
            let anchor = AnchorEntity(
                world: SIMD3<Float>(
                    Float(position.x),
                    Float(position.y),
                    Float(position.z)
                )
            )
            let preview = FurniturePlacementRendering.makePreview(
                dimensions: placement.dimensions, yawRadians: placement.yawRadians
            )
            anchor.addChild(preview)
            view.scene.addAnchor(anchor)
            furnitureAnchor = anchor
            furniturePlacement = placement
        }

        func updateNavigationPath(
            in view: ARView,
            path: ARIndoorNavigationPathOutput?
        ) {
            guard renderedNavigationPath != path else {
                return
            }
            removeNavigationPath(from: view)
            guard let path,
                path.waypoints.allSatisfy(Self.isRepresentableAsFloat)
            else {
                return
            }

            let material = UnlitMaterial(color: UIColor.systemCyan)
            for waypoint in path.waypoints {
                let anchor = AnchorEntity(world: Self.floatVector(waypoint))
                let marker = ModelEntity(
                    mesh: .generateSphere(radius: 0.035),
                    materials: [material]
                )
                marker.name = "vispace-navigation-waypoint"
                anchor.addChild(marker)
                view.scene.addAnchor(anchor)
                navigationAnchors.append(anchor)
            }

            for segment in path.segments {
                let start = Self.floatVector(segment.start)
                let end = Self.floatVector(segment.end)
                let delta = end - start
                let length = simd_length(delta)
                guard length.isFinite, length > 0.001 else {
                    continue
                }
                let anchor = AnchorEntity(world: (start + end) / 2)
                let line = ModelEntity(
                    mesh: .generateBox(
                        width: 0.055,
                        height: 0.018,
                        depth: length
                    ),
                    materials: [material]
                )
                line.name = "vispace-navigation-segment"
                line.orientation = simd_quatf(
                    from: SIMD3<Float>(0, 0, 1),
                    to: simd_normalize(delta)
                )
                anchor.addChild(line)
                view.scene.addAnchor(anchor)
                navigationAnchors.append(anchor)
            }
            renderedNavigationPath = path
        }

        func removeFurniturePlacement(from view: ARView) {
            if let furnitureAnchor {
                view.scene.removeAnchor(furnitureAnchor)
            }
            furnitureAnchor = nil
            furniturePlacement = nil
        }

        func removeNavigationPath(from view: ARView) {
            for anchor in navigationAnchors {
                view.scene.removeAnchor(anchor)
            }
            navigationAnchors.removeAll(keepingCapacity: false)
            renderedNavigationPath = nil
        }

        private static func isRepresentableAsFloat(_ position: Vec3) -> Bool {
            let limit = Double(Float.greatestFiniteMagnitude)
            return abs(position.x) <= limit
                && abs(position.y) <= limit
                && abs(position.z) <= limit
        }

        private static func isRepresentableAsFloat(_ value: Double) -> Bool {
            value.isFinite && abs(value) <= Double(Float.greatestFiniteMagnitude)
        }

        private static func floatVector(_ position: Vec3) -> SIMD3<Float> {
            SIMD3<Float>(
                Float(position.x),
                Float(position.y),
                Float(position.z)
            )
        }

        func updateDisplayGeometry(from view: ARView) {
            let orientation = FrameInterfaceOrientation(
                view.window?.windowScene?.interfaceOrientation ?? .portrait
            )
            sessionController.setDisplayGeometry(
                FrameDisplayGeometry(
                    orientation: orientation,
                    viewportSize: ViewportSizeSnapshot(
                        width: view.bounds.width,
                        height: view.bounds.height
                    )
                )
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionController: sessionController)
    }

    func makeUIView(context: Context) -> ARView {
        let view = GeometryReportingARView(
            frame: .zero,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        view.backgroundColor = .black
        view.isOpaque = true
        updateAccessibility(on: view)
        view.onGeometryChange = { [coordinator = context.coordinator] view in
            coordinator.updateDisplayGeometry(from: view)
        }
        context.coordinator.attachAfterViewUpdate(to: view)
        context.coordinator.updateWorldMarker(in: view, position: worldMarkerPosition)
        context.coordinator.updateFurniturePlacement(
            in: view,
            placement: recommendedFurniturePlacement
        )
        context.coordinator.updateNavigationPath(in: view, path: navigationPath)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        updateAccessibility(on: view)
        context.coordinator.updateDisplayGeometry(from: view)
        context.coordinator.updateWorldMarker(in: view, position: worldMarkerPosition)
        context.coordinator.updateFurniturePlacement(
            in: view,
            placement: recommendedFurniturePlacement
        )
        context.coordinator.updateNavigationPath(in: view, path: navigationPath)
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.cancelPendingAttach()
        coordinator.removeWorldMarker(from: view)
        coordinator.removeFurniturePlacement(from: view)
        coordinator.removeNavigationPath(from: view)
        (view as? GeometryReportingARView)?.onGeometryChange = nil
        coordinator.sessionController.detach(from: view)
    }

    private func updateAccessibility(on view: ARView) {
        view.isAccessibilityElement = exposesAccessibility
        view.accessibilityElementsHidden = !exposesAccessibility
        view.accessibilityIdentifier =
            exposesAccessibility ? "vispace.camera.surface" : nil
        view.accessibilityLabel =
            exposesAccessibility
            ? String(localized: "camera.accessibility.label") : nil
        view.accessibilityHint =
            exposesAccessibility
            ? String(localized: "camera.accessibility.hint") : nil
    }
}

@MainActor
private final class GeometryReportingARView: ARView {
    var onGeometryChange: ((ARView) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onGeometryChange?(self)
    }
}

extension FrameInterfaceOrientation {
    fileprivate init(_ orientation: UIInterfaceOrientation) {
        switch orientation {
        case .portrait:
            self = .portrait
        case .portraitUpsideDown:
            self = .portraitUpsideDown
        case .landscapeLeft:
            self = .landscapeLeft
        case .landscapeRight:
            self = .landscapeRight
        default:
            self = .portrait
        }
    }
}
