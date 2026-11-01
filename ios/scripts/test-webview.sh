#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -f web/out/mobile-assets.json ]] || { echo 'Build web/out before running WebKit tests' >&2; exit 1; }
output="${1:-ios/build/WebViewCI}"
[[ ! -e "$output" ]] || { echo "Output already exists: $output" >&2; exit 1; }
mkdir -p "$output"
simulator="${UCHI_SIMULATOR_ID:-}"
created=false
cleanup() {
  if [[ "$created" == true ]]; then
    xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
if [[ -z "$simulator" ]]; then
  xcrun simctl list runtimes --json > "$output/runtimes.json"
  sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
  runtime="$(python3 - "$output/runtimes.json" "$sdk" <<'PY'
import json, sys
sdk = tuple(map(int, sys.argv[2].split('.')))
available = [r for r in json.load(open(sys.argv[1]))['runtimes']
             if r.get('isAvailable') and '.iOS-' in r['identifier']
             and tuple(map(int, r['version'].split('.')))[:2] == sdk[:2]]
if not available:
    raise SystemExit('Install an iOS simulator runtime matching the selected Xcode SDK')
print(available[0]['identifier'])
PY
)"
  simulator="$(xcrun simctl create 'Uchiyomi CI' com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro "$runtime")"
  created=true
fi
xcrun simctl bootstatus "$simulator" -b
# Keep simulator signing enabled: the Keychain fixture needs it. No Apple team is needed.
xcodebuild -project ios/Uchiyomi.xcodeproj -scheme Uchiyomi -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath "$output/DerivedData" -resultBundlePath "$output/tests.xcresult" \
  ONLY_ACTIVE_ARCH=YES \
  DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- PRODUCT_BUNDLE_IDENTIFIER=org.uchiyomi.ci \
  UCHI_TEST_BUNDLE_IDENTIFIER=org.uchiyomi.ci.tests test 2>&1 | tee "$output/test.log"
