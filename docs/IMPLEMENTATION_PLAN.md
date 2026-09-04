# Vispace implementation plan

## Delivery contract

The shipping iPhone surface is the live camera image only. System camera permission UI is allowed because iOS owns it. Vispace does not add controls, labels, navigation chrome, status banners, onboarding, a coaching overlay, debug geometry, or AR content in the current milestone.

The product architecture still reserves output seams for later AR arrows, markers, and paths. Those outputs remain disabled until a later requirement explicitly authorizes them.

## Technical baseline

- Platform: iPhone, iOS 17+
- Language: Swift 6 language mode with strict concurrency checks
- App shell: SwiftUI
- Camera and world tracking: ARKit `ARSession` with `ARWorldTrackingConfiguration`
- Camera rendering: RealityKit `ARView`, manually configured session
- Perception boundary: Vision and Core ML adapters; no unapproved model bundled
- Metadata persistence: Core Data-compatible repository boundary
- Large spatial artifacts: protected Application Support blobs with schema version and checksum
- Core logic: local Swift Package with no Apple UI or AR dependencies
- Runtime dependencies: Apple frameworks only

These are delegated implementation choices. They can change when device support, detector provenance, or retention requirements are confirmed.

## Cross-cutting invariants

1. Coordinate data is invalid without a coordinate-frame identifier, timestamp, tracking quality, and uncertainty.
2. Tracking IDs are temporary and never become permanent object IDs directly.
3. Place, identity, state, and relation confidence are independent signals.
4. Provisional evidence cannot mutate canonical memory.
5. Deltas are uniquely identified, revision checked, and idempotent under replay.
6. The frame queue is bounded; stale work is dropped in favor of the newest frame.
7. Raw camera frames are never written to disk.
8. LLM output cannot manufacture coordinates, distance, existence, or relation facts.
9. Capability checks are runtime checks. A non-LiDAR iPhone must not receive fake depth precision.
10. A failed relocalization starts a distinct session segment and cannot silently merge maps.

## Phase 0 — production shell and camera

### Scope

- deterministic Xcode project, build configurations, CI, and signing separation;
- full-screen `ARView` with camera permission handling;
- foreground/background and interruption lifecycle;
- manual AR session configuration with supported depth/mesh options only;
- app/container dependency boundaries, logging, privacy manifest;
- camera-only XCUITest contract;
- Linux-testable core package and verification scripts.

### Acceptance

- clean unsigned Simulator build;
- physical iPhone shows the camera with zero custom visual elements;
- denial, restriction, unsupported tracking, interruption, and restart do not crash;
- twenty foreground/background cycles do not create duplicate sessions;
- no microphone permission and no raw-frame persistence.

## Phase 1 — pose, mapping, and 3D observations

### Scope

- typed coordinate frames and pose snapshots;
- camera intrinsics and display-orientation transforms;
- raw and smoothed depth sampling with confidence filtering;
- plane and capability-gated scene mesh observations;
- `ARWorldMap` checkpoint, checksum, secure unarchive, relocalization timeout;
- map/object metadata schema v1 and migration fixture.

### Acceptance

- transform round-trip tests and fixture replays are deterministic;
- saved world map restores only after tracking returns to normal;
- corrupted or incompatible blobs are quarantined, never silently deleted;
- non-LiDAR devices expose unavailable depth rather than fabricated coordinates.

## Phase 2 — place, tracking, and identity

### Scope

- detector protocol and licensed Core ML model integration;
- Vision sequence tracking with periodic detector correction;
- candidate selection restricted by active/adjacent place and semantic class;
- multi-signal identity score: semantic, visual, geometry, spatial, temporal;
- Known/Overlapping/New place proposals;
- two-stage map merge with validation and rollback.

### Acceptance

- no single frame creates a permanent object;
- uncertain identity stays provisional;
- false identity merge and false map merge are first-class measured failures;
- lighting, viewpoint, occlusion, duplicate-instance, movement, and revisit datasets are replayable.

## Phase 3 — deterministic search and AR output seam

### Scope

- L1 realtime → L2 local → L3 long-term search;
- deterministic intent routing for object search, last seen, navigation, and relation queries;
- target resolution with current-versus-last-seen semantics;
- camera-aligned output protocol for arrows and markers, kept disabled in the shipping surface.

### Acceptance

- search result provenance identifies memory level, timestamp, and confidence;
- an absent current observation is never phrased as a current location;
- network and LLM failure do not affect deterministic queries;
- enabling an AR renderer later does not alter domain search results.

## Phase 4 — scene graph and spatial reasoning

### Scope

- temporal relations such as ON, UNDER, INSIDE, NEAR, BLOCKING, INTERSECTS, CONNECTED_TO, and ACCESSIBLE_FROM;
- evidence and validity windows per relation;
- rule-based answers for geometry and access questions;
- dirty-entity recomputation rather than whole-graph rebuilds.

### Acceptance

- relations expire or downgrade when evidence becomes stale;
- axis, distance, and occupancy thresholds are versioned policy;
- contradictory relations remain inspectable and cannot overwrite each other silently.

## Phase 5 — long-term memory and change

### Scope

- appeared, observed, not-visible, last-seen, moved, removed, and reclassified events;
- immutable movement history separate from current presence;
- delta compaction, representative feature retention, quotas, and recovery journal;
- export and deletion seams ahead of account/cloud decisions.

### Acceptance

- replaying the same delta has no effect;
- crashes at every persistence boundary recover to the last committed revision;
- data compaction preserves query-visible facts and provenance;
- retention and deletion policy is approved before production data collection.

## Phase 6 — indoor navigation

### Scope

- walkable nodes, obstacles, doors, corridors, and accessible edges;
- deterministic A* path finding and no-path result;
- route invalidation when the map or obstacle set changes;
- AR path output adapter, still separately feature-gated.

### Acceptance

- a path never crosses a blocked edge or wall to shorten distance;
- no-path is returned instead of a misleading straight arrow;
- route latency, recovery, and position error are measured on physical spaces.

## Phase 7 — service release

### Scope

- approved model provenance, update strategy, and rollback;
- privacy policy, account/sync boundary, retention, deletion, and export;
- Core Data migration matrix and long-running recovery tests;
- MetricKit diagnostics, signposts, crash reporting policy, and operational runbook;
- TestFlight, accessibility review, App Store privacy labels, signing, archive, and release automation.

### Release gates

- Xcode build, test, analyze, archive, and clean-checkout recheck pass;
- LiDAR and non-LiDAR behavior is verified on physical supported devices;
- 30-minute thermal/memory soak has no unbounded backlog or sustained memory growth;
- first camera frame p95, query latency, 3D position error p50/p95, IDF1, false identity merge, false map merge, and relocalization recovery are measured against approved targets;
- all product-open decisions below are resolved.

## Product decisions still open

- launch user and initial environment;
- whether LiDAR is required or an enhancement;
- supported device floor beyond iOS 17;
- detector classes, dataset, model license, binary size, and accuracy threshold;
- how a camera-only interface receives Search/Ask input;
- whether and when AR arrows, markers, and paths may appear;
- local-only versus account/cloud synchronization;
- spatial data retention, export, deletion, and consent;
- portrait-only versus rotation support;
- quantitative service-level and accuracy gates.
- final App Store icon and other approved brand assets.

None of these decisions is silently filled with a product claim. Phase 0 and the deterministic core proceed behind explicit capability and feature boundaries.
