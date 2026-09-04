import RealityKit
import SwiftUI

@MainActor
struct CameraSurfaceView: UIViewRepresentable {
    let sessionController: any CameraSessionControlling

    final class Coordinator {
        let sessionController: any CameraSessionControlling

        init(sessionController: any CameraSessionControlling) {
            self.sessionController = sessionController
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionController: sessionController)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(
            frame: .zero,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        view.backgroundColor = .black
        view.isOpaque = true
        view.accessibilityIdentifier = "vispace.camera.surface"
        view.accessibilityLabel = "Live camera"
        view.isAccessibilityElement = true
        sessionController.attach(to: view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.sessionController.detach(from: view)
    }
}
