#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
  printf 'Usage: bash Scripts/verify-model.sh\n' >&2
  exit 64
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
detector_model="$repo_root/Vispace/Resources/Models/YOLOv3TinyInt8LUT.mlmodel"
detector_sha256='cde8af2528d6eca1d1580fdd0f0147cb6613d40ba962656b5f683c65f571870e'

if [[ ! -f "$detector_model" ]]; then
  printf 'Required detector model is missing: %s\n' "$detector_model" >&2
  exit 1
fi

actual_detector_sha256="$(shasum -a 256 "$detector_model" | awk '{print $1}')"
if [[ "$actual_detector_sha256" != "$detector_sha256" ]]; then
  printf 'Detector model digest mismatch: %s\n' "$actual_detector_sha256" >&2
  exit 1
fi

printf 'Bundled detector model SHA-256 verified.\n'
python3 "$repo_root/Scripts/verify-model.py"
