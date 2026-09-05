#!/usr/bin/env python3
"""Check the manifest against Vispace's known required-reason API uses.

This source guard covers the APIs below, not arbitrary Swift or SDK behavior.
Reasons describe this app's purposes; new uses require a privacy review.
Apple reference:
https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype
"""

import argparse
from pathlib import Path
import plistlib
import re
import sys


# Disk information stays local: admission rejects insufficient space (E174.1),
# and Settings displays the available bytes (85F4.1). File timestamps are read
# only for retention inside the app container (C617.1).
API_USES = {
    "UserDefaults": (r"\bUserDefaults\b", {"CA92.1"}),
    "SystemBootTime": (r"\b(?:systemUptime|mach_absolute_time)\b", {"35F9.1"}),
    "DiskSpace": (
        r"\b(?:systemFreeSize|volumeAvailableCapacity\w*|statfs|fstatfs)\b",
        {"E174.1", "85F4.1"},
    ),
    "FileTimestamp": (
        r"\b(?:contentModificationDate(?:Key)?|creationDate(?:Key)?|"
        r"modificationDate|fileModificationDate|stat|fstat|fstatat|lstat)\b",
        {"C617.1"},
    ),
}


def verify(root: Path, manifest: Path) -> list[str]:
    with manifest.open("rb") as stream:
        payload = plistlib.load(stream)
    if not isinstance(payload, dict):
        return ["Privacy manifest root must be a dictionary"]
    entries = payload.get("NSPrivacyAccessedAPITypes")
    if not isinstance(entries, list):
        return ["NSPrivacyAccessedAPITypes must be an array"]
    declared = {}
    errors = []
    for entry in entries:
        if not isinstance(entry, dict):
            errors.append("Each accessed API entry must be a dictionary")
            continue
        category = entry.get("NSPrivacyAccessedAPIType")
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
        if not isinstance(category, str) or not isinstance(reasons, list):
            errors.append("Each accessed API entry needs a category and reasons array")
            continue
        if not reasons or any(not isinstance(reason, str) or not reason for reason in reasons):
            errors.append(f"{category}: reasons must be nonempty strings")
            continue
        if category in declared:
            errors.append(f"{category}: duplicate category")
        declared[category] = set(reasons)

    sources = sorted((root / "Vispace").rglob("*.swift"))
    sources += sorted((root / "Packages/VispaceCore/Sources").rglob("*.swift"))
    if not sources:
        return errors + ["No production Swift sources found"]
    text = "\n".join(path.read_text(encoding="utf-8") for path in sources)
    for name, (pattern, required_reasons) in API_USES.items():
        if not re.search(pattern, text):
            continue
        category = "NSPrivacyAccessedAPICategory" + name
        missing = required_reasons - declared.get(category, set())
        if missing:
            errors.append(f"{category}: missing app-use reasons {', '.join(sorted(missing))}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    manifest = args.manifest or args.root / "Vispace/Resources/PrivacyInfo.xcprivacy"
    try:
        errors = verify(args.root, manifest)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        errors = [str(error)]
    if errors:
        for error in errors:
            print(f"Privacy verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Known required-reason API uses are declared in {manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
