# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Stack

Delegated technical decision: a native iPhone application built with SwiftUI and Apple platform frameworks. The initial implementation uses ARKit and RealityKit for the live camera/spatial session, Vision for on-device perception seams, and Foundation for deterministic domain logic and protected local persistence. Third-party runtime dependencies are avoided until a capability demonstrably requires one.

## Users

The confirmed user is an iPhone owner who needs to search, understand, remember, or navigate a real indoor space through the phone camera. A narrower launch segment such as consumers, classrooms, offices, or facilities management is not yet decided.

## Product Purpose

Vispace continuously builds and updates a digital model of the space seen by the iPhone. It associates objects with stable identities, positions, relationships, confidence, and history so that the user can later search the physical world, ask spatial questions, and receive camera-aligned AR guidance.

Success means that the spatial engine remains useful without waiting for an LLM: deterministic search, last-seen lookup, basic relation queries, and navigation continue locally, while an LLM is an optional explanation layer for complex questions.

## Positioning

Vispace does not stop at classifying the current camera frame. Its distinct mechanism is a continuously updated LiveMap plus hierarchical spatial memory that connects what an object is, where it is, how it relates to the space, where it was, and how the user can reach it.

## Operating Context

The app is used while a person moves through indoor rooms and corridors with an iPhone camera active. The system must recognize known, overlapping, and new space; avoid duplicate maps; preserve object identity across viewpoint, lighting, occlusion, and movement; and recover from tracking, network, and LLM failures.

## Capabilities and Constraints

- The only visible application surface is the live camera. Do not add cards, toolbars, onboarding chrome, status labels, buttons, or decorative overlays unless the user explicitly changes this constraint.
- The first shipping target is iPhone only.
- The implementation must be structured for production distribution, not as a disposable prototype.
- Pose and object tracking run frequently; expensive detection, place recognition, re-identification, persistence, and LLM work are event-driven or throttled.
- Spatial facts carry confidence. Uncertain place, identity, state, or relation data stays provisional rather than being written as confirmed truth.
- Current, last-seen, moved, and removed states are distinct.
- Search, last-seen lookup, navigation, and basic relation queries must not depend on an available LLM.
- Camera/depth capability varies by iPhone. The product must use available depth and mesh features when supported and degrade safely when they are not.
- Multi-device sync, account model, launch segment, cloud boundary, retention policy, a production object-detection model, and final App Store brand assets are open product decisions.

## Brand Commitments

- Product name: Vispace.
- Visible UI commitment: the world itself is the interface; the camera image remains unobstructed.

## Evidence on Hand

- Product specification: `Vispace_프로젝트_기획서_수정1.docx` supplied by the user.
- Source repository: `https://github.com/L3J-Vispace/Vispace`.
- The repository was empty at implementation start; no existing code, visual identity, model assets, benchmarks, or production claims existed to preserve.

## Product Principles

1. See continuously, compute selectively.
2. Never turn uncertainty into a spatial fact.
3. AR output precedes optional language generation.
4. The camera view is the product surface, not a backdrop for interface chrome.
5. Local spatial capability survives network and LLM failure.

## Accessibility & Inclusion

The camera-only surface contains no custom interactive controls. System permission prompts and platform accessibility behavior remain intact. Any future interactive or explanatory layer must support VoiceOver, Dynamic Type, sufficient contrast, Reduce Motion, and non-visual alternatives to direction-only AR guidance.
