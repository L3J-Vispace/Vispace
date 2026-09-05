# Bundled model provenance

## YOLOv3TinyInt8LUT

- Purpose: on-device, multi-object detection for the Phase 1 spatial-observation pipeline
- Source: Apple Core ML model gallery
- Download URL: `https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyInt8LUT.mlmodel`
- Retrieved: 2026-09-04
- File size: 8,913,366 bytes
- SHA-256: `cde8af2528d6eca1d1580fdd0f0147cb6613d40ba962656b5f683c65f571870e`
- Model metadata author: Joseph Redmon, Ali Farhadi
- Model metadata version: YOLOv3-tiny
- Model metadata license pointer: `https://github.com/pjreddie/darknet`
- Upstream primary license: Darknet is dedicated to the public domain and permits unrestricted use.
- Training taxonomy: 80 COCO object classes
- Input: 416 x 416 RGB image, with optional confidence and IoU thresholds
- Outputs: labeled bounding-box coordinates and confidence arrays consumed through Vision

The quantized model is the smallest Apple-hosted YOLOv3 Tiny variant. It is an
engineering default, not an accuracy claim. Before a public release, its
precision, recall, latency, thermal behavior, and duplicate-instance behavior
must be measured on the approved Vispace physical-device dataset. A release
build must fail if this file's digest differs from the value above.
