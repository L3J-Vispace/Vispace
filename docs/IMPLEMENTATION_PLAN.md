# Vispace implementation plan

## Delivery contract

Vispace is no longer a camera-only milestone. On first run it shows one localized, pre-permission explanation of scanning, spatial memory, queries, placement, navigation, raw-frame privacy, and local retention. After agreement and camera permission, the live camera remains the primary surface while the explicitly authorized query, relation, placement, navigation, guidance, and spatial-data settings UI operates over or alongside it.

Spatial output is evidence-gated:

- no current-position claim without current confirmed coordinate identity and presence evidence;
- no last-seen claim without durable timestamped provenance;
- no relation claim without compatible bounded objects and valid relation evidence;
- no placement recommendation without verified support, collision, clearance, and passage evidence;
- no route without verified floor coverage, obstacles, start, target, and matching map/surface revision;
- no traversal through a classified door unless separate evidence verifies its open state.

Insufficient or incompatible evidence returns an explicit unavailable, unsuitable, or no-path outcome. It never becomes guessed geometry.

## Technical baseline

- Platform: iPhone, iOS 17+
- Language: Swift 6 language mode with strict concurrency checks
- App shell: SwiftUI
- Camera and world tracking: ARKit `ARSession` with `ARWorldTrackingConfiguration`
- Camera and spatial rendering: RealityKit `ARView`, manually configured session
- Perception: Vision/Core ML with a bundled on-device object detector and fail-safe unavailable fallback
- Metadata persistence: actor-isolated local repository boundaries
- Large spatial artifacts: protected Application Support blobs with schema version and checksum
- Core logic: local Swift Package with no Apple UI or AR dependencies
- Runtime dependencies: Apple frameworks only
- Network/LLM requirement: none for implemented spatial capabilities

## Cross-cutting invariants

1. Coordinate data is invalid without a coordinate-frame identifier, timestamp, tracking quality, and uncertainty.
2. Tracking IDs are temporary and never become permanent object IDs directly.
3. Place, identity, state, and relation confidence are independent signals.
4. Provisional evidence cannot mutate canonical memory.
5. Deltas are uniquely identified, revision checked, and idempotent under replay.
6. Frame, pose, and surface streams are bounded; stale work is dropped rather than creating an unbounded backlog.
7. Raw camera frames and video are never written to disk or transmitted by Vispace.
8. LLM output cannot manufacture coordinates, distance, existence, relations, placement approval, or routes.
9. Capability checks are runtime checks. A non-LiDAR iPhone never receives fake depth or mesh precision.
10. A failed relocalization starts a distinct session segment and cannot silently merge maps.
11. AR output is removed across coordinate, tracking, evidence-revision, cancellation, background, and session transitions.
12. Structured spatial data remains local until user deletion; deletion is scoped to the dedicated Vispace spatial-capture store.

## Status vocabulary

- **Implemented:** the source path is connected end to end and covered by the repository's current automated verification.
- **Physically accepted:** the signed build has also passed the phase's recorded real-device and real-space measurements.

An implemented phase is not described as physically accepted until that evidence exists.

## Phase 0 — production shell and informed camera start

### Scope

- deterministic Xcode project, build configurations, CI, and signing separation;
- full-screen `ARView` with camera permission handling;
- first-run guidance and a versioned local completion preference that gates camera creation and permission;
- localized English/Korean explanation and denied-permission Settings recovery;
- foreground/background and interruption lifecycle;
- manual AR session configuration with supported depth/mesh options only;
- app/container dependency boundaries, logging, privacy manifest, and UI contracts.

### Current status

Implemented. First-run content now explains the complete available workflow, including local retention, before the user chooses **Agree and Start Camera**. Live capture can show the authorized spatial controls and outputs; the former zero-overlay contract has been retired.

### Physical acceptance

Still unconfirmed. Record permission, denial/recovery, interruption, repeated foreground/background, and camera restart behavior on the signed physical build.

## Phase 1 — pose, mapping, and 3D observations

