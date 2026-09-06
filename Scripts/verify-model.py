#!/usr/bin/env python3
"""Read-only bundled Core ML/catalog contract check; Python standard library only.

This decodes metadata, never executes the neural network. It runs on Windows,
Linux and macOS and does not need coremltools or an Apple runtime.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys


EXPECTED_SHA256 = "cde8af2528d6eca1d1580fdd0f0147cb6613d40ba962656b5f683c65f571870e"
REPO_ROOT = Path(__file__).resolve().parent.parent
MODEL_PATH = REPO_ROOT / "Vispace/Resources/Models/YOLOv3TinyInt8LUT.mlmodel"
CATALOG_PATH = REPO_ROOT / "Packages/VispaceCore/Sources/VispaceCore/ObjectSemanticCatalog.swift"


def varint(data: bytes, position: int) -> tuple[int, int]:
    value = 0
    for shift in range(0, 70, 7):
        if position >= len(data):
            raise ValueError("Truncated protobuf varint")
        byte = data[position]
        position += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, position
    raise ValueError("Oversized protobuf varint")


def fields(data: bytes) -> list[tuple[int, int, object]]:
    """Decode only protobuf wire types used by the pinned Core ML model."""
    result = []
    position = 0
    while position < len(data):
        tag, position = varint(data, position)
        number, wire = tag >> 3, tag & 7
        if number == 0:
            raise ValueError("Invalid protobuf field number")
        if wire == 0:
            value, position = varint(data, position)
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
            if position + size > len(data):
                raise ValueError("Truncated protobuf numeric field")
            value = struct.unpack_from("<d" if wire == 1 else "<f", data, position)[0]
            position += size
        elif wire == 2:
            size, position = varint(data, position)
            if size > len(data) - position:
                raise ValueError("Truncated protobuf byte field")
            value = data[position : position + size]
            position += size
        else:
            raise ValueError(f"Unsupported protobuf wire type: {wire}")
        result.append((number, wire, value))
    return result


def one(message: list[tuple[int, int, object]], number: int, wire: int):
    values = [value for field, kind, value in message if field == number and kind == wire]
    if len(values) != 1:
        raise ValueError(f"Expected exactly one protobuf field {number} (wire {wire})")
    return values[0]


def inspect_model(data: bytes) -> dict:
    # Field numbers are from Apple's Core ML format specification:
    # https://apple.github.io/coremltools/mlmodel/Format/Model.html
    # https://apple.github.io/coremltools/mlmodel/Format/NonMaximumSuppression.html
    model = fields(data)
    description = fields(one(model, 2, 2))
    inputs = {}
    for number, wire, value in description:
        if number == 1 and wire == 2:
            feature = fields(value)
            inputs[one(feature, 1, 2).decode("utf-8")] = fields(one(feature, 3, 2))
    image_type = fields(one(inputs["image"], 4, 2))
    dimensions = [one(image_type, 1, 0), one(image_type, 2, 0)]
    for name in ("confidenceThreshold", "iouThreshold"):
        one(inputs[name], 2, 2)  # DoubleFeatureType
        if one(inputs[name], 1000, 0) != 1:
            raise ValueError(f"Model threshold input must be optional: {name}")

    pipeline = fields(one(model, 202, 2))
    suppression_models = []
    for number, wire, value in pipeline:
        if number == 1 and wire == 2:
            suppression_models.extend(
                nested for field, kind, nested in fields(value) if field == 610 and kind == 2
            )
    if len(suppression_models) != 1:
        raise ValueError("Expected one non-maximum-suppression pipeline stage")
    suppression = fields(suppression_models[0])
    label_vector = fields(one(suppression, 100, 2))
    labels = [value.decode("utf-8") for number, wire, value in label_vector if number == 1 and wire == 2]
    return {
        "sha256": hashlib.sha256(data).hexdigest(),
        "size_bytes": len(data),
        "input_dimensions": dimensions,
        "labels": labels,
        "class_count": len(labels),
        "nms_per_class": one(fields(one(suppression, 1, 2)), 1, 0) == 1,
        "model_default_iou_threshold": one(suppression, 110, 1),
        "model_default_confidence_threshold": one(suppression, 111, 1),
        "iou_threshold_input": one(suppression, 202, 2).decode("utf-8"),
        "confidence_threshold_input": one(suppression, 203, 2).decode("utf-8"),
    }


def verify(data: bytes, catalog_source: str) -> dict:
    digest = hashlib.sha256(data).hexdigest()
    if digest != EXPECTED_SHA256:
        raise ValueError(f"Detector model digest mismatch: {digest}")
    contract = inspect_model(data)
    if contract["input_dimensions"] != [416, 416]:
        raise ValueError("Unexpected detector image dimensions")
    labels = contract["labels"]
    if len(labels) != 80 or len(set(labels)) != 80:
        raise ValueError("The bundled model must contain exactly 80 distinct labels")
    # The catalog's detected(...) entries are its single source of automatic
    # classes; manual(...) entries must never be advertised as model coverage.
    catalog_labels = re.findall(r'^\s*detected\("([^"\r\n]+)"', catalog_source, re.MULTILINE)
    if catalog_labels != labels:
        missing = sorted(set(labels) - set(catalog_labels))
        extra = sorted(set(catalog_labels) - set(labels))
        raise ValueError(f"Model/catalog class contract mismatch (including order); missing={missing}, extra={extra}")
    if not contract["nms_per_class"]:
        raise ValueError("Expected class-specific non-maximum suppression")
    if contract["iou_threshold_input"] != "iouThreshold" or contract["confidence_threshold_input"] != "confidenceThreshold":
        raise ValueError("Runtime threshold provider names do not match the model")
    return contract


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Print verified model metadata and all class labels")
    args = parser.parse_args()
    try:
        contract = verify(MODEL_PATH.read_bytes(), CATALOG_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError, KeyError, UnicodeError) as error:
        print(f"Model verification failed: {error}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(contract, indent=2))
    else:
        print("Bundled detector SHA-256, 416x416 inputs, runtime threshold inputs and all 80 catalog labels verified.")
        print("This checks the model contract, not real-world recognition accuracy.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
