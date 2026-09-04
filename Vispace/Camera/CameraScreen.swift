/*
 THESIS: The observed world is the interface; this surface refuses camera-app chrome and HUD decoration.
 OWN-WORLD: Unmodified edge-to-edge camera imagery, with black reserved only for unavailable capture. No tint, cards, type, controls, or overlays.
 STORY: Launch, grant the system camera permission when needed, and immediately see the spatial capture surface.
 FIRST VIEWPORT: One RealityKit camera plane fills every pixel beneath system-owned hardware cutouts; there is no primary on-screen action.
 FORM: Unmediated Lens, seventh grounded direction, seed 00a7cae7, explicitly pinned by the brief.
 FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
 */

import SwiftUI

@MainActor
struct CameraScreen: View {
    let sessionController: any CameraSessionControlling

    var body: some View {
        CameraSurfaceView(sessionController: sessionController)
            .background(Color.black)
            .ignoresSafeArea()
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
    }
}
