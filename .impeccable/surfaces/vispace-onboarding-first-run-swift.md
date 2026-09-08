---
version: 1
slug: "vispace-onboarding-first-run-swift"
primary_target: "Vispace/Onboarding/FirstRunOnboardingScreen.swift"
related_targets: ["Vispace/Onboarding/OnboardingState.swift","Vispace/VispaceApp.swift"]
---

Scope: `Vispace/Onboarding/FirstRunOnboardingScreen.swift` and the state gate that precedes camera capture. Visitor mode: Explanation.

Audience: an iPhone owner opening Vispace for the first time, potentially unfamiliar with spatial applications. Job: understand what the current build does, how to move the phone, and why camera access is about to be requested. Primary action: start the camera.

Proof/content: introduce the service, supported on-device object recognition and memory, local search and relations, geometric furniture checks, verified navigation, and scanning. The user should hold the phone vertically and move slowly to cover the surroundings. Data-retention explanations belong in spatial-data settings, not this introduction. Starting capture invokes the system-owned camera permission flow.

Constraints: appear only until the versioned completion preference is stored; never mount CameraScreen or activate ARSessionController behind the guidance; use one screen and one primary action; make all content scrollable at AXXXL; localize English and Korean copy through string catalogs; use system text styles, semantic colors, native controls, and SF Symbols. Distinguish implemented evidence-gated features from unverified real-room accuracy, unsupported detector classes, and unimplemented free-form style AI.

Direction: Calm Threshold. One opaque, spacious native surface prepares the user, then gets out of the way permanently. No cards, illustration, pager, decorative motion, or camera overlay.

Unresolved: final App Store icon and broader brand assets.
