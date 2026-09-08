---
name: Vispace
description: An evidence-grounded spatial assistant layered lightly over an edge-to-edge live camera.
colors:
  unavailable-capture: "#000000"
  grounded-target: system-yellow
  feasible-placement: system-green
  verified-route: system-cyan
---

# Design system: Vispace

## Overview

**Creative North Star: “Grounded Lens”**

Vispace keeps the observed world primary while exposing the minimum interface needed to search it, ask about it, test a furniture placement, navigate it, and manage stored spatial data. The camera is not decorative background: every visible control or AR element must correspond to a direct user action and verified spatial evidence.

First-run guidance is an opaque, pre-permission explanation. It introduces the service, spatial memory, available questions, placement and navigation, and scanning behavior before the user agrees to start the camera. Data-retention explanations belong in spatial-data settings. Guidance is never mounted over capture.

After onboarding, an edge-to-edge rear-camera surface carries the explicitly authorized spatial interface: a compact bottom query/placement control, temporary result messages, target guidance, a feasible furniture preview, a verified route, and access to spatial-data settings. These elements are state-bound and disappear when their evidence or coordinate identity is no longer valid.

## Visual hierarchy and colors

The live camera supplies the dominant visual field. App-owned colors have fixed semantic roles:

- system yellow identifies a grounded target, direction, arrival, and confidence;
- translucent system green identifies only a placement that passed the conservative evaluator;
- system cyan identifies only a route built from verified walkable-floor and obstacle evidence;
- opaque dark material supports short results without pretending to be part of the room;
- pure black is an operational fallback while capture is unavailable.

Do not use these colors decoratively or show success geometry for provisional, stale, incompatible, or insufficient evidence.

## Layout

The onboarding and spatial-data settings screens respect safe areas, use semantic system typography, and remain scrollable at large Dynamic Type sizes. Their primary and destructive actions retain minimum 44-point targets.

The camera extends edge to edge beneath hardware cutouts. The query capsule is anchored near the bottom safe region. Result cards sit immediately above it and stay narrow enough to preserve surrounding scene context. Direction guidance may use a compact label near the top and one central arrow only when the grounded target is outside the forward view.

World-space markers, placement volumes, and route segments must remain registered to their confirmed coordinate frame. They are removed immediately on capture transition, invalid tracking, superseding results, cancellation, or evidence revision.

## Components

### First-run guidance

- **Visual:** Opaque system background, product name, direct title, concise feature and scanning rows, permission notice, and one prominent action.
- **Content:** Introduce the service, local spatial memory, example searches and relation questions, placement/navigation evidence requirements, and slow multi-angle scanning. Keep data-retention explanations in spatial-data settings.
- **Interaction:** **Agree and Start Camera** is the sole completion action. Camera creation and permission wait for it.
- **Persistence:** Completion is stored locally with a versioned preference.
- **Accessibility:** Semantic text styles and colors, heading trait, intentional VoiceOver order, decorative symbols hidden, scrollable AXXXL layout, and a minimum 44-point action.

### Live camera and query panel

- **Camera:** Unfiltered rear-camera imagery fills the window.
- **Input:** A compact material capsule contains the localized query field, furniture menu, progress state, submit action, and spatial-data settings access.
- **Queries:** Object search, last-seen, relation, and navigation requests share deterministic local intent routing.
- **Results:** One dismissible result or unavailable card is visible at a time. It states the conclusion without hiding lack of confidence or evidence.
- **Lifecycle:** Input may remain available while capture is active, but stale results and AR output are cleared across session or coordinate transitions.

### Grounded target guidance

- A yellow world-space marker appears only for a compatible confirmed target.
- A compact label exposes object name, distance, confidence, and whether the point is a last-seen location.
- Direction/arrival visuals are noninteractive and provide an equivalent VoiceOver description.
- Reduce Motion removes bearing animation without removing direction information.

### Furniture placement

- The furniture menu offers the implemented sofa, bed, and desk checks.
- The result explains feasible, unsuitable, or unavailable evidence.
- A translucent green box is rendered only for a recommended placement that passed surface, collision, wall, clearance, passage, and coordinate checks.
- No preview is rendered for ambiguous geometry or unsupported depth/mesh capability.

### Indoor navigation

- A cyan path is rendered only when the start, target, floor coverage, obstacle evidence, coordinate context, and surface revision agree.
- No-path and insufficient-evidence outcomes use a message, not a speculative straight arrow.
- A plane classified as a door is not treated as an open portal; without verified open-state evidence, routing fails closed.

### Spatial-data settings

- The screen states that structured maps and spatial facts remain local until the user deletes them and that raw frames are not stored.
- **Delete all spatial data** is destructive, requires confirmation, shows progress, and reports success or failure.
- Deletion targets the dedicated Vispace spatial-capture store, not unrelated app or device data.

### Unavailable capture

- Temporary unavailability uses pure black without stale spatial output.
- Denied or restricted camera permission replaces capture with an opaque localized explanation and a Settings recovery action.

## Do's and don'ts

### Do

- Keep the camera visually primary and every overlay task-specific.
- State whether a result is current, last-seen, uncertain, unsuitable, no-path, or unavailable.
- Remove AR output immediately when its evidence becomes stale or incompatible.
- Keep destructive spatial-data deletion explicit and confirmed.
- Verify registration, readability, VoiceOver output, and lifecycle clearing on a physical iPhone.

### Don't

- Don't resurrect the obsolete camera-only or no-overlay contract; search, relation, placement, navigation, and settings UI are now explicitly authorized.
- Don't show a target, green placement, or cyan path from provisional or incomplete evidence.
- Don't route through a classified door merely because a door-shaped plane exists.
- Don't imply that raw camera frames are saved or sent, or that structured spatial data expires automatically.
- Don't claim physical accuracy from Simulator or automated tests alone.

## Verification status

Simulator and automated UI checks validate layout contracts, lifecycle, deterministic state, and unavailable paths. The final physical-device visual and accessibility pass is not yet confirmed in this document: live registration, real-room obstruction, door behavior, large text, VoiceOver, contrast, and sustained use must be recorded on supported hardware before release acceptance.