### Scope

- typed coordinate frames and pose snapshots;
- camera intrinsics and display-orientation transforms;
- raw and smoothed depth sampling with confidence filtering;
- plane and capability-gated scene mesh observations;
- `ARWorldMap` checkpoint, checksum, secure unarchive, relocalization timeout;
- map/object metadata schema and deterministic migration;
- rolling recovery history, bounded active-map capacity, and quarantine of corrupt or detached blobs.

### Current status

Implemented and connected to the live AR session. Automated verification covers coordinate conversion, bounded surface accumulation, capability absence, session-epoch isolation, relocalization transitions, checkpoint identity, atomic persistence, interrupted publication recovery, checksum failures, migration, retention, and quarantine behavior.

### Physical acceptance

Still unconfirmed. A supported LiDAR iPhone must produce real depth/mesh observations, save a mapped checkpoint, terminate/relaunch, and relocalize in the same room without merging an unrelated session.

## Phase 2 — on-device perception, place, tracking, and identity

### Scope

- bundled Vision/Core ML detector with unavailable fallback;
- bounded inference scheduling and periodic detection/tracking correction;
- depth-backed 3D position and conservative object bounds;
- candidate selection restricted by active/adjacent place and semantic class;
- multi-signal identity scoring across semantics, geometry, space, and time;
- confidence-gated promotion from observations to durable objects;
- Known/Overlapping/New place proposals and validated map association/merge.

### Current status

Implemented. The live session feeds the bundled detector, provisional observations, depth localization, durable promotion, place fingerprints, coordinate compatibility, and map association. Missing detector/depth/identity evidence remains unavailable or provisional rather than creating a permanent object.

### Physical acceptance

Still unconfirmed. Measure supported classes, viewpoint and lighting variation, occlusion recovery, duplicate instances, movement, revisit identity, false identity merge, and false map merge on representative rooms. Model provenance and licensed distribution must also be approved before release.

## Phase 3 — deterministic search and camera-aligned guidance

### Scope

- realtime, local, and long-term object search;
- deterministic routing for object search, last seen, navigation, relation, and unsupported complex asks;
- target resolution with current-versus-last-seen semantics;
- query input, result presentation, and camera-aligned target marker/direction output.

### Current status

Implemented and enabled in the shipping surface. The bottom query field resolves local records and only publishes guidance when the target belongs to the confirmed active capture identity. Current and last-seen wording and rendering remain distinct. Network or LLM failure does not affect the result.

### Physical acceptance

Still unconfirmed. Record search and guidance behavior for current, moved, occluded, absent, last-seen, ambiguous, and incompatible-map targets, including marker registration and lifecycle clearing.

## Phase 4 — scene graph, relation questions, and furniture placement

### Scope

- versioned ON, UNDER, INSIDE, NEAR, BLOCKING, INTERSECTS, CONNECTED_TO, and ACCESSIBLE_FROM relations;
- evidence and validity windows per relation;
- deterministic relation questions and dirty-entity recomputation;
- sofa, bed, and desk candidates evaluated against support, wall, object collision, clearance, and passage evidence;
- feasible-placement result and world-space preview.

### Current status

Implemented. Durable object updates project into the scene graph, relation queries use local compatible evidence, and furniture evaluation renders a translucent preview only for a conservative feasible result. Missing object bounds, surface context, capability, or coordinate compatibility prevents approval.

### Physical acceptance

Still unconfirmed. Test relation freshness and contradiction, object-bound collisions, wall clearance, passage preservation, rotated candidates, crowded rooms, and false-positive placement approval with measured dimensions.

## Phase 5 — long-term memory, change, recovery, and deletion

### Scope

- appeared, observed, not-visible, last-seen, moved, removed, and reclassified events;
- immutable movement history separate from current presence;
- idempotent delta processing, compaction, quotas, recovery journal, and scene-graph projection recovery;
- durable negative-evidence handling across relaunch;
- clear local retention disclosure and user-controlled deletion.

### Current status

