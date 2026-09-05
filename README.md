# Vispace

Vispace is an iPhone-first Spatial AI application that turns a live camera session into a durable, local spatial model. It recognizes supported objects on device, preserves their identity and history, answers deterministic spatial questions, evaluates furniture placement, and renders camera-aligned guidance only when the captured evidence is sufficient.

## Current milestone

The application currently connects these production-oriented paths end to end:

- a localized English/Korean first-run explanation covering scanning, memory, search, placement, navigation, privacy, and local storage before camera permission;
- an explicitly configured ARKit/RealityKit session with runtime depth and mesh capability gates;
- a bundled Core ML object detector running through Vision, bounded frame scheduling, depth-supported 3D localization, provisional tracking, and confidence-gated promotion to durable object identity;
- place recognition, protected and checksummed `ARWorldMap` checkpoints, relocalization gating, coordinate provenance, and recovery from interrupted or corrupt persistence;
- local temporal memory for current, last-seen, moved, removed, and reclassified object state;
- deterministic object search, last-seen lookup, and scene-relation questions such as what is on, under, inside, or near another object;
- conservative sofa, bed, and desk placement evaluation using verified surfaces, object bounds, collision and clearance evidence;
- deterministic indoor routing and camera-aligned guidance using verified LiDAR floor and obstacle evidence;
- a compact camera query/placement interface plus AR markers, furniture previews, and route paths authorized for the implemented search, placement, and navigation features;
- a local spatial-data settings surface that explains retention and lets the user delete all Vispace spatial capture data.

Spatial output is fail-closed. Vispace does not invent a location, placement, or route when coordinate identity, confidence, floor coverage, obstacle geometry, or tracking evidence is insufficient. In particular, ARKit's door classification alone does not prove that a door is open, so a detected door is not treated as a traversable opening without verified open-state evidence.

## Requirements

- Xcode 26 or newer for the current project and submission toolchain
- iOS 17.0 or newer
- an ARKit-capable iPhone
- a LiDAR iPhone for verified scene depth, mesh-backed placement, and route guidance
- XcodeGen 2.46.0 when regenerating the project or running the macOS verifier

The runtime uses Apple frameworks only. The bundled object detector executes locally through Vision/Core ML; its final release provenance, class coverage, size, and measured accuracy remain release evidence, not assumptions.

## Open and run

1. Open `Vispace.xcodeproj` in Xcode.
2. Select the `Vispace` scheme and an iPhone.
3. Set the development team, or use an unsigned Simulator build for non-AR checks.
4. Run the app, review the first-run explanation, tap **Agree and Start Camera** (**동의하고 카메라 시작**), and grant camera access.
5. Move slowly while covering the floor, walls, surrounding objects, and the intended route or placement area from more than one angle.
6. Use the bottom query field for object, last-seen, relation, or navigation requests. Use the furniture menu for a sofa, bed, or desk placement check.
7. Open spatial-data settings to review local storage behavior or delete all stored Vispace spatial data.

The Simulator is useful for compilation, lifecycle, UI-contract, and non-AR tests. Real depth, mesh reconstruction, relocalization, placement accuracy, and route safety require a physical LiDAR iPhone and a mapped indoor space.

For a reproducible physical-device install, run the following from Terminal in
your logged-in Mac desktop session after configuring signing:

```bash
xcrun devicectl list devices
bash Scripts/install-device.sh DEVICE_UUID
```

The installer requires a certificate-signed Release build and a provisioning
profile before installation. It does not change keychain permissions. Respond
to any macOS signing-key approval prompt yourself; a failed signature stops the
installation. Follow [the Korean device acceptance checklist](docs/DEVICE_ACCEPTANCE.md)
after launch, recording successful spatial results separately from correct
insufficient-evidence handling.

## Verification

Run the current macOS verification commands instead of relying on a documentation test count:

```bash
./Scripts/verify-ios.sh
./Scripts/verify-ios.sh --clean-recheck
```

On Windows with Docker, the platform-independent core can be built and tested twice:

```powershell
./Scripts/verify-core.ps1
./Scripts/verify-core.ps1 -CleanRecheck
```

The automated suite covers the deterministic core, iOS integrations, lifecycle behavior, persistence recovery, and UI contracts. The final signed physical-device acceptance pass is still unconfirmed at the time of this document update; installation, real-room relocalization, recognition, placement, route obstruction, and thermal/memory measurements must be recorded before release claims are made.

See `docs/IMPLEMENTATION_PLAN.md` for phase scopes and remaining release gates.

Latest refactoring, security review, and verification status: [2026-09-05 PR review](docs/PR_REVIEW_2026-09-05.md).
The review records the tested source manifest separately from historical test runs and physical-device release gates.

## Privacy and retention

- Raw camera frames and raw camera video are processed ephemerally. They are neither persisted nor transmitted by Vispace.
- Durable maps, object metadata, and spatial relations stay on the device until user deletion. Replay, inference, and association bookkeeping is bounded and may rotate; historical mutation proposals are not silently discarded without acknowledgement.
- The dedicated store is excluded from new OS backups and uses iOS file protection. Copies already present in older backups cannot be removed by the app.
- The spatial-data settings screen deletes the dedicated local Vispace spatial-capture store after confirmation.
- Search, last-seen, relation, placement, and navigation logic run locally and do not depend on an LLM or network connection.
- Cloud sync and account-based storage are not implemented in this milestone.
