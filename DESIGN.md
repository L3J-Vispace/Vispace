---
name: Vispace
description: An unobstructed, edge-to-edge live camera surface for spatial capture.
colors:
  unavailable-capture: "#000000"
---

# Design System: Vispace

## Overview

**Creative North Star: "Unmediated Lens"**

Vispace treats the observed world as the interface. It removes every app-owned visual layer so live camera pixels remain unmodified and occupy the entire visible surface.

That absence is deliberate, not unfinished. Pure black is a functional fallback only while capture is unavailable; it is not a brand field, theme surface, or decorative palette.

**The Unmediated Lens Doctrine.** The observed world is the interface; app-owned visuals must never mediate the camera image.

**Key Characteristics:**

- Live camera pixels are the only visible application content.
- Capture begins as soon as system permission and hardware allow.
- App-owned interface chrome is absent in every visual state.
- Nonvisual accessibility metadata remains available without adding visible UI.

## Colors

Unavailable Capture is the sole app-owned visual token. Its role is strictly operational.

### Neutral

- **Unavailable Capture:** Pure black fills the window only before capture is ready, while capture is paused or interrupted, or after capture becomes unavailable or fails.

**The No Decorative Color Rule.** Camera pixels supply every visible color. The app contributes no tint, accent, overlay, or theme coloration.

## Layout

This system has one layout: an iPhone portrait surface that fills the full window, extends through safe-area boundaries, and sits beneath platform-owned hardware cutouts. The status bar and persistent system overlays are hidden. There are no margins, containers, grids, gutters, spacing tokens, or responsive breakpoints.

**The Every Pixel Rule.** When capture is available, the camera feed covers the full window edge to edge.

## Elevation & Depth

Vispace defines no app-owned elevation or depth. There are no shadows, materials, blur, overlays, stacked surfaces, or motion treatments; only the changing camera feed can create perceived depth or movement.

## Shapes

Vispace defines no app-owned shapes. There are no borders, dividers, masks, corner radii, icons, markers, or decorative geometry. The physical display outline and cutouts remain platform-owned.

## Components

Vispace currently has exactly one visible application surface and no visual primitive library.

### Live Camera Surface

- **Visual:** Unmodified rear-camera imagery fills the window without text, controls, overlays, or AR geometry.
- **Unavailable state:** Pure black remains visible while the camera feed cannot be shown; no app-owned explanation or recovery control is rendered.
- **Permission:** The system-owned camera permission prompt is the only permitted visible interruption.
- **Lifecycle:** Capture starts when permission and hardware permit, pauses whenever the scene is inactive or interrupted, and returns without app-owned transition motion.
- **Accessibility:** The native camera surface remains a noninteractive accessibility element labeled "Live camera" without visible text.
- **Verification:** Live-camera appearance must be verified on a physical iPhone; the iOS Simulator cannot verify production camera pixels or ARKit camera behavior. The light/default and dark/AXXXL simulator captures are intentionally identical pure black, proving only the unavailable-capture fallback and the absence of app-owned UI.

## Do's and Don'ts

### Do:

- Do let unmodified live camera pixels fill every visible pixel whenever capture is available.
- Do reserve unavailable-capture black for states in which the camera feed cannot be shown.
- Do allow the system-owned camera permission prompt to interrupt the surface when required.
- Do retain the nonvisual "Live camera" accessibility label.
- Do verify the live-camera surface on a physical iPhone.

### Don't:

- Don't add app-owned text, controls, typography, cards, chrome, HUDs, coaching, debug geometry, or AR markers.
- Don't introduce decorative color, tint, overlays, depth, borders, shapes, or motion.
- Don't add future Search/Ask or AR guidance interface until an explicit decision changes the visible contract.