Implemented. Temporal events and current metadata are committed through a replay-safe journal, current/last-seen semantics remain queryable, and projection recovery preserves consistency after interrupted writes. Durable maps, objects, and relations remain local until the user confirms **Delete all spatial data** in settings. Replay and inference history is bounded; association attempts may rotate only when every recorded decision is deferred, while unacknowledged mutation proposals stay pinned. Raw camera frames are not part of that store.

### Physical acceptance

Still unconfirmed. Exercise relaunch, crash-boundary recovery, movement and removal history, long-running compaction, storage quotas, deletion during an active session, and fresh capture after deletion on a physical device.

## Phase 6 — verified indoor navigation

### Scope

- conservative walkable grid derived from verified LiDAR floor coverage;
- walls, classified obstacles, and mesh occupancy as blockers;
- deterministic A* routing and no-path result;
- start and target grounded to the confirmed coordinate context;
- route invalidation when map, surface revision, tracking, or obstacles change;
- camera-aligned cyan waypoint/segment rendering.

### Current status

Implemented with fail-closed evidence adaptation. Unknown or insufficient geometry, multiple floor levels, uncovered cells, excessive input, incompatible coordinates, and unverified door state do not produce a route. A route never falls back to a speculative straight arrow.

### Physical acceptance

Still unconfirmed. Test open spaces, narrow passages, moved obstacles, blocked destinations, no-path rooms, multi-level observations, doors, rerouting, positioning error, and route latency on a mapped LiDAR device. Door traversal remains unavailable until a trustworthy open/closed-state source is implemented and verified.

## Phase 7 — service release

### Remaining scope

- approve detector provenance, update strategy, class list, measured accuracy, and rollback;
- record physical-device capability and accuracy evidence;
- complete long-running migration, recovery, thermal, memory, and backlog tests;
- finish accessibility review, App Store privacy labels, signing, archive, TestFlight, and operational runbook;
- decide export scope, hardware floor, launch segment, orientation support, and final brand assets.

### Release gates

- `./Scripts/verify-ios.sh` and `./Scripts/verify-ios.sh --clean-recheck` pass on the current macOS/Xcode toolchain;
- `./Scripts/verify-core.ps1` and `./Scripts/verify-core.ps1 -CleanRecheck` pass where the Docker core verifier is used;
- Xcode build, test, analyze, signed archive, installation, and clean-checkout recheck pass;
- LiDAR and non-LiDAR behavior is recorded on physical supported devices;
- sustained-use testing shows no unbounded stream, inference, route, or persistence backlog;
- first camera frame, query latency, route latency, position error, IDF1, false identity merge, false map merge, false placement approval, and relocalization recovery meet approved targets;
- raw-frame privacy, local-until-deletion retention, dedicated-store deletion, permission text, and App Store disclosures agree;
- every physically dependent phase above has acceptance evidence.

Do not copy a fixed test count into this document. The verification commands and their current output are the source of truth as the suite evolves.

## Decisions now closed for this milestone

- Search/Ask input, relation results, placement controls, AR target guidance, feasible furniture previews, verified route paths, and spatial-data settings are allowed on the camera workflow.
- Implemented spatial reasoning remains local and deterministic; no LLM or network is required.
- Raw camera frames/video are ephemeral and are not persisted or transmitted.
- Structured spatial data is local-only and retained until explicit user deletion.
- The settings flow can delete all data in the dedicated Vispace spatial-capture store.
- Insufficient evidence and unverified door openness fail closed.

## Product and release decisions still open

- launch segment and representative deployment environments;
- whether LiDAR is mandatory for the whole app or only for placement/navigation features;
- supported device floor beyond iOS 17;
- final detector license/provenance, supported classes, binary budget, and accuracy threshold;
- optional future cloud/account synchronization and its separate consent model;
- spatial-data export scope and format;
- portrait-only versus rotation support;
- quantitative service-level and accuracy thresholds;
- final App Store icon and other approved brand assets.

None of these open decisions is silently converted into a product or physical-accuracy claim.
