#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash Scripts/install-device.sh DEVICE_UUID

Build a signed Release app, verify its Apple certificate signature, install it
on the specified iPhone, and launch it. DEVICE_UUID is the CoreDevice identifier
shown by: xcrun devicectl list devices

Run this from Terminal in your logged-in Mac desktop session so macOS can show
any signing-key approval prompt. Configure your own signing team in Xcode or
the ignored Config/Signing.xcconfig before running. The connected iPhone must
be paired, unlocked, and have Developer Mode enabled.

Build output and logs are retained in a unique TestResults/device-install.*
directory. No existing build or app data is deleted by this script. Installation
and launch occur only after all preceding steps succeed.

Options:
  -h, --help  Show this help without creating files or contacting a device.
USAGE
}

if [[ $# -eq 1 && ( "$1" == '--help' || "$1" == '-h' ) ]]; then
  usage
  exit 0
fi
if [[ $# -ne 1 ]]; then
  usage >&2
  exit 64
fi

device_id="$1"
if [[ ! "$device_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
  printf 'Expected one CoreDevice UUID from xcrun devicectl list devices.\n' >&2
  exit 64
fi
if [[ "$(uname -s)" != 'Darwin' ]]; then
  printf 'Device installation requires macOS and Xcode.\n' >&2
  exit 69
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="$repo_root/Vispace.xcodeproj"
if [[ ! -d "$project_path" ]]; then
  printf 'Xcode project not found: %s\n' "$project_path" >&2
  exit 66
fi
for required_command in xcodebuild xcrun codesign; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$required_command" >&2
    exit 69
  fi
done
xcrun --find devicectl >/dev/null
xcrun --sdk iphoneos --show-sdk-path >/dev/null

result_root="$repo_root/TestResults"
mkdir -p "$result_root"
run_root="$(mktemp -d "$result_root/device-install.XXXXXX")"
derived_data="$run_root/DerivedData"
stage='detector model verification'
trap 'result=$?; if [[ $result -ne 0 ]]; then printf "Stopped during %s (exit %s). Logs: %s\n" "$stage" "$result" "$run_root" >&2; fi' EXIT

bash "$repo_root/Scripts/verify-model.sh" 2>&1 | tee "$run_root/model-verification.log"

stage='signed Release build'
printf 'Building signed Release app. Logs: %s\n' "$run_root"
if ! xcodebuild \
  -project "$project_path" \
  -scheme Vispace \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  -allowProvisioningUpdates \
  build 2>&1 | tee "$run_root/build.log"; then
  printf 'Signing failed? Approve the signing-key prompt in your Mac desktop session and rerun.\n' >&2
  printf 'Check the Xcode signing account and Config/Signing.xcconfig if the build reports a team or profile error.\n' >&2
  exit 1
fi

stage='signature verification'
app_path="$derived_data/Build/Products/Release-iphoneos/Vispace.app"
if [[ ! -d "$app_path" || ! -f "$app_path/embedded.mobileprovision" ]]; then
  printf 'The build did not produce an iPhone app with an embedded provisioning profile.\n' >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 \
  -R='anchor apple generic' "$app_path" 2>&1 | tee "$run_root/signature-verify.log"
signature_details="$(codesign --display --verbose=4 "$app_path" 2>&1)"
printf '%s\n' "$signature_details" | tee "$run_root/signature-details.log"
if printf '%s\n' "$signature_details" | grep -Eq '^Signature=adhoc|^TeamIdentifier=not set$'; then
  printf 'Refusing an ad-hoc or teamless signature. No installation was attempted.\n' >&2
  exit 1
fi
if ! printf '%s\n' "$signature_details" | grep -q '^Authority='; then
  printf 'No signing certificate authority found. No installation was attempted.\n' >&2
  exit 1
fi
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
if [[ ! "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]]; then
  printf 'The built app has an invalid bundle identifier.\n' >&2
  exit 1
fi

stage='device installation'
xcrun devicectl device install app \
  --device "$device_id" "$app_path" 2>&1 | tee "$run_root/install.log"

stage='app launch'
xcrun devicectl device process launch \
  --device "$device_id" "$bundle_id" 2>&1 | tee "$run_root/launch.log"

printf 'Vispace installed and launched on %s. Logs: %s\n' "$device_id" "$run_root"
