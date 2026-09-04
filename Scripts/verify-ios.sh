#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

clean_recheck=0
if [[ "${1:-}" == "--clean-recheck" ]]; then
  clean_recheck=1
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--clean-recheck]" >&2
  exit 64
fi

scheme="Vispace"
project="Vispace.xcodeproj"
result_root="$repo_root/TestResults"
xcodegen_version="2.46.0"

xcode_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
xcode_major="${xcode_version%%.*}"
if [[ -z "$xcode_major" || "$xcode_major" -lt 26 ]]; then
  echo "Vispace requires Xcode 26 or newer; selected $xcode_version." >&2
  exit 1
fi

sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
sdk_major="${sdk_version%%.*}"
if [[ -z "$sdk_major" || "$sdk_major" -lt 26 ]]; then
  echo "Vispace requires the iOS 26 SDK or newer; selected $sdk_version." >&2
  exit 1
fi

select_simulator_udid() {
  xcrun simctl list devices available --json | python3 -c '
import json, re, sys

devices = json.load(sys.stdin)["devices"]
candidates = []
for runtime, runtime_devices in devices.items():
    match = re.search(r"\.iOS-(\d+)(?:-(\d+))?(?:-(\d+))?$", runtime)
    if match is None:
        continue
    version = tuple(int(part or 0) for part in match.groups())
    for device in runtime_devices:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            candidates.append((version, device["name"], device["udid"]))

if not candidates:
    raise SystemExit("No available iPhone Simulator was found")

latest_version = max(candidate[0] for candidate in candidates)
latest = sorted(candidate for candidate in candidates if candidate[0] == latest_version)
print(latest[0][2])
'
}

simulator_udid="$(select_simulator_udid)"

run_preflight() {
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "XcodeGen $xcodegen_version is required for deterministic verification." >&2
    exit 1
  fi
  if ! xcodegen --version | grep -q "$xcodegen_version"; then
    echo "Expected XcodeGen $xcodegen_version; found $(xcodegen --version)." >&2
    exit 1
  fi

  xcodegen generate --spec project.yml
  git diff --exit-code -- Vispace.xcodeproj

  grep -q 'INFOPLIST_KEY_NSCameraUsageDescription' project.yml
  grep -q 'UIRequiredDeviceCapabilities' project.yml
  if grep -R --line-number --exclude-dir=.git \
    -E 'NSMicrophoneUsageDescription|INFOPLIST_KEY_NSMicrophoneUsageDescription' \
    project.yml Config Vispace; then
    echo 'Microphone usage description must remain absent.' >&2
    exit 1
  fi
  plutil -lint Vispace/Resources/PrivacyInfo.xcprivacy
  swift test --package-path Packages/VispaceCore --parallel
  xcodebuild \
    -resolvePackageDependencies \
    -project "$project" \
    -scheme "$scheme"
}

run_verification() {
  local suffix="$1"
  local derived="$result_root/DerivedData-$suffix"
  local archive="$result_root/Vispace-$suffix.xcarchive"
  local tests="$result_root/Tests-$suffix.xcresult"

  rm -rf "$derived" "$archive" "$tests"

  xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO \
    clean build

  xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Release \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO \
    build

  local release_binary="$derived/Build/Products/Release-iphonesimulator/Vispace.app/Vispace"
  if [[ ! -f "$release_binary" ]]; then
    echo "Release app binary was not produced at $release_binary." >&2
    exit 1
  fi
  if grep -aFq 'VispaceDisableARSession' "$release_binary"; then
    echo 'Release app binary contains the simulator-only AR session bypass.' >&2
    exit 1
  fi

  xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived" \
    -archivePath "$archive" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    archive

  xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$simulator_udid" \
    -derivedDataPath "$derived" \
    -resultBundlePath "$tests" \
    CODE_SIGNING_ALLOWED=NO \
    test

  xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO \
    analyze
}

mkdir -p "$result_root"
run_preflight
run_verification primary

if [[ "$clean_recheck" -eq 1 ]]; then
  run_preflight
  run_verification recheck
fi

echo 'Vispace iOS verification passed.'
