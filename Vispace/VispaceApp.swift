import SwiftUI

@main
@MainActor
struct VispaceApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var services = VispaceServices()
    @StateObject private var onboardingState = OnboardingState()

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingState.hasCompleted {
                    CameraScreen(
                        sessionController: services.sessionController,
                        perceptionController: services.perceptionController,
                        queryController: services.queryController,
                        relationQueryController: services.relationQueryController,
                        guidanceController: services.guidanceController,
                        placementController: services.placementController,
                        navigationController: services.navigationController,
                        dataManagementController: services.dataManagementController,
                        lifecycle: services.lifecycle
                    )
                } else {
                    FirstRunOnboardingScreen { onboardingState.complete() }
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                updateActivity(phase)
            }
            .onChange(of: onboardingState.hasCompleted) { _, _ in
                updateActivity(scenePhase)
            }
        }
    }

    private func updateActivity(_ phase: ScenePhase) {
        switch phase {
        case .active:
            services.lifecycle.setActive(onboardingState.hasCompleted)
        case .inactive, .background:
            services.lifecycle.setActive(false)
        @unknown default:
            services.lifecycle.setActive(false, saveCheckpoint: false)
        }
    }
}
