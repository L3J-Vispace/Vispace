# VispaceCore

`VispaceCore` is the deterministic, platform-independent domain layer for the
Vispace iPhone application. It intentionally imports neither SwiftUI nor ARKit,
so the same rules can be exercised by XCTest on macOS and Linux.

## Platform contract

- Swift tools and language mode: 6.0
- App deployment floor: iOS 17
- Runtime dependencies: Foundation only
- Public models: `Codable`, `Hashable` where meaningful, and `Sendable`
- Spatial unit: meters
- Coordinate convention: right-handed, Y-up. Adapters must attach the correct
  coordinate frame before creating domain values.
- Matrix storage: row-major 4x4 homogeneous transforms
- Time: monotonic seconds for frame/event ordering. Wall-clock dates belong in
  persistence metadata, not the realtime reducer.

## Safety invariants

1. IDs are phantom-typed UUID values, so a frame ID cannot be passed as an
   object or spatial-node ID.
2. Confidence dimensions remain separate. A strong visual score cannot promote
   a weak identity or relation score.
3. Provisional objects and relations are stored separately from confirmed
   spatial facts.
4. A delta is atomic, revision checked, and idempotent by `SpatialDeltaID`.
5. The frame scheduler runs at most one expensive job and retains only the
   newest pending frame.
6. Place overlap is validated before an existing map is updated or merged.
7. Re-identification requires both an absolute score and an ambiguity margin;
   ties stay provisional.
8. L1/L2/L3 search stops at the first tier containing a confirmed match.
9. A* ignores blocked nodes and edges. Edge cost cannot be lower than Euclidean
   distance, preserving an admissible heuristic.

## Modules in this target

- `Identifiers`, `Geometry`, `Confidence`: validated domain primitives
- `FrameAdmissionScheduler`: pure latest-frame/single-flight admission logic
- `SpatialObject`, `SpatialDeltaReducer`: object lifecycle and atomic history
- `PlaceRecognition`: Known / Overlapping / New classification
- `ObjectIdentity`: deterministic candidate ranking and merge decisions
- `SceneGraph`: provisional and confirmed spatial relations
- `SpatialMemory`: confirmed-only L1/L2/L3 lookup
- `IntentRouter`: deterministic non-LLM intent routing
- `Navigation`: deterministic A* path finding

Apple adapters should convert ARKit/Vision values at the application boundary.
No camera pixel buffer, AR anchor, Core Data context, or UI object belongs in
this package.

## Validation

From this directory:

```sh
swift test
swift test --configuration release
```

The test suite covers boundary thresholds, deterministic ties, provisional-data
isolation, atomic rollback, delta replay, stale/superseded frames, memory-tier
precedence, intent precedence, and blocked navigation paths.

## Deliberate limits

- Confidence thresholds and evidence weights are initial policy values. They
  must be versioned and recalibrated against the selected production models.
- This target does not perform camera capture, depth unprojection, persistence,
  Core ML inference, AR rendering, natural-language generation, or sync.
- The deterministic router recognizes a small Korean/English rule set; unknown
  language is routed to `complexAsk` rather than guessed.
- Spatial relation derivation assumes axis-aligned Y-up boxes. A future oriented
  bounding-box adapter may add richer geometry without changing graph storage.
