# Bundled model provenance

## YOLOv3Int8LUT

- Purpose: on-device, multi-object detection for the Phase 1 spatial-observation pipeline
- Source: Apple Core ML model gallery
- Download URL: `https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3/YOLOv3Int8LUT.mlmodel`
- Retrieved: 2026-09-07
- File size: 62,200,325 bytes
- SHA-256: `0e32f297ad9cfc0ea8e67276867956488c7ee10dc87c057da4debc939e20b76d`
- Model metadata author: Joseph Redmon, Ali Farhadi
- Model metadata version: YOLOv3
- Model metadata license pointer: `https://github.com/pjreddie/darknet`
- Upstream primary license: Darknet is dedicated to the public domain and permits unrestricted use.
- Training taxonomy: 80 COCO object classes
- Input: 416 x 416 RGB image, with optional confidence and IoU thresholds
- Outputs: labeled bounding-box coordinates and confidence arrays consumed through Vision

The bundled model is Apple's quantized full YOLOv3 variant. It replaces
YOLOv3TinyInt8LUT after a reproduction on the reported desk photograph showed
that Tiny's keyboard score was below the visual-candidate threshold, while
the full model detected the keyboard, mouse, and monitor with the existing
letterbox preprocessing and runtime thresholds. This single-image comparison
does not establish general accuracy or performance on an iPhone. The model
resource grows from 8,913,366 to 62,200,325 bytes. Before a public release, its
precision, recall, latency, thermal behavior, and duplicate-instance behavior
must be measured on the approved Vispace physical-device dataset. A release
build must fail if this file's digest differs from the value above.

## Runtime detection contract

The model file is bundled exactly as downloaded. Its embedded
non-maximum-suppression defaults are confidence `0.50`, IoU `0.10`, and
suppression within each class. The application
supplies `confidenceThreshold = 0.30` and `iouThreshold = 0.45` through
`VNCoreMLModel.featureProvider`. This admits more provisional visual candidates
and avoids suppressing separate same-class boxes after only 10% overlap. These
values are engineering starting points pending physical-device precision/recall
measurements, not calibrated probabilities or an accuracy guarantee. The model's
objectness and label confidence are still multiplied as Vision specifies;
confidence is never inflated to bypass durable spatial-evidence requirements.

Before inference, Core Image applies the camera's EXIF orientation and fits the
full image into the model's input dimensions with black padding, preserving the
aspect ratio. Vision receives that exact-size canvas with `.scaleFill` and `.up`.
The app removes the known padding and scale from every returned box before depth
sampling and tracking use the original oriented camera coordinates. Partially
visible boxes are clipped to the camera image; padding-only boxes are rejected.
The raw camera image and fitted canvas remain in memory for the request only.

The supported class catalog is verified against the actual bundled model,
including legacy labels such as `tvmonitor`, `diningtable`, and `pottedplant`.
`keyboard` and `mouse` are supported. A user-defined name for an unsupported
class does not add a new automatically detectable model class.

Run `python Scripts/verify-model.py` on Windows, or `python3 Scripts/verify-model.py`
on macOS/Linux, to validate the digest, input dimensions, optional threshold
inputs and all 80 catalog labels without executing Core ML. Add `--json` to
inspect the verified metadata. `Scripts/verify-model.sh` also runs this contract
check in CI. Geometry tests run in `VispaceCore`; Apple-runtime tests additionally
check EXIF preprocessing, threshold features, result conversion and a CPU-only
blank-image Vision inference. A successful blank-image inference is not a
positive-object recognition benchmark.

Apple API references:

- [Threshold providers for Vision object detection](https://developer.apple.com/documentation/coreml/understanding-a-dice-roll-with-vision-and-object-detection)
- [Vision recognized-object confidence](https://developer.apple.com/documentation/vision/vnrecognizedobjectobservation)
- [Core ML non-maximum-suppression format](https://apple.github.io/coremltools/mlmodel/Format/NonMaximumSuppression.html)
