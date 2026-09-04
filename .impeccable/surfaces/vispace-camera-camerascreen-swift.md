---
version: 1
slug: "vispace-camera-camerascreen-swift"
primary_target: "Vispace/Camera/CameraScreen.swift"
related_targets: ["Vispace/Camera/CameraSurfaceView.swift","Vispace/VispaceApp.swift"]
---

Scope: `Vispace/Camera/CameraScreen.swift` and its iPhone camera surface. Visitor mode: Experience.

Audience: an iPhone owner moving through an indoor space. Job: enter a spatial capture session immediately. Primary action: move through and point the phone at the real space; there is no on-screen action.

Proof/content: the unmodified rear-camera feed fills the window. Black is reserved for capture that is not yet available. The system-owned camera permission prompt is the only permitted interruption.

Constraints: render no app-owned text, buttons, cards, chrome, HUD, coaching overlay, debug geometry, or AR markers. Target iPhone portrait, cover the full safe-area extent, pause capture whenever the scene is inactive, and retain only nonvisual accessibility metadata for the live camera surface.

Direction: Unmediated Lens. The memorable moment is the absence of interface chrome: after launch, the observed world itself occupies every pixel.

Unresolved: whether future Search/Ask input or AR guidance may ever change this visible contract; final App Store icon and brand assets; and whether a denied-permission recovery surface will be allowed later.
