# Product

<!-- impeccable:product-schema 1 -->

## Platform

iOS, iPhone first.

## Stack

Vispace is a native SwiftUI application built with Apple platform frameworks. ARKit and RealityKit provide capture, tracking, depth, mesh, rendering, and relocalization. Vision and Core ML run the bundled object detector on device. Foundation-backed repositories provide deterministic domain logic and protected local persistence. The app has no third-party runtime dependency and does not require a network or LLM for its spatial functions.

## Users

The confirmed user is an iPhone owner who wants to find, understand, remember, arrange, or navigate a real indoor space through the phone camera. A narrower launch segment such as homes, classrooms, offices, or facilities management remains a release decision.

## Product purpose

Vispace continuously builds and updates a local digital model of the observed space. It associates supported objects with identity, 3D bounds, positions, relationships, confidence, and history. The user can then search the physical world, ask spatial questions, inspect where something was last seen, evaluate whether furniture fits, and request camera-aligned guidance.

Success means that spatial truth remains deterministic and evidence-backed without an LLM. An optional language layer may later improve expression, but it cannot create coordinates, existence, relations, placement safety, or routes.

## Positioning

Vispace does more than classify one camera frame. Its LiveMap and temporal spatial memory connect what an object is, where it is, how it relates to the room, where it was, whether it changed, whether a proposed item fits, and how the user can reach a verified target.

## Operating context

The app is used while a person moves slowly through indoor rooms and corridors with the rear camera active. It must distinguish known, overlapping, and new space; avoid duplicate maps; preserve object identity across viewpoint, lighting, occlusion, movement, and relaunch; and recover conservatively from tracking or persistence failures.

## Implemented capabilities and constraints

- First-run guidance explains scanning, spatial memory, search, placement, navigation, privacy, local retention, and the camera permission request before capture starts.
- The live camera is the primary surface. The bottom query field, results, relation answers, placement controls, AR target markers, furniture previews, navigation paths, and the spatial-data settings entry are explicitly authorized parts of the implemented user workflow.
- On-device Vision/Core ML detection is throttled and depth-supported. A detection remains provisional until identity and confidence gates permit durable promotion.
- Current, last-seen, moved, and removed states retain provenance. Explicit user classification correction has a separate journal event and preserves the object's ID, user name, and previous locations; changing a display name alone does not reclassify it.
- Continuous identity updates require actual tracked image/depth continuity. After an observation gap, a user may confirm the same physical object or a distinct new object; an arbitrary temporary tracking ID never authorizes a merge.
- Cross-coordinate map alignment uses bounded, local Vision appearance features with capture provenance and uniquely verified nondegenerate landmark correspondences. Visual thresholds are engineering admission rules pending physical calibration.
- Object search, last-seen lookup, basic relation queries, placement evaluation, and indoor routing run locally and do not depend on a network or LLM.
- Placement advice uses verified geometry, collision, wall, clearance, and passage evidence. Missing or incompatible evidence produces an unavailable or unsuitable result, never invented approval.
- Indoor routes use verified floor and obstacle evidence and deterministic A*. A route is removed when its map, surface revision, tracking, or obstacle evidence becomes invalid.
- A plane classified as a door does not establish that the door is open. Until open-state evidence exists, Vispace does not route through that opening.
- Door uncertainty blocks the affected passage locally. Full measured portal geometry and multiple recent depth views are required for a short-lived open passage; unrelated verified areas can still be routed.
- Observed access, connection, and blockage relations expire with their map/surface/object revision or evidence lease. Missing evidence remains an unconfirmed answer.
- All spatial recommendations and guidance fail closed when required evidence is missing, stale, excessive, or incompatible.
- Camera/depth capability varies by iPhone. Unsupported devices expose unavailable capability rather than fabricated depth, geometry, placement, or navigation precision.
- Raw camera frames are ephemeral and are neither persisted nor transmitted.
- Structured maps, object metadata, relations, and temporal history stay local and are retained until the user deletes them from spatial-data settings.
- Cloud sync, accounts, and remote spatial storage are not implemented.

## Brand commitments

- Product name: Vispace.
- The observed world remains visually primary.
- Every app-owned overlay must answer a direct spatial task, be dismissible or state-bound, avoid hiding the scene unnecessarily, and disappear when its evidence becomes invalid.
- Uncertainty is shown as uncertainty; lack of evidence is never styled as success.

## Evidence on hand

- Product specification: `Vispace_프로젝트_기획서_수정1.docx` supplied by the user.
- Source repository: `https://github.com/L3J-Vispace/Vispace`.
- Current source, automated tests, and verification scripts are the implementation evidence. Physical accuracy and performance claims require recorded device measurements.

## Product principles

1. See continuously, compute selectively.
2. Never turn uncertainty into a spatial fact.
3. Deterministic spatial output precedes optional language generation.
4. The observed world is primary; interface elements exist only to operate or explain a spatial feature.
5. Local spatial capability survives network and LLM failure.
6. A safe unavailable result is better than an attractive unsupported answer.

## Accessibility and inclusion

English/Korean first-run guidance supports VoiceOver, Dynamic Type, sufficient contrast, Reduce Motion, and minimum 44-point controls. Query, placement, result dismissal, settings, deletion confirmation, and camera recovery controls require localized accessibility labels and predictable focus order. Direction-only AR output must also expose a nonvisual target, direction, distance, confidence, or unavailable explanation. Reduced Motion removes nonessential direction animation without changing spatial meaning.

## Release evidence still required

- Final model provenance, licensed distribution basis, supported classes, and measured accuracy.
- Signed installation and end-to-end validation on supported LiDAR and non-LiDAR physical iPhones.
- Real-room recognition, identity, relocalization, last-seen, relation, placement, obstacle, no-path, and door-state behavior.
- Thermal, memory, latency, accessibility, and positioning-error measurements against approved targets.
- Launch segment, minimum supported hardware policy, portrait/rotation policy, export scope, App Store privacy labels, and final brand assets.

Feature-specific source and execution status is recorded in [the gap follow-up](docs/FEATURE_GAPS_2026-09-05.md). Newly connected source paths are not called automation-verified until their latest build and regression results exist. Physical acceptance and release certification remain separate.
