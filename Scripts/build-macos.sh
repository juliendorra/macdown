#!/usr/bin/env bash
# One test/build produces the universal app; no second archive or clean build.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -version
Scripts/check-macos-local.sh
Scripts/setup.sh
mkdir -p Artifacts
rm -rf Artifacts/MacDown.xcresult Artifacts/Diagnostics
rm -f Artifacts/MacDown-macOS.zip Artifacts/MacDown-unverified.zip
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/macdown-build.XXXXXX")
cleanup() {
  result=$?
  if (( result != 0 )); then
    mkdir -p Artifacts/Diagnostics
    # Preserve the built app for local diagnosis even when XCTest cannot boot.
    product="$work/DerivedData/Build/Products/Release/MacDown.app"
    if [[ -d "$product" ]]; then
      ditto -c -k --keepParent "$product" Artifacts/MacDown-unverified.zip || true
    fi
    reports="$HOME/Library/Logs/DiagnosticReports"
    if [[ -d "$reports" ]]; then
      find "$reports" -maxdepth 1 -type f -name 'MacDown*.ips' \
        -exec cp {} Artifacts/Diagnostics/ \; || true
    fi
  fi
  rm -rf "$work"
}
trap cleanup EXIT
xcodebuild test -workspace MacDown.xcworkspace -scheme MacDown \
  -configuration Release -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$work/DerivedData" -resultBundlePath "$PWD/Artifacts/MacDown.xcresult" \
  ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-
app="$work/DerivedData/Build/Products/Release/MacDown.app"
# The hosted test bundle is embedded by Xcode for execution, not distribution.
rm -rf "$app/Contents/PlugIns/MacDownTests.xctest" \
       "$app/Contents/PlugIns/MacDownTests.xctest.dSYM"
# Xcode also injects its test runtime into the host. None belongs in the app
# distributed to users; removing just the .xctest bundle leaves these behind.
for runtime in "$app"/Contents/Frameworks/{XCT*,XCUnit,XCUIAutomation,Testing,_Testing_*}.framework \
               "$app"/Contents/Frameworks/libXCTest*.dylib; do
  rm -rf "$runtime"
done
# Sign nested executable bundles first, then the app. This local signature
# requires no Apple account and does not claim notarization.
while IFS= read -r -d '' item; do
  codesign --force --sign - "$item"
done < <(find "$app/Contents/Frameworks" -depth \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) -print0)
codesign --force --sign - "$app/Contents/SharedSupport/bin/macdown"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
lipo "$app/Contents/MacOS/MacDown" -verify_arch arm64 x86_64
python3 Scripts/verify-app.py "$app"
# Replace only this generated app, preserving other artifacts.
rm -rf Artifacts/MacDown.app
ditto "$app" Artifacts/MacDown.app
ditto -c -k --keepParent Artifacts/MacDown.app Artifacts/MacDown-macOS.zip
printf 'Built: %s/Artifacts/MacDown.app\n' "$PWD"
