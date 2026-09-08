# Post-integration correctness and recovery audit

Baseline: `main` at `749672bc6dd43d6af7b0bf7c9c30594dc061a397`.
Scope: the user requested another code review, remediation, independent
re-review, verification, and a pull-request merge after branch consolidation.

## Confirmed Findings

| Priority | Failure | Resolution |
| --- | --- | --- |
| P1 | Low disk space prevented individual-place deletion because the visual catalog required the normal 128 MiB free-space reserve. | Use the existing reclaiming-write policy for deletion; still require room for the entire atomic replacement and preserve the original if admission fails. |
| P2 | Invalid JSON, duplicate landmarks, or invalid visual provenance repeatedly blocked place recognition and individual-place deletion. | Bounded reads and existing protected quarantine recovery for invalid catalogs; preserve I/O failures, future schemas, and unclassified oversized files in place. Include visual artifacts in the established bounded retention policy. |
| P2 | A second-ranked last-seen object could hide an equally plausible third-ranked visible object, causing an ambiguous search to return a selected coordinate. | Compare the best candidate with every remaining candidate before applying the display limit. Explicit user selection and ranking remain unchanged. |
| P2 | Guidance could retain a marker when the stored position's tracking quality degraded without another pose update. | Include source tracking quality in the periodic invalidation fence; test both limited and unavailable tracking. |
| P2 | Passage rejection used the passage confidence even when the blocking obstacle was uncertain. | Separate confirmed from possible blockage and cap the decision confidence by its evidence. Uncertain obstacles cannot erase a blockage already proved by confirmed evidence. |
| P2 | An in-memory settled-map-pair cache survived deletion, preventing reimported maps with the same IDs from establishing a fresh alignment. | Invalidate affected pairs at destructive alignment deletion and clear all pairs at whole-store deletion, including partial-failure paths. Preserve ordinary background, export, and unrelated-map deduplication. |

## Review Coverage

- Perception admission, detection/tracking, promotion, persistent identity,
  manual registration, temporal commit/recovery/correction, and relation freshness.
- Local catalog publication, corruption recovery, backup/deletion ordering,
  archive import bounds, data protection policy, and lifecycle writer barriers.
- Place fingerprints, verified coordinate alignment, map association, and
  deletion/reimport cache lifetime.
- Route evidence validation, endpoint connectors, obstacle/wall/portal checks,
  depth occupancy/history, guidance freshness, and furniture support/clearance.
- Application service wiring, camera/onboarding/recovery controls, release
  configuration, bundled model/catalog contract, privacy declaration, and CI.

Independent reviewers checked changes outside their own implementation scope.
Re-review caught two additional boundary conditions before publication:
oversized future-schema files must not enter quarantine, and partially failed
destructive deletion must not leave settled-pair caches authoritative.

## Regression Evidence

- Core Debug: 374 XCTest cases and 9 Swift Testing cases passed on Swift 6.2.
- Core Release: the same 383 cases passed with optimization.
- Native guidance, visual/storage, and manual-registration focused run:
  43 passed, 2 existing device-only skips, no failures.
- Native visual/storage recheck after oversized-file preservation:
  31 passed, 2 existing device-only skips, no failures.
- Native original-code deletion/reimport reproducer failed with merge count
  1 instead of 2. The corrected place/lifecycle focused run passed 22 cases.
- Final combined recheck of all six affected native test classes: 66 passed,
  2 existing device-only skips, no failures. The partial-deletion failure
  placement was independently reviewed in the actual service closures; no
  filesystem-failure injection seam exists in that concrete dependency graph.
- The new largest-accessibility-text registration workflow passed two initial
  repetitions and the complete registration test class, without production UI changes.
- Production, test, configuration, and Xcode project transfer was checked with
  193 matching normalized Git blobs. Swift source parsing, model SHA-256 and
  80-class contract, privacy verification, and whitespace checks passed.

The pull request records the final exact-head iOS CI result, including the
complete Simulator suite, history-rotation stress test, Debug/Release builds,
unsigned device archive, resource checks, and static analysis. Intermediate
native bundles are retained in the Mac validation checkout's
`TestResults/post-integration-audit.*` directories; they are not committed.

## Limits and Rollback

This audit does not establish the absence of every possible defect or physical
AR accuracy. The real-camera Vision feature test and effective Data Protection
test require physical iOS and remain skipped on Simulator. Real-room navigation,
relocalization, recognition accuracy, and signed release acceptance still follow
`DEVICE_ACCEPTANCE.md`.

The GitHub-hosted Core job is blocked before execution by account billing or
spending limits. Linux Debug/Release verification and native iOS CI are separate
evidence, not a claim that the blocked hosted job passed. No billing or runner
policy was changed to bypass it.

Risk: medium, because the changes affect grounding and storage recovery.
There is no storage schema migration or detector-model replacement. Revert the
integration pull request to roll back code; this does not restore data that the
user explicitly deleted. Invalid visual catalogs remain subject to the existing
quarantine retention limits rather than indefinite retention.
