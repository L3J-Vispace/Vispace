---
version: 1
slug: "vispace-camera-camerascreen-swift"
primary_target: "Vispace/Camera/CameraScreen.swift"
related_targets: ["Vispace/Camera/CameraSurfaceView.swift","Vispace/VispaceApp.swift"]
---

Scope: `Vispace/Camera/CameraScreen.swift` and its iPhone camera surface. Visitor mode: Experience.

Audience: an iPhone owner moving through an indoor space. Job: scan after first-run guidance, then search remembered objects, inspect spatial relations, evaluate furniture placement, or request verified route guidance. Primary action: move slowly to collect evidence and use the compact query controls when needed.

Proof/content: the rear-camera feed fills the window behind compact controls. AR target markers, placement previews, and route paths require current compatible spatial evidence. Unavailable or denied capture has an explicit recovery explanation; missing evidence never becomes an invented result.

Constraints: keep live camera pixels dominant. Query, placement, navigation, and data-settings controls and grounded AR overlays are authorized by the implemented feature scope; debug geometry is not. Target iPhone portrait, cover the safe-area extent, pause capture when inactive, and provide accessible recovery and insufficient-evidence states.

Direction: Camera-first spatial guidance. After the one-time first-run gateway, the observed world remains the primary surface; controls and evidence-backed guidance support the current request without obscuring the room.

Unresolved: final App Store icon and brand assets; physical-device accuracy, accessibility, and release acceptance. Search/Ask and AR guidance are implemented, not future authorization questions.

Navigation extension (2026-09-07, Operate): the user's floor-route reference replaces narrow route sticks with a continuous translucent ribbon, inset edges, repeated direction marks, and a floor destination ring. A confirmed search result offers an explicit route action that preserves the selected object's identity and revalidates evidence. No map panel is added. Geometry and lifecycle checks passed, but native visual approval and updated iPhone installation remain pending; see `docs/FLOOR_ROUTE_GUIDANCE_2026-09-07.md`. Black Simulator captures are invalid evidence, not an approved visual result.

Review update (2026-09-08): fixed direction/arrival overlap, renderer input rejection, observation-refresh races, explicit route retry, dismissal touch size, reduced-motion handling, and truncated accessibility-size messages. Ten final native panel captures passed visual review, including scrolling long results; actual touch/VoiceOver acceptance is still separate. Latest Simulator results are 579 passed, one RealityKit graphics capture failure, and two physical-only skips. The signed updated iPhone app is installed, but device lock prevents current physical testing and normal launch verification. See `docs/FLOOR_ROUTE_REVIEW_2026-09-08.md` for evidence and remaining checks.
