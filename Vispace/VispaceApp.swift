import SwiftUI

@main
@MainActor
struct VispaceApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var sessionController = ARSessionController()

    var body: some Scene {
        WindowGroup {
            CameraScreen(sessionController: sessionController)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active:
                        sessionController.activate()
                    case .inactive:
                        sessionController.deactivate()
                    case .background:
                        sessionController.enterBackground()
                    @unknown default:
                        sessionController.deactivate()
                    }
                }
        }
    }
}
