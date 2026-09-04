# Vispace

Vispace is an iPhone-first Spatial AI application that turns a live camera session into a durable spatial model. The product is designed to recognize places, preserve object identity, remember change, answer deterministic spatial queries, and eventually provide camera-aligned AR guidance without making an LLM the source of spatial truth.

## Current milestone

This repository starts with the production foundation rather than a disposable demo:

- a native SwiftUI application whose shipping surface is only the edge-to-edge camera feed;
- an explicitly configured ARKit/RealityKit session with runtime depth and mesh capability gates;
- a platform-independent `VispaceCore` package for confidence, identity, map classification, memory, scene relations, intent routing, and navigation;
- bounded frame scheduling so inference cannot create an unbounded backlog;
- protected local world-map persistence seams and no raw camera-frame persistence;
- unit, integration, UI-contract, clean-build, and static verification entry points.

No toolbar, label, button, card, debug mesh, coaching overlay, or decorative HUD is rendered over the camera.

## Requirements

- Xcode 26 or newer for App Store submission requirements current at project creation
- iOS 17.0 or newer
- an ARKit-capable iPhone
- a LiDAR iPhone for scene depth and mesh reconstruction validation
- XcodeGen 2.46.0 when regenerating the project or running the macOS verifier

The project contains no third-party runtime dependency. An object detector is deliberately not bundled until its classes, dataset provenance, model license, size, and accuracy gates are approved.

## Open and run

1. Open `Vispace.xcodeproj` in Xcode.
2. Select the `Vispace` scheme and an iPhone.
3. Set your development team or use an unsigned Simulator build.
4. Run the app and grant the system camera permission.

ARKit camera and depth behavior must be validated on physical hardware. The Simulator is useful for compilation, lifecycle, UI-contract, and non-AR tests only.

## Verification

On macOS:

```bash
./Scripts/verify-ios.sh
./Scripts/verify-ios.sh --clean-recheck
```

On Windows with Docker, the platform-independent core can be built and tested twice:

```powershell
./Scripts/verify-core.ps1
./Scripts/verify-core.ps1 -CleanRecheck
```

See `docs/IMPLEMENTATION_PLAN.md` for phase boundaries, acceptance gates, and the decisions that still require product evidence.

## Privacy baseline

- Raw camera frames are processed ephemerally and are not persisted.
- Spatial facts are not committed when confidence is below policy thresholds.
- Search, last-seen, relation, and navigation logic are designed to remain local and independent of an LLM.
- Cloud sync, retention, deletion, account, and model-data policies remain explicit release blockers until decided.
