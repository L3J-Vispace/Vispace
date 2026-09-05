/*
 THESIS: The observed world remains the interface while grounded search and AR
 guidance add only the controls required by the now-authorized feature phases.
 */

import SwiftUI
import UIKit
import VispaceCore

@MainActor
struct CameraScreen: View {
    @ObservedObject var sessionController: ARSessionController
    @ObservedObject var perceptionController: SpatialPerceptionController
    @ObservedObject var queryController: SpatialObjectQueryController
    @ObservedObject var relationQueryController: SpatialRelationQueryController
    @ObservedObject var guidanceController: ARGuidanceController
    @ObservedObject var placementController: FurniturePlacementController
    @ObservedObject var navigationController: IndoorNavigationController
    @ObservedObject var dataManagementController: SpatialDataManagementController
    @ObservedObject var lifecycle: SpatialApplicationLifecycle
    @State private var showsDataManagement = false

    private var recoveryMode: CameraRecoveryMode? {
        if lifecycle.state == .storageUnavailable { return .storageUnavailable }
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-VispaceSimulateCameraUnavailable") {
                return .unavailable
            }
            if arguments.contains("-VispaceSimulateCameraFailed") {
                return .failed
            }
        #endif
        return CameraRecoveryMode(sessionState: sessionController.state)
    }

    private var isPerceptionUnavailable: Bool {
        if case .unavailable = perceptionController.state {
            return true
        }
        return false
    }

    var body: some View {
        ZStack {
            CameraSurfaceView(
                sessionController: sessionController,
                exposesAccessibility: recoveryMode == nil,
                worldMarkerPosition: guidanceController.renderableWorldPosition,
                recommendedFurniturePlacement:
                    placementController.latestRecommendedPlacement,
                navigationPath: navigationController.renderablePath
            )
            .background(Color.black)
            .ignoresSafeArea()

            if let recoveryMode {
                CameraRecoveryScreen(
                    mode: recoveryMode,
                    onRetry: {
                        lifecycle.retry()
                    },
                    onManageData: {
                        showsDataManagement = true
                    }
                )
            } else {
                ARGuidanceOverlay(controller: guidanceController)
                SpatialQueryPanel(
                    perceptionController: perceptionController,
                    queryController: queryController,
                    relationQueryController: relationQueryController,
                    placementController: placementController,
                    navigationController: navigationController,
                    onManageData: {
                        showsDataManagement = true
                    },
                    distanceDescription: { position in
                        guard let frame = sessionController.latestDepthFrame else { return "현재 거리 확인 불가" }
                        let camera = frame.pose.cameraTransform.column3
                        let distance = hypot(
                            hypot(position.x - Double(camera.x), position.y - Double(camera.y)),
                            position.z - Double(camera.z))
                        return "카메라에서 약 \(distance.formatted(.number.precision(.fractionLength(1))))m"
                    }
                )
                if sessionController.persistenceFailureMessage != nil
                    || perceptionController.persistenceFailureMessage != nil {
                    VStack {
                        Button {
                            showsDataManagement = true
                        } label: {
                            Label(
                                perceptionController.persistenceFailureMessage
                                    ?? sessionController.persistenceFailureMessage
                                    ?? String(localized: "storage.save.failed"),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.callout)
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .accessibilityIdentifier("vispace.storage.failure")
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                } else if perceptionController.objectCapacityReached {
                    VStack {
                        Button { showsDataManagement = true } label: {
                            Label("storage.objects.full", systemImage: "externaldrive.badge.exclamationmark")
                                .font(.callout)
                                .padding(12)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                } else if isPerceptionUnavailable {
                    VStack {
                        PerceptionUnavailableBanner()
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                }
            }
        }
        .background(Color.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onChange(of: queryController.latestGroundedTarget) { _, target in
            bridgeGroundedTarget(target)
        }
        .sheet(isPresented: $showsDataManagement) {
            SpatialDataSettingsScreen(controller: dataManagementController)
        }
    }

    private func bridgeGroundedTarget(_ grounded: GroundedSpatialObjectQueryTarget?) {
        guard let grounded else {
            guidanceController.clear()
            navigationController.clearRoute()
            return
        }

        let identity = sessionController.captureIdentity
        guard identity.status == .confirmed,
            grounded.currentCoordinateFrameID == identity.coordinateFrameID,
            grounded.currentSegmentID == identity.segmentID,
            grounded.currentMapID == identity.mapID
        else {
            guidanceController.clear()
            navigationController.clearRoute()
            return
        }

        if grounded.intent == .navigate {
            guidanceController.clear()
            navigationController.navigate(to: grounded)
            return
        }
        navigationController.clearRoute()

        let presence = queryController.latestPresentation?
            .result.selectedCandidate?.record.metadata.object.presence
        let isLastSeen =
            grounded.intent == .lastSeen
            || presence.map { $0 != .visible } == true
        guard
            let target = try? ARGuidanceTarget(
                objectID: grounded.objectID,
                semanticLabel: grounded.semanticLabel,
                activeMapID: grounded.currentMapID,
                activeSegmentID: grounded.currentSegmentID,
                position: grounded.currentFramePosition,
                confidenceGrade: grounded.confidenceGrade,
                representsLastSeenLocation: isLastSeen,
                resolvedAt: grounded.resolvedAt,
                sourceMetadata: queryController.latestPresentation?.result.selectedCandidate?.record.metadata
            )
        else {
            guidanceController.clear()
            return
        }
        guidanceController.show(target)
    }
}

enum CameraRecoveryMode: Equatable {
    case permissionDenied
    case unavailable
    case failed
    case storageUnavailable

    init?(sessionState: ARSessionControllerState) {
        switch sessionState {
        case .cameraAccessUnavailable:
            self = .permissionDenied
        case .unavailable:
            self = .unavailable
        case .failed:
            self = .failed
        case .detached, .waitingForCameraPermission, .ready, .running, .paused:
            return nil
        }
    }
}

private struct CameraRecoveryScreen: View {
    @Environment(\.openURL) private var openURL
    let mode: CameraRecoveryMode
    let onRetry: () -> Void
    let onManageData: () -> Void

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: symbolName)
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)

                    Text(titleKey)
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("vispace.camera.recovery.title")

                    Text(bodyKey)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("vispace.camera.recovery.body")
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button(primaryActionKey) {
                        if mode == .permissionDenied {
                            guard
                                let settingsURL = URL(
                                    string: UIApplication.openSettingsURLString
                                )
                            else {
                                return
                            }
                            openURL(settingsURL)
                        } else {
                            onRetry()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier(primaryActionIdentifier)

                    Button("camera.recovery.manageData", action: onManageData)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("vispace.camera.recovery.manageData")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(Color(uiColor: .systemBackground))
            }
        }
    }

    private var symbolName: String {
        switch mode {
        case .permissionDenied:
            "camera.fill"
        case .unavailable:
            "iphone.slash"
        case .failed:
            "exclamationmark.triangle.fill"
        case .storageUnavailable:
            "externaldrive.badge.exclamationmark"
        }
    }

    private var titleKey: LocalizedStringKey {
        switch mode {
        case .permissionDenied:
            "camera.permissionDenied.title"
        case .unavailable:
            "camera.unavailable.title"
        case .failed:
            "camera.failed.title"
        case .storageUnavailable:
            "storage.unavailable.title"
        }
    }

    private var bodyKey: LocalizedStringKey {
        switch mode {
        case .permissionDenied:
            "camera.permissionDenied.body"
        case .unavailable:
            "camera.unavailable.body"
        case .failed:
            "camera.failed.body"
        case .storageUnavailable:
            "storage.unavailable.body"
        }
    }

    private var primaryActionKey: LocalizedStringKey {
        mode == .permissionDenied ? "camera.permissionDenied.action" : "camera.recovery.retry"
    }

    private var primaryActionIdentifier: String {
        mode == .permissionDenied
            ? "vispace.camera.permission.openSettings"
            : "vispace.camera.recovery.retry"
    }
}

private struct PerceptionUnavailableBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "viewfinder.circle")
                .font(.title3)
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("perception.unavailable.title")
                    .font(.headline)
                    .accessibilityIdentifier("vispace.perception.unavailable.title")
                Text("perception.unavailable.body")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("vispace.perception.unavailable.body")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vispace.perception.unavailable")
    }
}
